; ---------------------------------------------------------------------------
; RayWalls v2 - upright-wall raycaster for the Atari 2600
; Cartridge: 8K F8 + Superchip (F8SC, 128 bytes extra RAM)
;
; Bank 0: display kernels, main loop, buffer swap, joystick/movement.
; Bank 1: ray casting (Work), called from bank 0 through a trampoline.
;
; Per view:  for every column, cast a ray (DDA) and look up the wall height
; from a per-column-bucket table (fisheye correction is baked in).  Columns
; are accumulated 1-8 at a time into one playfield byte ("group"), then the
; 16 level bytes of that group are written in one pass ("compose"):
;     level L byte = OR of masks of the group's columns with height >= L
; done as a cascade: cur |= mask for every lit column, and the column's mask
; is dropped at level h+1.  Every byte of the back buffer gets written, so no
; clearing and no read-modify-write.
;
; All work is split into small chunks (setup, one DDA step, finish, two
; compose levels) that check the RIOT timer first and pause when time runs
; short; state lives in RAM so they simply resume in the next free period.
;
; Two playfield buffers (16 levels x 6 bytes): A in Superchip RAM, B in
; console RAM $80-$DF.  One is displayed while the other is built.
;
; Build:  dasm raywalls.asm -f3 -oraywalls.bin
; ---------------------------------------------------------------------------
        processor 6502
        include "config.inc"

VSYNC   = $00
VBLANK  = $01
WSYNC   = $02
COLUPF  = $08
COLUBK  = $09
CTRLPF  = $0A
PF0     = $0D
PF1     = $0E
PF2     = $0F
SWCHA   = $280
SWCHB   = $282
INTIM   = $284
TIM64T  = $296

NLEV    = 16
CEILCOL = $80
FLOORCOL= $F4
TURN    = 5
MARGIN  = 72            ; keep 0.28 cell from walls

; Superchip RAM: write $F000-$F07F, read $F080-$F0FF
SCW     = $F000
SCR     = $F080
; buffer layout (offsets): 6 arrays of NLEV bytes, level 1 at index 0
P0L     = 0
P1L     = 16
P2L     = 32
P0R     = 48
P1R     = 64
P2R     = 80
BUFB    = $80
; Superchip variables
V_FRONT = $60           ; 0 = showing A (Superchip), 1 = showing B (RAM)
V_BCOL  = $61           ; column being built
V_SIG   = $62           ; previous column's wall signature
V_STATE = $63           ; 0 idle, 1 ray in DDA, 2 composing a group
V_OPT   = $64           ; console switches snapshot
V_READY = $65           ; 1 = back buffer complete, swap wanted
V_BACKL = $66           ; low byte of back buffer write address
V_CY    = $67           ; compose: next level index
D0      = $68           ; 16 bytes: drop masks, D0+h = columns of height h

; zero page variables ($E0-$FB), stack $FC-$FF (2 call levels)
posXL   = $E0
posXH   = $E1
posYL   = $E2
posYH   = $E3
ang     = $E4
wptrL   = $E5           ; compose write pointer (back buffer + group)
wptrH   = $E6
cur     = $E7           ; compose: lit columns of the current group
smask   = $E8           ; compose: inverted mask of striped columns
cell    = $E9
stepX   = $EA
stepY   = $EB
sdXL    = $EC
sdXH    = $ED
sdYL    = $EE
sdYH    = $EF
ddXL    = $F0
ddXH    = $F1
ddYL    = $F2
ddYH    = $F3
distL   = $F4
distH   = $F5
side    = $F6
tmp     = $F7
mb      = $F8
prodL   = $F9
prodH   = $FA
colr    = $FB

; timer thresholds (units of 64 cycles); measured worst cases in comments
VBTIME  = 62
OSTIME  = 53
STARTT  = 8             ; ray setup + first check (worst ~395 cycles)
FINT    = 6             ; one DDA step + finish column + next check (~295)
COMPT   = 3             ; two compose levels + next check (~140)
SWAPT   = 7             ; buffer swap + joystick + movement (~345)

; ===========================================================================
; Bank 0: display, main loop, movement
; ===========================================================================
        org $0000
        rorg $F000
        ds 256, 0               ; Superchip RAM window

