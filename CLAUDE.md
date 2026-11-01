# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# Tiki 100 core for MiSTer

An FPGA recreation of the Tiki 100 (Tiki Data, Oslo, 1984), a Z80 home and school computer, as a MiSTer core for the DE10-Nano, created from MiSTer-devel/Template_MiSTer.

Milestones 1-6 below are done and run on the owner's MiSTer: CPU, memory, video, CTC/DART/PIO, keyboard, floppy (with disk timing), sound, plus boot ROM selection, disk write-back, the printer port sync mod and the hard disk card. The README's Status section has the details and test results; `plans/` has work in progress and finished plans.

## Working with the owner

- The owner is a hobbyist, new to HDL beyond some MyHDL experiments. Explain hardware decisions briefly when you make them.
- The owner builds in Quartus and tests on the real MiSTer. You can't see the screen, so when a change needs hardware testing, say exactly what to copy to the SD card and what the owner should expect to see.
- Prefer simulation over hardware round trips. A full Quartus build takes many minutes.

## Rules

- **Quartus Prime Lite 17.0.x only.** Don't let any tool upgrade the project files to a newer Quartus version.
- **Don't edit `sys/`.** It is the MiSTer framework and is updated from the `template` git remote (`git fetch template && git checkout template/master -- sys`).
- The top-level module in `Tiki100.sv` must stay named `emu`. Glue between the framework and the core goes there; the core itself goes in `rtl/`.
- Add source files to `files.qip`, not to `Tiki100.qsf`. If Quartus adds files to the `.qsf`, move them to `files.qip`.
- **Never commit ROMs or disk images.** Add `*.rom`, `*.bin` and disk image extensions to `.gitignore`. The core loads ROMs from the SD card at startup.
- **One clock domain.** `clk_sys` runs at 40 MHz and everything slower uses clock enables, not derived clocks.
- Reuse existing MiSTer modules where they fit, keep their license headers, and only use GPL-compatible code.
- **Language:** SystemVerilog/Verilog by default. Ask the owner before writing a module in MyHDL. If MyHDL is used, keep the Python under `myhdl/`, commit the generated Verilog under `rtl/` so the core builds without Python, and document the regeneration command in the README.
- Keep commits small, one milestone step at a time.

## Gotchas

- **Line endings:** `Tiki100.sv`, `files.qip`, `rtl/wd1793.sv` and other template files are CRLF; `.gitignore` mixes CRLF (template lines) and LF (project lines). Python or `sed` rewrites can silently convert a whole file. Check with `file` and keep the existing endings.
- **The simulator doesn't compile `Tiki100.sv`** (`sim/sim_top.sv` instantiates `rtl/tiki100.sv` directly). Changes to the `emu` glue, CONF_STR or `hps_io` wiring are only checked by the owner's Quartus build, so check widths by hand. All of `hps_io`'s per-drive arrays (`sd_lba`, `sd_blk_cnt`, `sd_buff_din`, ...) must have `VDNUM` elements.
- **Quartus 17 stops a single loop after 5000 iterations:** nest loops (see the RAM `initial` block in `rtl/tiki100.sv`).
- **MAME writes to disk images:** give it copies. A compressed CHD is read-only to MAME (writes go to a `diff/` file), so create CHDs with `chdman ... -c none`.

## Primary reference: MAME's tiki100 driver

MAME's driver is the hardware spec. Current MAME keeps it in `src/mame/tiki/` (`tiki100.cpp`, `tiki100.h`); older trees used `src/mame/drivers/tiki100.cpp` and `src/mame/includes/tiki100.h`. The disk format is in `src/lib/formats/tiki100_dsk.cpp`. Read the source for anything below that's marked "verify". MAME's own TODO list: analog/digital I/O and light pen are not emulated, so they're out of scope for now, as is the 8088 CPU card. MAME master emulates the hard disk card since 2026-09-30 (not in 0.289 or older); the core has it (see Hard disk).

The Kontiki-100 technical handbook (`docs/tiki100_teknisk_handbok.pdf`, a Norwegian scan with OCR text) overrides MAME where they disagree. Don't load the whole PDF: extract it with `pdftotext -layout` and grep (the OCR puts spaces inside words). Known corrections to MAME so far: the CTC's timer mode counts 4 MHz, not 2 MHz (p. 14), and the palette write happens at the end of HBLANK (p. 37).

### Chips and clocks

