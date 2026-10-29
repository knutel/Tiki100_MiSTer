#!/usr/bin/env python3
"""Extract the Tiki 100 ROMs from a MAME romset zip (tiki100.zip or kontiki.zip).

Files are found by CRC32, so it doesn't matter how the zip is laid out.
Writes boot.rom (TIKI ROM 2.03w) and boot1.rom (53LS140 banking PROM),
the same names the MiSTer core loads from games/Tiki100/.

Usage: extract_roms.py <romset.zip> <output dir>
"""
import os
import sys
import zipfile

WANTED = {
    0x79662476: "boot.rom",   # tikirom-2.03w.u10
    0x894B756F: "boot1.rom",  # 53ls140.u4
}


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    zip_path, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)
    found = set()
    with zipfile.ZipFile(zip_path) as z:
        for info in z.infolist():
            name = WANTED.get(info.CRC)
            if name:
                with open(os.path.join(out_dir, name), "wb") as f:
                    f.write(z.read(info))
                print(f"{info.filename} -> {name}")
                found.add(name)
    missing = set(WANTED.values()) - found
    if missing:
        sys.exit(f"missing from {zip_path}: {', '.join(sorted(missing))}")


if __name__ == "__main__":
    main()
