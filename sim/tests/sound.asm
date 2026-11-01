; SPDX-License-Identifier: GPL-2.0-or-later
; Tiki 100 AY-3-8912 test ROM
;
; Runs in place of the boot ROM. First reads back AY registers and writes the
; values to the result port FF (only values MAME and a real AY-3-8910 agree
; on: register bits that exist, and port A while it is an output). Then
; plays four sound segments of about 0.25 s each, separated by short
; silences, for comparing recordings:
;
;   1. channel A, 440 Hz tone (period 284), volume 15
;   2. channel B, 880 Hz tone (period 142), volume 10
;   3. channel C, 1563 Hz tone (period 80) with the envelope generator,
;      shape 0E (triangle), envelope period 200h: 7.6 Hz
;   4. channel A, noise only (noise period 10h), volume 15
;
; Assemble: z80asm -o sound.rom sound.asm

RES:    equ 0FFh        ; result port
AYADDR: equ 16h
AYDATA: equ 17h

        org 0
        di
        ld sp, 0FFF0h

        ld a, 01h               ; part 1: register read back
        out (RES), a

        ld hl, regvals          ; write registers 0-15 (14 last, with port A as output)
        ld b, 0
wr:     ld a, b
        out (AYADDR), a
        ld a, (hl)
        out (AYDATA), a
        inc hl
        inc b
        ld a, b
        cp 15
        jr nz, wr

        ld b, 0                 ; read registers 0-14 back
rd:     ld a, b
        out (AYADDR), a
        in a, (AYDATA)
        out (RES), a
        inc b
        ld a, b
        cp 15
        jr nz, rd

        ld a, 02h               ; part 2: sounds
        out (RES), a

        ld a, 7                 ; all off, port A output
        ld c, 07Fh
        call ay
        call silence

        ; 1: channel A, 440 Hz, volume 15
        ld a, 0
        ld c, 1Ch
        call ay
        ld a, 1
        ld c, 01h
        call ay
        ld a, 8
        ld c, 15
        call ay
        ld a, 7
        ld c, 07Eh              ; tone A on
        call ay
        call play
        ld a, 8
        ld c, 0
        call ay
        call silence

        ; 2: channel B, 880 Hz, volume 10
        ld a, 2
        ld c, 8Eh
        call ay
        ld a, 3
        ld c, 0
        call ay
        ld a, 9
        ld c, 10
        call ay
        ld a, 7
        ld c, 07Dh              ; tone B on
        call ay
        call play
        ld a, 9
        ld c, 0
        call ay
        call silence

        ; 3: channel C with the envelope
        ld a, 4
        ld c, 80
        call ay
        ld a, 5
        ld c, 0
        call ay
        ld a, 11
        ld c, 00h
        call ay
        ld a, 12
        ld c, 02h
        call ay
        ld a, 13
        ld c, 0Eh
        call ay
        ld a, 10
        ld c, 10h               ; volume from the envelope
        call ay
        ld a, 7
        ld c, 07Bh              ; tone C on
        call ay
        call play
        ld a, 10
        ld c, 0
        call ay
        call silence

        ; 4: noise on channel A
        ld a, 6
        ld c, 10h
        call ay
        ld a, 8
        ld c, 15
        call ay
        ld a, 7
        ld c, 077h              ; noise A on, tones off
        call ay
        call play
        ld a, 8
        ld c, 0
        call ay
        call silence

        ld a, 0EEh              ; done
        out (RES), a
        halt

; Write C to AY register A
ay:     out (AYADDR), a
        ld a, c
        out (AYDATA), a
        ret

; Delays: the inner loop is 26 cycles x 10000 = 65 ms at 4 MHz
play:   ld d, 4                 ; 0.26 s
        jr wait
silence:
        ld d, 1                 ; 65 ms
wait:   ld bc, 10000
w1:     dec bc
        ld a, b
        or c
        jr nz, w1
        dec d
        jr nz, wait
        ret

; Register values for the read-back test: unused bits are 0, so a real
; AY-3-8910 and MAME's AY-3-8912 read back the same. Register 7 has port A
; as an output (bit 6) and all channels off; register 14 is then readable.
regvals:
        db 5Ah, 0Ah, 0A5h, 05h, 3Ch, 0Ch, 15h, 7Fh
        db 0Ah, 0Bh, 0Ch, 34h, 12h, 08h, 0C3h

        ; pad to 8 KB
        ds 2000h - $, 0FFh
