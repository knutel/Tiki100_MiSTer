`default_nettype none
//============================================================================
//  Z80 CTC (Z8430) counter/timer circuit
//
//  Four channels, each a timer (prescaler 16 or 256 on the CTC clock) or a
//  counter (counts edges on its TRG input). Behaviour follows MAME's
//  z80ctc.cpp. Takes part in the Z80 IM2 daisy chain (see tiki100.sv).
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

module z80ctc
(
	input        clk,
	input        reset,
	input        ce,          // CTC clock (the 4 MHz CPU clock on the Tiki 100)

	// CPU interface. wr is a one-clock pulse; reads have no side effects.
	input        wr,
	input  [1:0] ch_sel,      // A1-A0: channel
	input  [7:0] din,
	output [7:0] dout,

	// Interrupt daisy chain
	input        iei,
	output       ieo,
	output       int_req,     // wants to interrupt (already gated by iei)
	input        intack,      // one-clock pulse: this device is acknowledged
	output [7:0] vector,      // valid while int_req is high
	input        reti,        // one-clock pulse: CPU executed RETI

	input  [3:0] trg,         // CLK/TRG inputs
	output [3:0] zc_to        // ZC/TO outputs, high for about one CTC clock
);

// Channel control word bits
localparam INT_EN   = 7;
localparam COUNTER  = 6;
localparam PRE256   = 5;
localparam RISING   = 4;
localparam TRIGGER  = 3;   // timer waits for a trigger edge after the time constant
localparam TC_NEXT  = 2;
localparam RST      = 1;

reg  [7:0] ctrl[4];
reg  [7:0] tc[4];          // time constant, 0 means 256
reg  [7:0] down[4];        // down counter, 0 means 256
reg  [7:0] pre[4];         // prescaler
reg  [3:0] tc_next;        // next write is the time constant
reg  [3:0] running;        // time constant loaded and not reset
reg  [3:0] waiting;        // timer waiting for its trigger
reg  [3:0] ip, ius;        // interrupt pending, interrupt under service
reg  [3:0] trg_d;
reg  [3:0] zc;
reg  [4:0] vec;            // vector bits 7-3

assign zc_to = zc;

// Read: the down counter of the addressed channel
assign dout = down[ch_sel];

////////////////////////////////////////////////////////////////////////////////
// Daisy chain
//
// Channel 0 has the highest priority. A channel can request an interrupt
// unless it or a higher-priority channel is under service; IEO goes low while
// any channel is under service.

reg  [3:0] req;
reg  [1:0] ack_ch;
always @(*) begin : priority_chain
	reg blocked;
	blocked = 1'b0;
	req = 4'd0;
	ack_ch = 2'd0;
	for (int i = 0; i < 4; i++) begin
		blocked = blocked | ius[i];
		req[i] = ip[i] & ~blocked;
	end
	for (int i = 3; i >= 0; i--) if (req[i]) ack_ch = i;
end

assign int_req = iei & |req;
assign ieo     = iei & ~|ius;
assign vector  = {vec, ack_ch, 1'b0};

////////////////////////////////////////////////////////////////////////////////
// Channels

always @(posedge clk) begin : channels
	reg [3:0] zero;
	zero = 4'd0;

	if (reset) begin
		for (int i = 0; i < 4; i++) begin
			ctrl[i] <= 8'h02;       // reset active
			tc[i]   <= 8'h00;
			down[i] <= 8'h00;
			pre[i]  <= 8'h00;
		end
		tc_next <= 4'd0;
		running <= 4'd0;
		waiting <= 4'd0;
		ip      <= 4'd0;
		ius     <= 4'd0;
		trg_d   <= 4'hF;
		zc      <= 4'd0;
		vec     <= 5'd0;
	end
	else begin
		trg_d <= trg;

		// Interrupt acknowledge and return from interrupt. A new interrupt
		// below takes precedence over an acknowledge in the same clock.
		if (intack) begin
			ip[ack_ch]  <= 1'b0;
			ius[ack_ch] <= 1'b1;
		end
		else if (reti && iei) begin
			for (int i = 3; i >= 0; i--) begin
				if (ius[i]) begin
					ius <= ius & ~(4'd1 << i);
				end
			end
		end


		for (int i = 0; i < 4; i++) begin
			// Active trigger edge
			if (trg[i] != trg_d[i] && trg[i] == ctrl[i][RISING]) begin
				if (ctrl[i][COUNTER]) begin
					if (running[i]) begin
						if (down[i] == 8'd1) zero[i] = 1'b1;
						else                 down[i] <= down[i] - 8'd1;
					end
				end
				else if (waiting[i]) begin
					waiting[i] <= 1'b0;
					pre[i]     <= 8'd0;
				end
			end

			// Timer
			if (ce && running[i] && !waiting[i] && !ctrl[i][COUNTER]) begin
				if (pre[i] == (ctrl[i][PRE256] ? 8'd255 : 8'd15)) begin
					pre[i] <= 8'd0;
					if (down[i] == 8'd1) zero[i] = 1'b1;
					else                 down[i] <= down[i] - 8'd1;
				end
				else pre[i] <= pre[i] + 8'd1;
			end

			// Zero count: pulse ZC/TO, reload, maybe interrupt
			if (ce) zc[i] <= 1'b0;
			if (zero[i]) begin
				zc[i]   <= 1'b1;
				down[i] <= tc[i];
				if (ctrl[i][INT_EN]) ip[i] <= 1'b1;
			end
		end

		// CPU writes
		if (wr) begin
			if (tc_next[ch_sel]) begin
				tc[ch_sel]      <= din;
				down[ch_sel]    <= din;
				tc_next[ch_sel] <= 1'b0;
				ctrl[ch_sel][RST] <= 1'b0;
				running[ch_sel] <= 1'b1;
				pre[ch_sel]     <= 8'd0;
				waiting[ch_sel] <= ~ctrl[ch_sel][COUNTER] & ctrl[ch_sel][TRIGGER];
			end
			else if (!din[0]) begin
				if (ch_sel == 2'd0) vec <= din[7:3];
			end
			else begin
				ctrl[ch_sel]    <= din;
				tc_next[ch_sel] <= din[TC_NEXT];
				if (din[RST]) begin
					running[ch_sel] <= 1'b0;
					waiting[ch_sel] <= 1'b0;
				end
				// Clearing the interrupt enable also clears a pending interrupt
				if (!din[INT_EN]) ip[ch_sel] <= 1'b0;
			end
		end

	end
end

endmodule
`default_nettype wire
