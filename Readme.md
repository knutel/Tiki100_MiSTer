# Tiki100 for MiSTer

An FPGA recreation of the Tiki 100 (Tiki Data, Oslo, 1984), a Z80 home and
school computer. MAME's `tiki100` driver is used as the hardware reference.

Work in progress. Implemented so far: Z80 CPU (T80), 64 KB RAM, 32 KB video
RAM, boot ROM, PROM-based memory banking, system latch, I/O decoding, ROM
loading, video (all three graphics modes, palette, hardware scroll), and the
Z80 CTC, DART and PIO with mode 2 (daisy chain) interrupts, the keyboard, and
the FD1797 floppy controller with two drives, and the
AY-3-8912 sound chip. The serial ports, printer port and cassette aren't
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
| `boot.rom` | `tikirom-2.03w.u10` (TIKI ROM 2.03w) | 8 KB | 79662476 |
| `boot1.rom` | `53ls140.u4` (memory banking PROM) | 256 B | 894b756f |
| `boot2.rom` | `tikirom-1.35.u10` (TIKI ROM 1.35), optional | 8 KB | 7dac5ee7 |
| `boot3.rom` | `tikirom-1.30.u10` (TIKI ROM 1.30), optional | 8 KB | c482dcaf |

`boot.rom` and `boot1.rom` are required. Without `boot1.rom` the banking PROM
is empty and the CPU can't see the ROM. They come from MAME's `tiki100`
romset, which also has 1.35; 1.30 is in the `kontiki` set (a merged
`kontiki.zip` has all four). `sim/extract_roms.py` pulls them out of the zip
by CRC:

    python3 sim/extract_roms.py kontiki.zip out/

The OSD's **Boot ROM** option chooses between 2.03w (`boot.rom`), 1.35
(`boot2.rom`) and 1.30 (`boot3.rom`), like swapping the ROM chip. Changing it
resets the machine, and the choice is saved with the core's settings. If the
chosen file isn't on the SD card, the core runs `boot.rom`.

There are two resets. The OSD's **Reset** is like the Tiki 100's own reset
button: memory keeps its contents. The MiSTer's reset button is a power-on
reset: main RAM is filled again with its power-on contents (00 with 2.03w,
FF with 1.35 and 1.30). Use the button before running Darklite's "Tiki Tiki
Ta" a second time, because the demo needs RAM as it is at power-on.

## Disks

Mount disk images in the OSD as Drive A and Drive B. The core takes the raw
`.dsk` images from MAME's `tiki100` software list (for example
`tiko208r-400k.dsk`, TIKO 2.08r), with 512-byte sectors:

| Size | Format |
|---|---|
| 200 KB (204,800 bytes) | 40 tracks, single-sided, 10 sectors |
| 360 KB (368,640 bytes) | 40 tracks, double-sided, 9 sectors |
| 400 KB (409,600 bytes) | 40 tracks, double-sided, 10 sectors |
| 800 KB (819,200 bytes) | 80 tracks, double-sided, 10 sectors |

The 90 KB single density images (128-byte sectors) aren't supported.

With a disk in drive A, the boot ROM loads it on its own; TIKO shows its
program menu after about 10 seconds.

Writes go straight to the image file on the SD card, as on a real disk, so
keep a copy of images you want to keep unchanged. TIKO writes even when you
only run programs from a batch file: UTFØR (TIKO's SUBMIT) saves the
commands it is about to run in a `$$$.SUB` file. Disks that start a game
this way, like `invaders.dsk`, hang after printing "utfør 1.1" if they can't
write. An image the MiSTer can't write (a read-only file) shows as write
protected, and TIKO stops with "Feil på A: Lese/skrive feil" (read/write
error on A), as in MAME.

The floppy controller is `rtl/wd1793.sv` from the ZX Spectrum core, with a few
changes listed at the top of the file. It works on whole sectors of the
image rather than on the magnetic signal, but it models the disk's timing:
the disk turns at 300 rpm with MAME's track layout (10 sectors with 2:1
interleave), a sector's bytes come one every 32 µs while it passes under the
head, steps take the time the command asks for (6-30 ms), and the head
settles for 15 ms. A byte the CPU is too late for is lost and sets the lost
data status bit, as on the real chip. Each drive has its own copy, so unlike
the real FD1797 the two drives don't share one track register.

## Hard disk

The core has the Tiki 100's Winchester controller card (option 100/005, a
WD2010 at ports 20-27). The card is only there while an image is mounted
as **Hard disk** in the OSD; without one the machine is as before. With an
image mounted and no disk in drive A, TIKI ROM 2.03w boots from the hard
disk. The hard disk is then A: and B:, and the floppy drive is C:. With a disk in drive A, the ROM boots the floppy as usual.

