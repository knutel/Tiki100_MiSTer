# Plan: real disk timing in the floppy controller

Status: proposed, not started.

## Why

`rtl/wd1793.sv` (from the ZX Spectrum core) hands out sector bytes as fast as the CPU reads them, and starts the next sector as soon as the previous one ends. If the CPU leaves a byte waiting, a 4,096-clock (1 ms) watchdog drops it and sets "lost data" for that byte only.

That's enough for TIKO and most software. It isn't enough for Darklite's demo "The Hollow" (`disk_images/DARKLITE_OFFENCE-THE_HOLLOW_COMPOVERSION.dsk`), whose loader is built around real disk timing:

- A 512-byte sector arrives at one byte per 32 µs, so it takes 16.4 ms. With 10 sectors at 300 rpm, a sector slot is about 20 ms, the same as a video frame.
- The loader runs in the VSYNC interrupt. It reads one sector, writing AY music registers in the waits between bytes, and then returns. The main code then runs until the next VSYNC.
- In our core the next sector's bytes are already waiting while the main code runs a memory copy. The watchdog drops them, the loader comes up 17 bytes short in a multi-sector read, and it waits forever for DRQ. On real hardware those bytes haven't arrived yet.

Found in simulation: the hang is at frame ~134, the loop at F6F4.

## Sources

- Technical handbook (`docs/tiki100_teknisk_handbok.pdf`, gitignored), pages 26-31:
  - 300 rpm, 40 tracks, track 0 outermost.
  - Step rates 6/12/20/30 ms (`r1 r0`, table 8). Restore gives up with a seek error after 255 steps.
  - Type II commands must have E = 1 on the Kontiki 100 (15 ms head settle).
  - The data field must be found within 4 revolutions, otherwise Record Not Found.
  - A multi-sector read continues to the end of the track or until Force Interrupt.
  - A write sector writes the data mark 11-22 bytes after the ID field.
  - Read Address returns the first ID field that passes (6 bytes).
  - Type I status bit 5 is always 1 on the Kontiki 100.
  - Lost data (type II bit 2) means the CPU didn't read or write a byte in time and at least one byte is lost.
- MAME `src/lib/formats/tiki100_dsk.cpp`, the track layout for every 512-byte format (200K, 360K, 400K, 800K):
  - Physical sector order 1, 6, 2, 7, 3, 8, 4, 9, 5, 10 (2:1 interleave; the 9-sector 360K format uses the first 9 entries).
  - Gap 1 is 20 bytes of 4E.
  - Each sector: 12x00 3xA1 FE C H R N CRC (22 bytes), 22x4E, 12x00 3xA1 FB (16), 512 data bytes, CRC (2), 24x4E. That's 598 bytes per slot, with the first data byte 60 bytes into the slot.
  - MFM with a 2 µs cell size: 32 µs per byte, 6,250 bytes per revolution (200 ms).

## Model

### Rotation

Each drive gets a byte-position counter, 0 to 6249. It advances one step every 32 µs (1,280 `clk_sys` clocks, or 128 CPU clock enables) while the motor is on. Position 0 is the index hole. The index pulse (type I status bit 1) is high for the first ~2 ms (63 bytes) of each turn, replacing the current made-up `cnt` timer.

Sector slot `k` (0-9) starts at byte `20 + 598*k`:
- its ID field covers `+0` to `+21`;
- its data starts at `+60`;
- its data CRC ends at `+573`.

Logical sector `S` sits in slot `2*(S-1)` for S = 1-5, and in slot `2*(S-6)+1` for S = 6-10.

### Type I (restore, seek, step)

- Each step takes the time given by `r1 r0`: 6, 12, 20 or 30 ms. The track register and the head position update as now.
- If V = 1: wait 15 ms for the head to settle, then wait for the next ID field to pass under the head. If its track number doesn't match, set seek error. The image always matches, so a seek error only comes from seeking beyond the last track.
- Restore: if track 0 isn't reached within 255 steps, set seek error. It can't happen with an image; the step count only affects timing.
- Status bit 5 is always 1 (handbook). Today it follows the h flag.

### Type II (read and write sector)

