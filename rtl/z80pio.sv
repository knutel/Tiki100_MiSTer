`default_nettype none
//============================================================================
//  Z80 PIO (Z8420) parallel input/output
//
//  Two 8-bit ports with modes 0 (output), 1 (input), 2 (bidirectional,
//  port A only) and 3 (bit control). Behaviour follows MAME's z80pio.cpp.
//  Takes part in the Z80 IM2 daisy chain (see tiki100.sv).
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

module z80pio
(
	input        clk,
	input        reset,

	// CPU interface. wr is a one-clock pulse; reads have no side effects
	// apart from the RDY handshake, which is not modelled for reads.
	input        wr,
	input        port_sel,    // A0: 0 = port A, 1 = port B
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

	// Port pins. pX_oe has a 1 for each bit the PIO drives.
	input  [7:0] pa_in,
	output [7:0] pa_out,
	output [7:0] pa_oe,
	input        astb_n,
	output       ardy,
	input  [7:0] pb_in,
	output [7:0] pb_out,
	output [7:0] pb_oe,
	input        bstb_n,
	output       brdy
);

localparam MODE_OUT = 2'd0;
localparam MODE_IN  = 2'd1;
localparam MODE_BI  = 2'd2;
localparam MODE_BIT = 2'd3;

localparam NEXT_ANY  = 2'd0;
localparam NEXT_IOR  = 2'd1;
localparam NEXT_MASK = 2'd2;

reg  [1:0] mode[2];
reg  [1:0] next_cw[2];
reg  [7:0] out_r[2];      // output register
reg  [7:0] in_r[2];       // input latch (strobed in)
reg  [7:0] ior[2];        // mode 3 direction: 1 = input
reg  [7:0] mask[2];       // mode 3 interrupt mask: 1 = bit not monitored
reg  [7:0] icw[2];        // interrupt control word
reg  [7:0] vec[2];
reg  [1:0] ie, ip, ius, rdy, match, stb_d;

wire [7:0] pin_in[2];
assign pin_in[0] = pa_in;
assign pin_in[1] = pb_in;
reg  [7:0] bits_d[2];     // mode 3 port value one clock ago: the equation follows changes

wire [1:0] stb = {~bstb_n, ~astb_n};   // strobe active

assign ardy = rdy[0];
assign brdy = rdy[1];

// Pins: in mode 3 the input bits float high
function [7:0] drive(input [1:0] m, input [7:0] o, input [7:0] dir);
	case (m)
		MODE_OUT: drive = o;
		MODE_BIT: drive = dir | (o & ~dir);
		default:  drive = o;
	endcase
endfunction

assign pa_out = drive(mode[0], out_r[0], ior[0]);
assign pb_out = drive(mode[1], out_r[1], ior[1]);
assign pa_oe  = (mode[0] == MODE_OUT || mode[0] == MODE_BI) ? 8'hFF : (mode[0] == MODE_BIT) ? ~ior[0] : 8'h00;
assign pb_oe  = (mode[1] == MODE_OUT) ? 8'hFF : (mode[1] == MODE_BIT) ? ~ior[1] : 8'h00;

////////////////////////////////////////////////////////////////////////////////
// Reads

function [7:0] data_rd(input p);
	case (mode[p])
		MODE_OUT: data_rd = out_r[p];
		MODE_IN:  data_rd = stb[p] ? pin_in[p] : in_r[p];   // reads the pins while STB is low, like MAME
		MODE_BI:  data_rd = in_r[p];
		default:  data_rd = (pin_in[p] & ior[p]) | (out_r[p] & ~ior[p]);
	endcase
endfunction

assign dout = cd_sel ? {icw[0][7:6], 2'b00, icw[1][7:4]} : data_rd(port_sel);

////////////////////////////////////////////////////////////////////////////////
// Daisy chain: port A has priority over port B

wire req_a = ie[0] & ip[0] & ~ius[0];
wire req_b = ie[1] & ip[1] & ~ius[0] & ~ius[1];

assign int_req = iei & (req_a | req_b);
assign ieo     = iei & ~|ius;
assign vector  = req_a ? vec[0] : vec[1];

////////////////////////////////////////////////////////////////////////////////
// Bit control mode: the logic equation over the monitored bits

function logic bit_match(input p);
	logic [7:0] d, m;
	m = ~mask[p];
	d = ((pin_in[p] & ior[p]) | (out_r[p] & ~ior[p])) & m;
	case (icw[p][6:5])
		2'b00: bit_match = d != m;     // OR, active low
		2'b01: bit_match = d != 0;     // OR, active high
		2'b10: bit_match = d == 0;     // AND, active low
		2'b11: bit_match = d == m;     // AND, active high
	endcase
endfunction

////////////////////////////////////////////////////////////////////////////////

always @(posedge clk) begin
	if (reset) begin
		for (int p = 0; p < 2; p++) begin
			mode[p]    <= MODE_IN;
			next_cw[p] <= NEXT_ANY;
			out_r[p]   <= 8'h00;
			in_r[p]    <= 8'h00;
			ior[p]     <= 8'h00;
			mask[p]    <= 8'hFF;
			icw[p]     <= 8'h00;
			vec[p]     <= 8'h00;
		end
		ie    <= 2'b00;
		ip    <= 2'b00;
		ius   <= 2'b00;
		rdy   <= 2'b00;
		match <= 2'b00;
		stb_d <= 2'b11;
	end
	else begin
		stb_d <= stb;

		// Interrupt acknowledge and return from interrupt
		if (intack) begin
			if (req_a) begin ip[0] <= 1'b0; ius[0] <= 1'b1; end
			else       begin ip[1] <= 1'b0; ius[1] <= 1'b1; end
		end
		else if (reti && iei) begin
			if (ius[0]) ius[0] <= 1'b0;
			else        ius[1] <= 1'b0;
		end

		for (int p = 0; p < 2; p++) begin
			// Strobes: input latches while STB is low; the rising edge ends the
			// handshake. In mode 2, port A's strobe handles output and port B's
			// strobe handles input, both on port A's data.
			if (stb[p]) begin
				if (mode[0] == MODE_BI) begin
					if (p == 1) in_r[0] <= pa_in;
				end
				else if (mode[p] == MODE_IN) in_r[p] <= pin_in[p];
			end
			if (stb_d[p] && !stb[p] &&
			    ((mode[0] == MODE_BI || mode[p] == MODE_OUT) ? rdy[p] : mode[p] == MODE_IN)) begin
				ip[p]  <= 1'b1;
				rdy[p] <= 1'b0;
			end

			// Bit control mode: interrupt when the logic equation becomes true.
			// Like MAME, the equation is only evaluated when the port's value
			// (input pins and output bits) changes: after a new mask the
			// interrupt waits for the next change, even if the equation is
			// already true. Darklite's "The
			// Hollow" relies on this: it loads an HSYNC mask and then HALTs
			// for the interrupt.
			bits_d[p] <= (pin_in[p] & ior[p]) | (out_r[p] & ~ior[p]);
			if (mode[p] == MODE_BIT && next_cw[p] == NEXT_ANY &&
			    ((pin_in[p] & ior[p]) | (out_r[p] & ~ior[p])) != bits_d[p]) begin
				match[p] <= bit_match(p);
				if (bit_match(p) && !match[p] && !ius[p]) ip[p] <= 1'b1;
			end
		end

		// CPU writes
		if (wr) begin
			if (!cd_sel) begin
				out_r[port_sel] <= din;
				if (mode[port_sel] == MODE_OUT || mode[port_sel] == MODE_BI) rdy[port_sel] <= 1'b1;
			end
			else begin
				case (next_cw[port_sel])
					NEXT_IOR: begin
						ior[port_sel]     <= din;
						ie[port_sel]      <= icw[port_sel][7];
						next_cw[port_sel] <= NEXT_ANY;
					end
					NEXT_MASK: begin
						mask[port_sel]    <= din;
						ie[port_sel]      <= icw[port_sel][7];
						next_cw[port_sel] <= NEXT_ANY;
					end
					default: begin
						if (!din[0]) vec[port_sel] <= din;
						else case (din[3:0])
							4'hF: begin   // mode select
								if (port_sel == 1'b0 || din[7:6] != MODE_BI) mode[port_sel] <= din[7:6];
								case (din[7:6])
									MODE_OUT: rdy[port_sel] <= 1'b1;
									MODE_BIT: begin
										if (port_sel == 1'b0 || mode[0] != MODE_BI) rdy[port_sel] <= 1'b0;
										ie[port_sel]      <= 1'b0;
										match[port_sel]   <= 1'b0;
										next_cw[port_sel] <= NEXT_IOR;
									end
									default: ;
								endcase
							end
							4'h7: begin   // interrupt control word
								icw[port_sel] <= din;
								if (din[4]) begin
									ie[port_sel]      <= 1'b0;
									ip[port_sel]      <= 1'b0;
									match[port_sel]   <= 1'b0;
									next_cw[port_sel] <= NEXT_MASK;
								end
								else ie[port_sel] <= din[7];
							end
							4'h3: begin   // interrupt enable only
								icw[port_sel][7] <= din[7];
								ie[port_sel]     <= din[7];
							end
							default: ;
						endcase
					end
				endcase
			end
		end
	end
end

endmodule
`default_nettype wire