; ---- page $F100: kernel tables + kernel A (must not cross pages) ----------
LINES_COLT_START
        include "bank0.inc"     ; LINES, COLT first (page start), MAP0, MOVC
        align 256

; ---------------------------------------------------------------------------
; Kernel A: display buffer in Superchip RAM
; ---------------------------------------------------------------------------
KernelA
        lda #CEILCOL
        sta COLUBK
        ldy #NLEV
        lda COLT,y
        sta colr
        ldx LINES,y
KA_Top
        sta WSYNC
        lda colr                ; 3
        sta COLUPF              ; 6
        lda SCR-1+P0L,y         ; 10
        sta PF0                 ; 13
        lda SCR-1+P1L,y         ; 17
        sta PF1                 ; 20
        lda SCR-1+P2L,y         ; 24
        sta PF2                 ; 27
        lda SCR-1+P0R,y         ; 31
        sta PF0                 ; 34
        lda SCR-1+P1R,y         ; 38
        sta PF1                 ; 41
        lda SCR-1+P2R,y         ; 45
        nop                     ; 47
        nop                     ; 49
        sta PF2                 ; 52
        dex                     ; 54
        bne KA_Top              ; 57
        dey                     ; 58
        lda COLT,y              ; 62
        sta colr                ; 65
        ldx LINES,y             ; 69
        bne KA_Top              ; 72
        sta WSYNC
        lda #FLOORCOL           ; 2   horizon line = first floor line
        sta COLUBK              ; 5
        lda COLT+1              ; 9
        sta COLUPF              ; 12
        lda SCR+P0L             ; 16
        sta PF0                 ; 19
        lda SCR+P1L             ; 23
        sta PF1                 ; 26
        lda SCR+P2L             ; 30
        sta PF2                 ; 33
        lda SCR+P0R             ; 37
        sta PF0                 ; 40
        lda SCR+P1R             ; 44
        sta PF1                 ; 47
        lda SCR+P2R             ; 51
        sta PF2                 ; 54
        ldy #1                  ; 56
        lda COLT,y              ; 60
        sta colr                ; 63
        ldx LINES,y             ; 67
        dex                     ; 69
KA_Bot
        sta WSYNC
        lda colr
        sta COLUPF
        lda SCR-1+P0L,y
        sta PF0
        lda SCR-1+P1L,y
        sta PF1
        lda SCR-1+P2L,y
        sta PF2
        lda SCR-1+P0R,y
        sta PF0
        lda SCR-1+P1R,y
        sta PF1
        lda SCR-1+P2R,y
        nop
        nop
        sta PF2
        dex
        bne KA_Bot
        iny
        lda COLT,y
        sta colr
        ldx LINES,y
        bne KA_Bot
        jmp KernelEnd

        align 256
; ---------------------------------------------------------------------------
; Kernel B: display buffer in console RAM (same timing, absolute addressing)
; ---------------------------------------------------------------------------
KernelB
        lda #CEILCOL
        sta COLUBK
        ldy #NLEV
        lda COLT,y
        sta colr
        ldx LINES,y
KB_Top
        sta WSYNC
        lda colr
        sta COLUPF
        lda.w BUFB-1+P0L,y
        sta PF0
        lda.w BUFB-1+P1L,y
        sta PF1
        lda.w BUFB-1+P2L,y
        sta PF2
        lda.w BUFB-1+P0R,y
        sta PF0
        lda.w BUFB-1+P1R,y
        sta PF1
        lda.w BUFB-1+P2R,y
        nop
        nop
        sta PF2
        dex
        bne KB_Top
        dey
        lda COLT,y
        sta colr
        ldx LINES,y
        bne KB_Top
        sta WSYNC
        lda #FLOORCOL
        sta COLUBK
        lda COLT+1
        sta COLUPF
        lda.w BUFB+P0L
        sta PF0
        lda.w BUFB+P1L
        sta PF1
        lda.w BUFB+P2L
        sta PF2
        lda.w BUFB+P0R
        sta PF0
        lda.w BUFB+P1R
        sta PF1
        lda.w BUFB+P2R
        sta PF2
        ldy #1
        lda COLT,y
        sta colr
        ldx LINES,y
        dex
