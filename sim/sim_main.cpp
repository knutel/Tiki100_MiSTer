// Tiki 100 core testbench.
//
// Loads the boot ROM and banking PROM through the core's download port,
// releases reset and runs the core. It can:
//   - write the address of every executed instruction to a trace file, one
//     hex address per line, in the same order as MAME's debugger trace;
//   - save video frames (the visible 1024 x 256 area) as PPM images.
//
// Usage: Vsim_top <boot.rom> <boot1.rom> [options]
//   --trace FILE        write the instruction trace to FILE
//   --instructions N    stop after N instructions
//   --frames N          stop after N video frames
//   --dump K            save frame K (repeatable) as frame_KKKK.ppm
//   --outdir DIR        where to save frames (default .)
//
// Debug switches (environment variables):
//   TRACE_BYTES=1  print the first 20 opcode fetches with the byte read
//   TRACE_BUS=1    print the CPU bus for the first 60 clocks after reset
//   TRACE_LATCH=1  print every system latch change

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>
#include <vector>
#include "Vsim_top.h"
#include "verilated.h"

static const int WIDTH = 1024, HEIGHT = 256;

static std::vector<unsigned char> load(const char *path)
{
	FILE *f = fopen(path, "rb");
	if (!f) { perror(path); exit(1); }
	std::vector<unsigned char> d;
	int c;
	while ((c = fgetc(f)) != EOF) d.push_back(c);
	fclose(f);
	return d;
}

