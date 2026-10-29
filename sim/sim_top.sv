// Simulation wrapper: instantiates the core and exposes the CPU bus
// so the C++ testbench can trace instruction fetches.

module sim_top
(
	input         clk,
	input         reset,
	input         rom_wr,
	input         prom_wr,
	input  [12:0] dl_addr,
	input   [7:0] dl_data,

	output        m1_n,
	output        mreq_n,
	output        rd_n,
	output [15:0] addr,
	output  [7:0] din,
	output  [7:0] sys_latch
);

tiki100 core
(
	.clk(clk),
	.reset(reset),
	.rom_wr(rom_wr),
	.prom_wr(prom_wr),
	.dl_addr(dl_addr),
	.dl_data(dl_data),
	.key_col(),
	.key_row(8'hFF),
	.sys_latch(sys_latch),
	.video_mode(),
	.palette_val(),
	.scroll()
);

assign m1_n   = core.cpu_m1_n;
assign mreq_n = core.cpu_mreq_n;
assign rd_n   = core.cpu_rd_n;
assign addr   = core.cpu_a;
assign din    = core.cpu_di;

endmodule