KB_Bot
        sta WSYNC
        lda colr
        sta COLUPF
        lda.w BUFB-1+P0L,y
        sta PF0
        lda.w BUFB-1+P1L,y
        sta PF1
        lda.w BUFB-1+P2L,y
        sta PF2
        lda.w BUFB-1+P0R,y
        sta PF0
        lda.w BUFB-1+P1R,y
        sta PF1
        lda.w BUFB-1+P2R,y
        nop
        nop
        sta PF2
        dex
        bne KB_Bot
        iny
        lda COLT,y
        sta colr
        ldx LINES,y
        bne KB_Bot
        jmp KernelEnd

; ---------------------------------------------------------------------------
; Reset
; ---------------------------------------------------------------------------
Start
        sei
        cld
        ldx #0
        txa
ClearZP dex
        txs
        pha
        bne ClearZP             ; clears $00-$FF, leaves SP=$FF
        ldx #$7F
ClearSC sta SCW,x
        dex
        bpl ClearSC
        lda #$80
        sta posXL
        sta posYL
        sta SCW+V_BACKL         ; back buffer = B ($0080)
        lda #1
        sta posXH
        lda #5
        sta posYH
        lda #$FF
        sta SCW+V_SIG
        sta smask
        lda SWCHB
        sta SCW+V_OPT

; ---------------------------------------------------------------------------
; Main frame loop
; ---------------------------------------------------------------------------
MainLoop
        lda #2
        sta WSYNC
        sta VBLANK
        sta VSYNC
        sta WSYNC
        sta WSYNC
        sta WSYNC
        lda #0
        sta VSYNC
        lda #VBTIME
        sta TIM64T
        jsr CallWork
        lda SCR+V_READY
        beq VBWait
        lda INTIM
        cmp #SWAPT
        bcc VBWait
        jsr Swap
        jsr CallWork
VBWait  lda INTIM
        bne VBWait
        sta WSYNC
        sta VBLANK              ; A = 0
        lda SCR+V_FRONT
        bne ShowB
        jmp KernelA
ShowB   jmp KernelB
KernelEnd
        sta WSYNC
        lda #0
        sta PF0
        sta PF1
        sta PF2
        lda #2
        sta VBLANK
        lda #OSTIME
        sta TIM64T
        jsr CallWork
        lda SCR+V_READY
        beq OSWait
        lda INTIM
        cmp #SWAPT
        bcc OSWait
        jsr Swap
        jsr CallWork
OSWait  lda INTIM
        bne OSWait
        jmp MainLoop

; ---------------------------------------------------------------------------
; Swap buffers (the back buffer is complete), then read the joystick
; ---------------------------------------------------------------------------
Swap
        lda SCR+V_FRONT
        eor #1
        sta SCW+V_FRONT
        beq BackIsB
        lda #<SCW               ; showing B -> build into A
        sta SCW+V_BACKL
        lda #>SCW
        sta wptrH
        jmp SwapRst
BackIsB lda #BUFB
        sta SCW+V_BACKL
        lda #0
        sta wptrH
SwapRst lda #0
        sta SCW+V_BCOL
        sta SCW+V_READY
        lda #$FF
        sta SCW+V_SIG
        lda SWCHB
        sta SCW+V_OPT
        ; --- joystick ---
        lda SWCHA
        and #$80
        bne NoRight
        lda ang
        clc
        adc #TURN
        sta ang
NoRight lda SWCHA
        and #$40
        bne NoLeft
        lda ang
        sec
        sbc #TURN
        sta ang
NoLeft  lda SWCHA
        and #$10
        bne NoUp
        ldx ang
        lda MOVC,x
        sta tmp
        jsr TryX
        lda ang
        sec
        sbc #64
        tax
        lda MOVC,x
        sta tmp
        jsr TryY
NoUp    lda SWCHA
        and #$20
        bne NoDown
        ldx ang
        lda #0
        sec
        sbc MOVC,x
        sta tmp
        jsr TryX
        lda ang
        sec
        sbc #64
        tax
        lda #0
        sec
        sbc MOVC,x
        sta tmp
        jsr TryY
NoDown  rts

; move along X by signed tmp if the probe cell is free
TryX    lda tmp
        beq TXDone
        bmi TXNeg
        clc
        adc posXL
        sta prodL
        lda posXH
        adc #0
        sta prodH
        lda prodL
        clc
        adc #MARGIN
        lda prodH
        adc #0
        jmp TXChk
