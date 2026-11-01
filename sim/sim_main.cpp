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
//   --results FILE      write every byte the CPU writes to port FF (the
//                       test ROMs' result port) to FILE, one hex byte per line
//   --loopback 1        connect each DART channel's TxD to its RxD
//   --printer-sync 1    put VSYNC and HSYNC on printer data lines D0 and D1
//                       (the OSD's Printer port sync option)
//   --wav FILE          record the sound output (mono, 16 bits, 50 kHz)
//   --drive-sound 0     turn off the floppy motor and step sounds (the OSD's
//                       Drive sounds option, on by default)
//   --disk0 FILE        mount a disk image in drive A (--disk1: drive B).
//                       Writes change only the copy in memory.
//   --save0 FILE        at the end, save drive A's image with the writes
//                       (--save1: drive B)
//   --readonly0 1       mount drive A's image read-only (--readonly1: B)
//   --hdd FILE          mount a hard disk image (306 cylinders, 4 heads, 17
//                       sectors of 512 bytes; see tests/make_hd_image.py).
//                       --savehdd FILE and --readonlyhdd 1 as for drive A
//   --boot2 FILE        load a second boot ROM (like boot2.rom on the MiSTer;
//                       --boot3: a third, like boot3.rom)
//   --bootrom N         run boot ROM N: 0 = the first argument, 1 = --boot2,
//                       2 = --boot3 (the OSD's Boot ROM option)
//   --switch-rom F:N    at the start of frame F, reset and switch to boot ROM
//                       N, like changing the OSD option on the MiSTer
//   --reset F:C         at the start of frame F, reset: C = 0 for a warm reset
//                       (the OSD's Reset, RAM kept), 1 for a power-on reset
//                       (the MiSTer's reset button, RAM filled again)
//   --keys FILE         PS/2 key events, one per line: "frame scancode 1|0"
//                       (1 = press, 0 = release). The scancode is set 2 hex,
//                       with E0 in front for extended keys, e.g. "300 32 1"
//                       presses B at the start of frame 300, "310 E06B 0"
//                       releases left arrow.
//
// Debug switches (environment variables):
//   TRACE_BYTES=1  print the first 20 opcode fetches with the byte read
//   TRACE_BUS=1    print the CPU bus for the first 60 clocks after reset
//   TRACE_LATCH=1  print every system latch change
//   TRACE_FDC=FILE log floppy controller (ports 10-13, except data reads)
//                  and hard disk controller (ports 21-27) accesses
//                  and system latch accesses to FILE, like MAME's tap

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
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

	FILE *trace = nullptr, *results = nullptr;
	bool loopback = false;
	bool printer_sync = false;
	bool drive_sound = true;
	std::vector<unsigned char> disk[3];      // drive A, drive B, hard disk
	std::vector<unsigned char> boot[3];
	boot[0] = rom;
	unsigned bootrom = 0;
	long switch_frame = -1;
	long reset_frame = -1;
	unsigned reset_cold = 0;
	unsigned switch_rom = 0;
	std::string save[3];
	unsigned readonly = 0;
	FILE *wav = nullptr;
	unsigned long wav_samples = 0;
	struct KeyEvent { long frame; unsigned ps2; };
	std::deque<KeyEvent> keys;      // in file order
	std::deque<unsigned> key_queue; // due, waiting to be sent
	unsigned long long last_key_clk = 0;
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
		else if (a == "--results")      { results = fopen(v, "w"); if (!results) { perror(v); return 1; } }
		else if (a == "--loopback")     loopback = atoi(v) != 0;
		else if (a == "--printer-sync") printer_sync = atoi(v) != 0;
		else if (a == "--drive-sound")  drive_sound = atoi(v) != 0;
		else if (a == "--disk0")        disk[0] = load(v);
		else if (a == "--wav")          { wav = fopen(v, "wb"); if (!wav) { perror(v); return 1; } fseek(wav, 44, SEEK_SET); }
		else if (a == "--disk1")        disk[1] = load(v);
		else if (a == "--boot2")        boot[1] = load(v);
		else if (a == "--boot3")        boot[2] = load(v);
		else if (a == "--bootrom")      bootrom = atoi(v);
		else if (a == "--reset")        { if (sscanf(v, "%ld:%u", &reset_frame, &reset_cold) != 2) { fprintf(stderr, "--reset F:C\n"); return 1; } }
		else if (a == "--switch-rom")   { if (sscanf(v, "%ld:%u", &switch_frame, &switch_rom) != 2) { fprintf(stderr, "--switch-rom F:N\n"); return 1; } }
		else if (a == "--save0")        save[0] = v;
		else if (a == "--save1")        save[1] = v;
		else if (a == "--readonly0")    readonly = (readonly & ~1u) | (atoi(v) ? 1 : 0);
		else if (a == "--readonly1")    readonly = (readonly & ~2u) | (atoi(v) ? 2 : 0);
		else if (a == "--hdd")          disk[2] = load(v);
		else if (a == "--savehdd")      save[2] = v;
		else if (a == "--readonlyhdd")  readonly = (readonly & ~4u) | (atoi(v) ? 4 : 0);
		else if (a == "--keys") {
			FILE *f = fopen(v, "r");
			if (!f) { perror(v); return 1; }
			long frame; char code[16]; int press;
			while (fscanf(f, "%ld %15s %d", &frame, code, &press) == 3) {
				unsigned c = strtoul(code, nullptr, 16);
				unsigned ev = (press ? 0x200 : 0) | (c > 0xFF ? 0x100 : 0) | (c & 0xFF);
				keys.push_back({frame, ev});
			}
			fclose(f);
		}
		else { fprintf(stderr, "unknown option %s\n", a.c_str()); return 1; }
	}
	if (max_instr < 0 && max_frames < 0) max_frames = 1;

	Verilated::commandArgs(argc, argv);
	Vsim_top *top = new Vsim_top;
	top->loopback = loopback;
	top->printer_sync = printer_sync;
	top->drive_sound = drive_sound;

	auto tick = [&]() {
		top->clk = 0; top->eval();
		top->clk = 1; top->eval();
	};

	// Download ROMs with the CPU held in reset, like hps_io does on the MiSTer.
	top->reset = 1;
	for (int i = 0; i < 20; i++) tick();
	for (int r = 0; r < 3; r++) {
		top->rom_slot = r;
		for (size_t i = 0; i < boot[r].size() && i < 8192; i++) {
			top->dl_addr = i; top->dl_data = boot[r][i]; top->rom_wr = 1; tick();
		}
		top->rom_wr = 0;
	}
	top->rom_sel = bootrom;
	for (size_t i = 0; i < prom.size() && i < 256; i++) {
		top->dl_addr = i; top->dl_data = prom[i]; top->prom_wr = 1; tick();
	}
	top->prom_wr = 0;
	for (int i = 0; i < 20; i++) tick();
	top->reset = 0;

	// Disk images: mount them like hps_io does (img_mounted pulses with
	// img_size valid), then serve 512-byte sector reads on sd_rd: raise
	// sd_ack, write the block into the core's buffer through
	// sd_buff_addr/dout/wr, drop sd_ack. Writes on sd_wr work the same way,
	// but read the block from the core's buffer on sd_buff_din.
	for (int d = 0; d < 3; d++) {
		if (disk[d].empty()) continue;
		top->img_size = disk[d].size();
		top->img_readonly = readonly;
		top->img_mounted = 1 << d;
		for (int i = 0; i < 10; i++) tick();
		top->img_mounted = 0;
		for (int i = 0; i < 10; i++) tick();
	}
	int sd_drive = -1;      // drive being served
	long sd_pos = -1;       // clocks since the request (-1: idle)
	unsigned sd_lba = 0;
	bool sd_write = false;
	auto sd_step = [&]() {
		if (sd_pos < 0) {
			for (int d = 0; d < 3; d++) {
				if (top->sd_rd & (1 << d) || top->sd_wr & (1 << d)) {
					sd_drive = d;
					sd_lba = d == 2 ? top->sd_lba2 : d ? top->sd_lba1 : top->sd_lba0;
					sd_write = !(top->sd_rd & (1 << d));
					sd_pos = 0;
					break;
				}
			}
			return;
		}
		sd_pos++;
		long t = sd_pos - 200;          // some latency, like the ARM side
		top->sd_buff_wr = 0;
		std::vector<unsigned char> &img = disk[sd_drive];
		if (t == 0) top->sd_ack = 1 << sd_drive;
		else if (t > 0 && t <= 1024 && sd_write) {
			// Set the address on odd clocks, take the byte on even ones
			// (the core's buffer is a synchronous RAM)
			unsigned i = (t - 1) / 2;
			size_t off = (size_t)sd_lba * 512 + i;
			if (t & 1) top->sd_buff_addr = i;
			else if (off < img.size()) img[off] = sd_drive == 2 ? top->sd_buff_din2 : sd_drive ? top->sd_buff_din1 : top->sd_buff_din0;
		}
		else if (t > 0 && t <= 1024 && (t & 1)) {
			unsigned i = (t - 1) / 2;
			size_t off = (size_t)sd_lba * 512 + i;
			top->sd_buff_addr = i;
			top->sd_buff_dout = off < img.size() ? img[off] : 0;
			top->sd_buff_wr = 1;
		}
		else if (t == 1100) top->sd_ack = 0;
		else if (t > 1200) sd_pos = -1;
	};

	// Instruction trace state. An opcode fetch is M1 + MREQ + RD. Record its
	// address and the byte read, and log the address when the byte starts a
	// new instruction. DD/FD and a first CB/ED are prefixes: the next M1 fetch
	// belongs to the same instruction. (DD CB d op fetches d and op without M1.)
	long count = 0;
	bool in_fetch = false, prefixed = false;
	unsigned fetch_addr = 0, fetch_byte = 0;
	unsigned long long fetch_clk = 0, instr_clk = 0;
	bool trace_cycles = getenv("TRACE_CYCLES") != nullptr;   // add the CPU cycle count to each trace line
	unsigned last_latch = 0;
	bool last_io_write = false;
	bool last_io_acc = false, io_wr = false;
	unsigned io_port = 0, io_val = 0;
	FILE *fdc_log = getenv("TRACE_FDC") ? fopen(getenv("TRACE_FDC"), "w") : nullptr;

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
		sd_step();

		// Sound: one sample every 800 clocks (50 kHz), the 10-bit unsigned
		// mix scaled to signed 16 bits
		if (wav && cycles % 800 == 0) {
			int16_t v = (int16_t)(top->audio * 16 - 32768);
			fwrite(&v, 2, 1, wav);
			wav_samples++;
		}

		if (getenv("TRACE_BUS") && cycles < 60)
			fprintf(stderr, "clk %3llu  A=%04X m1=%d mreq=%d rd=%d di=%02X\n", cycles,
			        top->addr, top->m1_n, top->mreq_n, top->rd_n, top->din);

		bool fetch = !top->m1_n && !top->mreq_n && !top->rd_n;
		if (fetch) {
			if (!in_fetch) { fetch_addr = top->addr; fetch_clk = cycles; }
			fetch_byte = top->din;
		}
		else if (in_fetch) {
			if (getenv("TRACE_BYTES") && count < 20)
				fprintf(stderr, "fetch %04X = %02X\n", fetch_addr, fetch_byte);
			if (!prefixed) instr_clk = fetch_clk;
			if (!prefixed) {
				if (trace && trace_cycles) fprintf(trace, "%04X %llu\n", fetch_addr, instr_clk / 10);
				else if (trace)            fprintf(trace, "%04X\n", fetch_addr);
				count++;
			}
			prefixed = (fetch_byte == 0xDD || fetch_byte == 0xFD) ||
			           ((fetch_byte == 0xCB || fetch_byte == 0xED) && !prefixed);
		}
		in_fetch = fetch;

		// Send queued key events like hps_io: bit 10 toggles for each event.
		// Space them out so the core sees each one.
		if (!key_queue.empty() && cycles - last_key_clk > 1000) {
			top->ps2_key = ((top->ps2_key ^ 0x400) & 0x400) | key_queue.front();
			key_queue.pop_front();
			last_key_clk = cycles;
		}

		bool io_write = !top->iorq_n && !top->wr_n;
		if (io_write && !last_io_write && results && (top->addr & 0xFF) == 0xFF) {
			fprintf(results, "%02X\n", top->dout);
			fflush(results);
		}
		last_io_write = io_write;

		// Log at the end of each I/O access, when the read data is final
		bool io_acc = !top->iorq_n && top->m1_n;
		if (io_acc) { io_port = top->addr & 0xFF; io_wr = !top->wr_n; io_val = io_wr ? top->dout : top->din; }
		else if (last_io_acc && fdc_log) {
			bool fdc = io_port >= 0x10 && io_port <= 0x13 && !(io_port == 0x13 && !io_wr);
			bool hdc = io_port >= 0x21 && io_port <= 0x27;
			if (fdc || hdc || (io_port >= 0x1C && io_port <= 0x1F))
				fprintf(fdc_log, "%c %02X %02X %.6f\n", io_wr ? 'W' : 'R', io_port, io_val, cycles / 40e6);
		}
		last_io_acc = io_acc;

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
				if (frames == switch_frame) {
					// Tiki100.sv holds reset until the core has the new selection
					top->reset = 1;
					tick(); cycles++;
					top->rom_sel = switch_rom;
					tick(); cycles++;
					top->reset = 0;
				}
				if (frames == reset_frame) {
					top->reset = 1;
					top->cold_reset = reset_cold;
					tick(); cycles++;
					tick(); cycles++;
					top->reset = 0;
					top->cold_reset = 0;
				}
				while (!keys.empty() && keys.front().frame <= frames) {
					key_queue.push_back(keys.front().ps2);
					keys.pop_front();
				}
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
	if (results) fclose(results);
	for (int d = 0; d < 3; d++) {
		if (save[d].empty()) continue;
		FILE *f = fopen(save[d].c_str(), "wb");
		if (!f) { perror(save[d].c_str()); return 1; }
		fwrite(disk[d].data(), 1, disk[d].size(), f);
		fclose(f);
	}
	if (wav) {
		// RIFF header for 16-bit mono PCM at 50 kHz
		auto u32 = [&](uint32_t x) { fwrite(&x, 4, 1, wav); };
		auto u16 = [&](uint16_t x) { fwrite(&x, 2, 1, wav); };
		fseek(wav, 0, SEEK_SET);
		fwrite("RIFF", 1, 4, wav); u32(36 + wav_samples * 2); fwrite("WAVEfmt ", 1, 8, wav);
		u32(16); u16(1); u16(1); u32(50000); u32(100000); u16(2); u16(16);
		fwrite("data", 1, 4, wav); u32(wav_samples * 2);
		fclose(wav);
	}
	top->final();
	delete top;
	return 0;
}
