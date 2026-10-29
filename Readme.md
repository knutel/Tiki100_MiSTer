# Tiki100 for MiSTer

An FPGA recreation of the Tiki 100 (Tiki Data, Oslo, 1984), a Z80 home and
school computer. MAME's `tiki100` driver is used as the hardware reference.

Work in progress. Implemented so far: Z80 CPU (T80), 64 KB RAM, 32 KB video
RAM, boot ROM, PROM-based memory banking, system latch, I/O decoding, ROM
loading and video (all three graphics modes, palette, hardware scroll). No
keyboard, floppy, sound or interrupts yet.

Video is 1024 x 256 at 50 Hz with 15.6 kHz line rate. HDMI works through the
MiSTer scaler. Analog VGA users get 15 kHz video: the core doesn't scandouble
to 31 kHz yet.

## ROM files

ROMs are not included. Put these files in `games/Tiki100/` on the SD card:

| SD card file | MAME file | Size | CRC32 |
|---|---|---|---|
| `boot.rom` | `tikirom-2.03w.u10` | 8 KB | 79662476 |
| `boot1.rom` | `53ls140.u4` (memory banking PROM) | 256 B | 894b756f |

Both come from MAME's `tiki100` romset (also included in a merged `kontiki`
set). `sim/extract_roms.py` pulls them out of the zip by CRC:

    python3 sim/extract_roms.py kontiki.zip out/

Both files are required. Without `boot1.rom` the banking PROM is empty and the
CPU can't see the ROM.

## Simulation

Needs `make`, `verilator`, `ghdl`, `python3`, and `mame` for the reference
trace:

    sudo apt install make verilator ghdl mame

Put a `tiki100.zip` or `kontiki.zip` romset in the repository root (it's
ignored by git), then:

    cd sim
    make trace

This builds the simulator, runs the boot ROM for 1,000,000 instructions,
records a MAME trace of the same boot and reports the first instruction where
they differ. Options: `ROMSET=path/to/zip`, `INSTRUCTIONS=n`,
`MAME_SECONDS=n`.

    make frame

runs the core for 100 frames (2 seconds), saves the last one as
`obj/frame_0100.png`, takes a MAME snapshot of the same frame and compares
them pixel by pixel. Differences are marked red in `obj/diff_100.png`. Use
`FRAME=n` for another frame.

The T80 CPU is written in VHDL, which Verilator can't read. The Makefile uses
GHDL to convert it into a Verilog netlist (`sim/obj/T80pa.v`) that is only
used for simulation; Quartus builds from the original VHDL.

MAME's default `tiki100` machine has an 8088 card and a hard disk controller
in its expansion slots. `sim/mame_trace.sh` empties the slots so MAME matches
the core.

## Status

Milestone 2 (video): frame 100 of the boot (the "TIKI 100 / Monitor - ver
2.03 W" banner) matches MAME's snapshot pixel for pixel. Mode and scroll
changes take effect once per line, like MAME; set `PER_GROUP` to 1 in
`rtl/tiki100_video.sv` to apply them every 16 dots like the real hardware.

Milestone 1 (CPU, memory, banking, I/O decode) matches MAME's trace for the
first 916,222 instructions of TIKI ROM 2.03w. That covers the RAM and video
RAM tests, the move to high RAM and the switch to the RAM/VRAM memory map.
The traces diverge where the ROM enables interrupts and MAME takes the first
CTC interrupt, which this core doesn't have yet.