TXNeg   clc
        adc posXL
        sta prodL
        lda posXH
        adc #$FF
        sta prodH
        lda prodL
        sec
        sbc #MARGIN
        lda prodH
        sbc #0
TXChk   sta mb
        lda posYH
        asl
        asl
        asl
        asl
        ora mb
        tax
        lda MAP0,x
        bne TXDone
        lda prodL
        sta posXL
        lda prodH
        sta posXH
TXDone  rts

TryY    lda tmp
        beq TYDone
        bmi TYNeg
        clc
        adc posYL
        sta prodL
        lda posYH
        adc #0
        sta prodH
        lda prodL
        clc
        adc #MARGIN
        lda prodH
        adc #0
        jmp TYChk
TYNeg   clc
        adc posYL
        sta prodL
        lda posYH
        adc #$FF
        sta prodH
        lda prodL
        sec
        sbc #MARGIN
        lda prodH
        sbc #0
TYChk   asl
        asl
        asl
        asl
        ora posXH
        tax
        lda MAP0,x
        bne TYDone
        lda prodL
        sta posYL
        lda prodH
        sta posYH
TYDone  rts
Bank0End

; ---- bank switching trampoline + reset (same addresses in both banks) ----
        org $0FD0
        rorg $FFD0
CallWork
        lda $FFF9               ; -> bank 1, continues at $FFD3 there
        nop                     ; $FFD3-$FFD8 are never run in bank 0
        nop
        nop
        nop
        nop
        nop
        rts                     ; $FFD9: back from bank 1
        org $0FE0
        rorg $FFE0
Reset0  lda $FFF8               ; make sure bank 0 is selected
        jmp Start
        org $0FFC
        rorg $FFFC
        .word $FFE0
        .word $FFE0

; ===========================================================================
; Bank 1: ray casting
; ===========================================================================
        org $1000
        rorg $F000
        ds 256, 0               ; Superchip RAM window

; ---------------------------------------------------------------------------
; Work: run chunks while the timer allows; returns with time left < chunk
; ---------------------------------------------------------------------------
Work
WL      lda SCR+V_STATE
        beq WNew
        cmp #1
        bne WComp
        jmp StepLoop
WComp   jmp Compose
WNew    lda SCR+V_BCOL
        cmp #COLS
        bcc WCast
        lda #1
        sta SCW+V_READY
        rts
WCast   lda INTIM
        cmp #STARTT
        bcs CastColumn
        rts

; ---------------------------------------------------------------------------
; Ray setup for column V_BCOL
; ---------------------------------------------------------------------------
CastColumn
        ldx SCR+V_BCOL
        lda ang
        clc
        adc COLOFF,x
        sta side                ; ray angle (temp)
        ; |1/cos| for X: fold angle to 0..64
        and #$7F
        cmp #65
        bcc FX1
        eor #$7F
        adc #0                  ; carry set: 128 - t
FX1     tay
        lda DDQL,y
        sta ddXL
        lda DDQH,y
        sta ddXH
        ; |1/sin| = |1/cos(angle-64)|
        lda side
        sec
        sbc #64
        and #$7F
        cmp #65
        bcc FY1
        eor #$7F
        adc #0
FY1     tay
        lda DDQL,y
        sta ddYL
        lda DDQH,y
        sta ddYH
        ; ---- X: step direction and first boundary distance ----
        lda side
        clc
        adc #64
        bmi CXNeg
        lda #1
        sta stepX
        lda posXL
        eor #$FF
        jmp CXF
CXNeg   lda #$FF
        sta stepX
        lda posXL
CXF     sta mb
        ; sdX = hi(frac*ddXL) + frac*ddXH   (8.8)
        ; hi byte via quarter squares, low-byte borrow ignored (error <= 1/256)
        lda ddXL
        clc
        adc mb
        tax
        bcs MX1h
        lda SQH0,x
        jmp MX1d
MX1h    lda SQH1,x
MX1d    sta sdXL
        lda ddXL
        sec
        sbc mb
        bcs MX1p
        eor #$FF
        adc #1
MX1p    tax
        lda sdXL
        sec
        sbc SQH0,x
        sta sdXL
        lda #0
        sta sdXH
        ldx ddXH              ; integer part of 1/cos: usually 1..3
        cpx #4
        bcs MX2m
MX2a    lda sdXL              ; small: add frac that many times
        clc
        adc mb
        sta sdXL
        bcc MX2n
        inc sdXH
