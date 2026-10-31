# Debugging software that misbehaves

Techniques that worked when getting Darklite's demos running (October 2026). The standard tests are described in the README's Simulation section; this file covers ad-hoc investigation.

## Budget

- The simulator runs at about 1.3 frames per second (about 1 M clocks per second), so 1,000 frames takes about 13 minutes. Run anything over a few hundred frames in the background, and run independent jobs in parallel (the machine has many cores).
- Rebuilding `obj/Vsim_top` while a run is in progress is safe: the linker replaces the file, and the running process keeps the old one.
- MAME runs at 10-15x real time headless, so try it first when the software can run there.
- Checkpointing the simulator (Verilator `--savable`) was discussed but not built; the owner preferred to wait.

## Simulator

- `--disk0 FILE --printer-sync 1 --frames N --dump K --outdir DIR --wav FILE` covers most runs. Give it a copy of the disk image.
- `TRACE_FDC=file`: every floppy controller and system latch access, with timestamps in seconds. Reads and writes look like `R 10 03`. Type I status bit 2 means track 0; type II bit 2 means lost data, bit 4 record not found.
- `--trace file`: the address of every instruction, in order. A repeating address is a block instruction (`LDIR` and similar). To keep it small, pipe it through a filter, e.g. `--trace >(awk 'NR%200000==0' > pcs.txt)` to sample, or `sort | uniq -c` over a range to find hot loops.
- **Temporary probes:** add an output to `sim_top.sv` driven from hierarchical paths, read it in the `sim_main.cpp` main loop, and log per event or per frame to a file named by an environment variable. Remove the probe with `git checkout -- sim/sim_main.cpp sim/sim_top.sv` afterwards, and never commit probes. Paths that were useful:
  - `core.pio.ie[0]`, `ip[0]`, `ius[0]`, `next_cw[0]`, `mode[0]`, `icw[0]`, `mask[0]`
  - `core.ctc.ius`, `core.dart.ius`, `core.ctc_ieo`, `core.dart_ieo`, `core.intack_p`, `core.pio_int`
  - `core.cpu.u0.inte_ff1` (IFF1) and `core.cpu.u0.istatus` (interrupt mode)
  - `core.video.hcount`, `vcount`, `scroll_q`
  - `core.ay_addr`, `core.ay_porta_out`
  - `core.fdd[0].fdc.s_drq_busy`, `s_lostdata`
- **A frame-limited trace:** a temporary `frames >= N` condition on the trace `fprintf` gives a trace of just the interesting frames.
- **A memory dump:** shadow every CPU memory read and write (`mreq_n`, `rd_n`/`wr_n`, `addr`, `din`/`dout`) into a 64 KB array, and write it out at frame N. It holds what the CPU last *saw* at each address, so where video RAM is banked in, it shows video RAM rather than main RAM.
- **Frames:** `.ppm` files. Convert them with the helpers in `compare_frame.py`, running Python with `PYTHONDONTWRITEBYTECODE=1` so no `__pycache__` appears in `sim/`:

      import sys; sys.path.insert(0, 'sim')
      from compare_frame import read_ppm, write_png
      w, h, rgb = read_ppm(p); write_png(p.replace('.ppm', '.png'), w, h, rgb)

## MAME (0.264 here)

- `mame_snap.sh` takes snapshots; `mame_trace.sh` makes traces. MAME writes to disk images, so always give it a copy.
- **I/O taps from Lua** (`-autoboot_script x.lua`): `manager.machine.devices[":z80"].spaces["io"]:install_read_tap(0x0000, 0xffff, "name", function(offset, data, mask) ... return data end)`.
  - Tap the whole range: `IN A,(n)` puts A on the high address byte. Filter on `offset & 0xff`.
  - Keep the returned handle in a global, or it gets garbage-collected.
  - Errors inside a tap fail silently. Wrap the body in `pcall` and log the error.
  - Returning a modified `data` fakes an input, which is fine for polled bits. It can't raise PIO interrupts.
- **Beam position:** the Lua screen object has no `vpos` here. Derive it from `manager.machine.time:as_double()`: 15,625 lines per second, 312 lines per frame, 1,280 dots per line.
- **Debugger without a window:** `-debug -debugger none`, then `manager.machine.debugger:command("dasm file,start,len")` or `"save file,start,len"` from a frame notifier (`emu.add_machine_frame_notifier`).
- **Disassembling a dump from the simulator:** start MAME `tiki100` with no disk, and at frame 5 `load hi.bin,8000,8000` (the upper 32 KB of the dump), then `dasm`. That works for code at 8000 and up. For lower code, load it at 8000 too and add the offset yourself.
- Hardware mods that MAME lacks (the printer port sync) mean some software can only be followed in the simulator.

## Tiki-specific things that came up

- **System latch:** bit 2 is _ROME (1 = ROM off), bit 3 VIRE (1 = video RAM in), bit 6 motor.
- **PROM decode** (outputs inverted):
  - VIRE = 0: RAM everywhere except the ROM.
  - VIRE = 1, ROM off: video RAM at 0000-7FFF, RAM at 8000-FFFF.
  - VIRE = 1, ROM on: ROM at 0000-3FFF, video RAM at 4000-BFFF, RAM at C000-FFFF.
- **CPU access to video RAM** goes through the scroll register: address + scroll × 128.
- **Power-on RAM** is 00 with ROM 2.03w and FF with 1.35/1.30 (see `rtl/tiki100.sv`). Software that reads RAM it never wrote can hang. Tiki Tiki Ta reads 7202h and needs 0 there.
- **Darklite demo conventions:**
  - PIO port A is in bit mode with D0 = VSYNC and D1 = HSYNC, both inputs (control words `CF 03`).
  - The VSYNC interrupt is set up with `B7 FE 18 83`, the line interrupt with `97 FD 83`.
  - The interrupt vector table is at FF00 (I = FFh); the PIO vector is 18h.
  - Music sync points compare a 16-bit music position (F862h in Tiki Tiki Ta) for equality, so anything that runs slow can miss one and hang.
