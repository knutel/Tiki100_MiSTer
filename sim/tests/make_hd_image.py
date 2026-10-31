#!/usr/bin/env python3
"""Build a bootable Tiki 100 hard disk image from the Winchester system floppy.

  make_hd_image.py WCSYS.dsk OUT.hdf [--chd OUT.chd] [--rompath DIR]

WCSYS.dsk is the 800 KB "Winchester systemdiskett (for TIKI med harddisk)"
(MAME's tiki100_flop software list entry "wcsys", TIKO 4.01). OUT.hdf is a raw
10 MB image: 306 cylinders, 4 heads, 17 sectors of 512 bytes, for the core's
hard disk (and the simulator's --hdd). --chd also writes it as a CHD for MAME.

The disk is the one a dealer would have set up:
- The system track (A: track 0: boot sector and TIKO 4.01) is written by the
  floppy's own INSTALL program, run in MAME with the hard disk card. MAME
  needs the TIKI-100 hard disk interface (mamedev/mame commit b329eb2,
  2026-09-30; not in 0.289 or older): set MAME=/path/to/mame. INSTALL is
  started with the floppy's WD200C.SYS (A: and B: on the hard disk, C: the
  floppy) through the floppy's automatic command, which this script patches
  in a copy of the floppy. Typed into INSTALL: K (automatic command "meny"),
  G (update memory, so A: is the hard disk), H (write the system to A:).
- A: and B: get empty directories, and every file on the floppy is copied
  to A:, as HARDLES.TXT's "kopi a:=c:*.* -v" would.

Hard disk layout (WD200C.SYS): logical drive A: is heads 0-1, B: heads 2-3.
A logical track is one cylinder: sectors 0-16 on the even head, 17-33 on the
odd one. One system track, 8 KB blocks, 648 blocks (5,184 KB), 512 directory
entries in blocks 0-1.

Needs chdman (mame-tools) and the tiki100 ROMs in --rompath (default: the
repository root, where kontiki.zip is).
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

SEC = 512
CYLS, HEADS, SPT = 306, 4, 17

# Floppy (800 KB TIKO format): 20 sectors per track (both sides), one system
# track, 2 KB blocks, directory in block 0 (sector 20), 128 entries.
FL_DIR = 20 * SEC
FL_BLOCK = 2048
FL_ENTRIES = 128
FL_AUTOCMD = 0x87            # length byte, then the command (16 bytes max)

# Hard disk A: and B:
HD_SPT = 34
HD_BLOCK = 8192
HD_BLOCKS = 648
HD_ENTRIES = 512
HD_DIR_BLOCKS = 2

# Key matrix (column, bit) of the characters typed into INSTALL; see
# rtl/tiki100_keyboard.sv. MAME's input ports are Y1-Y12 for columns 0-11.
KEYS = {"\r": (0, 3), "g": (3, 6), "h": (4, 2), "j": (4, 6), "k": (5, 2),
        "m": (4, 7), "e": (2, 5), "n": (4, 3), "y": (4, 1)}
# (frame, text): INSTALL's menu takes a letter and RETUR; K asks "execute
# the command (J/N)?" and then for the command line; G and H ask for RETUR.
SCRIPT = [(1300, "k\r"), (1600, "j\r"), (1800, "meny\r"), (2100, "g\r"),
          (2400, "\r"), (2700, "h\r"), (2900, "\r")]
END_FRAME = 3300


def hd_offset(drive, track, sector):
    head = drive * 2 + sector // 17
    return ((track * HEADS + head) * SPT + sector % 17) * SEC


def hd_block_offsets(drive, block):
    first = HD_SPT + block * (HD_BLOCK // SEC)
    return [hd_offset(drive, s // HD_SPT, s % HD_SPT) for s in range(first, first + HD_BLOCK // SEC)]


def read_floppy_files(img):
    files = {}
    for i in range(FL_ENTRIES):
        e = img[FL_DIR + i * 32:FL_DIR + i * 32 + 32]
        if e[0] > 15:
            continue
        key = (e[0], bytes(e[1:12]))
        blocks = [e[16 + 2 * j] | e[17 + 2 * j] << 8 for j in range(8)]
        files.setdefault(key, []).append((e[12] + 32 * e[14], e[15], blocks))
    out = {}
    for key, exts in files.items():
        exts.sort()
        data = b"".join(b"".join(img[FL_DIR + b * FL_BLOCK:FL_DIR + (b + 1) * FL_BLOCK]
                                 for b in blocks if b)[:16384] for _, _, blocks in exts)
        last_ext, last_rc, _ = exts[-1]
        out[key] = data[:last_ext * 16384 + last_rc * 128]
    return out


def add_files(img, files):
    """Empty directories on A: and B:, then every file on A:"""
    for drive in (0, 1):
        for b in range(HD_DIR_BLOCKS):
            for off in hd_block_offsets(drive, b):
                img[off:off + SEC] = b"\xe5" * SEC
    entries = []
    block = HD_DIR_BLOCKS
    for (user, name), data in sorted(files.items(), key=lambda kv: kv[0][1]):
        records = (len(data) + 127) // 128
        data = data.ljust(records * 128, b"\x1a")
        blocks = list(range(block, block + (len(data) + HD_BLOCK - 1) // HD_BLOCK))
        block += len(blocks)
        if block > HD_BLOCKS:
            sys.exit("A: is full")
        for i, b in enumerate(blocks):
            chunk = data[i * HD_BLOCK:(i + 1) * HD_BLOCK].ljust(HD_BLOCK, b"\x1a")
            for j, off in enumerate(hd_block_offsets(0, b)):
                img[off:off + SEC] = chunk[j * SEC:(j + 1) * SEC]
        # One directory entry per 8 blocks: 64 KB, 4 logical extents (EXM 3)
        for e in range(max(1, (len(blocks) + 7) // 8)):
            n = min(records - e * 512, 512)
            last_ext = e * 4 + (max(n, 1) - 1) // 128
            rc = n - (last_ext - e * 4) * 128 if n else 0
            ptrs = b"".join(bytes([b & 0xFF, b >> 8]) for b in blocks[e * 8:(e + 1) * 8])
            entries.append(bytes([user]) + name + bytes([last_ext & 31, 0, last_ext >> 5, rc]) + ptrs.ljust(16, b"\0"))
    if len(entries) > HD_ENTRIES:
        sys.exit("too many directory entries")
    dirdata = b"".join(entries).ljust(HD_DIR_BLOCKS * HD_BLOCK, b"\xe5")
    for b in range(HD_DIR_BLOCKS):
        for j, off in enumerate(hd_block_offsets(0, b)):
            p = b * HD_BLOCK + j * SEC
            img[off:off + SEC] = dirdata[p:p + SEC]
    return block


def patch_floppy(img):
    """Start INSTALL with WD200C.SYS (renamed W.SYS: the command holds 16 characters)"""
    cmd = b"install w.sys"
    img[FL_AUTOCMD] = len(cmd)
    img[FL_AUTOCMD + 1:FL_AUTOCMD + 17] = cmd.ljust(16, b"\0")
    for i in range(FL_ENTRIES):
        off = FL_DIR + i * 32
        if img[off] < 16 and bytes(c & 0x7F for c in img[off + 1:off + 12]) == b"WD200C  SYS":
            img[off + 1:off + 9] = b"W       "
            return
    sys.exit("WD200C.SYS not found on the floppy")


def lua_script(log):
    lines = [f'local log = io.open("{log}", "w")', "local events = {"]
    for frame, text in SCRIPT:
        for ch in text:
            col, bit = KEYS[ch]
            lines.append(f"  {{{frame + 1}, ':Y{col + 1}', {1 << bit}, 1}},")
            lines.append(f"  {{{frame + 6}, ':Y{col + 1}', {1 << bit}, 0}},")
            frame += 14
    lines.append("}")
    lines.append(f"""
