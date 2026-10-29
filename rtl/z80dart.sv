`default_nettype none
//============================================================================
//  Z80 DART (Z8470) dual asynchronous receiver/transmitter
//
//  Two asynchronous serial channels, 5-8 data bits, optional parity, 1, 1.5
//  or 2 stop bits, x1/x16/x32/x64 clock modes, 3-byte receive FIFO, and the
//  receive, transmit and external/status interrupts. Behaviour follows the
//  asynchronous parts of MAME's z80sio.cpp. Takes part in the Z80 IM2 daisy
//  chain (see tiki100.sv).
//
//  Not implemented: the WAIT/READY outputs.
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

module z80dart
(
	input        clk,
	input        reset,

	// CPU interface. wr is a one-clock pulse. rd_done is a one-clock pulse
	// after a read has finished (with the same ch_sel/cd_sel), for the side
	// effects of reading: the receive FIFO advances and the register pointer
	// returns to 0.
	input        wr,
	input        rd_done,
	input        ch_sel,      // A0: 0 = channel A, 1 = channel B
	input        cd_sel,      // A1: 0 = data, 1 = control
	input  [7:0] din,
	output [7:0] dout,

	// Interrupt daisy chain
	input        iei,
	output       ieo,
	output       int_req,     // wants to interrupt (already gated by iei)
	input        intack,      // one-clock pulse: this device is acknowledged
	output [7:0] vector,      // valid while int_req is high
	input        reti,        // one-clock pulse: CPU executed RETI

	// Serial lines, channel A in bit 0 and channel B in bit 1. The clocks are
	// sampled on clk, so they may be any signal slower than clk/2.
	input  [1:0] rxc,
	input  [1:0] txc,
	input  [1:0] rxd,
	output [1:0] txd,
	input  [1:0] cts_n,
	input  [1:0] dcd_n,
	input  [1:0] ri_n,
	output [1:0] rts_n,
	output [1:0] dtr_n
);

wire [7:0] rr0[2], rr1[2], data_q[2], wr1[2], wr2[2];
wire [1:0] int_rx, int_tx, int_ext, rx_special, reset_all;

////////////////////////////////////////////////////////////////////////////////
// Daisy chain
//
// Six interrupt sources, highest priority first: A receive, A transmit,
// A external/status, B receive, B transmit, B external/status. A source stays
// pending until the condition is cleared (reading the data, writing the
// transmitter, resetting the status); acknowledging it only marks it as
// under service.

wire [5:0] pend = {int_ext[1], int_tx[1], int_rx[1], int_ext[0], int_tx[0], int_rx[0]};
reg  [5:0] ius;
reg  [5:0] req;
reg  [2:0] ack_src, top_src;

always @(*) begin : priority_chain
	reg blocked;
	blocked = 1'b0;
	for (int i = 0; i < 6; i++) begin
		blocked = blocked | ius[i];
		req[i] = pend[i] & ~blocked;
	end
	ack_src = 3'd0;
	top_src = 3'd7;
	for (int i = 5; i >= 0; i--) begin
		if (req[i])  ack_src = i;
		if (pend[i]) top_src = i;
	end
end

assign int_req = iei & |req;
assign ieo     = iei & ~|ius;

// Vector from channel B's WR2. With "status affects vector" (channel B WR1
// bit 2), bits 3-1 tell which source is pending.
reg [2:0] vec_code;
always @(*) begin
	case (top_src)
		3'd0:    vec_code = rx_special[0] ? 3'd7 : 3'd6;
		3'd1:    vec_code = 3'd4;
		3'd2:    vec_code = 3'd5;
		3'd3:    vec_code = rx_special[1] ? 3'd3 : 3'd2;
		3'd4:    vec_code = 3'd0;
		3'd5:    vec_code = 3'd1;
		default: vec_code = 3'd3;   // nothing pending
	endcase
end

wire [7:0] rr2 = wr1[1][2] ? {wr2[1][7:4], vec_code, wr2[1][0]} : wr2[1];
assign vector = rr2;

// Channel A's "return from interrupt" command does the same as RETI
wire cmd_reti;

always @(posedge clk) begin
	if (reset || reset_all[0]) ius <= 6'd0;
	else if (intack) ius[ack_src] <= 1'b1;
	else if ((reti && iei) || cmd_reti) begin
		for (int i = 5; i >= 0; i--) begin
			if (ius[i]) ius <= ius & ~(6'd1 << i);
		end
	end
end

////////////////////////////////////////////////////////////////////////////////
// Channels

wire [2:0] ptr[2];
wire [1:0] reti_cmd;
assign cmd_reti = reti_cmd[0];

genvar c;
generate
	for (c = 0; c < 2; c = c + 1) begin : chan
		z80dart_channel ch
		(
			.clk(clk),
			.reset(reset),
			.clr_int(reset_all[0]),
			.ctrl_wr(wr && cd_sel && ch_sel == c),
			.data_wr(wr && !cd_sel && ch_sel == c),
			.ctrl_rd_done(rd_done && cd_sel && ch_sel == c),
			.data_rd_done(rd_done && !cd_sel && ch_sel == c),
			.din(din),
			.ptr(ptr[c]),
			.rr0(rr0[c]),
			.rr1(rr1[c]),
			.data_q(data_q[c]),
			.wr1_q(wr1[c]),
			.wr2_q(wr2[c]),
			.int_rx(int_rx[c]),
			.int_tx(int_tx[c]),
			.int_ext(int_ext[c]),
			.rx_special(rx_special[c]),
			.reset_cmd(reset_all[c]),
			.reti_cmd(reti_cmd[c]),
			.rxc(rxc[c]),
			.txc(txc[c]),
			.rxd(rxd[c]),
			.txd(txd[c]),
			.cts_n(cts_n[c]),
			.dcd_n(dcd_n[c]),
			.ri_n(ri_n[c]),
			.rts_n(rts_n[c]),
			.dtr_n(dtr_n[c])
		);
	end
endgenerate

// Register reads. RR0 bit 1 (interrupt pending) only exists in channel A;
// RR2 (the vector) only in channel B.
reg [7:0] ctrl_q;
always @(*) begin
	case (ptr[ch_sel])
		3'd0:    ctrl_q = ch_sel ? rr0[1] : (rr0[0] | {6'd0, |pend, 1'b0});
		3'd1:    ctrl_q = rr1[ch_sel];
		3'd2:    ctrl_q = ch_sel ? rr2 : 8'h00;
		default: ctrl_q = 8'h00;
	endcase
end

assign dout = cd_sel ? ctrl_q : data_q[ch_sel];

endmodule

////////////////////////////////////////////////////////////////////////////////
// One DART channel

module z80dart_channel
(
	input            clk,
	input            reset,
	input            clr_int,       // channel A reset clears every interrupt

	input            ctrl_wr,
	input            data_wr,
	input            ctrl_rd_done,
	input            data_rd_done,
	input      [7:0] din,
	output     [2:0] ptr,
	output     [7:0] rr0,
	output     [7:0] rr1,
	output     [7:0] data_q,
	output     [7:0] wr1_q,
	output     [7:0] wr2_q,

	output reg       int_rx,
	output reg       int_tx,
	output reg       int_ext,
	output           rx_special,    // receive interrupt is a special condition
	output reg       reset_cmd,     // channel reset command (pulse)
	output reg       reti_cmd,      // return from interrupt command (pulse)

	input            rxc,
	input            txc,
	input            rxd,
	output           txd,
	input            cts_n,
	input            dcd_n,
	input            ri_n,
	output reg       rts_n,
	output reg       dtr_n
);

reg [2:0] wr0_ptr;
reg [7:0] wr1, wr2, wr3, wr4, wr5;
assign ptr   = wr0_ptr;
assign wr1_q = wr1;
assign wr2_q = wr2;

localparam [7:0] RR1_PARITY  = 8'h10;
localparam [7:0] RR1_OVERRUN = 8'h20;
localparam [7:0] RR1_FRAMING = 8'h40;
localparam [7:0] RR1_SPECIAL = RR1_OVERRUN | RR1_FRAMING;

wire [1:0] rx_int_mode = wr1[4:3];   // 0 off, 1 first char, 2 all (parity is special), 3 all

wire       rx_allowed = wr3[0] & (~wr3[5] | ~dcd_n);   // WR3 bit 5: auto enables
wire       tx_allowed = wr5[3] & (~wr3[5] | ~cts_n);

// Word length coding is the same in WR3 (receive) and WR5 (transmit)
function [3:0] word_len(input [1:0] code);
	case (code)
		2'b00: word_len = 4'd5;
		2'b01: word_len = 4'd7;
		2'b10: word_len = 4'd6;
		2'b11: word_len = 4'd8;
	endcase
endfunction

wire [3:0] rx_wl = word_len(wr3[7:6]);
wire [3:0] tx_wl = word_len(wr5[6:5]);
wire       par_en   = wr4[0];
wire       par_even = wr4[1];

// Clock edges per bit: x1, x16, x32, x64
wire [6:0] clk_mode = (wr4[7:6] == 2'd0) ? 7'd1 : (wr4[7:6] == 2'd1) ? 7'd16 :
                      (wr4[7:6] == 2'd2) ? 7'd32 : 7'd64;

////////////////////////////////////////////////////////////////////////////////
// Receive FIFO and status

reg  [7:0] fifo_d[3];
reg  [7:0] fifo_e[3];      // RR1 error bits per character
reg  [1:0] depth;
reg  [7:0] rr1_err;        // RR1 bits 4-6
reg        rx_first;       // interrupt on the next character
reg        brk;            // RR0 bit 7, break detected

assign data_q = fifo_d[0];
assign rx_special = (rx_int_mode == 2'd2 && (rr1_err & (RR1_SPECIAL | RR1_PARITY)) != 0) ||
                    (rx_int_mode == 2'd3 && (rr1_err & RR1_SPECIAL) != 0);

// External/status: the DCD, RI and CTS bits latch on a change until the
// "reset external/status interrupts" command
reg  [2:0] ext_pins_d;
reg  [2:0] ext_st;         // latched {CTS, RI, DCD}, 1 = active
reg        ext_latched;
wire [2:0] ext_pins = {~cts_n, ~ri_n, ~dcd_n};

reg        tx_full;        // transmit buffer holds a character
reg        all_sent;

assign rr0 = {brk, 1'b1 /* Tx underrun, always set in async mode */, ext_st[2], ext_st[1], ext_st[0],
              ~tx_full, 1'b0 /* int pending, added for channel A */, depth != 2'd0};
assign rr1 = rr1_err | {7'd0, all_sent};

////////////////////////////////////////////////////////////////////////////////
// Receiver and transmitter state

reg        rxc_d, txc_d;
reg  [5:0] rx_count;
reg  [3:0] rx_bit;
reg  [9:0] rx_sr;

reg  [7:0] tx_buf;
reg  [1:0] tx_state;       // 0 idle, 1 shifting start/data/parity, 2 stop bits
reg  [9:0] tx_sr;
reg  [3:0] tx_n;           // bits left in tx_sr
reg  [7:0] tx_cnt;         // clock edges left in the current bit
reg        txd_r;

assign txd = wr5[4] ? 1'b0 : txd_r;   // WR5 bit 4: send break

wire [7:0] stop_edges = (wr4[3:2] == 2'd2) ? {1'b0, clk_mode} + {2'b0, clk_mode[6:1]} :   // 1.5
                        (wr4[3:2] == 2'd3) ? {clk_mode, 1'b0} :                       // 2
                                             {1'b0, clk_mode};                        // 1

// The character in the transmit buffer as a frame, LSB first:
// start bit, data bits, parity bit (if enabled), then ones.
function [9:0] tx_frame(input [7:0] d, input [3:0] wl, input pe, input even);
	reg [7:0] m;
	reg       p;
	m = d & ~(8'hFF << wl);
	p = ^m ^ ~even;
	tx_frame = ({1'b0, m, 1'b0} | ({9'd0, pe & p} << (wl + 4'd1))) | ~(10'h3FF >> (4'd9 - wl - pe));
endfunction

////////////////////////////////////////////////////////////////////////////////

always @(posedge clk) begin : channel
	reg        tx_empty_now;
	reg  [5:0] clocks;
	reg  [3:0] wlen;
	reg        rx_queue;
	reg  [7:0] rx_err;
	reg        advance;
	reg  [9:0] sr;
	reg  [7:0] rx_data;
	reg        is_brk;
	reg  [7:0] m;
	reg  [1:0] d;

	tx_empty_now = 1'b0;
	rx_queue     = 1'b0;
	rx_err       = 8'd0;
	advance      = 1'b0;
	rx_data      = 8'd0;
	clocks       = clk_mode[5:0] - 6'd1;
	wlen         = rx_wl + {3'd0, par_en};

	reset_cmd <= 1'b0;
	reti_cmd  <= 1'b0;

	if (reset || (ctrl_wr && wr0_ptr == 3'd0 && din[5:3] == 3'd3)) begin
		// Hardware reset, or the channel reset command
		if (reset) begin
			wr0_ptr <= 3'd0;
			wr1 <= 8'h00; wr2 <= 8'h00; wr3 <= 8'h00; wr4 <= 8'h00; wr5 <= 8'h00;
			ext_pins_d <= ext_pins;
			rxc_d <= 1'b0;
			txc_d <= 1'b0;
		end
		else begin
			wr0_ptr <= din[2:0];
			wr3[0] <= 1'b0;   // receiver off
			wr5[3] <= 1'b0;   // transmitter off
			reset_cmd <= 1'b1;
		end
		depth    <= 2'd0;
		rr1_err  <= 8'd0;
		rx_bit   <= 4'd0;
		rx_count <= 6'd0;
		rx_first <= 1'b0;
		brk      <= 1'b0;
		tx_full  <= 1'b0;
		tx_state <= 2'd0;
		all_sent <= 1'b1;
		txd_r    <= 1'b1;
		rts_n    <= 1'b1;
		dtr_n    <= 1'b1;
		int_rx   <= 1'b0;
		int_tx   <= 1'b0;
		int_ext  <= 1'b0;
		ext_latched <= 1'b0;
		ext_st   <= ext_pins;
	end
	else begin
		rxc_d <= rxc;
		txc_d <= txc;
		ext_pins_d <= ext_pins;

		////////////////////////////////////////////////////////////////////////
		// External/status changes

		if (!ext_latched) ext_st <= ext_pins;
		if (ext_pins != ext_pins_d) begin
			ext_latched <= 1'b1;
			if (wr1[0]) int_ext <= 1'b1;
		end

		////////////////////////////////////////////////////////////////////////
		// Receiver: RxD is sampled on the rising edge of RxC. Like MAME, a
		// start bit must last half a bit time, and the data bits are sampled
		// a whole bit time apart from there.

		if (rx_allowed && rxc && !rxc_d && (!brk || rxd)) begin
			if (brk && rxd) begin
				// end of break
				brk <= 1'b0;
				ext_latched <= 1'b1;
				if (wr1[0]) int_ext <= 1'b1;
			end
			if (rx_bit == 4'd0) begin
				if (rxd) begin
					// line idle
					if (rx_count > {1'b0, clocks[5:1]}) rx_count <= rx_count - 6'd1;
					else                                rx_count <= {1'b0, clocks[5:1]};
				end
				else if (rx_count == 6'd0) begin
					rx_count <= clocks;
					rx_bit   <= 4'd1;
					rx_sr    <= 10'h3FF;
				end
				else rx_count <= rx_count - 6'd1;
			end
			else if (rx_count == 6'd0) begin
				sr = rx_sr;
				if (!rxd) sr[rx_bit - 4'd1] = 1'b0;
				rx_sr <= sr;
				if (rx_bit == wlen + 4'd1) begin
					// stop bit; a framing error adds half a bit time
					rx_count <= rxd ? {1'b0, clocks[5:1]} : clocks;
					rx_bit   <= 4'd0;
					m = ~(8'hFF << rx_wl);
					is_brk = (sr & ~(10'h3FF << (wlen + 4'd1))) == 10'd0;
					if (!is_brk && !sr[wlen]) rx_err = rx_err | RR1_FRAMING;
					if (par_en && ((^(sr[7:0] & m) ^ sr[rx_wl]) == par_even)) rx_err = rx_err | RR1_PARITY;
					rx_data  = sr[7:0] | (8'd1 << wlen);   // like MAME, the stop bit reads as 1
					rx_queue = 1'b1;
					if (is_brk && !brk) begin
						brk <= 1'b1;
						ext_latched <= 1'b1;
						if (wr1[0]) int_ext <= 1'b1;
					end
				end
				else begin
					rx_count <= clocks;
					rx_bit   <= rx_bit + 4'd1;
				end
			end
			else rx_count <= rx_count - 6'd1;
		end

		////////////////////////////////////////////////////////////////////////
		// Transmitter: bits change on the falling edge of TxC

		if (tx_state == 2'd0) begin
			txd_r <= 1'b1;
			if (tx_allowed && tx_full) begin
				tx_sr    <= tx_frame(tx_buf, tx_wl, par_en, par_even);
				tx_n     <= 4'd1 + tx_wl + {3'd0, par_en};
				tx_cnt   <= {1'b0, clk_mode};
				tx_state <= 2'd1;
				txd_r    <= 1'b0;
				tx_full  <= 1'b0;
				all_sent <= 1'b0;
				tx_empty_now = 1'b1;
			end
			else if (!tx_full) all_sent <= 1'b1;
		end
		else if (!txc && txc_d) begin
			if (tx_cnt != 8'd1) tx_cnt <= tx_cnt - 8'd1;
			else if (tx_state == 2'd1) begin
				tx_sr <= {1'b1, tx_sr[9:1]};
				if (tx_n == 4'd1) begin
					tx_state <= 2'd2;
					tx_cnt   <= stop_edges;
					txd_r    <= 1'b1;
				end
				else begin
					tx_n  <= tx_n - 4'd1;
					tx_cnt <= {1'b0, clk_mode};
					txd_r <= tx_sr[1];
				end
			end
			else tx_state <= 2'd0;
		end

		// RTS goes inactive once everything has been sent
		if (wr5[1])       rts_n <= 1'b0;
		else if (all_sent) rts_n <= 1'b1;

		if (tx_empty_now && wr1[1]) int_tx <= 1'b1;

		////////////////////////////////////////////////////////////////////////
		// Receive FIFO

		if (data_rd_done && !(rx_int_mode == 2'd1 && (rr1_err & RR1_SPECIAL) != 0))
			advance = 1'b1;

		if (advance && depth != 2'd0) begin
			fifo_d[0] <= fifo_d[1];
			fifo_d[1] <= fifo_d[2];
			fifo_e[0] <= fifo_e[1];
			fifo_e[1] <= fifo_e[2];
			depth <= depth - 2'd1;
			if (depth == 2'd1) int_rx <= 1'b0;
			else begin
				rr1_err <= (rr1_err & ~RR1_FRAMING) | fifo_e[1];
				if (rx_int_mode == 2'd1 && (((depth == 2'd3 ? fifo_e[2] : 8'd0) | fifo_e[1]) & RR1_SPECIAL) == 8'd0)
					int_rx <= 1'b0;
			end
		end

		if (rx_queue) begin
			d = (advance && depth != 2'd0) ? depth - 2'd1 : depth;
			if (d == 2'd3) begin
				// overrun: the newest character replaces the last one
				fifo_d[2] <= rx_data;
				fifo_e[2] <= rx_err | RR1_OVERRUN;
			end
			else begin
				fifo_d[d] <= rx_data;
				fifo_e[d] <= rx_err;
				if (d == 2'd0) rr1_err <= (rr1_err & ~RR1_FRAMING) | rx_err;
				depth <= d + 2'd1;
			end
			case (rx_int_mode)
				2'd1: begin
					if (rx_first || (rx_err & RR1_SPECIAL) != 0) int_rx <= 1'b1;
					rx_first <= 1'b0;
				end
				2'd2, 2'd3: int_rx <= 1'b1;
				default: ;
			endcase
		end

		////////////////////////////////////////////////////////////////////////
		// CPU access

		if (data_wr) begin
			tx_buf  <= din;
			tx_full <= 1'b1;
			all_sent <= 1'b0;
			int_tx  <= 1'b0;
		end

		if (ctrl_rd_done) wr0_ptr <= 3'd0;

		if (ctrl_wr) begin
			wr0_ptr <= 3'd0;
			case (wr0_ptr)
				3'd0: begin
					wr0_ptr <= din[2:0];
					case (din[5:3])
						3'd2: begin   // reset external/status interrupts
							ext_latched <= 1'b0;
							ext_st  <= ext_pins;
							int_ext <= 1'b0;
						end
						3'd4: rx_first <= 1'b1;    // enable interrupt on next character
						3'd5: int_tx   <= 1'b0;    // reset transmitter interrupt pending
						3'd6: begin                // error reset
							rr1_err <= 8'd0;
							if (rx_int_mode == 2'd1 && (rr1_err & RR1_SPECIAL) != 0 && depth != 2'd0) begin
								fifo_d[0] <= fifo_d[1];
								fifo_d[1] <= fifo_d[2];
								fifo_e[0] <= fifo_e[1];
								fifo_e[1] <= fifo_e[2];
								depth <= depth - 2'd1;
								if (depth == 2'd1) int_rx <= 1'b0;
								else rr1_err <= fifo_e[1];
							end
						end
						3'd7: reti_cmd <= 1'b1;    // return from interrupt (channel A)
						default: ;
					endcase
				end
				3'd1: wr1 <= din;
				3'd2: wr2 <= din;
				3'd3: wr3 <= din;
				3'd4: wr4 <= din;
				3'd5: begin
					wr5 <= din;
					dtr_n <= ~din[7];
					if (!din[3]) int_tx <= 1'b0;
				end
				default: ;   // WR6, WR7 don't exist on the DART
			endcase
		end
	end

	if (clr_int) begin
		int_rx  <= 1'b0;
		int_tx  <= 1'b0;
		int_ext <= 1'b0;
	end
end

endmodule
`default_nettype wire
