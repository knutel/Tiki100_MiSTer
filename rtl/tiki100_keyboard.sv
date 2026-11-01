`default_nettype none
//============================================================================
//  Tiki 100 keyboard
//
//  Turns PS/2 key events from hps_io into the Tiki 100's 13 x 8 key matrix.
//  The CPU reads one column at a time (see the column counter in
//  tiki100.sv); a pressed key reads as 0.
//
//  Keys map by position, as in MAME: on a Norwegian PC keyboard the letters,
//  Ø, Æ, Å, +, -, ' and < are where the Tiki 100 has them. Tiki keys with no
//  PC equivalent:
//
//    BRYTT = Esc        SLETT = Backspace   ANGRE   = Delete
//    GRAFIKK = Left Alt LOCK = Caps Lock    UTVID   = Insert
//    HJEM = Home        HTAB = Tab          SIDEOPP = Page Up
//    SIDENED = Page Down                    MLMROM  = Space
//    @ = the key left of Backspace (\ on a Norwegian keyboard)
//    ^ = the key left of Enter (¨ on a Norwegian keyboard)
//    Not in MAME: HJELP = F7, VTAB = F8, % (keypad) = Num Lock, = (keypad) = F9
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

module tiki100_keyboard
(
	input        clk,
	input        reset,

	// From hps_io: bit 10 toggles on every event, bit 9 = pressed,
	// bit 8 = extended (E0) scancode, bits 7-0 = PS/2 set 2 scancode
	input [10:0] ps2_key,

	input  [3:0] col,
	output [7:0] row      // active low
);

reg [7:0] matrix[13];     // 1 = pressed
assign row = (col < 4'd13) ? ~matrix[col] : 8'hFF;

// Scancode to matrix position: {valid, column, row bit}
reg [7:0] pos;
always @(*) begin
	case ({ps2_key[8], ps2_key[7:0]})
		// Column 0
		9'h014, 9'h114: pos = {1'b1, 4'd0, 3'd0};   // CTRL (left or right)
		9'h012, 9'h059: pos = {1'b1, 4'd0, 3'd1};   // SHIFT (left or right)
		9'h076:         pos = {1'b1, 4'd0, 3'd2};   // BRYTT = Esc
		9'h05A:         pos = {1'b1, 4'd0, 3'd3};   // RETUR = Enter
		9'h029:         pos = {1'b1, 4'd0, 3'd4};   // MLMROM = Space
		9'h14A:         pos = {1'b1, 4'd0, 3'd5};   // keypad /
		9'h066:         pos = {1'b1, 4'd0, 3'd6};   // SLETT = Backspace
		// Column 1
		9'h011:         pos = {1'b1, 4'd1, 3'd0};   // GRAFIKK = Left Alt
		9'h016:         pos = {1'b1, 4'd1, 3'd1};   // 1
		9'h171:         pos = {1'b1, 4'd1, 3'd2};   // ANGRE = Delete
		9'h01C:         pos = {1'b1, 4'd1, 3'd3};   // A
		9'h061:         pos = {1'b1, 4'd1, 3'd4};   // <
		9'h01A:         pos = {1'b1, 4'd1, 3'd5};   // Z
		9'h015:         pos = {1'b1, 4'd1, 3'd6};   // Q
		9'h058:         pos = {1'b1, 4'd1, 3'd7};   // LOCK = Caps Lock
		// Column 2
		9'h01E:         pos = {1'b1, 4'd2, 3'd0};   // 2
		9'h01D:         pos = {1'b1, 4'd2, 3'd1};   // W
		9'h01B:         pos = {1'b1, 4'd2, 3'd2};   // S
		9'h022:         pos = {1'b1, 4'd2, 3'd3};   // X
		9'h026:         pos = {1'b1, 4'd2, 3'd4};   // 3
		9'h024:         pos = {1'b1, 4'd2, 3'd5};   // E
		9'h023:         pos = {1'b1, 4'd2, 3'd6};   // D
		9'h021:         pos = {1'b1, 4'd2, 3'd7};   // C
		// Column 3
		9'h025:         pos = {1'b1, 4'd3, 3'd0};   // 4
		9'h02D:         pos = {1'b1, 4'd3, 3'd1};   // R
		9'h02B:         pos = {1'b1, 4'd3, 3'd2};   // F
		9'h02A:         pos = {1'b1, 4'd3, 3'd3};   // V
		9'h02E:         pos = {1'b1, 4'd3, 3'd4};   // 5
		9'h02C:         pos = {1'b1, 4'd3, 3'd5};   // T
		9'h034:         pos = {1'b1, 4'd3, 3'd6};   // G
		9'h032:         pos = {1'b1, 4'd3, 3'd7};   // B
		// Column 4
		9'h036:         pos = {1'b1, 4'd4, 3'd0};   // 6
		9'h035:         pos = {1'b1, 4'd4, 3'd1};   // Y
		9'h033:         pos = {1'b1, 4'd4, 3'd2};   // H
		9'h031:         pos = {1'b1, 4'd4, 3'd3};   // N
		9'h03D:         pos = {1'b1, 4'd4, 3'd4};   // 7
		9'h03C:         pos = {1'b1, 4'd4, 3'd5};   // U
		9'h03B:         pos = {1'b1, 4'd4, 3'd6};   // J
		9'h03A:         pos = {1'b1, 4'd4, 3'd7};   // M
		// Column 5
		9'h03E:         pos = {1'b1, 4'd5, 3'd0};   // 8
		9'h043:         pos = {1'b1, 4'd5, 3'd1};   // I
		9'h042:         pos = {1'b1, 4'd5, 3'd2};   // K
		9'h041:         pos = {1'b1, 4'd5, 3'd3};   // ,
		9'h046:         pos = {1'b1, 4'd5, 3'd4};   // 9
		9'h044:         pos = {1'b1, 4'd5, 3'd5};   // O
		9'h04B:         pos = {1'b1, 4'd5, 3'd6};   // L
		9'h049:         pos = {1'b1, 4'd5, 3'd7};   // .
		// Column 6
		9'h045:         pos = {1'b1, 4'd6, 3'd0};   // 0
		9'h04D:         pos = {1'b1, 4'd6, 3'd1};   // P
		9'h04C:         pos = {1'b1, 4'd6, 3'd2};   // Ø
		9'h04A:         pos = {1'b1, 4'd6, 3'd3};   // -
		9'h04E:         pos = {1'b1, 4'd6, 3'd4};   // +
		9'h054:         pos = {1'b1, 4'd6, 3'd5};   // Å
		9'h052:         pos = {1'b1, 4'd6, 3'd6};   // Æ
		9'h083:         pos = {1'b1, 4'd6, 3'd7};   // HJELP = F7
		// Column 7
		9'h055:         pos = {1'b1, 4'd7, 3'd0};   // @
		9'h05B:         pos = {1'b1, 4'd7, 3'd1};   // ^
		9'h05D:         pos = {1'b1, 4'd7, 3'd2};   // '
		9'h16B:         pos = {1'b1, 4'd7, 3'd3};   // left
		9'h170:         pos = {1'b1, 4'd7, 3'd4};   // UTVID = Insert
		9'h005:         pos = {1'b1, 4'd7, 3'd5};   // F1
		9'h00C:         pos = {1'b1, 4'd7, 3'd6};   // F4
		9'h17D:         pos = {1'b1, 4'd7, 3'd7};   // SIDEOPP = Page Up
		// Column 8
		9'h006:         pos = {1'b1, 4'd8, 3'd0};   // F2
		9'h004:         pos = {1'b1, 4'd8, 3'd1};   // F3
		9'h003:         pos = {1'b1, 4'd8, 3'd2};   // F5
		9'h00B:         pos = {1'b1, 4'd8, 3'd3};   // F6
		9'h175:         pos = {1'b1, 4'd8, 3'd4};   // up
		9'h17A:         pos = {1'b1, 4'd8, 3'd5};   // SIDENED = Page Down
		9'h00A:         pos = {1'b1, 4'd8, 3'd6};   // VTAB = F8
		9'h172:         pos = {1'b1, 4'd8, 3'd7};   // down
		// Column 9
		9'h079:         pos = {1'b1, 4'd9, 3'd0};   // keypad +
		9'h07B:         pos = {1'b1, 4'd9, 3'd1};   // keypad -
		9'h07C:         pos = {1'b1, 4'd9, 3'd2};   // keypad *
		9'h06C:         pos = {1'b1, 4'd9, 3'd3};   // keypad 7
		9'h075:         pos = {1'b1, 4'd9, 3'd4};   // keypad 8
		9'h07D:         pos = {1'b1, 4'd9, 3'd5};   // keypad 9
		9'h077:         pos = {1'b1, 4'd9, 3'd6};   // keypad % = Num Lock
		9'h001:         pos = {1'b1, 4'd9, 3'd7};   // keypad = = F9
		// Column 10
		9'h06B:         pos = {1'b1, 4'd10, 3'd0};  // keypad 4
		9'h073:         pos = {1'b1, 4'd10, 3'd1};  // keypad 5
		9'h074:         pos = {1'b1, 4'd10, 3'd2};  // keypad 6
		9'h00D:         pos = {1'b1, 4'd10, 3'd3};  // HTAB = Tab
		9'h069:         pos = {1'b1, 4'd10, 3'd4};  // keypad 1
		9'h070:         pos = {1'b1, 4'd10, 3'd5};  // keypad 0
		9'h071:         pos = {1'b1, 4'd10, 3'd6};  // keypad .
		// Column 11
		9'h16C:         pos = {1'b1, 4'd11, 3'd0};  // HJEM = Home
		9'h174:         pos = {1'b1, 4'd11, 3'd1};  // right
		9'h072:         pos = {1'b1, 4'd11, 3'd2};  // keypad 2
		9'h07A:         pos = {1'b1, 4'd11, 3'd3};  // keypad 3
		9'h15A:         pos = {1'b1, 4'd11, 3'd4};  // keypad Enter
		default:        pos = 8'd0;
	endcase
end

reg toggle_d;

always @(posedge clk) begin
	toggle_d <= ps2_key[10];
	if (reset) begin
		for (int i = 0; i < 13; i++) matrix[i] <= 8'd0;
	end
	else if (ps2_key[10] != toggle_d && pos[7]) begin
		matrix[pos[6:3]][pos[2:0]] <= ps2_key[9];
	end
end

endmodule
`default_nettype wire
