// Floppy drive sounds for the Tiki 100 core
//
// The real machine has two 5.25" drives next to the keyboard, and you hear
// them: the spindle motor runs while the system latch's MOTON bit is set,
// and the head steps, buzzing during seeks. This module plays recorded
// drive sounds for both, mixed with the AY-3-8912 by the core.
//
// The recordings are MAME's default 5.25" floppy drive samples (CC0 1.0;
// tools/make_drive_sound_rom.py converts them into tiki100_drive_sound.hex,
// 10-bit signed at 25 kHz, 39 K samples in block RAM). Synthesized sounds
// were tried first and didn't sound right.
//
// The playback follows MAME's floppy_sound_device (src/devices/sound/
// drivesound.cpp):
// - Spindle: 10 ms after the motor turns on, the start sample plays, then
//   the run sample loops. Both come in an "empty" and a "loaded" version,
//   chosen by whether a disk image is mounted. When the motor turns off,
//   the end sample plays. A motor that turns on again during the end
//   sample starts the start sample again.
// - Head: a step plays the step sample (75 ms). A step that comes while it
//   is still playing starts a seek: the seek sample for the step rate (6,
//   12 or 20 ms) loops while the steps keep coming, and the step sample is
//   paused. When no step has come for twice the step rate (at least 20 ms),
//   the rest of the step sample plays, 10 ms further on, for the head's
//   stop. MAME also pitches the seek sample to the exact rate; this module
//   doesn't, because the FD1797 only steps at 6, 12, 20 or 30 ms (30 ms
//   plays the 20 ms sample).
//
// The output is signed and silent at 0. With enable off (the OSD's Drive
// sounds option) the motor counts as off and steps are silent.

module tiki100_drive_sound #(parameter HEX = "rtl/tiki100_drive_sound.hex")
(
	input                    clk,
	input                    reset,
	input                    ce,       // 2 MHz
	input                    enable,
	input                    motor,    // system latch bit 6 (MOTON)
	input                    loaded,   // a disk image is mounted
	input                    step,     // a step pulse to either drive
	output reg signed  [9:0] out
);

