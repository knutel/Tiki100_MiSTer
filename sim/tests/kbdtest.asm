; SPDX-License-Identifier: GPL-2.0-or-later
; Tiki 100 keyboard test ROM
;
; Runs in place of the boot ROM. Scans the keyboard the way the TIKI ROM
; does (write port 00 to reset the column counter, then read port 00 once
; per column) and writes the whole 16-column matrix to the result port FF
; every time it changes, preceded by a marker byte. MAME and the simulator
; replay the same key events, so the two result lists must be identical.
;
; Assemble: z80asm -o kbdtest.rom kbdtest.asm

RES:    equ 0FFh        ; result port
KEYS:   equ 00h         ; keyboard

PREV:   equ 0F000h      ; previous scan, 16 bytes
CUR:    equ 0F010h      ; current scan, 16 bytes

        org 0
        di
        ld sp, 0FFF0h
        ld hl, PREV             ; previous scan: impossible values, so the
        ld b, 16                ; first scan is always reported
init:   ld (hl), 0AAh
        inc hl
        djnz init

scan:   out (KEYS), a           ; column counter to 0
        ld hl, CUR
        ld b, 16
col:    in a, (KEYS)
        ld (hl), a
        inc hl
        djnz col

        ld hl, CUR              ; compare with the previous scan
        ld de, PREV
        ld b, 16
cmp:    ld a, (de)
        cp (hl)
        jr nz, changed
        inc hl
        inc de
        djnz cmp
        jr scan

changed:
        ld a, 0A5h              ; marker
        out (RES), a
        ld hl, CUR
        ld de, PREV
        ld b, 16
report: ld a, (hl)
        out (RES), a
        ld (de), a
        inc hl
        inc de
        djnz report
        jr scan

        ; pad to 8 KB
        ds 2000h - $, 0FFh