local space = manager.machine.devices[":z80"].spaces["io"]
local writes = 0
wt = space:install_write_tap(0x0000, 0xffff, "wt", function(o, d, m)
  if (o & 0xff) == 0x27 and (d & 0xf0) == 0x30 then writes = writes + 1 end
  return d
end)
local function field(port, mask)
  local found
  for name, fl in pairs(manager.machine.ioport.ports[port].fields) do
    if fl.mask == mask and (found == nil or name ~= "Keyboard") then found = fl end
  end
  return found
end
local frames = 0
sub = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  for _, e in ipairs(events) do
    if e[1] == frames then field(e[2], e[3]):set_value(e[4]) end
  end
  if frames == {END_FRAME} then
    log:write(string.format("%d\\n", writes))
    log:close()
    manager.machine:exit()
  end
end)""")
    return "\n".join(lines) + "\n"


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("floppy")
    ap.add_argument("out")
    ap.add_argument("--chd")
    ap.add_argument("--rompath", default=os.path.join(here, "..", ".."))
    args = ap.parse_args()
    mame = os.environ.get("MAME", "mame")

    floppy = bytearray(open(args.floppy, "rb").read())
    if len(floppy) != 819200:
        sys.exit("expected an 800 KB floppy image")
    with tempfile.TemporaryDirectory() as tmp:
        fl = os.path.join(tmp, "wcsys.dsk")
        patched = bytearray(floppy)
        patch_floppy(patched)
        open(fl, "wb").write(patched)
        chd = os.path.join(tmp, "hd.chd")
        subprocess.run(["chdman", "createhd", "-o", chd, "-chs", f"{CYLS},{HEADS},{SPT}",
                        "-ss", str(SEC), "-c", "none"], check=True, capture_output=True)
        lua, log = os.path.join(tmp, "install.lua"), os.path.join(tmp, "install.log")
        open(lua, "w").write(lua_script(log))
        env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
        subprocess.run([mame, "tiki100", "-rompath", os.path.abspath(args.rompath),
                        "-slot1", "", "-slot2", "hdc", "-hard1", chd, "-flop1", fl,
                        "-autoboot_script", lua, "-autoboot_delay", "0", "-video", "none",
                        "-sound", "none", "-nothrottle", "-skip_gameinfo",
                        "-seconds_to_run", "200"], env=env, cwd=tmp, check=True, capture_output=True)
        writes = int(open(log).read()) if os.path.exists(log) else 0
        if writes != 2 * SPT:
            sys.exit(f"INSTALL wrote {writes} sectors to the hard disk, expected {2 * SPT} "
                     f"(does {mame} have the hard disk interface?)")
        raw = os.path.join(tmp, "hd.raw")
        subprocess.run(["chdman", "extracthd", "-i", chd, "-o", raw, "-f"], check=True, capture_output=True)
        img = bytearray(open(raw, "rb").read())

    files = read_floppy_files(floppy)
    used = add_files(img, files)
    open(args.out, "wb").write(img)
    print(f"{args.out}: system track from INSTALL, {len(files)} files on A: ({used} of {HD_BLOCKS} blocks)")
    if args.chd:
        # Uncompressed: MAME can only write to an uncompressed CHD
        subprocess.run(["chdman", "createhd", "-i", args.out, "-o", args.chd, "-chs", f"{CYLS},{HEADS},{SPT}",
                        "-ss", str(SEC), "-c", "none", "-f"], check=True, capture_output=True)
        print(f"{args.chd}: the same as a CHD for MAME")


if __name__ == "__main__":
    main()
