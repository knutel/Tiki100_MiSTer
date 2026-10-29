#!/usr/bin/env python3
"""Clean up GHDL's Verilog output so Verilator accepts it.

GHDL 4.1 (--synth --out=verilog) has two naming bugs that hit T80:

1. Escaped names inside identifiers, e.g. "u0_\\reg ", which isn't legal
   Verilog. These become plain names ("u0_reg_esc").

2. A VHDL signal and an instance output can get the same Verilog name. In
   T80.vhd the signal ALU_Q and the output Q of instance "alu" both become
   "alu_q". GHDL then declares the wire twice and connects the two copies
   through a helper wire:
       assign alu_q = alu_nNNN;   // the signal, from the helper
       assign alu_nNNN = alu_q;   // the helper, from the instance output
   Both carry the same value, so we drop the second declaration and the
   assignment that would otherwise give alu_q two drivers.

Usage: fix_ghdl_verilog.py <in.v> <out.v>
"""
import re
import sys


def fix_module(lines):
    decl = re.compile(r"^\s*wire\s+(\[[^\]]*\]\s*)?(\w+)\s*;")
    seen, dups, out = set(), set(), []
    for line in lines:
        m = decl.match(line)
        if m:
            name = m.group(2)
            if name in seen:
                dups.add(name)
                continue
            seen.add(name)
        out.append(line)
    for name in dups:
        # Find "assign helper = name;" and drop "assign name = helper;".
        helpers = set()
        for line in out:
            m = re.match(r"^\s*assign\s+(\w+)\s*=\s*%s\s*;" % re.escape(name), line)
            if m:
                helpers.add(m.group(1))
        loop = re.compile(r"^\s*assign\s+%s\s*=\s*(%s)\s*;" % (
            re.escape(name), "|".join(map(re.escape, helpers)) or "$^"))
        before = len(out)
        out = [l for l in out if not loop.match(l)]
        if len(out) != before - 1:
            sys.exit(f"don't know how to fix duplicate wire '{name}'")
        print(f"merged duplicate wire '{name}'", file=sys.stderr)
    return out


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    with open(sys.argv[1]) as f:
        text = f.read()
    text = re.sub(r"(\w)\\(\w*) ", r"\1\2_esc ", text)

    lines = text.splitlines(keepends=True)
    result, module = [], []
    for line in lines:
        if line.startswith("module "):
            result.extend(module)
            module = []
        module.append(line)
        if line.startswith("endmodule"):
            result.extend(fix_module(module))
            module = []
    result.extend(module)

    with open(sys.argv[2], "w") as f:
        f.writelines(result)


if __name__ == "__main__":
    main()