static void save_ppm(const std::string &path, const std::vector<unsigned char> &rgb)
{
	FILE *f = fopen(path.c_str(), "wb");
	if (!f) { perror(path.c_str()); exit(1); }
	fprintf(f, "P6\n%d %d\n255\n", WIDTH, HEIGHT);
	fwrite(rgb.data(), 1, rgb.size(), f);
	fclose(f);
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: %s boot.rom boot1.rom [--trace FILE] [--instructions N] "
		                "[--frames N] [--dump K]... [--outdir DIR]\n", argv[0]);
		return 1;
	}
	std::vector<unsigned char> rom  = load(argv[1]);
	std::vector<unsigned char> prom = load(argv[2]);

	FILE *trace = nullptr;
	long max_instr = -1, max_frames = -1;
	std::set<long> dump;
	std::string outdir = ".";
	for (int i = 3; i < argc; i += 2) {
		std::string a = argv[i];
		const char *v = (i + 1 < argc) ? argv[i + 1] : nullptr;
		if (!v) { fprintf(stderr, "%s needs a value\n", a.c_str()); return 1; }
		if      (a == "--trace")        { trace = fopen(v, "w"); if (!trace) { perror(v); return 1; } }
		else if (a == "--instructions") max_instr = atol(v);
		else if (a == "--frames")       max_frames = atol(v);
		else if (a == "--dump")         dump.insert(atol(v));
		else if (a == "--outdir")       outdir = v;
		else { fprintf(stderr, "unknown option %s\n", a.c_str()); return 1; }
	}
	if (max_instr < 0 && max_frames < 0) max_frames = 1;

	Verilated::commandArgs(argc, argv);
	Vsim_top *top = new Vsim_top;

	auto tick = [&]() {
		top->clk = 0; top->eval();
		top->clk = 1; top->eval();
	};

	// Download ROMs with the CPU held in reset, like hps_io does on the MiSTer.
	top->reset = 1;
	for (int i = 0; i < 20; i++) tick();
	for (size_t i = 0; i < rom.size() && i < 8192; i++) {
		top->dl_addr = i; top->dl_data = rom[i]; top->rom_wr = 1; tick();
	}
	top->rom_wr = 0;
	for (size_t i = 0; i < prom.size() && i < 256; i++) {
		top->dl_addr = i; top->dl_data = prom[i]; top->prom_wr = 1; tick();
	}
	top->prom_wr = 0;
	for (int i = 0; i < 20; i++) tick();
	top->reset = 0;

	// Instruction trace state. An opcode fetch is M1 + MREQ + RD. Record its
	// address and the byte read, and log the address when the byte starts a
	// new instruction. DD/FD and a first CB/ED are prefixes: the next M1 fetch
	// belongs to the same instruction. (DD CB d op fetches d and op without M1.)
	long count = 0;
	bool in_fetch = false, prefixed = false;
	unsigned fetch_addr = 0, fetch_byte = 0;
	unsigned last_latch = 0;

	// Video capture state. Pixels are taken on ce_pix outside blanking; a frame
	// ends at the start of vertical blanking.
	std::vector<unsigned char> frame(WIDTH * HEIGHT * 3);
	long frames = 0;
	int x = 0, y = 0;
	bool last_hblank = true, last_vblank = true, last_vsync = false;
	unsigned long long last_vsync_clk = 0;

	unsigned long long cycles = 0;
	for (;;) {
		tick();
		cycles++;

		if (getenv("TRACE_BUS") && cycles < 60)
			fprintf(stderr, "clk %3llu  A=%04X m1=%d mreq=%d rd=%d di=%02X\n", cycles,
			        top->addr, top->m1_n, top->mreq_n, top->rd_n, top->din);

		bool fetch = !top->m1_n && !top->mreq_n && !top->rd_n;
		if (fetch) {
			if (!in_fetch) fetch_addr = top->addr;
			fetch_byte = top->din;
		}
		else if (in_fetch) {
			if (getenv("TRACE_BYTES") && count < 20)
				fprintf(stderr, "fetch %04X = %02X\n", fetch_addr, fetch_byte);
			if (!prefixed) {
				if (trace) fprintf(trace, "%04X\n", fetch_addr);
				count++;
			}
			prefixed = (fetch_byte == 0xDD || fetch_byte == 0xFD) ||
			           ((fetch_byte == 0xCB || fetch_byte == 0xED) && !prefixed);
		}
		in_fetch = fetch;

		if (top->sys_latch != last_latch) {
			if (getenv("TRACE_LATCH"))
				fprintf(stderr, "instr %ld: system latch = %02X\n", count, top->sys_latch);
			last_latch = top->sys_latch;
		}

		if (top->ce_pix) {
			if (!top->hblank && !top->vblank) {
				if (x < WIDTH && y < HEIGHT) {
					unsigned char *p = &frame[(y * WIDTH + x) * 3];
					p[0] = top->vga_r; p[1] = top->vga_g; p[2] = top->vga_b;
				}
				x++;
			}
			if (top->hblank && !last_hblank) {
				if (!top->vblank && x != WIDTH)
					fprintf(stderr, "frame %ld line %d: %d pixels\n", frames, y, x);
				x = 0;
				if (!top->vblank) y++;
			}
			if (top->vblank && !last_vblank) {
				if (y != HEIGHT) fprintf(stderr, "frame %ld: %d lines\n", frames, y);
				if (dump.count(frames)) {
					char name[32];
					snprintf(name, sizeof name, "/frame_%04ld.ppm", frames);
					save_ppm(outdir + name, frame);
				}
				frames++;
				y = 0;
			}
			if (top->vsync && !last_vsync) {
				if (last_vsync_clk && frames == 2)
					fprintf(stderr, "frame period: %llu clocks (%.3f Hz)\n",
					        cycles - last_vsync_clk, 40e6 / (cycles - last_vsync_clk));
				last_vsync_clk = cycles;
			}
			last_hblank = top->hblank;
			last_vblank = top->vblank;
			last_vsync  = top->vsync;
		}

		if (max_instr >= 0 && count >= max_instr) break;
		if (max_frames >= 0 && frames >= max_frames) break;
	}

	fprintf(stderr, "%ld instructions, %ld frames, %llu clocks (%.3f s at 40 MHz)\n",
	        count, frames, cycles, cycles / 40e6);
	if (trace) fclose(trace);
	top->final();
	delete top;
	return 0;
}
