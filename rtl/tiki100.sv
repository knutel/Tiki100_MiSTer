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

	// Keyboard matrix: the core outputs the column it is reading,
	// the matrix returns that column's 8 rows (active low).
	output  [3:0] key_col,
	input   [7:0] key_row,

	// System latch (ports 1C-1F): drive select, ROME, VIRE, density, LEDs, motor
	output  [7:0] sys_latch,

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

////////////////////////////////////////////////////////////////////////////////
// CPU

wire [15:0] cpu_a;
wire  [7:0] cpu_do;
wire  [7:0] cpu_di;
wire        cpu_m1_n, cpu_mreq_n, cpu_iorq_n, cpu_rd_n, cpu_wr_n, cpu_rfsh_n, cpu_halt_n;

T80pa cpu
(
	.RESET_n(~reset),
	.CLK(clk),
	.CEN_p(cpu_cen_p),
	.CEN_n(cpu_cen_n),
	.WAIT_n(1'b1),
	.INT_n(1'b1),           // milestone 3: CTC/DART/PIO daisy chain
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
localparam IO_SERS = 3'd1;  // Z80 DART (milestone 3)
localparam IO_PARS = 3'd2;  // Z80 PIO (milestone 3)
localparam IO_VIPB = 3'd3;  // video mode
localparam IO_FLOP = 3'd4;  // FD1797 (milestone 5)
localparam IO_VIPS = 3'd5;  // palette, AY-3-8912
localparam IO_TIMS = 3'd6;  // Z80 CTC (milestone 3)
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
// Keyboard column counter
//
// Each read of port 00 returns the current column and then advances a 4-bit
// counter. Any write to port 00 resets it. Columns 13-15 read FF.

reg  [3:0] key_cnt;
reg        key_rd_d;
wire       key_rd = io_rd && io_keys;

assign key_col = key_cnt;

always @(posedge clk) begin
	key_rd_d <= key_rd;
	if (reset || (io_wr && io_keys)) key_cnt <= 4'd0;
	else if (key_rd_d && !key_rd)    key_cnt <= key_cnt + 4'd1;   // advance at the end of the read
end

wire [7:0] key_dout = (key_cnt < 4'd13) ? key_row : 8'hFF;

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
			default: io_dout = 8'hFF;   // DART, PIO, FDC, CTC come in later milestones
		endcase
	end
end

// IORQ together with M1 is an interrupt acknowledge, not an I/O read
// (milestone 3 puts the daisy chain's vector on the bus there). Note that
// T80pa doesn't reset IntCycleD_n, so its first M1 cycle after power-up
// also shows IORQ low; that fetch must still read memory.
assign cpu_di = (~cpu_iorq_n & cpu_m1_n) ? io_dout : mem_dout;

endmodule
`default_nettype wire
