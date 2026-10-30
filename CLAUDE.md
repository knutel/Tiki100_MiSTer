# Tiki 100 core for MiSTer

An FPGA recreation of the Tiki 100 (Tiki Data, Oslo, 1984), a Z80 home and school computer, as a MiSTer core for the DE10-Nano.

The project was created from MiSTer-devel/Template_MiSTer. The template builds and runs on the owner's MiSTer. Nothing Tiki-specific has been written yet.

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

## If the repo still uses Template names

Rename `Template.{qpf,qsf,sdc,srf,sv}` and `Template_Q13.{qpf,qsf,srf}` to `Tiki100*` with `git mv`, then update `PROJECT_REVISION` in the `.qpf` files, the `Template.sdc` and `Template.sv` entries in `files.qip`, and the first CONF_STR entry (`"Template;;"` becomes `"Tiki100;;"`). The CONF_STR name also sets the SD card folder: `games/Tiki100/`.

## Primary reference: MAME's tiki100 driver

MAME's driver is the hardware spec. Current MAME keeps it in `src/mame/tiki/` (`tiki100.cpp`, `tiki100.h`); older trees used `src/mame/drivers/tiki100.cpp` and `src/mame/includes/tiki100.h`. The disk format is in `src/lib/formats/tiki100_dsk.cpp`. Read the source for anything below that's marked "verify". MAME's own TODO list: hard disk, analog/digital I/O, light pen and the 8088 CPU card are not emulated, so they're out of scope for now.

### Chips and clocks

| Part | Clock | Notes |
|---|---|---|
| Z80 CPU | 4 MHz (8 MHz crystal ÷ 2) | IM2 interrupts via daisy chain |
| Z80 CTC | 2 MHz | Timers and baud rates |
| Z80 DART | 2 MHz | Two serial ports |
| Z80 PIO | 2 MHz | Centronics printer and cassette |
| AY-3-8912 | 2 MHz | Mono output; I/O port A drives the scroll register |
| FD1797 (or FD1767) | 1 MHz | Two 5.25" drives; MAME defaults to 80-track double-sided |
| Video | 20 MHz dot clock (separate crystal) | No CRTC chip; discrete logic |

With `clk_sys` = 40 MHz: dot clock enable = ÷2, CPU = ÷10, peripherals = ÷20, FDC = ÷40. The template's PLL currently outputs 20 MHz; change `output_clock_frequency0` in `rtl/pll/pll_0002.v` to `"40.000000 MHz"` (or ask the owner to regenerate it in the Quartus IP editor).

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

**Palette data (ports 14–15, write):** stored **inverted**. Bits 7–5 = red, 4–2 = green, 1–0 = blue. At the end of every scanline, if mode bit 7 is set, palette entry `mode[3:0]` gets the inverted palette value. That's 256 possible colors, 16 entries.

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
- MAME doesn't model sync and porch positions. Use standard PAL-like timings until a schematic says otherwise. Wikipedia cites a Norwegian article on the Rev C video circuit ("Videokretsen i TIKI-100 Rev C") that may have details.
- MAME TODO: some demos expect VSYNC on a PIO pin. Leave a hook for it.

### Interrupts

IM2 daisy chain, highest priority first: CTC, DART, PIO, then the three expansion slots (unused).

### CTC and serial wiring

- TRG0 and TRG1 are clocked at 2 MHz.
- ZC/TO0 (called BAR0) drives CTC TRG2, DART RxCA, and DART TxCA when the ST jumper is 0.
- ZC/TO1 drives DART RxTxCB.
- ZC/TO2 (BAR2) drives DART TxCA when ST is 1, and CTC TRG3.
- MAME's default ST setting is 1 (BAR2).

### PIO

- Port A: Centronics printer data.
- Port B: bit 0 = printer strobe (out), bit 4 = ACK (in), bit 5 = BUSY (in), bit 6 = tape out / NO PAPER in, bit 7 = tape in.

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

## MiSTer integration

### Modules to reuse

From MiSTer-devel/ZX-Spectrum_MISTer, `rtl/`:

