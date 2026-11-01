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


assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v" 
localparam CONF_STR = {
	"Tiki100;;",
	"-;",
	"S0,DSK,Drive A:;",
	"S1,DSK,Drive B:;",
	"S2,HDFIMG,Hard disk;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[2:1],Boot ROM,2.03w,1.35,1.30;",
	"O[4],Printer port sync,On,Off;",
	"O[5],Drive sounds,On,Off;",
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

wire   [2:0] img_mounted;
wire   [2:0] img_readonly;
wire  [63:0] img_size;
wire  [31:0] sd_lba[3];
wire   [2:0] sd_rd, sd_wr, sd_ack;
wire  [13:0] sd_buff_addr;
wire   [7:0] sd_buff_dout;
wire   [7:0] sd_buff_din[3];
wire         sd_buff_wr;
wire   [5:0] sd_blk_cnt[3] = '{6'd0, 6'd0, 6'd0};   // one 512-byte block per request

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(3)) hps_io
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

	.ps2_key(ps2_key),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys)
);

// Changing the boot ROM in the OSD resets the machine: rom_sel follows the
// menu only while reset is active, so the reset lasts until it has.
wire [1:0] rom_sel_osd = (status[2:1] == 2'd3) ? 2'd0 : status[2:1];
reg  [1:0] rom_sel = 2'd0;
wire reset = RESET | status[0] | buttons[1] | (rom_sel != rom_sel_osd);
always @(posedge clk_sys) if (reset) rom_sel <= rom_sel_osd;

///////////////////////   TIKI 100   /////////////////////////////

// Main_MiSTer loads bootN.rom with index N << 6 from games/Tiki100/ when the
// core starts (boot.rom if there is no boot0.rom). boot1.rom is the banking
// PROM; boot.rom, boot2.rom and boot3.rom are the boot ROMs the OSD's
// "Boot ROM" option chooses from (2.03w, 1.35, 1.30).
wire [1:0] dl_slot = ioctl_index[7:6];
wire rom_wr  = ioctl_download && ioctl_wr && dl_slot != 2'd1 && ioctl_addr < 27'h2000;
wire prom_wr = ioctl_download && ioctl_wr && dl_slot == 2'd1 && ioctl_addr < 27'h100;

wire [7:0] sys_latch;
wire [11:0] audio;

// The AY-3-8912 and the drive sounds are mono: the same unsigned signal on
// both channels
assign AUDIO_S   = 0;
assign AUDIO_L   = {audio, 4'd0};
assign AUDIO_R   = {audio, 4'd0};
assign AUDIO_MIX = 0;
wire       ce_pix, HSync, VSync, HBlank, VBlank;

tiki100 tiki100
(
	.clk(clk_sys),
	.reset_in(reset | ioctl_download),   // hold the CPU in reset while ROMs load
	.cold_reset(buttons[1]),             // the MiSTer's reset button: power-on reset, clears RAM

	.rom_wr(rom_wr),
	.rom_slot(dl_slot == 2'd0 ? 2'd0 : dl_slot - 2'd1),
	.rom_sel(rom_sel),
	.prom_wr(prom_wr),
	.dl_addr(ioctl_addr[12:0]),
	.dl_data(ioctl_dout),

	.ps2_key(ps2_key),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr[8:0]),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),

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
	// Printer port sync: Darklite's demo "Tiki Tiki Ta" needs a hardware
	// mod, a cable from the internal video expansion port to the printer
	// port with VSYNC on data line D0 and HSYNC on D1. The demo puts PIO
	// port A in bit mode with bits 0-1 as inputs, waits for D0 to rise once
	// per frame and takes an interrupt when D1 falls on every line. Both are
	// active high: its disk loader treats D0 = 1 as "in VSYNC" and plays the
	// music then. With the option off the lines read FF. The option is on
	// by default (status bit 4 = 0; bit 3 held it when it was off by default).
	.par_data_in(!status[4] ? {6'b111111, HSync, VSync} : 8'hFF),
	.par_strobe(),
	.par_ack(1'b1),
	.par_busy(1'b0),
	.par_perror(1'b1),
	.tape_out(),
	.tape_in(1'b0),

	.audio(audio),
	.drive_sound(!status[5]),            // OSD "Drive sounds", on by default

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
