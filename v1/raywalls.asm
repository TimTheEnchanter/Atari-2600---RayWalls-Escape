; ---------------------------------------------------------------------------
; RayWalls - upright-wall raycaster for the Atari 2600
; Cartridge: 8K F8 + Superchip (F8SC, 128 bytes extra RAM)
;
; Idea: cast one ray per playfield column (40 or 20), turn each hit into a
; wall height in "levels", and OR the column's bit into a 6-byte-per-level
; playfield buffer.  The kernel then just streams PF0/PF1/PF2 (asymmetric)
; for each level, mirrored above and below the horizon.
;
; Two buffers: A lives in Superchip RAM, B in console RAM ($80-$DF).
; One is displayed while the other is built, then they swap (no tearing).
; Ray casting runs in VBLANK + overscan, is timer-checked every DDA step
; and simply pauses mid-ray when time runs out, resuming next frame.
;
; Build:  dasm raywalls.asm -f3 -oraywalls.bin
; ---------------------------------------------------------------------------
        processor 6502

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
V_INRAY = $63           ; 1 = ray paused mid-DDA
V_OPT   = $64           ; console switches snapshot

; zero page variables ($E0-$FB), stack $FC-$FF
posXL   = $E0
posXH   = $E1
posYL   = $E2
posYH   = $E3
ang     = $E4
wptrL   = $E5
wptrH   = $E6
rptrL   = $E7
rptrH   = $E8
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

; timer thresholds (units of 64 cycles)
VBTIME  = 62
OSTIME  = 53
STARTT  = 10            ; time needed to set up a ray (worst ~525 cycles)
FINT    = 14            ; time needed for one DDA step + finishing a column (worst ~765)
SWAPT   = 23            ; time needed for buffer swap + input (worst ~1380)

; ===========================================================================
; Bank 0: only a stub that switches to bank 1
; ===========================================================================
        org $0000
        rorg $F000
        ds 256, 0               ; Superchip RAM window
        org $0FE0
        rorg $FFE0
        lda $FFF9               ; -> bank 1, continues at $FFE3 there
        nop
        nop
        nop
        org $0FFC
        rorg $FFFC
        .word $FFE0
        .word $FFE0

; ===========================================================================
; Bank 1: everything
; ===========================================================================
        org $1000
        rorg $F000
        ds 256, 0               ; Superchip RAM window

; ---- page $F100: kernel tables + kernels (must not cross pages) -----------
        include "tables_k.inc"  ; LINES, COLT

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
        lda #1
        sta posXH
        lda #5
        sta posYH
        lda #0
        sta ang
        lda #$FF
        sta SCW+V_SIG
        ; back buffer = B (console RAM)
        lda #BUFB
        sta wptrL
        sta rptrL
        lda #0
        sta wptrH
        sta rptrH

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
        jsr Work
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
        jsr Work
OSWait  lda INTIM
        bne OSWait
        jmp MainLoop

; ---------------------------------------------------------------------------
; Work: cast rays / swap buffers while the timer allows
; ---------------------------------------------------------------------------
Work
WorkLoop
        lda SCR+V_INRAY
        beq WNoResume
        lda #0
        sta SCW+V_INRAY
        jmp StepLoop
WNoResume
        lda SCR+V_BCOL
        cmp #COLS
        bcs WSwap
        lda INTIM
        cmp #STARTT
        bcc WDone
        jmp CastColumn
WSwap   lda INTIM
        cmp #SWAPT
        bcc WDone
        jmp Swap
WDone   rts

; ---------------------------------------------------------------------------
; Swap buffers, read the joystick, clear the new back buffer
; ---------------------------------------------------------------------------
Swap
        lda SCR+V_FRONT
        eor #1
        sta SCW+V_FRONT
        beq BackIsB
        lda #<SCW               ; showing B -> build into A
        sta wptrL
        lda #>SCW
        sta wptrH
        lda #<SCR
        sta rptrL
        lda #>SCR
        sta rptrH
        jmp DoClear
BackIsB lda #BUFB
        sta wptrL
        sta rptrL
        lda #0
        sta wptrH
        sta rptrH
DoClear lda #0
        ldy #NLEV*6-1
ClrLoop sta (wptrL),y
        dey
        bpl ClrLoop
        sta SCW+V_BCOL
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
NoDown  jmp WorkLoop

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
        lda MAP,x
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
        lda MAP,x
        bne TYDone
        lda prodL
        sta posYL
        lda prodH
        sta posYH
TYDone  rts