- `T80/`: Z80 CPU. Use `T80pa` (separate positive and negative clock enables) or `T80s`.
- `ym2149.sv`: AY-3-8910-family sound.
- `wd1793.sv`: WD1793-family floppy controller. It has `size_code`, `layout`, `side` and `ready` inputs and an SD-backed mode (`RWMODE=1`) for reading images through `hps_io`'s `sd_*` interface. Our copy in `rtl/` has small fixes (listed in its header); keep them if you update it from upstream.

The Spectrum core has no Z80 CTC, PIO or DART. Look for GPL-compatible implementations in other MiSTer/MiST cores first. If you write your own, implement only the modes the TIKI ROM and TIKO use at first, and test them against MAME's behavior.

### ROM loading

At core start, Main_MiSTer loads `boot0.rom`…`boot3.rom` from `games/Tiki100/` with `ioctl_index` = N << 6 (so 0x00, 0x40, 0x80, 0xC0), then falls back to `boot.rom` (index 0) if there's no `boot0.rom`. Plan:

- `boot.rom` = TIKI ROM (8 KB) → index 0x00
- `boot1.rom` = `53ls140.u4` PROM (256 bytes) → index 0x40

Write `ioctl_dout` to block RAM when `ioctl_wr` is high during `ioctl_download`, and hold the CPU in reset until downloading finishes. Document the files the owner needs to place in the README.

### Video, audio, input

- `CLK_VIDEO` = `clk_sys`, `CE_PIXEL` = the 20 MHz enable. Set the aspect ratio to 4:3 in the framework (the template has the `ARC` options). 15 kHz output works with the framework's scandoubler.
- AY output is mono; send it to both audio channels.
- Keyboard input comes from `hps_io`'s `ps2_key` (bit 10 toggles on each event, bit 9 = pressed, bit 8 = extended, bits 7–0 = scancode).
- Disk images: set `hps_io`'s `VDNUM=2` and add `S0`/`S1` mount entries to CONF_STR.

## Testing

- **Simulation first.** Use Verilator (or Icarus) with a C++ or cocotb testbench that runs the TIKI ROM. Keep testbenches under `sim/`.
- **CPU trace check:** run MAME with `mame tiki100 -debug`, type `trace tiki100.log` in the debugger, let it run, and compare the instruction trace with the simulated CPU's. Report the first divergence.
- **Video check:** have the simulator dump frames as PNG and compare them with MAME snapshots of the same screen.
- **Hardware check:** after each milestone, tell the owner which `.rbf` and ROM files to copy, and what should appear.

## Milestones

Do these in order. Each one should be simulated before it's tried on hardware.

1. **CPU, memory, banking, I/O decode.** Z80 + ROM + RAM + VRAM + PROM banking + system latch + ROM loading. Done when the simulated trace matches MAME's for the first several thousand instructions.
2. **Video.** Shifter, palette, scroll, sync timing, framework video output. Done when the boot ROM's screen shows on the MiSTer.
3. **CTC, PIO, DART and IM2 interrupts.**
4. **Keyboard.** PS/2 to matrix.
5. **Floppy.** FD1797 plus disk mounting. Done when TIKO boots from a disk image.
6. **Sound.** AY-3-8912 through the framework's audio output.
7. **Extras.** Writing disk changes back to SD, cassette via MiSTer's ADC input, serial, printer, ROM version selection in the menu, per-16-dot video timing (`PER_GROUP`), optional 31 kHz scandoubled analog VGA output (needs a `CLK_VIDEO` of at least 4× the 20 MHz dot clock for `video_mixer`).

## Links

- MAME driver (2020 copy, BSD-3): https://git.redump.net/hbmame/tree/src/mame/drivers/tiki100.cpp
- Current MAME source: https://github.com/mamedev/mame (`src/mame/tiki/`)
- MiSTer template: https://github.com/MiSTer-devel/Template_MiSTer
- ZX Spectrum core (T80, AY, WD1793): https://github.com/MiSTer-devel/ZX-Spectrum_MISTer
- Main_MiSTer (ARM-side code, e.g. boot ROM loading in `user_io.cpp`): https://github.com/MiSTer-devel/Main_MiSTer
- Tiki 100 overview: https://en.wikipedia.org/wiki/Tiki-100
