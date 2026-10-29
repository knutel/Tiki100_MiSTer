//============================================================================
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

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;  

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;

assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v" 
localparam CONF_STR = {
	"Tiki100;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"v,0;", // [optional] config version 0-99. 
	        // If CONF_STR options are changed in incompatible way, then change version number too,
			  // so all options will get default values on first start.
	"V,v",`BUILD_DATE 
};

wire forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(1'b0),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys)
);

wire reset = RESET | status[0] | buttons[1];

///////////////////////   TIKI 100   /////////////////////////////

// Main_MiSTer loads boot.rom with index 0 and boot1.rom with index 0x40
// (index = N << 6) from games/Tiki100/ when the core starts.
wire rom_wr  = ioctl_download && ioctl_wr && ioctl_index[7:6] == 2'd0 && ioctl_addr < 27'h2000;
wire prom_wr = ioctl_download && ioctl_wr && ioctl_index[7:6] == 2'd1 && ioctl_addr < 27'h100;

wire [7:0] sys_latch;
wire       ce_pix, HSync, VSync, HBlank, VBlank;

tiki100 tiki100
(
	.clk(clk_sys),
	.reset(reset | ioctl_download),   // hold the CPU in reset while ROMs load

	.rom_wr(rom_wr),
	.prom_wr(prom_wr),
	.dl_addr(ioctl_addr[12:0]),
	.dl_data(ioctl_dout),

	.ps2_key(ps2_key),

	.sys_latch(sys_latch),

	// Serial, printer and cassette are not connected yet (milestone 7).
	// Idle levels as in MAME: no data on RxD, CTS and DCD active, and the
	// printer port reports ACK and NO PAPER high like MAME's default printer.
	.ser_rxd(2'b11),
	.ser_txd(),
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

	.ce_pix(ce_pix),
	.vga_r(VGA_R),
	.vga_g(VGA_G),
	.vga_b(VGA_B),
	.hsync(HSync),
	.vsync(VSync),
	.hblank(HBlank),
	.vblank(VBlank)
);

// Video goes straight to the framework. CLK_VIDEO is only 2x the dot clock,
// too slow for video_mixer's scandoubler, so analog VGA gets 15 kHz video.
// HDMI goes through the framework's scaler and is unaffected.
assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = ce_pix;
assign VGA_DE    = ~(HBlank | VBlank);
assign VGA_HS    = HSync;
assign VGA_VS    = VSync;

// GRAFIKK key LED (system latch bit 5) on the user LED, LOCK key LED
// (bit 7) on the power LED, drive 0 select (bit 0) on the disk LED.
assign LED_USER  = sys_latch[5];
assign LED_POWER = {1'b1, sys_latch[7]};
assign LED_DISK  = {1'b1, sys_latch[0]};

endmodule