MX2n    dex
        bne MX2a
        jmp MX2x
MX2m    txa                     ; large: full 8x8 multiply
        sta tmp
        clc
        adc mb
        tax
        bcs MX2h
        lda SQL0,x
        sta prodL
        lda SQH0,x
        jmp MX2d
MX2h    lda SQL1,x
        sta prodL
        lda SQH1,x
MX2d    sta prodH
        lda tmp
        sec
        sbc mb
        bcs MX2p
        eor #$FF
        adc #1
MX2p    tax
        lda prodL
        sec
        sbc SQL0,x
        sta prodL
        lda prodH
        sbc SQH0,x
        sta prodH
        lda prodL
        clc
        adc sdXL
        sta sdXL
        lda prodH
        adc #0
        sta sdXH
MX2x
        ; ---- Y ----
        lda side
        bmi CYNeg
        lda #16
        sta stepY
        lda posYL
        eor #$FF
        jmp CYF
CYNeg   lda #$F0
        sta stepY
        lda posYL
CYF     sta mb
        ; sdY = hi(frac*ddYL) + frac*ddYH   (8.8)
        ; hi byte via quarter squares, low-byte borrow ignored (error <= 1/256)
        lda ddYL
        clc
        adc mb
        tax
        bcs MY1h
        lda SQH0,x
        jmp MY1d
MY1h    lda SQH1,x
MY1d    sta sdYL
        lda ddYL
        sec
        sbc mb
        bcs MY1p
        eor #$FF
        adc #1
MY1p    tax
        lda sdYL
        sec
        sbc SQH0,x
        sta sdYL
        lda #0
        sta sdYH
        ldx ddYH              ; integer part of 1/cos: usually 1..3
        cpx #4
        bcs MY2m
MY2a    lda sdYL              ; small: add frac that many times
        clc
        adc mb
        sta sdYL
        bcc MY2n
        inc sdYH
MY2n    dex
        bne MY2a
        jmp MY2x
MY2m    txa                     ; large: full 8x8 multiply
        sta tmp
        clc
        adc mb
        tax
        bcs MY2h
        lda SQL0,x
        sta prodL
        lda SQH0,x
        jmp MY2d
MY2h    lda SQL1,x
        sta prodL
        lda SQH1,x
MY2d    sta prodH
        lda tmp
        sec
        sbc mb
        bcs MY2p
        eor #$FF
        adc #1
MY2p    tax
        lda prodL
        sec
        sbc SQL0,x
        sta prodL
        lda prodH
        sbc SQH0,x
        sta prodH
        lda prodL
        clc
        adc sdYL
        sta sdYL
        lda prodH
        adc #0
        sta sdYH
MY2x
        ; ---- map cell ----
        lda posYH
        asl
        asl
        asl
        asl
        ora posXH
        sta cell
        lda #1
        sta SCW+V_STATE

; ---------------------------------------------------------------------------
; DDA: one step per chunk
; ---------------------------------------------------------------------------
StepLoop
        lda INTIM
        cmp #FINT
        bcs StepGo
        rts                     ; pause; V_STATE = 1 resumes here
StepGo  lda sdXL
        cmp sdYL
        lda sdXH
        sbc sdYH
        bcs DoStepY
        lda sdXH
        cmp #MAXD
        bcs NoHit
        lda sdXL
        clc
        adc ddXL
        sta sdXL
        lda sdXH
        adc ddXH
        sta sdXH
        lda cell
        clc
        adc stepX
        sta cell
        tax
        lda MAP1,x
        beq StepLoop
        lda sdXL                ; distance = side distance before the step
        sec
        sbc ddXL
        sta distL
        lda sdXH
        sbc ddXH
        sta distH
        lda #0
        sta side
        jmp Hit
DoStepY lda sdYH
        cmp #MAXD
        bcs NoHit
        lda sdYL
        clc
        adc ddYL
        sta sdYL
        lda sdYH
        adc ddYH
        sta sdYH
        lda cell
        clc
        adc stepY
        sta cell
        tax
        lda MAP1,x
        beq StepLoop
        lda sdYL
        sec
        sbc ddYL
        sta distL
        lda sdYH
        sbc ddYH
        sta distH
        lda #1
        sta side
        jmp Hit

