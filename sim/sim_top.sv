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
	input  [10:0] ps2_key,

	// Disk images (hps_io's SD interface, flattened for the C++ testbench)
	input   [1:0] img_mounted,
	input   [1:0] img_readonly,
	input  [63:0] img_size,
	output [31:0] sd_lba0,
	output [31:0] sd_lba1,
	output  [1:0] sd_rd,
	output  [1:0] sd_wr,
	input   [1:0] sd_ack,
	input   [8:0] sd_buff_addr,
	input   [7:0] sd_buff_dout,
	input         sd_buff_wr,
	output  [7:0] sd_buff_din0,
	output  [7:0] sd_buff_din1,

	output        m1_n,
	output        mreq_n,
	output        rd_n,
	output [15:0] addr,
	output  [7:0] din,
	output  [7:0] dout,
	output        iorq_n,
	output        wr_n,
	output  [7:0] sys_latch,

	output  [9:0] audio,
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
wire [31:0] sd_lba[2];
assign sd_lba0 = sd_lba[0];
assign sd_lba1 = sd_lba[1];
wire  [7:0] sd_buff_din[2];
assign sd_buff_din0 = sd_buff_din[0];
assign sd_buff_din1 = sd_buff_din[1];

tiki100 core
(
	.clk(clk),
	.reset(reset),
	.rom_wr(rom_wr),
	.prom_wr(prom_wr),
	.dl_addr(dl_addr),
	.dl_data(dl_data),
	.ps2_key(ps2_key),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
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
	.audio(audio),
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
