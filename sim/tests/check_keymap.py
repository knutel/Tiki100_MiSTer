#!/usr/bin/env python3
"""Check the PS/2 scancode table in rtl/tiki100_keyboard.sv against MAME.

MAME's tiki100 input ports give each Tiki key a PC key (KEYCODE_x). This
script turns those into PS/2 set 2 scancodes and checks that the core puts
each one at the same matrix position. Keys only the core maps (MAME leaves
them without a PC key) are listed.

Usage: check_keymap.py <MAME src/mame/tiki/tiki100.cpp> <rtl/tiki100_keyboard.sv>
"""
import re, sys
mame = open(sys.argv[1]).read()
sv = open(sys.argv[2]).read()
# MAME KEYCODE -> PS/2 set 2 (0x1xx = E0)
K = {'LCONTROL':0x14,'LSHIFT':0x12,'RSHIFT':0x59,'ESC':0x76,'ENTER':0x5A,'SPACE':0x29,'SLASH_PAD':0x14A,
'BACKSPACE':0x66,'LALT':0x11,'DEL':0x171,'BACKSLASH2':0x61,'CAPSLOCK':0x58,'COLON':0x4C,'SLASH':0x4A,
'MINUS':0x4E,'OPENBRACE':0x54,'QUOTE':0x52,'EQUALS':0x55,'CLOSEBRACE':0x5B,'BACKSLASH':0x5D,'LEFT':0x16B,
'INSERT':0x170,'PGUP':0x17D,'PGDN':0x17A,'UP':0x175,'DOWN':0x172,'PLUS_PAD':0x79,'MINUS_PAD':0x7B,
'ASTERISK':0x7C,'TAB':0x0D,'DEL_PAD':0x71,'HOME':0x16C,'RIGHT':0x174,'ENTER_PAD':0x15A,'COMMA':0x41,'STOP':0x49,
'F1':0x05,'F2':0x06,'F3':0x04,'F4':0x0C,'F5':0x03,'F6':0x0B}
for c,v in zip('ABCDEFGHIJKLMNOPQRSTUVWXYZ',[0x1C,0x32,0x21,0x23,0x24,0x2B,0x34,0x33,0x43,0x3B,0x42,0x4B,0x3A,0x31,0x44,0x4D,0x15,0x2D,0x1B,0x2C,0x3C,0x2A,0x1D,0x22,0x35,0x1A]): K[c]=v
for d,v in zip('0123456789',[0x45,0x16,0x1E,0x26,0x25,0x2E,0x36,0x3D,0x3E,0x46]): K[d]=v
for d,v in zip('0123456789',[0x70,0x69,0x72,0x7A,0x6B,0x73,0x74,0x6C,0x75,0x7D]): K[d+'_PAD']=v
want = {}
port = None
for line in mame.splitlines():
    m = re.search(r'PORT_START\("Y(\d+)"\)', line)
    if m: port = int(m.group(1)) - 1
    m = re.search(r'PORT_BIT\( 0x(\w\w),.*IPT_KEYBOARD', line)
    if m and port is not None:
        bit = int(m.group(1),16).bit_length()-1
        for kc in re.findall(r'KEYCODE_(\w+)', line):
            want[K[kc]] = (port, bit)
have = {}
for m in re.finditer(r"((?:9'h[0-9A-F]{3}(?:,\s*)?)+):\s*pos = \{1'b1, 4'd(\d+), 3'd(\d)\}", sv):
    for c in re.findall(r"9'h([0-9A-F]{3})", m.group(1)): have[int(c,16)] = (int(m.group(2)), int(m.group(3)))
bad = 0
for code,p in want.items():
    if have.get(code) != p: print("mismatch", hex(code), "MAME", p, "core", have.get(code)); bad += 1
for code,p in have.items():
    if code not in want: print("core only", hex(code), p)
print(len(want), "MAME keys checked,", bad, "mismatches")
sys.exit(1 if bad else 0)
