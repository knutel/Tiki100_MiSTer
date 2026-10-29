#!/usr/bin/env python3
"""Compare a simulator frame (PPM) with a MAME snapshot (PNG).

Converts the PPM to PNG next to it (same name, .png) so it can be viewed,
and reports how many pixels differ. With a third argument, also writes a
difference image: matching pixels dimmed, differing pixels bright red.

Uses only the Python standard library.

Usage: compare_frame.py <mame.png> <sim.ppm> [diff.png]
"""
import struct
import sys
import zlib


def read_png(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit(f"{path}: not a PNG")
    pos, idat = 8, b""
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or ctype not in (2, 6) or interlace:
                sys.exit(f"{path}: only 8-bit RGB/RGBA non-interlaced PNGs are supported")
            bpp = 3 if ctype == 2 else 4
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    raw = zlib.decompress(idat)
    stride = w * bpp
    rows, prev = [], bytearray(stride)
    for y in range(h):
        ftype = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if ftype == 1:
                line[i] = (line[i] + a) & 0xFF
            elif ftype == 2:
                line[i] = (line[i] + b) & 0xFF
            elif ftype == 3:
                line[i] = (line[i] + (a + b) // 2) & 0xFF
            elif ftype == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        rows.append(line)
        prev = line
    rgb = bytearray()
    for line in rows:
        if bpp == 3:
            rgb += line
        else:
            for x in range(w):
                rgb += line[x * 4:x * 4 + 3]
    return w, h, rgb


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    fields, pos = [], 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        start = pos
        while not data[pos:pos + 1].isspace():
            pos += 1
        fields.append(data[start:pos])
    if fields[0] != b"P6" or fields[3] != b"255":
        sys.exit(f"{path}: not an 8-bit P6 PPM")
    w, h = int(fields[1]), int(fields[2])
    return w, h, bytearray(data[pos + 1:pos + 1 + w * h * 3])


def write_png(path, w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb[y * w * 3:(y + 1) * w * 3]) for y in range(h))

    def chunk(kind, body):
        return (struct.pack(">I", len(body)) + kind + body +
                struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    mw, mh, mame = read_png(sys.argv[1])
    sw, sh, sim = read_ppm(sys.argv[2])
    write_png(sys.argv[2].rsplit(".", 1)[0] + ".png", sw, sh, sim)
    if (mw, mh) != (sw, sh):
        sys.exit(f"size differs: MAME {mw}x{mh}, simulator {sw}x{sh}")

    diff, box = 0, [sw, sh, -1, -1]
    out = bytearray(len(sim))
    for y in range(sh):
        for x in range(sw):
            i = (y * sw + x) * 3
            if mame[i:i + 3] != sim[i:i + 3]:
                diff += 1
                box = [min(box[0], x), min(box[1], y), max(box[2], x), max(box[3], y)]
                out[i:i + 3] = b"\xff\x00\x00"
            else:
                out[i:i + 3] = bytes(v // 3 for v in sim[i:i + 3])
    if len(sys.argv) == 4:
        write_png(sys.argv[3], sw, sh, out)

    if diff == 0:
        print(f"Frames match ({sw}x{sh}).")
    else:
        print(f"{diff} pixels differ, in the box x={box[0]}..{box[2]}, y={box[1]}..{box[3]}.")
        sys.exit(1)


if __name__ == "__main__":
    main()
