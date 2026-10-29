#!/usr/bin/env python3
"""Compare a MAME debugger trace with the simulator's trace.

MAME lines look like "003F: ld   sp,$FFFC"; simulator lines are just "003F".
Reports the first instruction where the two disagree, with some context.

Usage: compare_trace.py <mame.log> <sim.txt>
"""
import sys


def mame_lines(path):
    with open(path) as f:
        for line in f:
            if len(line) > 5 and line[4] == ":":
                yield line[:4].upper(), line.rstrip()


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    mame = list(mame_lines(sys.argv[1]))
    with open(sys.argv[2]) as f:
        sim = [l.strip().upper() for l in f if l.strip()]

    n = min(len(mame), len(sim))
    for i in range(n):
        if mame[i][0] != sim[i]:
            print(f"First divergence at instruction {i}:")
            for j in range(max(0, i - 10), min(n, i + 5)):
                mark = ">>" if j == i else "  "
                print(f"{mark} {j:8d}  sim {sim[j]}   mame {mame[j][1]}")
            sys.exit(1)
    print(f"Traces match for all {n} instructions "
          f"(MAME has {len(mame)}, simulator has {len(sim)}).")


if __name__ == "__main__":
    main()