The image is a raw 10 MB disk (`.hdf` or `.img`): 306 cylinders, 4 heads,
17 sectors of 512 bytes, 10,653,696 bytes, as TIKO 4.01 uses it. The
"Winchester systemdiskett (for TIKI med harddisk)" (MAME's `wcsys`, TIKO
4.01) assumes a hard disk that is already set up, so
`sim/tests/make_hd_image.py` sets one up from it the way a dealer would
have. The floppy's INSTALL writes the system to the hard disk, run in a MAME
that has the hard disk interface (MAME master since 2026-09-30, not yet in a
release). The script then copies the floppy's files to A::

    MAME=/path/to/mame python3 sim/tests/make_hd_image.py wcsys.dsk tiko401-hd.hdf

Copy the `.hdf` to `games/Tiki100/` and mount it as Hard disk. In the
hard disk system, C: reads 200 KB floppies (WD200C.SYS). See
`plans/hard-disk.md` for what is known about the card and how the image is
made.

## Printer port sync

Darklite's demo "Tiki Tiki Ta" needs a hardware mod: a cable from the
internal video expansion port to the printer port, with VSYNC on data line
D0 and HSYNC on D1 (both active high). The demo puts the PIO's port A in bit
mode with those two bits as inputs. It waits for D0 to rise once per frame,
and changes the palette from an interrupt that D1 raises on every line
(the raster bars). Without the cable it hangs on the boot ROM's screen, in
MAME too.

The OSD's **Printer port sync** option adds the cable. It is On by default.
With it On, the printer's D0 and D1 inputs follow the sync signals instead
of reading 1; turn it Off if other software misbehaves when it reads the
printer port. In the simulator, `--printer-sync 1` does
the same:

    sim/obj/Vsim_top sim/obj/boot.rom sim/obj/boot1.rom --printer-sync 1 \
        --disk0 darklite_-_tiki_tiki_ta.dsk --frames 1501 --dump 700 --dump 1500

We don't know where the real Tiki 100's VSYNC sits relative to the visible
lines, so raster effects that count lines from VSYNC may be a few lines off.

## Sound

The AY-3-8912 is `rtl/ym2149.sv` from the ZX Spectrum core, at 2 MHz with the
AY-3-8910 volume curve. It is mono, so both audio channels get the same
signal. Pitch, noise and envelopes match MAME; relative volume levels differ
somewhat, because MAME models the chip's output resistors and ym2149.sv uses
a volume table. Unused register bits read back as 0 like on a real AY-3-8910
(MAME returns all 8 bits for the 8912).

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
`MAME_SECONDS=n`, and `BOOTROM=1` or `BOOTROM=2` to check TIKI ROM 1.35
(MAME's `tiki100 -bios v135`) or 1.30 (MAME's `kontiki`) instead of 2.03w.
The simulator's `--boot2 FILE`, `--boot3 FILE` and `--bootrom N` options
load and choose the extra ROMs, and `--switch-rom F:N` switches to ROM N at
frame F, like the OSD option.

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

    make sound

runs `sim/tests/sound.asm` in the simulator and in MAME. It reads back AY
registers (the results must be identical) and plays a 440 Hz tone, an 880 Hz
tone at a lower volume, a tone shaped by the envelope generator, and noise.
The simulator records its sound with `--wav FILE` and MAME with
`-wavwrite`; `sim/tests/compare_sound.py` compares the pitch, envelope rate
and timing of each part, and reports the loudness without judging it.

    make tiko

