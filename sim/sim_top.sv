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
	input         loopback,     // connect each DART channel's TxD to its RxD

	output        m1_n,
	output        mreq_n,
	output        rd_n,
	output [15:0] addr,
	output  [7:0] din,
	output  [7:0] dout,
	output        iorq_n,
	output        wr_n,
	output  [7:0] sys_latch,

	output        ce_pix,
	output  [7:0] vga_r,
	output  [7:0] vga_g,
	output  [7:0] vga_b,
	output        hsync,
	output        vsync,
	output        hblank,
	output        vblank
);

wire [1:0] ser_txd;

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
	.ser_rxd(loopback ? ser_txd : 2'b11),
	.ser_txd(ser_txd),
	.ser_cts_n(2'b00),
	.ser_dcd_n(2'b00),
	.ser_rts_n(),
	.ser_dtr_n(),
	.par_data(),
	.par_strobe(),
	.par_ack(1'b1),
	.par_busy(1'b0),
	.par_perror(1'b1),
	.tape_out(),
	.tape_in(1'b0),
	.ce_pix(ce_pix),
	.vga_r(vga_r),
	.vga_g(vga_g),
	.vga_b(vga_b),
	.hsync(hsync),
	.vsync(vsync),
	.hblank(hblank),
	.vblank(vblank)
);

assign m1_n   = core.cpu_m1_n;
assign mreq_n = core.cpu_mreq_n;
assign rd_n   = core.cpu_rd_n;
assign addr   = core.cpu_a;
assign din    = core.cpu_di;
assign dout   = core.cpu_do;
assign iorq_n = core.cpu_iorq_n;
assign wr_n   = core.cpu_wr_n;

endmodule
