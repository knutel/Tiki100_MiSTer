# Tiki100 for MiSTer

An FPGA recreation of the Tiki 100 (Tiki Data, Oslo, 1984), a Z80 home and
school computer. MAME's `tiki100` driver is used as the hardware reference.

Work in progress. Implemented so far: Z80 CPU (T80), 64 KB RAM, 32 KB video
RAM, boot ROM, PROM-based memory banking, system latch, I/O decoding, ROM
loading, video (all three graphics modes, palette, hardware scroll), and the
Z80 CTC, DART and PIO with mode 2 (daisy chain) interrupts, and the keyboard.
No floppy or sound yet. The serial ports, printer port and cassette aren't
connected to the MiSTer's I/O yet.

Video is 1024 x 256 at 50 Hz with 15.6 kHz line rate. HDMI works through the
MiSTer scaler. Analog VGA users get 15 kHz video: the core doesn't scandouble
to 31 kHz yet.

## Keyboard

Keys map by position, like MAME: on a Norwegian PC keyboard the letters, Ø,
Æ, Å, +, -, ' and < are where the Tiki 100 has them. Tiki keys without a PC
equivalent:

| Tiki 100 | PC key |
|---|---|
| BRYTT | Esc |
| SLETT | Backspace |
| ANGRE | Delete |
| GRAFIKK | Left Alt |
| LOCK | Caps Lock |
| UTVID | Insert |
| HJEM | Home |
| HTAB | Tab |
| SIDEOPP / SIDENED | Page Up / Page Down |
| @ | the key left of Backspace (\ on a Norwegian keyboard) |
| ^ | the key left of Enter (¨ on a Norwegian keyboard) |
| HJELP | F7 |
| VTAB | F8 |
| % (keypad) | Num Lock |
| = (keypad) | F9 |

Both Ctrl keys are CTRL and both Shift keys are SHIFT. The GRAFIKK key's LED
shows on the MiSTer's user LED and the LOCK key's LED on the power LED.

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

Needs `make`, `verilator`, `ghdl`, `python3`, `z80asm` for the test ROM, and
`mame` for the reference runs:

    sudo apt install make verilator ghdl z80asm mame

Put a `tiki100.zip` or `kontiki.zip` romset in the repository root (it's
ignored by git), then:

    cd sim
    make trace

This builds the simulator, runs the boot ROM for 1,000,000 instructions,
records a MAME trace of the same boot and reports the first instruction where
they differ. Options: `ROMSET=path/to/zip`, `INSTRUCTIONS=n`,
`MAME_SECONDS=n`.

MAME's scheduler sometimes takes an interrupt an instruction or two earlier or
later than the core does (the core is cycle-exact; MAME runs the CPU in time
slices). The comparison allows for that: when the traces disagree it looks
for a small skip on either side after which they agree again, and reports
each one as a "resync". Use `--strict` with `compare_trace.py` to turn this
off.

    make frame

runs the core for 100 frames (2 seconds), saves the last one as
`obj/frame_0100.png`, takes a MAME snapshot of the same frame and compares
them pixel by pixel. Differences are marked red in `obj/diff_100.png`. Use
`FRAME=n` for another frame.

    make iotest

assembles `sim/tests/iotest.asm`, a test program for the CTC, DART and PIO,
and runs it in place of the boot ROM in both the simulator and MAME, with
both serial ports looped back (TxD to RxD). The program writes its results
to port FF, which nothing decodes; the two result lists must be identical.
It covers the PIO registers and bit control interrupt, CTC timer and counter
interrupts, polled and interrupt-driven serial transfers on both DART
channels, receive overrun, the DART's modified vectors, and interrupt
priority between the CTC and the DART.

    make kbdtest

runs `sim/tests/kbdtest.asm`, which scans the keyboard like the TIKI ROM and
writes the whole key matrix to port FF whenever it changes, while the key
presses in `sim/tests/keys_kbdtest.txt` are replayed. The simulator gets them
as PS/2 scancodes, like the MiSTer sends them; `sim/tests/mame_keys.py`
presses the same Tiki keys in MAME. The simulator's `--keys FILE` option
takes the same file format for any other test.
`sim/tests/check_keymap.py` checks the scancode table against the key
definitions in MAME's `tiki100.cpp` source.

The T80 CPU is written in VHDL, which Verilator can't read. The Makefile uses
GHDL to convert it into a Verilog netlist (`sim/obj/T80pa.v`) that is only
used for simulation; Quartus builds from the original VHDL.

MAME's default `tiki100` machine has an 8088 card and a hard disk controller
in its expansion slots. `sim/mame_trace.sh` empties the slots so MAME matches
the core.

## Status

Milestone 4 (keyboard): `make kbdtest` gives the same 33 key matrix states
as MAME, and the scancode table agrees with all 88 keys MAME maps to PC
keys. With the boot ROM, pressing B at frame 300 starts a disk boot that
times out to "Sett inn en TIKI diskett og trykk B" (insert a TIKI disk and
press B) by frame 850, as in MAME; frames 850 and 900 match MAME's.

Milestone 3 (CTC, DART, PIO, interrupts): `make iotest` gives the same 48
results as MAME. The boot trace now runs through the CTC's 62.5 Hz timer
interrupts and matches all 1,598,393 instructions MAME traced (`MAME_SECONDS=4`),
with 4 resyncs where MAME took a timer interrupt one instruction earlier or
later than the core. Frame 300 (6 seconds in, with the monitor's cursor below
the banner) matches MAME's snapshot. The CTC, DART and PIO are new modules
(`rtl/z80ctc.sv`, `rtl/z80dart.sv`, `rtl/z80pio.sv`) written from MAME's
`z80ctc.cpp`, `z80sio.cpp` and `z80pio.cpp`; the DART only does asynchronous
serial, which is all a DART can do.

Milestone 2 (video): frame 100 of the boot (the "TIKI 100 / Monitor - ver
2.03 W" banner) matches MAME's snapshot pixel for pixel. Mode and scroll
changes take effect once per line, like MAME; set `PER_GROUP` to 1 in
`rtl/tiki100_video.sv` to apply them every 16 dots like the real hardware.

Milestone 1 (CPU, memory, banking, I/O decode) matches MAME's trace for the
first 916,222 instructions of TIKI ROM 2.03w. That covers the RAM and video
RAM tests, the move to high RAM and the switch to the RAM/VRAM memory map.
At that point the ROM enables interrupts and MAME takes the first CTC
interrupt, which came with milestone 3.
