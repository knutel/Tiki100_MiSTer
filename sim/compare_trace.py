#!/usr/bin/env python3
"""Compare a MAME debugger trace with the simulator's trace.

MAME lines look like "003F: ld   sp,$FFFC"; simulator lines start with the
address ("003F", optionally followed by a cycle count).

MAME's scheduler lets the CPU run a few cycles past the moment a device
raises an interrupt, so MAME sometimes takes an interrupt one or two
instructions earlier or later than the cycle-exact core. When the traces
disagree, the script looks for a small skip on either side after which they
agree again (an interrupt taken at a different instruction shows up as one
skip going into the handler and the opposite skip coming back out). Each
resync is reported. Anything else is reported as a divergence.

Usage: compare_trace.py [--strict] <mame.log> <sim.txt>
"""
import sys

MAX_SKIP = 8      # instructions
LOOKAHEAD = 12    # instructions that must match after a skip


def mame_lines(path):
    with open(path) as f:
        for line in f:
            if len(line) > 5 and line[4] == ":":
                yield line[:4].upper(), line.rstrip()


def resync(mame, sim, i, j):
    """Return (di, dj) that makes the traces agree again, or None."""
    def agree(a, b):
        n = min(LOOKAHEAD, len(mame) - a, len(sim) - b)
        return n > 0 and all(mame[a + k][0] == sim[b + k] for k in range(n))
    for skip in range(1, MAX_SKIP + 1):
        if agree(i, j + skip):
            return 0, skip
        if agree(i + skip, j):
            return skip, 0
    return None


def show(mame, sim, i, j, title):
    print(title)
    for k in range(-8, 5):
        a, b = i + k, j + k
        if a < 0 or b < 0 or a >= len(mame) or b >= len(sim):
            continue
        mark = ">>" if k == 0 else "  "
        print(f"{mark} {a:8d}  sim {sim[b]}   mame {mame[a][1]}")


def main():
    args = sys.argv[1:]
    strict = "--strict" in args
    args = [a for a in args if a != "--strict"]
    if len(args) != 2:
        sys.exit(__doc__)
    mame = list(mame_lines(args[0]))
    with open(args[1]) as f:
        sim = [l.split()[0].upper() for l in f if l.strip()]

    i = j = 0
    resyncs = 0
    while i < len(mame) and j < len(sim):
        if mame[i][0] == sim[j]:
            i += 1
            j += 1
            continue
        r = None if strict else resync(mame, sim, i, j)
        if r is None:
            show(mame, sim, i, j, f"First divergence at MAME instruction {i}:")
            if resyncs:
                print(f"({resyncs} interrupt timing resyncs before this)")
            sys.exit(1)
        side = "simulator" if r[1] else "MAME"
        print(f"resync at MAME instruction {i}: skipped {max(r)} {side} instruction(s)")
        resyncs += 1
        i += r[0]
        j += r[1]

    print(f"Traces match for {i} MAME instructions with {resyncs} interrupt "
          f"timing resyncs (MAME has {len(mame)}, simulator has {len(sim)}).")


if __name__ == "__main__":
    main()
