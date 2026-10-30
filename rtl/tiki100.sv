`default_nettype none
//============================================================================
//  Tiki 100 core
//
//  Z80 CPU, ROM, RAM, video RAM, PROM-based memory banking, system latch
//  and I/O decoding. Modelled on MAME's tiki100 driver (src/mame/tiki/).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module tiki100
(
	input         clk,          // 40 MHz clk_sys
	input         reset,

	// ROM loading. The CPU must be held in reset while these are written.
	input         rom_wr,       // boot ROM byte (8 KB)
	input         prom_wr,      // banking PROM byte (256 B, only the first 64 are used)
	input  [12:0] dl_addr,
	input   [7:0] dl_data,

	// Keyboard: PS/2 key events from hps_io
	input  [10:0] ps2_key,

	// Floppy disk images through hps_io's SD interface (VDNUM=2), drive 0 in
	// bit 0 / element 0. Images are raw sector dumps as in MAME's tiki100
	// software list: 512-byte sectors, 10 (or 9) per track, track by track
	// and side by side.
	input   [1:0] img_mounted,
	input  [63:0] img_size,
	output [31:0] sd_lba[2],
	output  [1:0] sd_rd,
	output  [1:0] sd_wr,
	input   [1:0] sd_ack,
	input   [8:0] sd_buff_addr,
	input   [7:0] sd_buff_dout,
	output  [7:0] sd_buff_din[2],
	input         sd_buff_wr,

	// System latch (ports 1C-1F): drive select, ROME, VIRE, density, LEDs, motor
	output  [7:0] sys_latch,

	// Serial ports (DART): channel A in bit 0, channel B in bit 1
	input   [1:0] ser_rxd,
	output  [1:0] ser_txd,
	input   [1:0] ser_cts_n,
	input   [1:0] ser_dcd_n,
	output  [1:0] ser_rts_n,
	output  [1:0] ser_dtr_n,

	// Centronics printer and cassette (PIO)
	output  [7:0] par_data,
	output        par_strobe,
	input         par_ack,
	input         par_busy,
	input         par_perror,
	output        tape_out,
	input         tape_in,

	// Video, 20 MHz dot clock enable on clk
	output        ce_pix,
	output  [7:0] vga_r,
	output  [7:0] vga_g,
	output  [7:0] vga_b,
	output        hsync,
	output        vsync,        // also the hook for demos that read VSYNC on a PIO pin (MAME TODO)
	output        hblank,
	output        vblank
);

////////////////////////////////////////////////////////////////////////////////
// Clock enables
//
// The real CPU runs at 4 MHz. Instead of a separate 4 MHz clock we keep the
// whole design on clk_sys and give the CPU two enable pulses every 10 clocks:
// one for the rising edge of its virtual clock and one for the falling edge.

reg [3:0] cpu_div;
always @(posedge clk) cpu_div <= (cpu_div == 4'd9) ? 4'd0 : cpu_div + 4'd1;

wire cpu_cen_p = (cpu_div == 4'd0);
wire cpu_cen_n = (cpu_div == 4'd5);

// The CTC, DART and PIO run at 2 MHz: one enable pulse every 20 clocks.
reg [4:0] per_div;
always @(posedge clk) per_div <= (per_div == 5'd19) ? 5'd0 : per_div + 5'd1;

wire ce_2m = (per_div == 5'd0);

////////////////////////////////////////////////////////////////////////////////
// CPU

wire [15:0] cpu_a;
wire  [7:0] cpu_do;
wire  [7:0] cpu_di;
wire        cpu_m1_n, cpu_mreq_n, cpu_iorq_n, cpu_rd_n, cpu_wr_n, cpu_rfsh_n, cpu_halt_n;
wire        cpu_int;    // from the interrupt daisy chain

T80pa cpu
(
	.RESET_n(~reset),
	.CLK(clk),
	.CEN_p(cpu_cen_p),
	.CEN_n(cpu_cen_n),
	.WAIT_n(1'b1),
	.INT_n(~cpu_int),
	.NMI_n(1'b1),
	.BUSRQ_n(1'b1),
	.M1_n(cpu_m1_n),
	.MREQ_n(cpu_mreq_n),
	.IORQ_n(cpu_iorq_n),
	.RD_n(cpu_rd_n),
	.WR_n(cpu_wr_n),
	.RFSH_n(cpu_rfsh_n),
	.HALT_n(cpu_halt_n),
	.BUSAK_n(),
	.OUT0(1'b0),
	.A(cpu_a),
	.DI(cpu_di),
	.DO(cpu_do),
	.R800_mode(1'b0),
	.REG(),
	.DIRSet(1'b0),
	.DIR(212'd0)
);

wire mem_wr = ~cpu_mreq_n & ~cpu_wr_n;
wire io_rd  = ~cpu_iorq_n & ~cpu_rd_n & cpu_m1_n;   // M1+IORQ is an interrupt acknowledge, not an I/O read
wire io_wr  = ~cpu_iorq_n & ~cpu_wr_n;

// The CTC, DART and PIO need exactly one write per OUT instruction, so they
// get a pulse at the start of the write.
reg  io_wr_d;
always @(posedge clk) io_wr_d <= io_wr;
wire io_wr_p = io_wr & ~io_wr_d;

////////////////////////////////////////////////////////////////////////////////
// System latch (ports 1C-1F)

reg [7:0] syl;
assign sys_latch = syl;

wire rome = syl[2];   // _ROME: 0 maps the ROM in
wire vire = syl[3];

reg [7:0] scroll_r;   // AY port A, see the AY stub below

////////////////////////////////////////////////////////////////////////////////
// Memory banking
//
// A 256 x 8 PROM (53LS140, U4) decides which memory answers each access. Its
// address is {MDIS, VIRE, ROME, A15, A14, A13}. MDIS is 1 when no expansion
// card claims the access, which is always the case here, so only entries
// 32-63 are ever used. The PROM output is inverted; bits 0-3 select
// ROM0, ROM1, video RAM and RAM.

reg [7:0] prom[64];
always @(posedge clk) if (prom_wr && dl_addr[12:6] == 0) prom[dl_addr[5:0]] <= dl_data;

wire [7:0] prom_q   = ~prom[{1'b1, vire, rome, cpu_a[15:13]}];
wire       sel_rom0 = prom_q[0];
wire       sel_rom1 = prom_q[1];
wire       sel_vir  = prom_q[2];
wire       sel_ram  = prom_q[3];

// 64 KB main RAM
reg  [7:0] ram[65536];
reg  [7:0] ram_q;
always @(posedge clk) begin
	if (mem_wr && sel_ram) ram[cpu_a] <= cpu_do;
	ram_q <= ram[cpu_a];
end

// 32 KB video RAM. The CPU sees it offset by the scroll register, so that
// scrolling the screen also scrolls the CPU's view of it. The second port
// belongs to the video shifter.
wire [14:0] vram_a = cpu_a[14:0] + {scroll_r, 7'd0};
reg   [7:0] vram[32768];
reg   [7:0] vram_q;
always @(posedge clk) begin
	if (mem_wr && sel_vir) vram[vram_a] <= cpu_do;
	vram_q <= vram[vram_a];
end

wire [14:0] vid_addr;
reg   [7:0] vid_data;
always @(posedge clk) vid_data <= vram[vid_addr];

// 8 KB boot ROM in a 16 KB window; the upper 8 KB (an empty socket) reads FF.
// ROM1 always addresses that upper half.
reg  [7:0] rom[8192];
reg  [7:0] rom_q;
wire [13:0] rom_a = sel_rom1 ? {1'b1, cpu_a[12:0]} : cpu_a[13:0];
always @(posedge clk) begin
	if (rom_wr) rom[dl_addr] <= dl_data;
	rom_q <= rom[rom_a[12:0]];
end

// When several selects are active, MAME lets the last one win:
// RAM over video RAM over ROM1 over ROM0. Nothing selected reads FF.
wire [7:0] mem_dout = sel_ram               ? ram_q  :
                      sel_vir               ? vram_q :
                      (sel_rom1 | sel_rom0) ? (rom_a[13] ? 8'hFF : rom_q) :
                                              8'hFF;

////////////////////////////////////////////////////////////////////////////////
// I/O decoding
//
// Ports are decoded in groups of four from A7-A2. Ports 20-FF are unused
// (MAME passes them to the expansion bus, which is empty here).

wire       io_hit = (cpu_a[7:5] == 3'd0);
wire [2:0] io_grp = cpu_a[4:2];

localparam IO_KEYS = 3'd0;  // keyboard
localparam IO_SERS = 3'd1;  // Z80 DART
localparam IO_PARS = 3'd2;  // Z80 PIO
localparam IO_VIPB = 3'd3;  // video mode
localparam IO_FLOP = 3'd4;  // FD1797
localparam IO_VIPS = 3'd5;  // palette, AY-3-8912
localparam IO_TIMS = 3'd6;  // Z80 CTC
localparam IO_SYL  = 3'd7;  // system latch

wire io_keys = io_hit && io_grp == IO_KEYS;
wire io_vipb = io_hit && io_grp == IO_VIPB;
wire io_vips = io_hit && io_grp == IO_VIPS;
wire io_syl  = io_hit && io_grp == IO_SYL;

// Register writes. These are level-triggered: writing the same value on
// every clock while WR is low is harmless.
reg [7:0] mode_r, palv_r;

always @(posedge clk) begin
	if (reset) begin
		syl    <= 8'h00;    // ROME = 0, VIRE = 0: ROM mapped in at boot
		mode_r <= 8'h00;
		palv_r <= 8'h00;
	end
	else if (io_wr) begin
		if (io_syl)                       syl    <= cpu_do;
		if (io_vipb)                      mode_r <= cpu_do;
		if (io_vips && cpu_a[1] == 1'b0)  palv_r <= cpu_do;  // ports 14, 15
	end
end

////////////////////////////////////////////////////////////////////////////////
// Keyboard
//
// Each read of port 00 returns the current column of the key matrix and then
// advances a 4-bit counter. Any write to port 00 resets it. Columns 13-15
// read FF.

reg  [3:0] key_cnt;
reg        key_rd_d;
wire       key_rd = io_rd && io_keys;


always @(posedge clk) begin
	key_rd_d <= key_rd;
	if (reset || (io_wr && io_keys)) key_cnt <= 4'd0;
	else if (key_rd_d && !key_rd)    key_cnt <= key_cnt + 4'd1;   // advance at the end of the read
end

wire [7:0] key_dout;

tiki100_keyboard keyboard
(
	.clk(clk),
	.reset(reset),
	.ps2_key(ps2_key),
	.col(key_cnt),
	.row(key_dout)
);

////////////////////////////////////////////////////////////////////////////////
// AY-3-8912 register stub
//
// Only enough of the sound chip to drive the scroll register, which hangs off
// AY I/O port A. Milestone 6 replaces this with ym2149.sv. Like MAME, the
// port A value reaches the scroll register only when port A is set to output
// (register 7, bit 6).

reg [3:0] ay_addr;
reg [7:0] ay_reg[16];

always @(posedge clk) begin
	if (reset) begin
		ay_addr  <= 4'd0;
		scroll_r <= 8'h00;
		for (int i = 0; i < 16; i++) ay_reg[i] <= 8'h00;
	end
	else if (io_wr && io_vips) begin
		if (cpu_a[1:0] == 2'd2 && cpu_do[7:4] == 4'd0) ay_addr <= cpu_do[3:0];
		if (cpu_a[1:0] == 2'd3) begin
			ay_reg[ay_addr] <= cpu_do;
			if (ay_addr == 4'd14 && ay_reg[7][6])    scroll_r <= cpu_do;
			if (ay_addr == 4'd7  && cpu_do[6])       scroll_r <= ay_reg[14];
		end
	end
end

// Unused register bits read as 0 on the AY-3-8910 family.
reg [7:0] ay_mask;
always @(*) begin
	case (ay_addr)
		4'd1, 4'd3, 4'd5, 4'd13: ay_mask = 8'h0F;
		4'd6, 4'd8, 4'd9, 4'd10: ay_mask = 8'h1F;
		default:                 ay_mask = 8'hFF;
	endcase
end

wire [7:0] ay_dout = (ay_addr == 4'd14 && !ay_reg[7][6]) ? 8'hFF :   // port A as input: pulled high
                     (ay_addr == 4'd15)                  ? 8'hFF :   // the 8912 has no port B
                                                           ay_reg[ay_addr] & ay_mask;

////////////////////////////////////////////////////////////////////////////////
// Interrupts
//
// Z80 mode 2 interrupts through a daisy chain: CTC (highest priority), DART,
// PIO. A device may interrupt when every device above it in the chain is
// idle (IEI high). When the CPU acknowledges (M1 and IORQ low together,
// MREQ high), the highest-priority requester supplies the vector and marks
// that interrupt as under service, which blocks itself and everything below
// it until the CPU executes RETI (ED 4D). Like the real chips, the devices
// recognise RETI by watching the opcode fetches.

wire       ctc_int, ctc_ieo;
wire [7:0] ctc_vector;
wire       dart_int, dart_ieo;
wire [7:0] dart_vector;
wire       pio_int;
wire [7:0] pio_vector;

assign cpu_int = ctc_int | dart_int | pio_int;

wire intack_cyc = ~cpu_m1_n & ~cpu_iorq_n & cpu_mreq_n;
reg  intack_d;
always @(posedge clk) intack_d <= intack_cyc;
wire intack_p = intack_cyc & ~intack_d;

wire [7:0] int_vector = ctc_int  ? ctc_vector  :
                        dart_int ? dart_vector :
                        pio_int  ? pio_vector  :
                                   8'hFF;
reg  [7:0] int_vector_q;
always @(posedge clk) if (intack_p) int_vector_q <= int_vector;

// RETI detection: an ED prefix followed by 4D, both fetched in M1 cycles.
// After a CB prefix the next byte is the opcode even if it is ED (CB ED is
// SET 5,L), so that ED doesn't count as a prefix.
wire       op_fetch = ~cpu_m1_n & ~cpu_mreq_n & ~cpu_rd_n;
reg        op_fetch_d;
reg  [7:0] op_q;
reg        pfx_cb, pfx_ed;   // the previous opcode fetch was a CB or ED prefix
reg        reti;

always @(posedge clk) begin
	op_fetch_d <= op_fetch;
	reti <= 1'b0;
	if (reset) begin
		pfx_cb <= 1'b0;
		pfx_ed <= 1'b0;
	end
	else begin
		if (op_fetch) op_q <= cpu_di;
		if (op_fetch_d && !op_fetch) begin
			reti   <= pfx_ed && op_q == 8'h4D;
			pfx_ed <= !pfx_cb && !pfx_ed && op_q == 8'hED;
			pfx_cb <= !pfx_cb && !pfx_ed && op_q == 8'hCB;
		end
	end
end

////////////////////////////////////////////////////////////////////////////////
// Z80 CTC (ports 18-1B)
//
// TRG0 and TRG1 count a 2 MHz clock. Channel 0's output (BAR0) clocks
// channel 2 and the DART's channel A receiver; channel 2's output (BAR2)
// clocks channel 3 and the DART's channel A transmitter (the ST jumper, set
// to BAR2 as in MAME); channel 1 clocks both directions of DART channel B.

wire [7:0] ctc_dout;
wire [3:0] ctc_zc;

z80ctc ctc
(
	.clk(clk),
	.reset(reset),
	.ce(ce_2m),
	.wr(io_wr_p && io_hit && io_grp == IO_TIMS),
	.ch_sel(cpu_a[1:0]),
	.din(cpu_do),
	.dout(ctc_dout),
	.iei(1'b1),
	.ieo(ctc_ieo),
	.int_req(ctc_int),
	.intack(intack_p & ctc_int),
	.vector(ctc_vector),
	.reti(reti),
	.trg({ctc_zc[2], ctc_zc[0], ce_2m, ce_2m}),
	.zc_to(ctc_zc)
);

wire bar0 = ctc_zc[0];
wire bar1 = ctc_zc[1];
wire bar2 = ctc_zc[2];

////////////////////////////////////////////////////////////////////////////////
// Z80 DART (ports 04-07)
//
// A0 selects the channel (0 = A, 1 = B) and A1 control/data (1 = control),
// like MAME's cd_ba addressing. Reading the data register or a status
// register has side effects, so the DART is told when a read has finished.

localparam ST = 1'b1;   // ST jumper: channel A transmit clock from BAR2 (1) or BAR0 (0)

wire [7:0] dart_dout;
wire       dart_sel = io_hit && io_grp == IO_SERS;
reg        dart_rd_d;
reg  [1:0] dart_rd_a;
always @(posedge clk) begin
	dart_rd_d <= io_rd && dart_sel;
	if (io_rd && dart_sel) dart_rd_a <= cpu_a[1:0];
end
wire dart_rd_done = dart_rd_d && !(io_rd && dart_sel);

z80dart dart
(
	.clk(clk),
	.reset(reset),
	.wr(io_wr_p && dart_sel),
	.rd_done(dart_rd_done),
	.ch_sel(dart_rd_done ? dart_rd_a[0] : cpu_a[0]),
	.cd_sel(dart_rd_done ? dart_rd_a[1] : cpu_a[1]),
	.din(cpu_do),
	.dout(dart_dout),
	.iei(ctc_ieo),
	.ieo(dart_ieo),
	.int_req(dart_int),
	.intack(intack_p & ~ctc_int & dart_int),
	.vector(dart_vector),
	.reti(reti),
	.rxc({bar1, bar0}),
	.txc({bar1, ST ? bar2 : bar0}),
	.rxd(ser_rxd),
	.txd(ser_txd),
	.cts_n(ser_cts_n),
	.dcd_n(ser_dcd_n),
	.ri_n(2'b00),           // not connected; reads as active, like MAME
	.rts_n(ser_rts_n),
	.dtr_n(ser_dtr_n)
);

////////////////////////////////////////////////////////////////////////////////
// Z80 PIO (ports 08-0B)
//
// A0 selects the port (0 = A, 1 = B) and A1 control/data (1 = control).
// Port A is the Centronics data bus. Port B: bit 0 strobe (out), 4 ACK,
// 5 BUSY, 6 tape out / NO PAPER in, 7 tape in. The strobe inputs are not
// connected; like MAME they stay low, so input reads see the pins directly.
// (MAME TODO: some demos expect VSYNC on a PIO pin. vsync is available here
// if a schematic shows where it goes.)

wire [7:0] pio_dout;
wire [7:0] pa_out, pb_out;

z80pio pio
(
	.clk(clk),
	.reset(reset),
	.wr(io_wr_p && io_hit && io_grp == IO_PARS),
	.port_sel(cpu_a[0]),
	.cd_sel(cpu_a[1]),
	.din(cpu_do),
	.dout(pio_dout),
	.iei(dart_ieo),
	.ieo(),
	.int_req(pio_int),
	.intack(intack_p & ~ctc_int & ~dart_int & pio_int),
	.vector(pio_vector),
	.reti(reti),
	.pa_in(8'hFF),        // Centronics data lines read back nothing
	.pa_out(pa_out),
	.pa_oe(),
	.astb_n(1'b0),
	.ardy(),
	.pb_in({tape_in, par_perror, par_busy, par_ack, 4'b0000}),
	.pb_out(pb_out),
	.pb_oe(),
	.bstb_n(1'b0),
	.brdy()
);

assign par_data   = pa_out;
assign par_strobe = pb_out[0];
assign tape_out   = pb_out[6];

////////////////////////////////////////////////////////////////////////////////
// FD1797 floppy disk controller (ports 10-13) and two drives
//
// wd1793.sv (from the ZX Spectrum core) works on disk images rather than
// magnetic flux: a read or write sector command fetches the sector from the
// image on the SD card through hps_io. It has one image, so each drive gets
// its own instance and the system latch's drive select bits pick which one
// the CPU talks to. (A real FD1797 has a single track register for both
// drives; software normally seeks again after switching drives.)
//
// The FD1797 differs from the WD1793 in one way that matters here: bit 1 of
// the read/write commands selects the disk side (the SSO output). wd1793.sv
// takes the side as an input, so it is latched here.
//
// DRQ and INTRQ are not connected on the Tiki 100; software polls the status
// register. Like MAME, a drive is ready when it is selected, has a disk and
// the motor (system latch bit 6) has been on for one revolution, 200 ms at
// 300 rpm, to spin up. The single density bit (SDEN) is
// ignored: only double density images are supported.
//
// EDSK=1 is the configuration the Spectrum core builds with. On mount it
// reads the image's first block to look for an Extended CPC DSK header; the
// Tiki 100's raw images don't have one, so the fixed geometry from size_code
// and layout is used.

wire [7:0] fdc_dout_d[2];
wire       fdc_sel   = io_hit && io_grp == IO_FLOP;
wire       drive     = syl[1];                    // drive 1 selected (wins over drive 0, as in MAME)
wire       drive_sel = syl[0] | syl[1];
wire       motor     = syl[6];

reg [18:0] spinup;                                // 2 MHz ticks since the motor came on
wire       spun_up   = spinup == 19'd400000;
always @(posedge clk) begin
	if (reset || !motor) spinup <= 19'd0;
	else if (ce_2m && !spun_up) spinup <= spinup + 19'd1;
end
wire [7:0] fdc_dout  = fdc_dout_d[drive];

// Side select: bit 1 of type II (read/write sector) and type III (read
// address, read/write track) commands
reg side;
always @(posedge clk) begin
	if (reset) side <= 1'b0;
	else if (io_wr_p && fdc_sel && cpu_a[1:0] == 2'd0 && cpu_do[7]) begin
		if (cpu_do[7:4] != 4'hD) side <= cpu_do[1];   // Dx is Force Interrupt
	end
end

// Disk geometry from the image size. 368,640 bytes is 40 tracks, 2 sides,
// 9 sectors; everything else has 10 sectors. Single-sided images (up to
// 200 KB) are laid out track by track.
reg  [19:0] dsk_size[2];
reg   [1:0] mounted;
always @(posedge clk) begin
	for (int i = 0; i < 2; i++) begin
		if (img_mounted[i]) begin
			dsk_size[i] <= img_size[19:0];
			mounted[i]  <= img_size != 64'd0;
		end
	end
end

genvar d;
generate
	for (d = 0; d < 2; d = d + 1) begin : fdd
		wire sel = (drive == d) && drive_sel;

		wd1793 #(.RWMODE(1), .EDSK(1)) fdc
		(
			.clk_sys(clk),
			.ce(cpu_cen_p),
			.reset(reset),
			.io_en(fdc_sel && sel),
			.rd(io_rd),
			.wr(io_wr),
			.addr(cpu_a[1:0]),
			.din(cpu_do),
			.dout(fdc_dout_d[d]),
			.drq(),
			.intrq(),
			.busy(),

			.wp(1'b1),           // read-only for now: writing back to the SD card is milestone 7
			.size_code(dsk_size[d] == 20'd368640 ? 3'd2 : 3'd4),
			.layout(dsk_size[d] <= 20'd204800),
			.side(side),
			.ready(sel && mounted[d] && spun_up),

			.img_mounted(img_mounted[d]),
			.img_size(img_size[19:0]),
			.prepare(),
			.sd_lba(sd_lba[d]),
			.sd_rd(sd_rd[d]),
			.sd_wr(sd_wr[d]),
			.sd_ack(sd_ack[d]),
			.sd_buff_addr(sd_buff_addr),
			.sd_buff_dout(sd_buff_dout),
			.sd_buff_din(sd_buff_din[d]),
			.sd_buff_wr(sd_buff_wr),

			.input_active(1'b0),
			.input_addr(20'd0),
			.input_data(8'd0),
			.input_wr(1'b0),
			.buff_addr(),
			.buff_read(),
			.buff_din(8'd0)
		);
	end
endgenerate

////////////////////////////////////////////////////////////////////////////////
// Video

tiki100_video video
(
	.clk(clk),
	.mode(mode_r),
	.palette_val(palv_r),
	.scroll(scroll_r),
	.vram_addr(vid_addr),
	.vram_data(vid_data),
	.ce_pix(ce_pix),
	.r(vga_r),
	.g(vga_g),
	.b(vga_b),
	.hsync(hsync),
	.vsync(vsync),
	.hblank(hblank),
	.vblank(vblank)
);

////////////////////////////////////////////////////////////////////////////////
// I/O read data

reg [7:0] io_dout;
always @(*) begin
	io_dout = 8'hFF;
	if (io_hit) begin
		case (io_grp)
			IO_KEYS: io_dout = key_dout;
			IO_VIPS: if (cpu_a[1:0] == 2'd3) io_dout = ay_dout;
			IO_SERS: io_dout = dart_dout;
			IO_PARS: io_dout = pio_dout;
			IO_TIMS: io_dout = ctc_dout;
			IO_FLOP: io_dout = fdc_dout;
			default: io_dout = 8'hFF;
		endcase
	end
end

// IORQ together with M1 is an interrupt acknowledge, not an I/O read: the
// daisy chain puts its vector on the bus. Note that T80pa doesn't reset
// IntCycleD_n, so its first M1 cycle after power-up also shows IORQ low;
// that fetch has MREQ low and must still read memory.
assign cpu_di = intack_cyc               ? (intack_p ? int_vector : int_vector_q) :
                (~cpu_iorq_n & cpu_m1_n) ? io_dout :
                                           mem_dout;

endmodule
`default_nettype wire