- E = 1: wait 15 ms first. Tiki software always sets it.
- Search: wait for slot `slot(S)` to come under the head. If the sector number is 0 or above the sectors per track, or the track is out of range, give up with Record Not Found after 5 index pulses (4 revolutions), instead of at once.
- **Read:**
  - Each byte becomes available at `data_start + i + 1` byte times and sets DRQ.
  - If the next byte arrives while DRQ is still set, set lost data, which stays set until the next command. That byte replaces the unread one, and the read carries on.
  - After the 512th byte and the CRC, a single-sector read ends.
  - A multi-sector read increments the sector register and searches again. That's the next slot in the interleave, about 1 slot (19 ms) later.
  - When the sector register passes the last sector, the read ends with Record Not Found after the 5-index search. That matches a real FD1797; software normally sends Force Interrupt first.
- **Write:**
  - DRQ goes up when the ID is found. If the CPU hasn't written the first byte by `+22` bytes (the end of gap 2, the handbook's 11-22), set lost data and end the command without writing anything.
  - After that, one byte is taken every 32 µs. A late byte writes 00 and sets lost data.
  - The sector goes to the SD card at the end, as now.

### Type III and IV

- **Read Address:** wait for the next ID field (any slot) and send its 6 bytes at 32 µs per byte.
- **Read Track and Write Track:** keep today's behavior. Nothing is known to use them on the Tiki except formatting.
- **Force Interrupt:** unchanged.

### SD card latency

Start the SD block read when the command starts, as now. If the block hasn't arrived by the time the data field starts, wait for the sector to come round again, as if it had missed. The half-turn average rotational wait (100 ms) is far longer than the HPS's usual latency.

### Unchanged

- Single density (SDEN) stays unsupported, so no 90K images.
- INTRQ and DRQ stay unconnected (the Tiki 100 polls).
- Disk geometry still comes from the image size.
- The drives' ready signal (selected, mounted, spun up) is unchanged.

## Progress

Tick the boxes and add the commit hash as each step is done, so the next session knows where to pick up.

- [ ] **Step 1: rotation and read timing.**
  - Change: per-drive rotation counter; index pulse from it; type II read search by interleave slot; DRQ every 32 µs from the data start; sticky lost data; Record Not Found after 5 index pulses; the E-bit 15 ms delay; type I status bit 5 always 1.
  - Done when: The Hollow gets past frame 134 (no more `R 10 10` loop in `TRACE_FDC`), and `make tikodir` still passes.
- [ ] **Step 2: type I timing.**
  - Change: step time from `r1 r0`; with V = 1, 15 ms settle plus a wait for the next ID; replaces the fixed `STATE_WAIT` delay of 4,000 clock enables (1 ms).
  - Done when: `make tiko` and `make tikodir` pass, and seek durations in `TRACE_FDC` match the step rate.