| Part | Clock | Notes |
|---|---|---|
| Z80 CPU | 4 MHz (8 MHz crystal ÷ 2) | IM2 interrupts via daisy chain |
| Z80 CTC | 4 MHz (CPU clock) | Timers and baud rates. Timer mode counts 4 MHz (handbook p. 14, and p. 111: the monitor's channel 3 interrupt comes every 8 ms; MAME wrongly uses 2 MHz). TRG0/TRG1 count 2 MHz |
| Z80 DART | 2 MHz in MAME | Two serial ports. Baud clocks come from the CTC, so its own clock doesn't change behavior |
| Z80 PIO | 2 MHz in MAME | Centronics printer and cassette. No internal timing, so its own clock doesn't change behavior |
| AY-3-8912 | 2 MHz | Mono output; I/O port A drives the scroll register |
| FD1797 (or FD1767) | 1 MHz | Two 5.25" drives; MAME defaults to 80-track double-sided |
| Video | 20 MHz dot clock (separate crystal) | No CRTC chip; discrete logic |

With `clk_sys` = 40 MHz (`rtl/pll/pll_0002.v`): dot clock enable = ÷2, CPU and CTC = ÷10 (`cpu_cen_p` in `rtl/tiki100.sv`), AY, DART, PIO and CTC TRG0/TRG1 = ÷20 (`ce_2m`). The floppy controller runs on `cpu_cen_p`; its timing model counts in those 4 MHz ticks.

### ROMs (MAME romset `tiki100`)

| File | Size | CRC32 | Use |
|---|---|---|---|
| `tikirom-2.03w.u10` | 8 KB | 79662476 | Boot ROM, MAME default |
| `tikirom-1.35.u10` | 8 KB | 7dac5ee7 | Older boot ROM |
| `53ls140.u4` | 256 B | 894b756f | Memory banking PROM |

(The `kontiki` set has `tikirom-1.30.u10`.) MAME's ROM region is 16 KB with only the lower 8 KB populated; the rest reads 0xFF.

### Memory and banking

- 64 KB RAM, 32 KB video RAM, 8 KB ROM. Everything fits in block RAM; no SDRAM needed.
- A memory access looks up the PROM at address `{MDIS, VIRE, ROME, A15, A14, A13}`. MDIS is 1 when no expansion card claims the access (always 1 for us). The PROM output is **inverted** and contains four select bits: ROM0, ROM1, VIR and RAM0. Their bit positions are defined in MAME's `tiki100.h`: look them up, don't guess.
- Reads (MAME checks in this order, so later ones win): ROM0 reads `rom[A & 0x3FFF]`, ROM1 reads `rom[0x2000 | (A & 0x3FFF)]`, VIR reads `vram[(A + (scroll << 7)) & 0x7FFF]`, RAM0 reads `ram[A]`. If nothing is selected, the read returns 0xFF.
- Writes go to video RAM if VIR is set and to RAM if RAM0 is set (both if both are set). ROM is never written.
- Reset clears the system latch, so ROME = 0 and VIRE = 0, which maps the ROM in at boot.

### I/O map

Ports are decoded from address bits A7–A2 of the low byte (groups of four). Unmapped reads return 0xFF.

| Ports | Name | Read | Write |
|---|---|---|---|
| 00–03 | KEYS | Keyboard column (see Keyboard) | Reset column counter |
| 04–07 | SERS | DART | DART |
| 08–0B | PARS | PIO | PIO |
| 0C–0F | VIPB | – | Video mode / palette index |
| 10–13 | FLOP | FD1797 registers (A1–A0) | FD1797 registers |
| 14–17 | VIPS | 17: AY data | 14, 15: palette data; 16: AY address; 17: AY data |
| 18–1B | TIMS | CTC channels 0–3 | CTC channels 0–3 |
| 1C–1F | SYL | – | System latch |
| 20–27 | Hard disk | WD2010 (21–27), buffer (20) | Only while a hard disk image is mounted |

For both the DART (MAME's `cd_ba` addressing) and the PIO (MAME's generic `read`/`write`), A0 selects the channel/port (0 = A, 1 = B) and A1 selects control (1) or data (0). So 04 = DART A data, 06 = DART A control, 08 = PIO A data, 0A = PIO A control. In MAME the DART's CTS, DCD and RI inputs are unconnected and read as active, and the default Centronics printer reports ACK and NO PAPER high on PIO port B; the core copies both.

### Registers

**System latch (ports 1C–1F, write):**

| Bit | Signal | Function |
|---|---|---|
| 0 | DRIS0 | Select drive 0 |
| 1 | DRIS1 | Select drive 1 |
| 2 | _ROME | Enable ROM at 0000–3FFF (active low) |
| 3 | VIRE | Enable video RAM at 0000–7FFF or 4000–BFFF |
| 4 | SDEN | Density: 0 = double, 1 = single |
| 5 | _LMP0 | GRAFIKK key LED |
| 6 | MOTON | Floppy motor |
| 7 | _LMP1 | LOCK key LED |

**Video mode (ports 0C–0F, write):** bits 3–0 = palette index, bits 5–4 = mode, bit 6 unused, bit 7 = write palette entry during horizontal blanking.

**Palette data (ports 14–15, write):** stored **inverted**. Bits 7–5 = red, 4–2 = green, 1–0 = blue. At the end of every scanline (the end of HBLANK, handbook p. 37), if mode bit 7 is set, palette entry `mode[3:0]` gets the inverted palette value. That's 256 possible colors, 16 entries.

**Scroll register:** written through AY port A. 8 bits, in units of one line (128 bytes).

### Video

- 20 MHz dot clock, 1280 dots × 312 lines per frame (about 50.08 Hz, 15.625 kHz line rate). Visible area is 1024 × 256.
- Each line is 128 bytes of video RAM. 256 lines × 128 bytes = 32 KB.
- For each 16-dot group, fetch a 16-bit little-endian word from `((line + scroll) << 7) | (column << 1)`.
- A shift register shifts the word right by one bit every dot. A 4-bit pixel latch takes the low four bits of the shifter: every dot in mode 1, every 2nd dot in mode 2, every 4th dot in mode 3. Mode 0 holds the last pixel. The output is `palette[pixel latch]`.
  - Mode 3 = 256 × 256, 16 colors. Mode 2 = 512 × 256, 4 colors. Mode 1 = 1024 × 256, 2 colors.
  - In modes 1 and 2 the latch still holds four bits, and software sets up the palette so only the low bits matter. Copy this behavior exactly rather than "cleaning it up".
  - Bit 1 of the column counter is shifted into the top of the shifter (a test pattern normally hidden by the palette).
- Changes to mode, scroll and video RAM take effect at 16-dot group boundaries on real hardware. MAME only applies them once per line, and only one known demo needs finer timing. Start with per-line, but structure the design so per-group is possible later.
- Sync timing (handbook fig. 4.3, p. 38): 64 µs line, 13 µs HBLANK, 4.8 µs HSYNC starting about 1.6 µs into HBLANK (dots 1056–1151), VBLANK 3.6 ms (56 lines) + 16.4 ms (256 lines) = 312 lines. The handbook doesn't give VSYNC's line. The core uses line 280, which makes the raster effects in Darklite's demo "Tiki Tiki Ta" cover exactly the visible lines.
- Printer port sync (OSD option): that demo needs a hardware mod that connects VSYNC to Centronics data line D0 and HSYNC to D1, read through PIO port A in bit mode. Both are active high on the cable: the demo's disk loader treats D0 = 1 as "in VSYNC". The demo needs the 4 MHz CTC to fit its raster sequence into one frame.

### Wait states

Not in MAME; from the handbook's schematics (25085-1 U39, 25085-4 "processor interface" U126/U127) and the demos' author. Every M1 cycle gets one wait state. Video RAM is shared in 400 ns turns: SWCLK (dot clock ÷ 16) high = video fetch, low = CPU; a CPU access to video RAM (VIR from the MREQ-enabled PROM, plus RD or WR) waits until a whole SWCLK-low period has passed, then WAIT ends at the next CPU clock edge: 2-5 wait states per read, 2-4 per write. `rtl/tiki100.sv` models the flip-flops gate by gate; `cpu_waits` (OSD option, simulator `--waits`, Makefile `WAITS`) turns them off.

### Interrupts

IM2 daisy chain, highest priority first: CTC, DART, PIO, then the three expansion slots (unused).

### CTC and serial wiring

- TRG0 and TRG1 are clocked at 2 MHz. Timer mode counts the 4 MHz CPU clock.
- ZC/TO0 (called BAR0) drives CTC TRG2, DART RxCA, and DART TxCA when the ST jumper is 0.
- ZC/TO1 drives DART RxTxCB.
- ZC/TO2 (BAR2) drives DART TxCA when ST is 1, and CTC TRG3.
- MAME's default ST setting is 1 (BAR2).

### PIO

- Port A: Centronics printer data.
- Port B: bit 0 = printer strobe (out), bit 4 = ACK (in), bit 5 = BUSY (in), bit 6 = tape out / NO PAPER in, bit 7 = tape in.
- Bit mode (mode 3) interrupts when the logic equation becomes true, evaluated only when the port's value changes, as in MAME. A new mask doesn't interrupt even if the equation is already true. "The Hollow" loads an HSYNC mask and then HALTs, so an immediate interrupt hangs it.

### Keyboard

- Reading port 00 returns the current column (active low, 1 = not pressed) and then advances a 4-bit counter. Columns 12–15 return 0xFF. Writing port 00 resets the counter to 0.
- Matrix (column = counter value, bits 0–7):

| Col | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| 0 | CTRL | SHIFT | BRYTT | RETUR | MLMROM (space) | / (num) | SLETT | – |
| 1 | GRAFIKK | 1 | ANGRE | A | < | Z | Q | LOCK |
| 2 | 2 | W | S | X | 3 | E | D | C |
| 3 | 4 | R | F | V | 5 | T | G | B |
| 4 | 6 | Y | H | N | 7 | U | J | M |
| 5 | 8 | I | K | , | 9 | O | L | . |
| 6 | 0 | P | Ø | - | + | Å | Æ | HJELP |
| 7 | @ | ^ | ' | Left | UTVID | F1 | F4 | SIDEOPP |
| 8 | F2 | F3 | F5 | F6 | Up | SIDENED | VTAB | Down |
| 9 | + (num) | - (num) | * (num) | 7 (num) | 8 (num) | 9 (num) | % (num) | = (num) |
| 10 | 4 (num) | 5 (num) | 6 (num) | HTAB | 1 (num) | 0 (num) | . (num) | – |
| 11 | HJEM | Right | 2 (num) | 3 (num) | ENTER (num) | – | – | – |

- MAME's PC mapping: BRYTT = Esc, SLETT = Backspace, ANGRE = Delete, GRAFIKK = Left Alt, LOCK = Caps Lock, UTVID = Insert, SIDEOPP = Page Up, SIDENED = Page Down, HJEM = Home, HTAB = Tab. Ø, Å, Æ go on the keys a Norwegian PC keyboard has them on. HJELP, VTAB, % and = have no default in MAME; the core uses F7, F8, Num Lock and F9 (documented in the README and `rtl/tiki100_keyboard.sv`).
- The key LEDs go to the MiSTer LEDs: GRAFIKK (latch bit 5) on the user LED, LOCK (bit 7) on the power LED, with the latch bit's polarity, as in MAME.

### Disks

FD1797 with two drives. Drive select, motor and density come from the system latch. Use MAME's `tiki100_dsk.cpp` for the disk image geometries. MAME's floppy software list `tiki100` shows which images exist.

The controller models disk timing (`plans/disk-timing.md`, done): a rotating disk with MAME's track layout (2:1 interleave, 32 µs per byte), step and settle times from the handbook (pages 26-31), lost data for late bytes, and Record Not Found after 5 index pulses. Darklite's demo "The Hollow" needs it, because its loader reads one sector per frame from the VSYNC interrupt. Sector read durations match MAME's within a rotation. Known differences from MAME: MAME's drive stays ready while the motor is off (ours needs 200 ms after the motor restarts), and MAME's Read Address and Restore take longer.

### Hard disk

`rtl/tiki100_hdc.sv`: the Winchester controller card (option 100/005), a WD2010 with a 1 KB buffer at ports 20-27, following MAME master's `bus/tiki100/hdc.cpp` and `machine/wd2010.cpp`. The card exists only while an image is mounted (hps_io drive 2, "Hard disk" in the OSD); otherwise ports 20-27 read FF. With an image and no floppy, ROM 2.03w boots from it. Geometry is TIKO 4.01's 10 MB disk: 306 cylinders × 4 heads × 17 sectors of 512 bytes, block = (C × 4 + H) × 17 + S - 1. `sim/tests/make_hd_image.py` builds a bootable image from the Winchester system floppy (`wcsys`); it needs MAME master (`MAME=`). `make hdboot` tests the boot against MAME. Details and the protocol: `plans/hard-disk.md`.

## Code map

- `Tiki100.sv` (module `emu`): CONF_STR and OSD status bits (`[0]` OSD Reset, `[2:1]` boot ROM, `[4]` printer port sync, `[5]` drive sounds, `[6]` wait states, 0 = on; `[122:121]` aspect ratio), `hps_io` (`VDNUM=3`: drives A, B and the hard disk), boot ROM download routing (`ioctl_index[7:6]` slot), resets (OSD Reset and changing the boot ROM are warm resets; the MiSTer's reset button, `buttons[1]`, is a power-on reset that refills RAM), audio and video to the framework.
- `rtl/tiki100.sv`: the machine. T80 CPU, ROM/RAM/VRAM and PROM banking, power-on RAM fill, I/O decode and the `io_dout` read mux, system latch, keyboard counter, IM2 daisy chain (`int_vector`, `reti` decoding), the two `wd1793` instances (`fdd[0]`, `fdd[1]`) and the hard disk card.
- `rtl/tiki100_video.sv` (shifter, palette, sync; `PER_GROUP` parameter), `rtl/tiki100_drive_sound.sv` (floppy motor and step sounds: MAME's CC0 drive samples in block RAM, `rtl/tiki100_drive_sound.hex`/`.svh` generated by `tools/make_drive_sound_rom.py`, played like MAME's `drivesound.cpp`), `rtl/tiki100_keyboard.sv` (PS/2 scancode to matrix table, also parsed by `sim/tests/mame_keys.py` and `check_keymap.py`), `rtl/z80ctc.sv`, `rtl/z80dart.sv`, `rtl/z80pio.sv` (written for this core, following MAME), `rtl/tiki100_hdc.sv` (WD2010 card), `rtl/wd1793.sv` (FD1797, adapted from the Spectrum core), `rtl/ym2149.sv`, `rtl/T80/`.
- `sim/`: `sim_top.sv` flattens the core's ports for the C++ testbench `sim_main.cpp` (frame dumps, key replay, SD card emulation for the disk images, traces). The Makefile converts the VHDL T80 to Verilog with GHDL for Verilator. Outputs, extracted ROMs and disk images go in `sim/obj/` (gitignored).

## Commands

Simulation (from `sim/`; needs verilator, ghdl, z80asm, python3 and mame; ROMs come from `kontiki.zip` in the repo root):

    make                  # build sim/obj/Vsim_top
    make roms             # extract the ROMs from the romset zip into sim/obj/
    make trace            # boot ROM instruction trace vs MAME (BOOTROM=1/2 for ROM 1.35/1.30)
    make frame FRAME=100  # compare a boot screen frame with a MAME snapshot
    make iotest           # CTC/DART/PIO test ROM vs MAME
    make kbdtest          # key replay into the keyboard test ROM vs MAME
    make sound            # AY test ROM vs MAME (register read-back and recorded sound)
    make tiko             # boot TIKO from a floppy and compare frame TIKO_FRAME with MAME (DISK=, TIKO_KEYS=)
    make tikodir          # tiko plus the menu's file list
    make hdboot MAME=...  # hard disk boot vs MAME (needs MAME master and chdman, see Hard disk)
    make hdwrite MAME=... # hard disk writes vs MAME

Running the simulator directly (options are documented at the top of `sim/sim_main.cpp`):

    obj/Vsim_top obj/boot.rom obj/boot1.rom --disk0 copy.dsk --frames 600 --dump 600 --outdir DIR \
        [--keys FILE] [--printer-sync 1] [--hdd FILE] [--reset F:C] [--trace FILE] [--wav FILE]

`TRACE_FDC=file` logs floppy and hard disk controller accesses. The simulator runs at about 1.3 frames per second, so run long jobs in the background and in parallel. Run the simulator from `sim/`: it reads the drive sound samples from `../rtl/tiki100_drive_sound.hex`. Rebuilding `Vsim_top` while a run is in progress is safe, but don't start several `make` targets at once after an RTL or Makefile change, because they all try to rebuild it.

The FPGA build is done by the owner in Quartus (`Tiki100.qpf`); the result is `output_files/Tiki100.rbf`, and errors are in `output_files/Tiki100.map.rpt`.

## MiSTer integration

### Modules to reuse

From MiSTer-devel/ZX-Spectrum_MISTer, `rtl/`:

- `T80/`: Z80 CPU. Use `T80pa` (separate positive and negative clock enables) or `T80s`.
- `ym2149.sv`: AY-3-8910-family sound. Our copy in `rtl/` is unmodified; `sim/Makefile` makes a simulation-only copy because Verilator rejects its volume table declaration.
- `wd1793.sv`: WD1793-family floppy controller with an SD-backed mode (`RWMODE=1`) for reading images through `hps_io`'s `sd_*` interface. Our copy has diverged from upstream: fixes and a rotating-disk timing model, all listed in its header. Don't replace it from upstream.

The Spectrum core has no Z80 CTC, PIO or DART; this core's are its own, tested against MAME with `make iotest`.

### ROM loading

At core start, Main_MiSTer loads `boot0.rom`…`boot3.rom` from `games/Tiki100/` with `ioctl_index` = N << 6 (so 0x00, 0x40, 0x80, 0xC0), then falls back to `boot.rom` (index 0) if there's no `boot0.rom`. The core uses `boot.rom` = TIKI ROM 2.03w, `boot1.rom` = the banking PROM, `boot2.rom`/`boot3.rom` = TIKI ROM 1.35/1.30 (the OSD's Boot ROM option). The CPU is held in reset while they load. The README lists the files.

### Video, audio, input

- `CLK_VIDEO` = `clk_sys`, `CE_PIXEL` = the 20 MHz enable. Set the aspect ratio to 4:3 in the framework (the template has the `ARC` options). 15 kHz output works with the framework's scandoubler.
- AY output is mono; send it to both audio channels.
- Keyboard input comes from `hps_io`'s `ps2_key` (bit 10 toggles on each event, bit 9 = pressed, bit 8 = extended, bits 7–0 = scancode).
- Disk images: `hps_io` `VDNUM=3`, CONF_STR entries `S0`/`S1` (floppies) and `S2` (hard disk).

## Testing

- **Simulation first**, against MAME as the reference (see Commands). The test targets compare traces, frames, test ROM results or disk images with MAME's.
- **Wait states:** MAME has none, so the Makefile's MAME comparisons run with `WAITS=0` by default. With waits on, the boot banner appears later than MAME's frame 100 and `make sound`'s CPU-timed notes are longer.
- **Known, expected differences from MAME:** `make trace` for ROM 2.03w diverges at instruction 912,562 because the CTC timer counts 4 MHz (handbook) instead of MAME's 2 MHz; `tikodir` compares frame 960 because the core's drive needs 200 ms to be ready after the motor restarts.
- **Investigating software that misbehaves:** see `sim/DEBUGGING.md` (simulator probes, frame-limited traces, memory dumps, MAME Lua taps and debugger, time budgets). Work in progress is tracked in `plans/`; check there first when starting a session.
- **Hardware check:** after each change that needs it, tell the owner which `.rbf`, ROM and disk image files to copy, and what should appear.

## Milestones

1-6 are done: CPU/memory/banking/I/O decode, video, CTC/PIO/DART with IM2 interrupts, keyboard, floppy, sound. Done from the extras: disk write-back to SD, boot ROM selection in the OSD, the printer port sync mod, floppy disk timing, the hard disk card, drive sounds, wait states.

A license review of all third-party material (MAME's drive sound samples, the reused MiSTer modules, MAME-derived code) is still to do; the owner wants it done later, as a separate step.

Remaining extras: cassette via MiSTer's ADC input, serial and printer ports to MiSTer I/O, per-16-dot video timing (`PER_GROUP` exists in `rtl/tiki100_video.sv` but is off), optional 31 kHz scandoubled analog VGA output (needs a `CLK_VIDEO` of at least 4× the 20 MHz dot clock for `video_mixer`). Simulate each change before it's tried on hardware.

## Links

- MAME driver (2020 copy, BSD-3): https://git.redump.net/hbmame/tree/src/mame/drivers/tiki100.cpp
- Current MAME source: https://github.com/mamedev/mame (`src/mame/tiki/`)
- MiSTer template: https://github.com/MiSTer-devel/Template_MiSTer
- ZX Spectrum core (T80, AY, WD1793): https://github.com/MiSTer-devel/ZX-Spectrum_MISTer
- Main_MiSTer (ARM-side code, e.g. boot ROM loading in `user_io.cpp`): https://github.com/MiSTer-devel/Main_MiSTer
- Tiki 100 overview: https://en.wikipedia.org/wiki/Tiki-100
