; Tiki 100 CTC/DART/PIO test ROM
;
; Runs in place of the boot ROM, both in MAME and in the simulator, with
; both DART channels looped back (TxD to RxD). Every result is written to
; port FF, which nothing on the Tiki 100 decodes; the test scripts log those
; writes and compare them. Results are chosen so that they don't depend on
; exact timing. Interrupt handlers write a marker byte, so the order of
; interrupts is checked too. The main program waits for interrupts by
; watching an interrupt counter (HALT could miss one that arrives early).
;
; Assemble: z80asm -o iotest.rom iotest.asm

RES:    equ 0FFh        ; result port

DARTAD: equ 04h         ; DART channel A data
DARTBD: equ 05h         ; DART channel B data
DARTAC: equ 06h         ; DART channel A control
DARTBC: equ 07h         ; DART channel B control
PIOAD:  equ 08h         ; PIO port A data
PIOBD:  equ 09h         ; PIO port B data
PIOAC:  equ 0Ah         ; PIO port A control
PIOBC:  equ 0Bh         ; PIO port B control
CTC0:   equ 18h
CTC1:   equ 19h
CTC2:   equ 1Ah
CTC3:   equ 1Bh

VECTAB: equ 0FE00h      ; IM2 vector table in RAM
COUNT:  equ 0FD00h      ; interrupt counter

        org 0
        di
        ld sp, 0FFF0h
        ld hl, vectors
        ld de, VECTAB
        ld bc, vectors_end - vectors
        ldir
        ld a, VECTAB >> 8
        ld i, a
        im 2
        xor a
        ld (COUNT), a

        ld a, 01h               ; test 1
        out (RES), a

;-----------------------------------------------------------------------------
; PIO registers

        ld a, 0Fh               ; port A: mode 0 (output)
        out (PIOAC), a
        ld a, 55h
        out (PIOAD), a
        in a, (PIOAD)           ; mode 0 reads the output register: 55
        out (RES), a

        ld a, 0CFh              ; port B: mode 3 (bit control)
        out (PIOBC), a
        ld a, 0F0h              ; bits 4-7 inputs, 0-3 outputs
        out (PIOBC), a
        ld a, 0A5h
        out (PIOBD), a
        in a, (PIOBD)           ; printer status and tape in bits 4-7, 5 in bits 0-3
        out (RES), a

        ld a, 4Fh               ; port A: mode 1 (input)
        out (PIOAC), a

;-----------------------------------------------------------------------------
; PIO bit control interrupt: port B, interrupt when output bit 1 goes high

        ld a, 02h
        out (RES), a

        ld a, 20h               ; vector
        out (PIOBC), a
        ld a, 0B7h              ; enable, OR, active high, mask follows
        out (PIOBC), a
        ld a, 0FDh              ; monitor bit 1 only
        out (PIOBC), a
        in a, (PIOAC)           ; control read: interrupt control bits
        out (RES), a
        ei
        ld a, 07h               ; bit 1 high: the logic equation becomes true
        out (PIOBD), a
        ld b, 1
        call wait_count
        ld a, 03h               ; port B interrupts off
        out (PIOBC), a

;-----------------------------------------------------------------------------
; CTC timer interrupts: channel 1, prescaler 16, time constant 100

        ld a, 03h
        out (RES), a

        ld a, 00h               ; vector 00 (written to channel 0)
        out (CTC0), a
        ld a, 85h               ; interrupt, timer, prescaler 16, time constant follows
        out (CTC1), a
        ld a, 100
        out (CTC1), a
        ld b, 4
        call wait_count
        ld a, 03h               ; channel 1: reset, interrupt off
        out (CTC1), a