; ---------------------------------------------------------------------------
; Cast the ray for column V_BCOL (DDA through the 16x16 map)
; ---------------------------------------------------------------------------
CastColumn
        ldx SCR+V_BCOL
        lda ang
        clc
        adc COLOFF,x
        sta side                ; ray angle (temp)
        tax
        lda DDL,x
        sta ddXL
        lda DDH,x
        sta ddXH
        txa
        sec
        sbc #64
        tay
        lda DDL,y
        sta ddYL
        lda DDH,y
        sta ddYH
        ; X direction: cos >= 0 when (angle+64) < 128
        txa
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
        lda ddXL
        jsr Mul8
        lda prodH
        sta sdXL
        lda ddXH
        jsr Mul8
        lda prodL
        clc
        adc sdXL
        sta sdXL
        lda prodH
        adc #0
        sta sdXH
        ; Y direction: sin > 0 when angle < 128
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
        lda ddYL
        jsr Mul8
        lda prodH
        sta sdYL
        lda ddYH
        jsr Mul8
        lda prodL
        clc
        adc sdYL
        sta sdYL
        lda prodH
        adc #0
        sta sdYH
        lda posYH
        asl
        asl
        asl
        asl
        ora posXH
        sta cell

StepLoop
        lda INTIM
        cmp #FINT
        bcs StepGo
        lda #1                  ; out of time: pause, resume next slot
        sta SCW+V_INRAY
        rts
StepGo  lda sdXL
        cmp sdYL
        lda sdXH
        sbc sdYH
        bcs DoStepY
        lda sdXL
        sta distL
        lda sdXH
        sta distH
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
        lda MAP,x
        beq StepLoop
        lda #0
        sta side
        jmp Hit
DoStepY lda sdYL
        sta distL
        lda sdYH
        sta distH
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
        lda MAP,x
        beq StepLoop
        lda #1
        sta side
        jmp Hit

NoHit   lda #$FF
        sta SCW+V_SIG
        jmp ColDone

Hit     ; perpendicular distance = dist * cos(column offset)
        ldx SCR+V_BCOL
        lda CCOS,x
        sta mb
        lda distL
        jsr Mul8
        lda prodH
        sta distL
        lda distH
        jsr Mul8
        lda prodL
        clc
        adc distL
        sta distL
        lda prodH
        adc #0
        ; index = perp in 4.4
        asl
        asl
        asl
        asl
        sta distH
        lda distL
        lsr
        lsr
        lsr
        lsr
        ora distH
        cmp #160
        bcc HIdx
        lda #159
HIdx    tax
        lda HTAB,x
        sta distH               ; distH = height in levels
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
        ldx SCR+V_BCOL
        beq NoEdge
        bit SCR+V_OPT           ; P1 difficulty (bit 7): A = no edge gaps
        bmi NoEdge
        jmp ColDone             ; edge: leave this column empty
NoEdge  lda distH
        beq ColDone
        ldx SCR+V_BCOL
        lda COLMASK,x
        sta mb
        lda side
        beq Solid
        bit SCR+V_OPT           ; P0 difficulty (bit 6): A = solid side walls
        bvs Solid
        ; striped side wall: light odd levels only
        lda distH
        sec
        sbc #1
        and #$FE
        clc
        adc COLARR,x
        tay
        lda distH
        clc
        adc #1
        lsr
        tax
FillS   lda (rptrL),y
        ora mb
        sta (wptrL),y
        dey
        dey
        dex
        bne FillS
        jmp ColDone
Solid   lda COLARR,x
        clc
        adc distH
        tay
        dey
        ldx distH
Fill    lda (rptrL),y
        ora mb
        sta (wptrL),y
        dey
        dex
        bne Fill
ColDone lda SCR+V_BCOL
        clc
        adc #1
        sta SCW+V_BCOL
        jmp WorkLoop

; ---------------------------------------------------------------------------
; 8x8 -> 16 multiply via quarter squares: A * mb -> prodH:prodL
; ---------------------------------------------------------------------------
Mul8    sta tmp
        clc
        adc mb
        tax
        bcs MulHi
        lda SQL0,x
        sta prodL
        lda SQH0,x
        sta prodH
        jmp MulDif
MulHi   lda SQL1,x
        sta prodL
        lda SQH1,x
        sta prodH
MulDif  lda tmp
        sec
        sbc mb
        bcs MulPos
        eor #$FF
        adc #1
MulPos  tax
        lda prodL
        sec
        sbc SQL0,x
        sta prodL
        lda prodH
        sbc SQH0,x
        sta prodH
        rts

; ---------------------------------------------------------------------------
        include "tables.inc"
TablesEnd

        org $1FE0
        rorg $FFE0
        lda $FFF9
        jmp Start
        org $1FFC
        rorg $FFFC
        .word $FFE0
        .word $FFE0
