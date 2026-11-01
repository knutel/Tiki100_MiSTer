`default_nettype none
//============================================================================
//  Tiki 100 video
//
//  The Tiki 100 has no CRTC chip. Discrete logic reads one 16-bit word of
//  video RAM per 16 dots and shifts it out one bit per dot. A 4-bit pixel
//  latch samples the low four bits of the shifter every dot (mode 1), every
//  2nd dot (mode 2) or every 4th dot (mode 3); mode 0 holds the last pixel.
//  The latch indexes a 16-entry palette of 8-bit (3-3-2) colors.
//
//  Modelled on MAME's tiki100 screen_update(). Sync positions aren't in MAME;
//  they come from the technical handbook and its schematics (see Timing).
//
//  Copyright (C) 2026 Knut Eldhuset
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

module tiki100_video
#(
	// 0: mode and scroll changes take effect once per line (like MAME).
	// 1: they take effect at every 16-dot group (like the real hardware).
	//    Tiki Tiki Ta's plasma needs it: its line interrupt writes the scroll
	//    register early in the line, for that same line.
	parameter PER_GROUP = 1
)
(
	input             clk,          // 40 MHz clk_sys

	input       [7:0] mode,         // video mode register (ports 0C-0F)
	input       [7:0] palette_val,  // palette data register (ports 14-15)
	input       [7:0] scroll,       // scroll register (AY port A)

	output reg [14:0] vram_addr,    // video RAM read port, data one clock later
	input       [7:0] vram_data,

	output reg        ce_pix,       // 20 MHz dot clock enable
	output reg  [7:0] r,
	output reg  [7:0] g,
	output reg  [7:0] b,
	output reg        hsync,
	output reg        vsync,
	output reg        hblank,
	output reg        vblank,

	output            swclk         // video RAM phase: 1 = video fetch, 0 = CPU slot
);

////////////////////////////////////////////////////////////////////////////////
// Timing: 1280 dots x 312 lines at 20 MHz = 15.625 kHz, 50.08 Hz.
// Visible area 1024 x 256 starts at dot 0 of line 0. The horizontal timing
// follows fig. 4.3 of the technical handbook (13 us HBLANK, 4.8 us HSYNC
// starting about 1.6 us into it; 3.6 ms VBLANK).
//
// VSYNC follows the vertical scan schematic (25085-4, U107/U115): the
// vertical address counts on through VBLANK from 0, and VSYNC is high for
// counts 20-23 of it (VBLANK ends after count 55, 56 lines). The vertical
// address steps where the horizontal address passes 64 (section 4.2), dot
// 1024, so VSYNC runs from dot 1024 of line 275 to dot 1024 of line 279.
// Tiki Tiki Ta's plasma times its raster sequence from VSYNC with the CTC;
// with this timing it covers lines 0-255 and shows only the rows it drew.

localparam H_ACTIVE     = 1024;
localparam H_SYNC_START = 1056;   // 1.6 us front porch
localparam H_SYNC_END   = 1152;   // 4.8 us sync, 6.4 us back porch
localparam H_TOTAL      = 1280;

localparam V_ACTIVE     = 256;
localparam V_SYNC_START = 275;   // VBLANK count 20, from dot H_ACTIVE
localparam V_SYNC_END   = 279;   // VBLANK count 24
localparam V_TOTAL      = 312;

reg [10:0] hcount = 0;
reg  [8:0] vcount = 0;

always @(posedge clk) ce_pix <= ~ce_pix;

wire       ce = ce_pix;               // this clock is a dot
wire [3:0] dot = hcount[3:0];         // dot within the 16-dot group
wire [6:0] grp = hcount[10:4];        // group within the line, 0-79
wire       last_grp  = (grp == H_TOTAL/16 - 1);
wire       last_line = (vcount == V_TOTAL - 1);

// SWCLK (handbook fig. 4.3) is the dot clock divided by 16. The video RAM
// alternates between the video logic, which fetches the next group's word
// while SWCLK is high (dots 8-15, ending with the shifter load), and the CPU,
// which gets it while SWCLK is low (dots 0-7). We read the block RAM at other
// dots, but the CPU's wait states follow SWCLK (see rtl/tiki100.sv).
assign swclk = hcount[3];

always @(posedge clk) if (ce) begin
	if (hcount == H_TOTAL - 1) begin
		hcount <= 0;
		vcount <= last_line ? 9'd0 : vcount + 9'd1;
	end
	else hcount <= hcount + 11'd1;
end

wire visible = (hcount < H_ACTIVE) && (vcount < V_ACTIVE);

////////////////////////////////////////////////////////////////////////////////
// Mode and scroll latches
//
// The shifter uses copies of the mode and scroll registers. With
// PER_GROUP = 0 they're copied when the first group of a line is set up,
// with PER_GROUP = 1 for every group.

reg [1:0] mode_q   = 0;
reg [7:0] scroll_q = 0;

wire group_setup = (dot == 4'd0)  && (PER_GROUP != 0 || last_grp);   // fetch of the next group starts
wire group_load  = (dot == 4'd15) && (PER_GROUP != 0 || last_grp);   // next group's first dot follows

always @(posedge clk) if (ce) begin
	if (group_setup) scroll_q <= scroll;
	if (group_load)  mode_q   <= mode[5:4];
end

////////////////////////////////////////////////////////////////////////////////
// Video RAM fetch
//
// During each group we read the word for the next group:
// address ((line + scroll) << 7) | (column << 1), low byte first.
// After the last group of a line comes column 0 of the next line.

wire [5:0] next_col  = last_grp ? 6'd0 : grp[5:0] + 6'd1;
wire [7:0] next_line = !last_grp ? vcount[7:0] :
                       last_line ? 8'd0        : vcount[7:0] + 8'd1;
wire [7:0] scroll_f  = group_setup ? scroll : scroll_q;   // the value being latched this dot
wire [7:0] fetch_row = next_line + scroll_f;

reg [7:0] next_lo, next_hi;
reg [7:0] row_q;
reg [5:0] col_q;

always @(posedge clk) if (ce) begin
	case (dot)
		4'd0: begin
			row_q     <= fetch_row;
			col_q     <= next_col;
			vram_addr <= {fetch_row, next_col, 1'b0};
		end
		4'd1: begin
			next_lo   <= vram_data;
			vram_addr <= {row_q, col_q, 1'b1};
		end
		4'd2: next_hi <= vram_data;
		default: ;
	endcase
end

////////////////////////////////////////////////////////////////////////////////
// Shifter, pixel latch and palette

reg [15:0] shifter = 0;
reg  [3:0] pixel   = 0;
reg  [7:0] palette[16];

initial for (int i = 0; i < 16; i++) palette[i] = 8'h00;

wire latch = (mode_q == 2'd1) ||
             (mode_q == 2'd2 && dot[0]   == 1'b0) ||
             (mode_q == 2'd3 && dot[1:0] == 2'd0);

wire [3:0] pixel_next = (visible && latch) ? shifter[3:0] : pixel;
wire [7:0] color      = palette[pixel_next];

always @(posedge clk) if (ce) begin
	pixel <= pixel_next;

	// Shift right one bit per dot. Bit 1 of the column counter goes in at the
	// top: a test pattern that the palette normally hides.
	if (dot == 4'd15) shifter <= {next_hi, next_lo};
	else              shifter <= {grp[1], shifter[15:1]};

	// At the end of horizontal blanking (the MRAMW pulse in the handbook), if
	// mode bit 7 is set, palette entry mode[3:0] takes the inverse of the
	// palette register.
	if (hcount == H_TOTAL - 1 && mode[7]) palette[mode[3:0]] <= ~palette_val;

	// Outputs, one dot after the counters
	r <= visible ? {color[7:5], color[7:5], color[7:6]} : 8'd0;
	g <= visible ? {color[4:2], color[4:2], color[4:3]} : 8'd0;
	b <= visible ? {4{color[1:0]}}                      : 8'd0;

	hblank <= (hcount >= H_ACTIVE);
	vblank <= (vcount >= V_ACTIVE);
	hsync  <= (hcount >= H_SYNC_START) && (hcount < H_SYNC_END);
	if (hcount == H_ACTIVE) vsync <= (vcount >= V_SYNC_START) && (vcount < V_SYNC_END);
end

endmodule
`default_nettype wire
