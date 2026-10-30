#!/usr/bin/env python3
"""Run MAME's tiki100 while replaying PS/2 key events.

Usage:
  mame_keys.py <rompath> <keys.txt> <frame> --snapshot OUT.png [--disk IMAGE.dsk]
  mame_keys.py <rompath> <keys.txt> <frame> --results OUT.txt --rom TEST.rom --prom boot1.rom

keys.txt has the simulator's format: "frame scancode 1|0" per line. Each
scancode is turned into a Tiki 100 matrix position using the table in
rtl/tiki100_keyboard.sv, and the key is pressed in MAME by setting that bit
of MAME's input port Y<column+1>. This checks the core's keyboard path
against MAME's. (The table itself is checked against MAME's input port
definitions by check_keymap.py.)

MAME stops at <frame>. --snapshot saves the screen there. --results runs
TEST.rom in place of the boot ROM and logs every byte written to port FF,
one hex byte per line.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TABLE = os.path.join(HERE, "..", "..", "rtl", "tiki100_keyboard.sv")


def scancode_table():
    """{scancode (0x1xx = E0 prefix): (column, bit)} from tiki100_keyboard.sv"""
    table = {}
    pat = re.compile(r"^\s*((?:9'h[0-9A-Fa-f]{3}(?:,\s*)?)+):\s*pos = \{1'b1, 4'd(\d+), 3'd(\d)\}")
    with open(TABLE) as f:
        for line in f:
            m = pat.match(line)
            if m:
                for code in re.findall(r"9'h([0-9A-Fa-f]{3})", m.group(1)):
                    table[int(code, 16)] = (int(m.group(2)), int(m.group(3)))
    return table


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rompath")
    ap.add_argument("keys")
    ap.add_argument("frame", type=int)
    ap.add_argument("--snapshot")
    ap.add_argument("--results")
    ap.add_argument("--rom")
    ap.add_argument("--prom")
    ap.add_argument("--disk", help="disk image for drive A")
    args = ap.parse_args()
    if bool(args.snapshot) == bool(args.results):
        sys.exit("give one of --snapshot and --results")
    if args.rom and not args.prom:
        sys.exit("--rom needs --prom")

    table = scancode_table()
    events = []
    with open(args.keys) as f:
        for line in f:
            parts = line.split()
            if len(parts) != 3:
                continue
            code = int(parts[1], 16)
            code = (code & 0xFF) | (0x100 if code > 0xFF else 0)
            if code not in table:
                sys.exit(f"scancode {parts[1]} is not in the keyboard table")
            col, bit = table[code]
            events.append((int(parts[0]), col, bit, int(parts[2])))

    with tempfile.TemporaryDirectory() as tmp:
        rompath = os.path.abspath(args.rompath)
        if args.rom:
            rompath = os.path.join(tmp, "roms")
            os.makedirs(os.path.join(rompath, "tiki100"))
            shutil.copyfile(args.rom, os.path.join(rompath, "tiki100", "tikirom-2.03w.u10"))
            shutil.copyfile(args.prom, os.path.join(rompath, "tiki100", "53ls140.u4"))

        lua = os.path.join(tmp, "keys.lua")
        with open(lua, "w") as f:
            f.write("local events = {\n")
            for fr, col, bit, press in events:
                f.write(f"  {{{fr}, ':Y{col + 1}', {1 << bit}, {press}}},\n")
            f.write("}\n")
            if args.results:
                out = os.path.abspath(args.results)
                f.write(f"""
local out = assert(io.open("{out}", "w"))
local space = manager.machine.devices[":z80"].spaces["io"]
-- OUT (n),A puts A on the upper address lines, so watch the whole space
results_tap = space:install_write_tap(0x0000, 0xffff, "results", function(offset, data, mask)
  if (offset & 0xff) == 0xff then
    out:write(string.format("%02X\\n", data & 0xff))
    out:flush()
  end
end)
""")
            snapshot = "manager.machine.video:snapshot()" if args.snapshot else ""
            f.write(f"""
-- Some masks also have a field named "Keyboard"; prefer the key's own field
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
  if frames == {args.frame} then
    {snapshot}
    manager.machine:exit()
  end
end)
""")
        env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
        subprocess.run(["mame", "tiki100", "-rompath", rompath,
                        "-slot1", "", "-slot2", "",
                        *(["-flop1", os.path.abspath(args.disk)] if args.disk else []),
                        "-autoboot_script", lua, "-autoboot_delay", "0",
                        "-video", "none", "-sound", "none", "-nothrottle",
                        "-skip_gameinfo", "-snapshot_directory", tmp],
                       env=env, check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
        if args.snapshot:
            shutil.copyfile(os.path.join(tmp, "tiki100", "0000.png"), args.snapshot)


if __name__ == "__main__":
    main()