- [ ] **Step 3: type II write timing.**
  - Change: DRQ when the ID is found; lost data and abort if the first byte isn't written by +22 bytes; one byte per 32 µs after that, 00 and lost data for late bytes.
  - Done when: the invaders write test matches as before (README Status: the sectors written match MAME's apart from 15 bytes of never-written RAM).
- [ ] **Step 4: Read Address timing.**
  - Change: wait for the next ID field, then send 6 bytes at 32 µs.
  - Done when: TIKO still boots (it uses Read Address while mounting).
- [ ] **Step 5: docs.**
  - Change: `README.md` (the Disks section's "doesn't reproduce exact disk timing" note, and Status), `CLAUDE.md` (the Disks note), the `wd1793.sv` header list of changes, and mark this plan done.

## Starting point for a new session

### Reproduce the hang (about 3 minutes)

    make -C sim obj/Vsim_top
    cp disk_images/DARKLITE_OFFENCE-THE_HOLLOW_COMPOVERSION.dsk /tmp/hollow.dsk
    TRACE_FDC=/tmp/fdc.log sim/obj/Vsim_top sim/obj/boot.rom sim/obj/boot1.rom \
        --disk0 /tmp/hollow.dsk --printer-sync 1 --frames 140

(Use the session's scratchpad rather than `/tmp`.) The log ends with millions of `R 10 10` lines, the loader polling for a DRQ that never comes. Before the fix, frames stay on the boot ROM screen. The demo also uses the printer port sync (PIO port A `CF 03 18`, then `B7 FE`), so `--printer-sync 1` is required. MAME can't run it, because it has no sync mod.

### What the investigation found

- The loader's byte loop is at about F57E-F70E. It waits for DRQ (`in a,(10h) / and e`, where E = 02h); `D` counts 256-byte blocks. In the wait paths it writes AY registers (`out (16h)`, `out (c),b` / `outi`), which is the music.
- The main code copies memory with an unrolled `LDI` loop at FC22-FC50 while a multi-sector read is in progress. That's where bytes go missing: two per ~9 ms gap in our model.
- At ~2.44 s it starts a read at track 1, sector 6, then runs `LDIR` at 3009h for 22 ms, then sends Force Interrupt and Restore. The 14 bytes dropped there are harmless.
- The fatal read: seek to track 2 (`11=00 13=02 10=1C`), then a multi-sector read from sector 1 (`12=01 10=9C`). It got 5,103 of the 5,120 bytes it expected.
- Its loader seeks relatively (writes the track register as 0, then seeks to N). Our model's seek is absolute (`disk_track <= wdreg_data`), so that only works because the image has no physical head position. Keep that behavior unless there's a reason to model the head position separately.

### Where the current shortcuts are in `rtl/wd1793.sv` (line numbers as of commit 8ca8236)

- **Status mux (~233):** type I bit 5 is `s_headloaded`; on the Kontiki 100 it should always be 1. Bit 1 is `s_index`.
- **Index (~271-279):** a made-up period of 35,000 clock enables (8.75 ms at 4 MHz) with a 100-enable pulse. It should be 200 ms with a pulse of about 2 ms.
- **Watchdog (~260-268):** 4,096 clock enables (1 ms). On expiry `STATE_READ_2` (~497) and `STATE_WRITE_2` (~574) drop one byte. This is what the timing model replaces.
- **`STATE_READ` / `STATE_READ_1` (~480-495):** the next byte is ready 15 clock enables after the CPU reads the last one.
- **`STATE_SEARCH` (~406):** a fixed `seektimer` of 1,023 clock enables, then an immediate Record Not Found for sector 0 or a sector above the sectors per track.
- **`STATE_WAIT` (~597):** every type I command takes 4,000 clock enables (1 ms).
- **SEEK (~642) and READ ADDRESS (~708):** the command decode.
- The module's `ce` is the 4 MHz CPU clock enable (`cpu_cen_p` in `rtl/tiki100.sv`), so 1 byte = 32 µs = 128 clock enables. Each drive has its own `wd1793` instance (`fdd[0]`, `fdd[1]`), so a rotation counter inside the module is naturally per drive.

### Simulator speed

About 1.3 frames per second of wall time: The Hollow's hang (frame 134) takes 2 minutes, and Tiki Tiki Ta to frame 3,000 takes about 40 minutes. See `sim/DEBUGGING.md` for the probes and scripts used in this investigation.

## Verification

- **The Hollow** in the simulator: past frame 134, and a longer run to watch for further loading. The hang shows within 3 minutes of simulation.
- **Tiki Tiki Ta** in the simulator: its loader also polls the disk between frames. Check the loading parts (frames 0-3000) behave as before.
- **`make tiko` / `make tikodir`:** compare with MAME, which models real disk timing. Frames may now line up more closely. If a fixed frame number lands at a different moment, adjust `TIKO_FRAME`, but only after checking MAME's timing.
- **Invaders:** `make tiko DISK=obj/invaders.dsk TIKO_FRAME=1500` with the existing write check. `$$$.SUB` must still be written.
- **Timing check against MAME:** log FDC command times in MAME (a Lua tap on ports 10-13) and in the simulator (`TRACE_FDC`) for the TIKO boot. Read durations should agree to within one rotation, since the starting angle may differ.
- **Hardware:** TIKO boots and lists files; both Darklite demos run with Printer port sync on.

## Open questions

- Where is the disk when the motor starts? MAME's floppy device keeps an angle; we start at 0. This only shifts timing by a fraction of a turn.
- MAME's 400K track is 6,275 bytes (275 bytes of end fill) against 6,250 at exactly 300 rpm. Use 6,250 and treat the rest as slack.