`include "tiki100_drive_sound.svh"

// The samples
reg  [9:0] rom[0:DS_ROM_SIZE-1];
initial $readmemh(HEX, rom);

reg [15:0] rom_a;
reg  [9:0] rom_q;
always @(posedge clk) rom_q <= rom[rom_a];

// 25 kHz sample tick
reg  [6:0] div;
wire       tick = ce && div == 7'd79;
always @(posedge clk) begin
	if (reset) div <= 7'd0;
	else if (ce) div <= tick ? 7'd0 : div + 7'd1;
end

// Phase within a sample, see below
reg  [2:0] ph;

// A step pulse can come between ticks: hold it until phase 1 handles it
reg step_d, step_req;
always @(posedge clk) begin
	step_d <= step;
	if (reset) step_req <= 1'b0;
	else if (step && !step_d) step_req <= enable;
	else if (ph == 3'd1) step_req <= 1'b0;
end

// Spindle
localparam SPIN_QUIET = 2'd0, SPIN_START = 2'd1, SPIN_RUN = 2'd2, SPIN_END = 2'd3;
reg  [1:0] spin;
reg        spin_ld;                 // playing the "loaded" samples
reg [12:0] spin_pos;
reg  [8:0] spin_delay;              // samples to the start sound, 0 = none pending
reg        motor_on;
wire       motor_now = motor && enable;

reg [15:0] spin_base;
reg [12:0] spin_len;
always @(*) begin
	case (spin)
		SPIN_START: begin
			spin_base = spin_ld ? DS_SPIN_START_LOADED     : DS_SPIN_START_EMPTY;
			spin_len  = spin_ld ? DS_SPIN_START_LOADED_LEN : DS_SPIN_START_EMPTY_LEN;
		end
		SPIN_RUN: begin
			spin_base = spin_ld ? DS_SPIN_LOADED     : DS_SPIN_EMPTY;
			spin_len  = spin_ld ? DS_SPIN_LOADED_LEN : DS_SPIN_EMPTY_LEN;
		end
		default: begin
			spin_base = DS_SPIN_END;
			spin_len  = DS_SPIN_END_LEN;
		end
	endcase
end

// Head
localparam SEEK_NONE = 2'd0, SEEK_6 = 2'd1, SEEK_12 = 2'd2, SEEK_20 = 2'd3;
reg        step_on;                 // the step sample is playing (or paused by a seek)
reg [11:0] step_pos;
reg  [1:0] seek;
reg [13:0] seek_pos;
reg [11:0] seek_timeout;            // samples to the end of the seek sound, 0 = none
reg [15:0] since;                   // samples since the last step, saturating

// The seek sample for the time since the last step (25 samples per ms)
wire [1:0] rate_seek = since <=  225 ? SEEK_6  :
                       since <=  375 ? SEEK_12 :
                       since <= 1250 ? SEEK_20 : SEEK_NONE;

reg [15:0] seek_base;
reg [13:0] seek_len;
always @(*) begin
	case (seek)
		SEEK_6: begin
			seek_base = DS_SEEK_6MS;
			seek_len  = DS_SEEK_6MS_LEN;
		end
		SEEK_12: begin
			seek_base = DS_SEEK_12MS;
			seek_len  = DS_SEEK_12MS_LEN;
		end
		default: begin
			seek_base = DS_SEEK_20MS;
			seek_len  = DS_SEEK_20MS_LEN;
		end
	endcase
end

// Each tick: phase 1 handles the motor and step events, phases 2 and 3
// read the spindle and the head sample from the ROM, phase 4 mixes them
// and moves on.
reg signed [9:0] spin_val;
wire signed [10:0] mix = spin_val + $signed(rom_q);

always @(*) begin
	if (ph == 3'd2)             rom_a = spin_base + {3'd0, spin_pos};
	else if (seek != SEEK_NONE) rom_a = seek_base + {2'd0, seek_pos};
	else                        rom_a = DS_STEP + {4'd0, step_pos};
end

always @(posedge clk) begin
	if (reset) begin
		ph           <= 3'd0;
		spin         <= SPIN_QUIET;
		spin_ld      <= 1'b0;
		spin_pos     <= 13'd0;
		spin_delay   <= 9'd0;
		motor_on     <= 1'b0;
		step_on      <= 1'b0;
		step_pos     <= 12'd0;
		seek         <= SEEK_NONE;
		seek_pos     <= 14'd0;
		seek_timeout <= 12'd0;
		since        <= 16'hFFFF;
		spin_val     <= 10'sd0;
		out          <= 10'sd0;
	end
	else begin
		case (ph)
			3'd0: if (tick) ph <= 3'd1;

			// Events
			3'd1: begin
				// Motor
				motor_on <= motor_now;
				if (motor_now && !motor_on && (spin == SPIN_QUIET || spin == SPIN_END))
					spin_delay <= 9'd250;                   // 10 ms
				else if (!motor_now && motor_on && spin == SPIN_RUN) begin
					spin     <= SPIN_END;
					spin_pos <= 13'd0;
				end
				if (!motor_now) spin_delay <= 9'd0;
				else if (spin_delay == 9'd1) begin
					spin       <= SPIN_START;
					spin_ld    <= loaded;
					spin_pos   <= 13'd0;
					spin_delay <= 9'd0;
				end
				else if (spin_delay > 9'd1) spin_delay <= spin_delay - 9'd1;

				// Step
				if (since != 16'hFFFF) since <= since + 16'd1;
				if (step_req) begin
					since <= 16'd0;
					if (step_on && rate_seek != SEEK_NONE) begin
						// A step while the step sample plays: a seek. A
						// different seek sample starts from its beginning.
						if (rate_seek != seek) seek_pos <= 14'd0;
						seek         <= rate_seek;
						seek_timeout <= since < 16'd250 ? 12'd500 : {since[10:0], 1'b0};
					end
					else begin
						step_on  <= 1'b1;
						step_pos <= 12'd0;
						seek     <= SEEK_NONE;
						seek_pos <= 14'd0;
					end
				end
				ph <= 3'd2;
			end

			// rom_a: the spindle sample, then the head sample
			3'd2: ph <= 3'd3;
			3'd3: begin
				spin_val <= spin == SPIN_QUIET ? 10'sd0 : $signed(rom_q);
				ph <= 3'd4;
			end

			// Mix and move on
			3'd4: begin
				if (seek != SEEK_NONE || step_on)
					out <= mix > 11'sd511 ? 10'sd511 : mix < -11'sd511 ? -10'sd511 : mix[9:0];
				else
					out <= spin_val;

				if (spin != SPIN_QUIET) begin
					if (spin_pos + 13'd1 < spin_len) spin_pos <= spin_pos + 13'd1;
					else begin
						spin_pos <= 13'd0;
						case (spin)
							SPIN_START: spin <= SPIN_RUN;
							SPIN_RUN:   if (!motor_on) spin <= SPIN_END;
							SPIN_END:   if (motor_on) begin
							                spin    <= SPIN_START;
							                spin_ld <= loaded;
							            end
							            else spin <= SPIN_QUIET;
							default: ;
						endcase
					end
				end

				if (seek != SEEK_NONE) begin
					seek_pos <= seek_pos + 14'd1 < seek_len ? seek_pos + 14'd1 : 14'd0;
					if (seek_timeout == 12'd1) begin
						// The seek is over: the rest of the step sample, 10 ms on
						seek     <= SEEK_NONE;
						step_pos <= step_pos + 12'd250;
					end
					if (seek_timeout != 12'd0) seek_timeout <= seek_timeout - 12'd1;
				end
				else if (step_on) begin
					if (step_pos + 12'd1 < DS_STEP_LEN) step_pos <= step_pos + 12'd1;
					else begin
						step_on  <= 1'b0;
						step_pos <= 12'd0;
					end
				end
				ph <= 3'd0;
			end
			default: ph <= 3'd0;
		endcase
	end
end

endmodule
