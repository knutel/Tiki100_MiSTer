// Tiki 100 core testbench.
//
// Loads the boot ROM and banking PROM through the core's download port,
// releases reset and writes the address of every executed instruction to a
// trace file, one hex address per line, in the same order as MAME's
// debugger trace.
//
// Usage: Vsim_top <boot.rom> <boot1.rom> <trace.txt> <instructions>
//
// Debug switches (environment variables):
//   TRACE_BYTES=1  print the first 20 opcode fetches with the byte read
//   TRACE_BUS=1    print the CPU bus for the first 60 clocks after reset

#include <cstdio>
#include <cstdlib>
#include <vector>
#include "Vsim_top.h"
#include "verilated.h"

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

int main(int argc, char **argv)
{
	if (argc < 5) {
		fprintf(stderr, "usage: %s boot.rom boot1.rom trace.txt instructions\n", argv[0]);
		return 1;
	}
	std::vector<unsigned char> rom  = load(argv[1]);
	std::vector<unsigned char> prom = load(argv[2]);
	FILE *trace = fopen(argv[3], "w");
	if (!trace) { perror(argv[3]); return 1; }
	long limit = atol(argv[4]);

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

	// An opcode fetch is M1 + MREQ + RD. Record its address and the byte read,
	// and log the address when the byte starts a new instruction. DD/FD and
	// a first CB/ED are prefixes: the next M1 fetch belongs to the same
	// instruction. (DD CB d op fetches d and op without M1.)
	long count = 0;
	unsigned long long cycles = 0;
	bool in_fetch = false, prefixed = false;
	unsigned fetch_addr = 0, fetch_byte = 0;
	unsigned last_latch = 0;

	while (count < limit) {
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
				fprintf(trace, "%04X\n", fetch_addr);
				count++;
			}
			prefixed = (fetch_byte == 0xDD || fetch_byte == 0xFD) ||
			           ((fetch_byte == 0xCB || fetch_byte == 0xED) && !prefixed);
		}
		in_fetch = fetch;

		if (top->sys_latch != last_latch) {
			fprintf(stderr, "instr %ld: system latch = %02X\n", count, top->sys_latch);
			last_latch = top->sys_latch;
		}

		if (cycles > (unsigned long long)limit * 1000) {
			fprintf(stderr, "stopped: too many cycles without enough instructions\n");
			break;
		}
	}

	fprintf(stderr, "%ld instructions, %llu clocks (%.3f s at 40 MHz)\n",
	        count, cycles, cycles / 40e6);
	fclose(trace);
	top->final();
	delete top;
	return 0;
}