boots TIKO from `tiko208r-400k.dsk` (unpacked from `tiko208r-400k.zip` in the
repository root, from MAME's software list) and compares frame 600 with
MAME booting the same disk (up to 16 pixels may differ, for the blinking
cursor). Options: `DISK=path/to/image.dsk`,
`TIKO_FRAME=n`. The simulator's `--disk0 FILE` and `--disk1 FILE` options
mount images (writes change only the simulator's copy; `--save0 FILE` saves
it at the end, `--readonly0 1` mounts it write protected);
`TRACE_FDC=file` logs every floppy controller access.

    make tikodir

does the same, but also chooses B (file list) from TIKO's menu with the key
presses in `sim/tests/keys_tiko_dir.txt`, and compares the directory listing
at frame 960. `TIKO_KEYS=file` replays other key presses with `make tiko`.

    make hdboot MAME=/path/to/mame-master

builds the hard disk image from the Winchester system floppy
(`HD_FLOPPY`, default `disk_images/wcsys.dsk`), boots it with no floppy,
chooses B (file list) and compares frame 1000 with MAME (which needs the hard
disk interface, MAME master since 2026-09-30). The simulator's `--hdd FILE`
mounts a hard disk image (`--savehdd FILE`, `--readonlyhdd 1` as for the
floppies).

    make hdwrite MAME=/path/to/mame-master

runs INSTALL from the hard disk in both, changes the automatic command and
writes the system back to the hard disk. The images must then be identical.

The T80 CPU is written in VHDL, which Verilator can't read. The Makefile uses
GHDL to convert it into a Verilog netlist (`sim/obj/T80pa.v`) that is only
used for simulation; Quartus builds from the original VHDL.

MAME's default `tiki100` machine has an 8088 card and a hard disk controller
in its expansion slots. `sim/mame_trace.sh` empties the slots so MAME matches
the core.

## Status

Hard disk: the Winchester controller card works in the simulator. TIKO 4.01
boots from a hard disk image made from the Winchester system floppy, the
file list matches MAME master's (`make hdboot`), and after INSTALL rewrites
the system the simulator's image is byte for byte the same as MAME's
(`make hdwrite`). It works on the MiSTer too.

Disk timing: the floppy controller now models a turning disk
(`plans/disk-timing.md`). Darklite's demo "The Hollow" runs on the MiSTer
and in the simulator with the printer port sync option. Its loader reads one sector
per frame and plays music while it waits for each byte; before, it hung
after about 3 seconds waiting for bytes the controller had dropped. It also
needed a PIO fix: in bit mode the interrupt now waits for the port to change
after a new mask is loaded, as in MAME. For TIKO's boot, sector read times match MAME's to
within a rotation, and `make tiko` still matches. `make tikodir` now
compares frame 960, because the core's drive needs 200 ms to be ready after
the motor restarts and MAME's doesn't. Invaders writes the same sectors as
before. Tiki Tiki Ta plays the same, a little later, because its loading
now takes real time.

Darklite's demo "Tiki Tiki Ta" runs to the end on the MiSTer with the
printer port sync option on. It needed three changes besides the option:
the CTC's timer mode counts the 4 MHz CPU clock, as the technical handbook
says (at MAME's 2 MHz the plasma's raster sequence doesn't fit in a frame);
the palette write happens at the end of HBLANK; and with TIKI ROM 2.03w,
RAM powers up as 00 instead of FF, because the demo reads a byte it never
loads (7202) and only carries on if it is 0. Because of the 4 MHz CTC, the
boot ROM's timer interrupt runs twice as fast as in MAME, so `make trace`
for 2.03w now matches MAME's trace for the first 912,562 instructions.

Boot ROM selection: TIKI ROMs 1.35 and 1.30 match MAME's traces
(`make trace BOOTROM=1`: 1,600,000 instructions; `BOOTROM=2`: all 1,011,776
MAME recorded), and 2.03w still matches. Both older ROMs copy their start-up
code to RAM one byte short and depend on RAM's power-on contents to end
their I/O setup table, so RAM now powers up as FF like MAME's, and changing
the boot ROM fills it with FF again. Switching from 2.03w to 1.30 at frame
150 gives the same screen 150 frames later as MAME's `kontiki`, and 1.35's
screen at frame 150 matches MAME's `-bios v135`.

Disk writes: the core now writes disk images back to the SD card.
`invaders.dsk` (started by TIKO's UTFØR batch command, which writes a
`$$$.SUB` file) reaches the game's title screen, and frame 1500 matches
MAME's pixel for pixel. The sectors it writes match MAME's (apart from 15
bytes of never-written RAM, 00 in the core and FF in MAME). With the image
write protected, TIKO stops with the same read/write error as MAME.

Milestone 6 (sound): `make sound` matches MAME: identical register
read-back, and the same pitch, noise rate, envelope rate and timing. In
TIKO's menu, Ctrl+G rings the bell, as in MAME. The scroll register now
follows the AY's port A pins (FF while port A is an input, as in MAME), and
the boot trace, video frames and TIKO boot still match.

Milestone 5 (floppy): TIKO 2.08r boots from both the 400 KB and the 200 KB
image in the simulator. Frame 600 shows TIKO's program menu as in MAME (the
200 KB boot matches exactly; with the 400 KB image only the blinking cursor
differs). Choosing B (file list) from the menu gives the same directory
listing as MAME, pixel for pixel. The boot without a disk still matches
MAME's instruction trace.

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
