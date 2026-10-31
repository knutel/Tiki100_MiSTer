# Plan: optional hard disk (Winchester controller, option 100/005)

Status: Step 0 done; Step 1 (controller in the core) next.

## Context

The owner wants optional hard disk support, for TIKI ROM 2.03w only. What the research found:

- **Hardware.** The handbook's I/O map lists the "Winchester-controller", option 100/005, at ports 20-27. MAME emulates it as `tiki100_hdc` (`src/devices/bus/tiki100/hdc.cpp`, the default card in slot 2): a WD2010 at 5 MHz plus a 1 KB buffer with a 10-bit counter.
  - Port 20 is the buffer. Each access moves the counter on by one.
  - Ports 21-27 are WD2010 registers 1-7. A write to 27 also resets the counter and clears buffer-ready.
  - Up to two drives (SDH bits 4-3: 10 = drive 0, 01 = drive 1). No interrupts or DMA.
- **ROM 2.03w** has the driver (ROM 0D2A-0DE4, copied to F926-F9E0 in RAM):
  - Probe: write 512 bytes to port 20, then status bit 7 must read 0. An empty port reads FF, so today the ROM sees no card. Then sector register 23 must read back 1, then Restore `10h`, waiting for bit 7 to clear and checking error bit 0.
  - Read: `20h`, wait for not busy, then 2×INIR from port 20. Write: `30h`, then 2×OTIR to port 20 straight away, then wait for not busy. Up to 10 retries.
  - Seek only writes the cylinder registers (24/25). SDH = `20h` (512-byte sectors) | drive bits | head.
  - Logical drives 4+ are the hard disk. Logical drive n uses heads 2n and 2n+1; bit 7 of the sector number picks the odd head.
- **The wcsys floppy** (`disk_images/wcsys.dsk`, "Winchester systemdiskett", TIKO 4.01):
  - `HARDLES.TXT`: with no floppy at power-on, the machine boots from the hard disk, A:/B: are the hard disk and the floppy is C:. With a floppy in, the floppy boots and the hard disk can't be reached.
  - `WD200C.SYS`/`WD400C.SYS` hold A:/B: disk parameter blocks: SPT 136, 8 KB blocks, DSM 647, DRM 511, OFF 1.
  - That gives the drive geometry: **306 cylinders × 4 heads × 17 sectors × 512 bytes = 10,653,696 bytes** (a 10 MB ST-506 drive). Each sector is one 512-byte SD block, so LBA = (cyl × 4 + head) × 17 + sector - 1.
- **MAME's WD2010** (`src/devices/machine/wd2010.cpp`) is simple:
  - Status bits: BSY 80, RDY 40 (= drive ready), WF 20, SC 10, DRQ 08, CIP 02, ERR 01. Error register: AC 04 (aborted), ID 10.
  - Restore/Seek finish after 15 + 8.33 ms + √steps × rate. Other commands take 1 ms. Read/write finish on buffer handshakes.
  - No drive ready means Aborted Command (`ERR` + `AC`). Scan ID and Format are stubs.

Owner decisions:
- 2.03w only.
- The card is **present only while a hard disk image is mounted**. Without an image, ports 20-27 read FF as today.
- If MAME can't bootstrap a bootable hard disk from wcsys, **build the image by hand** with a script.

## Step 0: reference image and protocol in MAME (done)

**MAME:** the installed 0.264 has only a stub card (no buffer, no image, and register writes land at the wrong index, so the ROM reads back 00 from register 23 and gives up). The working card is in MAME master since commit `b329eb2` (2026-09-30, "tiki/tiki100: Implement the hard disk interface"), not in any release up to 0.289. A Tiki-only master build works as the reference: `make SUBTARGET=tiki SOURCES=src/mame/tiki/tiki100.cpp TOOLS=0 -j32` (a few minutes), then `MAME=<path>/tiki`.

**Image:** `sim/tests/make_hd_image.py disk_images/wcsys.dsk sim/obj/wcsys-hd.hdf --chd sim/obj/wcsys-hd.chd` builds a bootable 10 MB disk.
- Typing at TIKO's prompt doesn't work after its menu's "A" (the next RETUR restarts TIKO). So the script patches the floppy's automatic command (sector 0, offset 87h: length byte, 16 characters) to `install w.sys`, with WD200C.SYS renamed W.SYS so it fits.
- INSTALL then gets K (automatic command `meny`), G (update memory: A:/B: become the hard disk) and H (write the system to A:: 34 sector writes, cylinder 0 heads 0-1).
- The script then gives A: and B: empty directories and copies the floppy's 70 files to A: itself. The `kopi` route fails because WD200C.SYS makes C: a 200K drive, which can't read the 800K floppy.
- In MAME master, with no floppy: TIKO 4.01 boots from the hard disk to the menu, B lists the 70 files, SJAKK runs.

**Boot:** with no floppy, ROM 2.03w probes the card, reads C0/H0/S1 to 0080 and jumps to it. That sector is the floppy's boot loader with drive 4 selected. It loads the system through the ROM's jump table.