;-----------------------------------------------------------------------------
; CTC counter interrupts: channel 0 divides the 2 MHz clock by 4 (BAR0),
; channel 2 counts BAR0 and interrupts every 200 pulses. Channel 1 divides
; by 4 for DART channel B. These stay running as the baud rate clocks.

        ld a, 04h
        out (RES), a

        ld a, 47h               ; counter, falling edge, time constant follows, reset
        out (CTC0), a
        ld a, 4
        out (CTC0), a
        ld a, 47h
        out (CTC1), a
        ld a, 4
        out (CTC1), a
        ld a, 0C7h              ; channel 2: same with interrupt, every 200 pulses
        out (CTC2), a
        ld a, 200
        out (CTC2), a
        ld b, 6
        call wait_count
        ld a, 47h               ; channel 2: interrupt off, count every BAR0 pulse
        out (CTC2), a           ; (BAR2 is DART channel A's transmit clock)
        ld a, 1
        out (CTC2), a

;-----------------------------------------------------------------------------
; DART channel A, polled. x16 clock: 500 kHz / 16 = 31250 baud.

        ld a, 05h
        out (RES), a

        ld c, DARTAC
        ld hl, dart_init
        ld b, dart_init_end - dart_init
        otir
        ld a, 10h               ; reset external/status
        out (DARTAC), a
        in a, (DARTAC)          ; RR0
        out (RES), a
        ld a, 01h
        out (DARTAC), a
        in a, (DARTAC)          ; RR1: all sent
        out (RES), a

        ld a, 54h               ; send 'T'
        out (DARTAD), a
        call rx_a
        out (RES), a            ; 54
        call delay
        in a, (DARTAC)          ; RR0: nothing received, transmitter empty
        out (RES), a
        ld a, 01h
        out (DARTAC), a
        in a, (DARTAC)          ; RR1: all sent
        out (RES), a

        ; two characters back to back
        ld a, 0A1h
        out (DARTAD), a
        call tx_wait_a
        ld a, 0B2h
        out (DARTAD), a
        call rx_a
        out (RES), a            ; A1
        call rx_a
        out (RES), a            ; B2

;-----------------------------------------------------------------------------
; Receive overrun: four characters without reading. The FIFO holds three; the
; fourth replaces the third and sets the overrun error.

        ld a, 06h
        out (RES), a

        ld b, 4
        ld a, 30h
ovr:    out (DARTAD), a
        call tx_wait_a
        inc a
        djnz ovr
        call delay
        call delay
        ld a, 01h
        out (DARTAC), a
        in a, (DARTAC)          ; RR1: overrun, all sent
        out (RES), a
        in a, (DARTAD)          ; 30
        out (RES), a
        in a, (DARTAD)          ; 31
        out (RES), a
        ld a, 01h
        out (DARTAC), a
        in a, (DARTAC)          ; RR1: overrun stays until error reset
        out (RES), a
        in a, (DARTAD)          ; 33 (replaced 32)
        out (RES), a
        in a, (DARTAC)          ; RR0: FIFO empty
        out (RES), a
        ld a, 30h               ; error reset
        out (DARTAC), a
        ld a, 01h
        out (DARTAC), a
        in a, (DARTAC)          ; RR1
        out (RES), a

;-----------------------------------------------------------------------------
; DART channel B with interrupts: vector 10 with status affecting the vector,
; receive interrupt on all characters, transmit interrupt.

        ld a, 07h
        out (RES), a

        ld c, DARTBC
        ld hl, dart_init
        ld b, dart_init_end - dart_init
        otir
        ld a, 02h               ; WR2: vector
        out (DARTBC), a
        ld a, 10h
        out (DARTBC), a
        ld a, 02h
        out (DARTBC), a
        in a, (DARTBC)          ; RR2 with nothing pending: 16
        out (RES), a
        ld a, 01h               ; WR1: status affects vector, Rx int on all, Tx int
        out (DARTBC), a
        ld a, 1Eh
        out (DARTBC), a

        ld a, 6Bh               ; send 'k'
        out (DARTBD), a
        ld b, 8                 ; transmit buffer empty, then receive
        call wait_count
        ld a, 0C4h
        out (DARTBD), a
        ld b, 10
        call wait_count

        ld a, 01h               ; WR1: interrupts off, status still affects the vector
        out (DARTBC), a
        ld a, 04h
        out (DARTBC), a

;-----------------------------------------------------------------------------
; Interrupt priority: the CTC (channel 3) and DART channel A receive
; interrupt are both pending when interrupts are enabled; the CTC goes
; first. A nested interrupt can't happen because the handlers don't EI.

        ld a, 08h
        out (RES), a

        ld a, 01h               ; DART A WR1: Rx interrupt on all characters
        out (DARTAC), a
        ld a, 18h
        out (DARTAC), a
        ld a, 0C7h              ; CTC 3: counter of BAR2, interrupt
        out (CTC3), a
        ld a, 200
        out (CTC3), a
        ld a, 5Ah
        out (DARTAD), a
        call delay              ; both now pending
        call delay
        ld a, 83h               ; CTC 3 stops; its interrupt stays pending
        out (CTC3), a
        ld b, 12
        call wait_count
        ld a, 03h               ; CTC 3 interrupt off
        out (CTC3), a
        ld a, 01h
        out (DARTAC), a
        xor a
        out (DARTAC), a

;-----------------------------------------------------------------------------

        ld a, 0EEh              ; done
        out (RES), a
        di
        halt

;-----------------------------------------------------------------------------
; Subroutines

; Enable interrupts and wait until B interrupts have happened in total
; (counting from the start). Interrupts are disabled again on return.
wait_count:
        push hl
        ld hl, 0
        ei
wc1:    ld a, (COUNT)
        cp b
        jr nc, wc2
        dec hl
        ld a, h
        or l
        jr nz, wc1
        ld a, 0ECh              ; timeout
        out (RES), a
wc2:    di
        ld a, (COUNT)
        out (RES), a            ; the count
        pop hl
        ret

; Wait for a character on channel A and return it in A
rx_a:   push bc
        ld bc, 0
rx_a1:  in a, (DARTAC)
        rra
        jr c, rx_a2
        dec bc
        ld a, b
        or c
        jr nz, rx_a1
        ld a, 0EFh              ; timeout
        out (RES), a
rx_a2:  pop bc
        in a, (DARTAD)
        ret

; Wait until channel A's transmit buffer is empty
tx_wait_a:
        push af
tx_w1:  in a, (DARTAC)
        and 04h
        jr z, tx_w1
        pop af
        ret

; About 10 ms
delay:  push bc
        ld bc, 2000
del1:   dec bc
        ld a, b
        or c
        jr nz, del1
        pop bc
        ret

; DART setup, written to a control port with OTIR
dart_init:
        db 18h                  ; channel reset
        db 04h, 44h             ; WR4: x16 clock, 1 stop bit, no parity
        db 03h, 0C1h            ; WR3: receive 8 bits, enable
        db 05h, 0EAh            ; WR5: DTR, transmit 8 bits, enable, RTS
        db 01h, 00h             ; WR1: no interrupts
dart_init_end:

;-----------------------------------------------------------------------------
; Interrupt handlers. Each writes a marker to the result port.

int_count:
        push af
        ld a, (COUNT)
        inc a
        ld (COUNT), a
        pop af
        ret

ctc0_int:
        push af
        ld a, 0C0h
        jr ctc_int
ctc1_int:
        push af
        ld a, 0C1h
        jr ctc_int
ctc2_int:
        push af
        ld a, 0C2h
        jr ctc_int
ctc3_int:
        push af
        ld a, 0C3h
ctc_int:
        out (RES), a
        call int_count
        pop af
        ei
        reti

; DART channel B
b_tx_int:
        push af
        call int_count
        ld a, 0B0h
        out (RES), a
        ld a, 28h               ; reset transmit interrupt pending
        out (DARTBC), a
        pop af
        ei
        reti
b_rx_int:
        push af
        call int_count
        ld a, 0B4h
        out (RES), a
        in a, (DARTBD)
        out (RES), a
        pop af
        ei
        reti
; DART channel A receive
a_rx_int:
        push af
        call int_count
        ld a, 0A4h
        out (RES), a
        in a, (DARTAD)
        out (RES), a
        pop af
        ei
        reti
unexpected:
        push af
        ld a, 0EDh
        out (RES), a
        pop af
        ei
        reti

pio_b_int:
        push af
        call int_count
        ld a, 0B9h
        out (RES), a
        pop af
        ei
        reti

vectors:
        dw ctc0_int, ctc1_int, ctc2_int, ctc3_int       ; 00-06
        dw unexpected, unexpected, unexpected, unexpected
        dw b_tx_int, unexpected, b_rx_int, unexpected   ; 10-16: B Tx, B ext, B Rx, B special
        dw unexpected, unexpected, a_rx_int, unexpected ; 18-1E: A Tx, A ext, A Rx, A special
        dw pio_b_int                                    ; 20
vectors_end:

        ; pad to 8 KB
        ds 2000h - $, 0FFh
