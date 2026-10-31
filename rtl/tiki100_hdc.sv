`default_nettype none
//============================================================================
//  Tiki 100 Winchester controller (option 100/005): a WD2010 hard disk
//  controller with a 1 KB sector buffer, at ports 20-27.
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
//
//============================================================================
//
// The behaviour follows MAME's emulation of the card (bus/tiki100/hdc.cpp and
// machine/wd2010.cpp, MAME master since 2026-09-30); see plans/hard-disk.md.
//
// Ports:
//   20     sector buffer: each read or write moves a 10-bit counter on
//   21     read: error register (the status while a command is in
//          progress); write: write precompensation cylinder (ignored)
//   22-26  sector count, sector number, cylinder low and high, SDH
//          (bits 6-5 sector size, 4-3 drive, 2-0 head): read back as written
//   27     read: status; write: command. A write also clears the counter.
//
// Status: 80 busy, 40 drive ready, 10 seek complete (always 1), 08 data
// request, 02 command in progress, 01 error. Error: 10 ID not found, 04
// aborted command.
//
// The hard disk image is drive 0 (SDH bits 4-3 = 10), with the geometry of
// TIKO 4.01's 10 MB disk: 4 heads, 17 sectors of 512 bytes per track, and
// as many cylinders as the image holds. Sector C/H/S is image block
// (C * 4 + H) * 17 + S - 1, as in MAME. There is no drive 1.
//
// Commands TIKO and the 2.03w ROM use: Restore 1x, Read Sector 2x, Write
// Sector 3x. Also: Seek 7x, Scan ID 4x, Write Format 5x (writes the buffer
// to the sector, like MAME), Set Parameter 0x and Compute Correction 08.
// Multi-sector transfers are not supported.
//
// Timing, from MAME: Restore and Seek take 15 ms settling plus 8.33 ms
// latency (MAME adds sqrt(steps) x the step rate to Seek); Scan ID, Set
// Parameter and Compute Correction take 1 ms; Read and Write take as long
// as the SD card does. ce is the 4 MHz CPU clock enable.
//
// A read-only image fails writes with aborted command (MAME's drives can
// always be written).

module tiki100_hdc
(
	input         clk,
	input         ce,
	input         reset,

	// CPU: sel is ports 20-27, rd and wr are the I/O read and write strobes
	input         sel,
	input   [2:0] addr,
	input         rd,
	input         wr,
	input   [7:0] din,
	output  [7:0] dout,

	// Image
	input         mounted,     // an image of whole cylinders is mounted
	input         readonly,
	input  [31:0] blocks,      // its size in 512-byte blocks

	// hps_io SD interface for the image
	output [31:0] sd_lba,
	output reg    sd_rd,
	output reg    sd_wr,
	input         sd_ack,
	input   [8:0] sd_buff_addr,
	input   [7:0] sd_buff_dout,
	output  [7:0] sd_buff_din,
	input         sd_buff_wr
);

localparam ST_BSY = 8'h80;
localparam ST_RDY = 8'h40;
localparam ST_SC  = 8'h10;
localparam ST_DRQ = 8'h08;
localparam ST_CIP = 8'h02;
localparam ST_ERR = 8'h01;

localparam ER_ID = 8'h10;
localparam ER_AC = 8'h04;

localparam [16:0] T_SEEK = 17'd93333;   // 23.33 ms
localparam [16:0] T_CMD  = 17'd4000;    // 1 ms

reg        wr_d, rd_sel_d;
wire       wr_p = wr & ~wr_d;

// Task file
reg  [7:0] count, sector, cyl_lo, cyl_hi, sdh;
reg  [7:0] status;   // BSY, DRQ, CIP, ERR; RDY and SC are added when read
reg  [7:0] error;

wire       drdy = mounted && sdh[4:3] == 2'b10;
wire [7:0] status_r = status | (drdy ? ST_RDY : 8'h00) | ST_SC;

wire [10:0] cylinder = {cyl_hi[2:0], cyl_lo};
wire [31:0] lba = {cylinder, 6'd0} + {cylinder, 2'd0} + sdh[2:0] * 5'd17 + sector - 32'd1;   // (C * 4 + H) * 17 + S - 1
assign sd_lba = lba;

////////////////////////////////////////////////////////////////////////////////
// Sector buffer: port a for the SD card (the first 512 bytes), port b for the
// CPU through the counter

reg  [9:0] counter;
wire [7:0] buf_q;
wire       buf_we = sel && wr_p && addr == 3'd0;

tiki100_hdc_dpram sbuf
(
	.clk(clk),

	.a_addr({1'b0, sd_buff_addr}),
	.a_din(sd_buff_dout),
	.a_we(sd_buff_wr & sd_ack),
	.a_q(sd_buff_din),

	.b_addr(counter),
	.b_din(din),
	.b_we(buf_we),
	.b_q(buf_q)
);

reg  [7:0] reg_q;
always @(*) begin
	case (addr)
		3'd1:    reg_q = (status & ST_CIP) ? status_r : error;
		3'd2:    reg_q = count;
		3'd3:    reg_q = sector;
		3'd4:    reg_q = cyl_lo;
		3'd5:    reg_q = cyl_hi;
		3'd6:    reg_q = sdh;
		3'd7:    reg_q = status_r;
		default: reg_q = buf_q;
	endcase
end
assign dout = reg_q;

////////////////////////////////////////////////////////////////////////////////
// Commands

typedef enum logic [2:0] {
	S_IDLE,
	S_WAIT,         // timed command: finish when timer runs out
	S_READ,         // SD block read into the buffer
	S_WRITE_BUF,    // waiting for the CPU to fill the buffer
	S_WRITE         // SD block write from the buffer
} state_t;
state_t state;

reg [16:0] timer;
reg  [1:0] ack;

always @(posedge clk) begin
	wr_d <= wr;
	rd_sel_d <= rd && sel && addr == 3'd0;
	ack <= {ack[0], sd_ack};

	if (reset) begin
		{count, sector, cyl_lo, cyl_hi, sdh} <= 0;
		status  <= 0;
		error   <= 0;
		counter <= 0;
		state   <= S_IDLE;
		{sd_rd, sd_wr} <= 0;
	end
	else begin
		// Buffer counter: moves on after each access to port 20
		if (rd_sel_d && !(rd && sel)) counter <= counter + 10'd1;
		if (buf_we) counter <= counter + 10'd1;

		if (sel && wr_p) begin
			case (addr)
				3'd2: count  <= din;
				3'd3: sector <= din;
				3'd4: cyl_lo <= din;
				3'd5: cyl_hi <= din;
				3'd6: sdh    <= din;
				3'd7: begin
					counter <= 10'd0;
					error   <= 8'h00;
					status  <= 8'h00;
					state   <= S_IDLE;
					{sd_rd, sd_wr} <= 0;
					casez (din)
						8'h08, 8'b0000_000?: begin              // compute correction, set parameter
							timer <= T_CMD;
							state <= S_WAIT;
						end
						8'h1?: begin                            // restore
							status <= ST_BSY | ST_CIP;
							{cyl_hi, cyl_lo} <= 16'd0;
							timer  <= T_SEEK;
							state  <= S_WAIT;
						end
						8'h7?: begin                            // seek
							if (!drdy) begin
								error  <= ER_AC;
								status <= ST_ERR;
							end
							else begin
								status <= ST_BSY | ST_CIP;
								timer  <= T_SEEK;
								state  <= S_WAIT;
							end
						end
						8'h4?: begin                            // scan ID: the cylinder registers already hold the head position
							status <= ST_BSY | ST_CIP;
							timer  <= T_CMD;
							state  <= S_WAIT;
						end
						8'h2?: begin                            // read sector
							if (!drdy) begin
								error  <= ER_AC;
								status <= ST_ERR;
							end
							else if (sector > 8'd32) begin
								error  <= ER_ID;
								status <= ST_ERR;
							end
							else begin
								status <= ST_BSY | ST_CIP;
								// A sector beyond the image leaves the buffer as it is (MAME)
								if (lba < blocks) begin
									sd_rd <= 1'b1;
									state <= S_READ;
								end
								else begin
									timer <= 17'd1;
									state <= S_WAIT;
								end
							end
						end
						8'h3?, 8'h5?: begin                     // write sector, write format
							status <= ST_BSY | ST_CIP | ST_DRQ;
							state  <= S_WRITE_BUF;
						end
						default: ;
					endcase
				end
				default: ;
			endcase
		end

		case (state)
			S_IDLE: ;

			S_WAIT:
				if (ce) begin
					if (timer != 17'd0) timer <= timer - 17'd1;
					else begin
						status <= status & ~(ST_BSY | ST_CIP | ST_DRQ);
						state  <= S_IDLE;
					end
				end

			S_READ: begin
				if (ack == 2'b01) sd_rd <= 1'b0;
				if (ack == 2'b10) begin
					counter <= 10'd0;
					status  <= 8'h00;
					state   <= S_IDLE;
				end
			end

			S_WRITE_BUF:
				if (counter == 10'd512) begin
					status <= status & ~ST_DRQ;
					if (!drdy || readonly) begin
						error  <= ER_AC;
						status <= ST_ERR;
						state  <= S_IDLE;
					end
					else if (lba < blocks) begin
						sd_wr <= 1'b1;
						state <= S_WRITE;
					end
					else begin
						status <= 8'h00;
						state  <= S_IDLE;
					end
				end

			S_WRITE: begin
				if (ack == 2'b01) sd_wr <= 1'b0;
				if (ack == 2'b10) begin
					counter <= 10'd0;
					status  <= 8'h00;
					state   <= S_IDLE;
				end
			end
		endcase
	end
end

endmodule

module tiki100_hdc_dpram
(
	input            clk,

	input      [9:0] a_addr,
	input      [7:0] a_din,
	input            a_we,
	output reg [7:0] a_q,

	input      [9:0] b_addr,
	input      [7:0] b_din,
	input            b_we,
	output reg [7:0] b_q
);

reg [7:0] ram[1024];

always @(posedge clk) begin
	if (a_we) ram[a_addr] <= a_din;
	a_q <= ram[a_addr];
end

always @(posedge clk) begin
	if (b_we) ram[b_addr] <= b_din;
	b_q <= ram[b_addr];
end

endmodule
`default_nettype wire