**Protocol seen in MAME** (what the core must reproduce):
- The ROM's select re-probes before every operation: 512 bytes to port 20, then status, then sector 1 written and read back from 23, then Restore `10h`. Busy (D2) for about 23 ms, then 50 (RDY|SC).
- Read: 23, 26, 21, then `20h`, poll 27 until bit 7 is clear (50), then 512 bytes from port 20. TIKO's BIOS sometimes splits the 512 reads.
- Write: `30h`, 512 bytes to port 20, poll until not busy.
- Only `10h`, `20h` and `30h` are used. No multi-sector, Seek, Scan ID or Format.
- SDH is `30h` | head (drive 0, 512-byte sectors). Cylinder in 24/25.

## Step 1: controller in the core

**New `rtl/tiki100_hdc.sv`** (WD2010 subset plus the card's buffer; behaviour copied from MAME's hdc.cpp/wd2010.cpp):
- Registers 1-6: latched writes, raw reads. Reading 21 gives the error register, or the status while CIP is set. Reading 27 gives the status: `BSY|RDY|0|SC(1)|DRQ|0|CIP|ERR`, where RDY = image mounted and SDH selects drive 0.
- Buffer: 1 KB block RAM with a 10-bit counter. Port 20 read/write moves it on. A write to 27 clears it.
- Commands:
  - Restore `1x` and Seek `7x`: BSY for MAME's time (15 + 8.33 ms + √steps × rate; counter in `ce` ticks, no derived clocks). Seek copies the cylinder registers to the present cylinder.
  - Read `2x`: BSY, SD read of LBA into the buffer, counter cleared, then done. Not ready gives ERR + AC. Sector number above 17 gives ERR + ID.
  - Write `3x`: BSY|DRQ, wait for the CPU to write 512 bytes (counter = 512), SD write of the buffer, then done.
  - Scan ID `4x`: load the cylinder registers from the present cylinder. Format `5x`: take a buffer of data and complete without writing (MAME does the same).
  - Set parameter `0x` and compute correction `08`: done after 1 ms.
  - Multi-sector (M bit): not needed. TIKO and the ROM only use `10h`, `20h` and `30h`.
- Geometry: fixed 4 heads × 17 sectors, cylinders taken from the image size. Any other size: drive not ready.

**`rtl/tiki100.sv`:**
- Decode `cpu_a[7:3] == 5'b00100` (ports 20-27) when `hd_mounted`. Add the result to the `io_dout` mux; otherwise FF. Update the I/O decode comment.
- Add a third SD channel: `img_mounted[2]`, `sd_lba[3]`, etc.

**`Tiki100.sv`:**
- `hps_io` `VDNUM(3)`. CONF_STR entry `"S2,HDFIMG,Hard disk;"`. Widen the sd_* arrays.
- Edit the file as CRLF (memory: Python rewrites turn it LF).

**`files.qip`:** add `rtl/tiki100_hdc.sv`.

## Step 2: simulator

- `sim/sim_top.sv` and `sim/sim_main.cpp`: a third SD drive, `--hdd FILE` / `--savehdd FILE`. The existing `sd_step()` serves blocks by LBA, so this is mostly widening.
- `TRACE_FDC` also logs ports 20-27, in the same format as the MAME tap.
- `sim/Makefile`: add `rtl/tiki100_hdc.sv`, plus a `hdboot` target. It boots from the hard disk image with no floppy, compares frame N with MAME's (`-slot2 hdc -hard1 <chd>`), and with keys lists A: (`kat`) as `tikodir` does.

## Step 3: docs

- README: a Hard disk section covering the image (306/4/17, 10,653,696 bytes, `.hdf`/`.img` in `games/Tiki100/`), how it was made, booting without a floppy, the wcsys copy steps and Status.
- CLAUDE.md: the controller's port map and geometry, and the Step 0 findings.
- Also the gitignore entry for the image, and the I/O map in CLAUDE.md (ports 20-27).

## Verification

1. **Step 0:** MAME boots TIKO 4.01 from the hard disk with no floppy. That proves the reference image.
2. **`make hdboot`:** the simulator's hard disk boot frame matches MAME's, and the A: listing matches. Compare the `TRACE_FDC` and MAME tap logs for the command sequence and rough durations.
3. **Write test:** in both, copy a file from C: to B: (`kopi b:=c:...`) with `--savehdd`. The changed sectors should match MAME's CHD after `chdman extracthd`.
4. **Regression:** with no hard disk image, `make tiko`, `tikodir`, `iotest`, `kbdtest` and `trace` give the same results as before (ports 20-27 still read FF).
5. **Hardware:** copy the `.rbf` and the hard disk image to `games/Tiki100/`, mount it as "Hard disk" with no floppy, reset with the button. TIKO 4.01 should boot from the hard disk with A:/B: listings. Then mount wcsys as Drive A and check that C: reads it.

Commits: one per step (Step 0's script and key files, then the controller, the simulator, the docs).

## Progress

Tick the boxes and add the commit hash as each step is done.

- [x] Step 0: reference image and MAME protocol logs (this commit)
- [ ] Step 1: controller in the core
- [ ] Step 2: simulator
- [ ] Step 3: docs