NoHit   lda #0
        sta SCW+V_STATE
        lda #$FF
        sta SCW+V_SIG
        jmp ColEnd

; ---------------------------------------------------------------------------
; Finish a column: height lookup, edge detection, add to the group
; ---------------------------------------------------------------------------
Hit     lda #0
        sta SCW+V_STATE
        ; index = Euclidean distance in 4.4 (dist < MAXD -> < 160)
        lda distH
        asl
        asl
        asl
        asl
        sta tmp
        lda distL
        lsr
        lsr
        lsr
        lsr
        ora tmp
        tax
        ldy SCR+V_BCOL
        lda CBUCK,y             ; 0..7 -> one of 8 height tables
        lsr
        bcs HBodd
        beq HB0
        cmp #2
        bcc HB2
        beq HB4
        lda HTB6,x
        jmp HGot
HB0     lda HTB0,x
        jmp HGot
HB2     lda HTB2,x
        jmp HGot
HB4     lda HTB4,x
        jmp HGot
HBodd   beq HB1
        cmp #2
        bcc HB3
        beq HB5
        lda HTB7,x
        jmp HGot
HB1     lda HTB1,x
        jmp HGot
HB3     lda HTB3,x
        jmp HGot
HB5     lda HTB5,x
HGot    sta distH               ; distH = height in levels
        ; wall signature: side + plane coordinate
        lda side
        bne SigY
        lda cell
        and #15
        jmp SigC
SigY    lda cell
        lsr
        lsr
        lsr
        lsr
        ora #16
SigC    cmp SCR+V_SIG
        sta SCW+V_SIG
        beq NoEdge
        cpy #0                  ; y = column
        beq NoEdge
        bit SCR+V_OPT           ; P1 difficulty (bit 7): A = no edge gaps
        bmi NoEdge
        jmp ColEnd              ; edge: leave this column empty
NoEdge  lda distH
        beq ColEnd
        lda CMASK,y
        sta mb
        ora cur
        sta cur
        ldx distH
        cpx #NLEV
        beq NoDrop
        lda SCR+D0,x            ; drop this column from level h+1 on
        ora mb
        sta SCW+D0,x
NoDrop  lda side
        beq ColEnd
        bit SCR+V_OPT           ; P0 difficulty (bit 6): A = solid side walls
        bvs ColEnd
        lda mb
        eor #$FF
        and smask
        sta smask
ColEnd  ldx SCR+V_BCOL
        lda CGRP,x
        bmi NotEnd
        clc
        adc SCR+V_BACKL
        sta wptrL
        lda #0
        sta SCW+V_CY
        lda #2
        sta SCW+V_STATE
        jmp Compose
NotEnd  inx
        stx SCW+V_BCOL
        jmp WL

; ---------------------------------------------------------------------------
; Compose: write the 16 level bytes of the finished group (2 levels/chunk)
; ---------------------------------------------------------------------------
Compose
        ldy SCR+V_CY
CLoop   lda INTIM
        cmp #COMPT
        bcs CGo
        sty SCW+V_CY
        rts                     ; pause; V_STATE = 2 resumes here
CGo     lda SCR+D0,y            ; odd level: solid and striped columns
        eor #$FF
        and cur
        sta cur
        sta (wptrL),y
        lda #0
        sta SCW+D0,y
        iny
        lda SCR+D0,y            ; even level: striped columns dark
        eor #$FF
        and cur
        sta cur
        and smask
        sta (wptrL),y
        lda #0
        sta SCW+D0,y
        iny
        cpy #NLEV
        bne CLoop
        lda #0
        sta cur
        sta SCW+V_STATE
        lda #$FF
        sta smask
        ldx SCR+V_BCOL
        inx
        stx SCW+V_BCOL
        jmp WL

; ---------------------------------------------------------------------------
        include "bank1.inc"
Bank1End

        org $1FD0
        rorg $FFD0
        lda $FFF9               ; (bank 0 executes this)
        jsr Work                ; $FFD3
        lda $FFF8               ; $FFD6 -> bank 0, continues at $FFD9 (rts)
        rts
        org $1FE0
        rorg $FFE0
        lda $FFF8               ; -> bank 0, continues at $FFE3 there
        nop
        nop
        nop
        org $1FFC
        rorg $FFFC
        .word $FFE0
        .word $FFE0
