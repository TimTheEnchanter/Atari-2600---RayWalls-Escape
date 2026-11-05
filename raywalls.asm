; ---------------------------------------------------------------------------
; RayWalls - maze escape on an upright-wall raycaster for the Atari 2600
; Cartridge: 8K F8 + Superchip (F8SC, 128 bytes extra RAM)
;
; Game: 6 levels; find the shimmering exit block before the timer runs out.
; Status bar under the view: level pips, timer bar, compass marker (sprite).
;
; Bank 0: display kernels, main loop, game logic, buffer swap, movement.
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
NUSIZ0  = $04
COLUP0  = $06
RESP0   = $10
AUDC0   = $15
AUDF0   = $17
AUDV0   = $19
GRP0    = $1B
HMP0    = $20
HMOVE   = $2A
SWCHA   = $280
SWCHB   = $282
INTIM   = $284
TIM64T  = $296

NLEV    = 16
BARCOL  = $C8           ; status bar (timer, pips)
LOWCOL  = $46           ; timer bar when almost out of time
MARKCOL = $1E           ; compass marker
MARK    = %00111100     ; compass marker shape
SND_BUMP  = 1*32+6
SND_TICK  = 2*32+3
SND_CHIME = 3*32+31
SND_BUZZ  = 4*32+31
SND_WIN   = 5*32+31
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
V_LEVEL = $78           ; current level 0..NLEVELS-1
V_GAME  = $79           ; 0 playing, 1 level done, 2 time out, 3 victory
V_TIMEL = $7A           ; playing: 4-frame ticks left in this timer segment
                        ; other states: countdown in frames
V_TIMEH = $7B           ; timer segments left (TSEGS..0)
V_SND   = $7C           ; sound: type*32 + frames left
V_OMASK = $7D           ; compose: inverted mask of columns dark on odd levels
V_CEIL  = $7E           ; ceiling colour this frame
V_MARK  = $7F           ; compass sprite shape this frame (0 = blinking off)

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
frame   = $F9           ; frame counter
exitc   = $FA           ; exit cell (y*16+x)
lvb     = $FB           ; level * 32 = offset of the level's packed map
; aliases: never live at the same time
prodL   = distL         ; ray setup / movement  vs  column finish
prodH   = distH
colr    = tmp           ; kernel  vs  work chunks

; timer thresholds (units of 64 cycles).  A reading of N guarantees only about
; (N-1)*64 cycles, so each threshold is (worst case / 64) + 2.
VBTIME  = 62
SBTIME  = 12            ; status bar (work keeps running during it)
OSTIME  = 41
STARTT  = 8             ; ray setup + first check (worst ~395 cycles)
FINT    = 7             ; one DDA step + finish column + next check (~325)
COMPT   = 4             ; two compose levels + next check (~150)
SWAPT   = 9             ; buffer swap + joystick + movement + exit check (~440)

; ===========================================================================
; Bank 0: display, main loop, movement
; ===========================================================================
        org $0000
        rorg $F000
        ds 256, 0               ; Superchip RAM window

; ---- page $F100: kernel tables + kernel A (must not cross pages) ----------
LINES_COLT_START
        include "bank0.inc"     ; LINES, COLT first (page start), then game tables
        align 256

; ---------------------------------------------------------------------------
; Kernel A: display buffer in Superchip RAM
; ---------------------------------------------------------------------------
KernelA
        lda SCR+V_CEIL
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
        lda colr                ; 3   = COLT[0] = floor colour; horizon line
        sta COLUBK              ; 6   (COLUPF already holds level 1's colour)
        lda SCR+P0L             ; 10
        sta PF0                 ; 13
        lda SCR+P1L             ; 17
        sta PF1                 ; 20
        lda SCR+P2L             ; 24
        sta PF2                 ; 27
        lda SCR+P0R             ; 31
        sta PF0                 ; 34
        lda SCR+P1R             ; 38
        sta PF1                 ; 41
        lda SCR+P2R             ; 45
        nop                     ; 47
        nop                     ; 49
        sta PF2                 ; 52
        ldy #1                  ; 54
        lda COLT,y              ; 58
        sta colr                ; 61
        ldx LINES,y             ; 65
        dex                     ; 67
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
        lda SCR+V_CEIL
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
        lda colr
        sta COLUBK
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
        nop
        nop
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
        sta SCW+V_BACKL         ; back buffer = B ($0080), wptrH = 0
        lda SWCHB
        sta SCW+V_OPT
        lda #0
        jsr LoadLevel

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
        jsr GameFrame
        jsr PosMarker
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

; ---------------------------------------------------------------------------
; After the view: status bar, then overscan.  The bar is a static reflected
; playfield plus the compass sprite, so ray casting keeps running under it.
; ---------------------------------------------------------------------------
KernelEnd
        sta WSYNC
        lda #0
        sta PF0
        sta PF1
        sta PF2
        sta COLUBK              ; black behind the status bar
        lda #SBTIME
        sta TIM64T
        lda #1
        sta CTRLPF              ; reflected playfield
        ldx SCR+V_TIMEH
        lda #BARCOL
        cpx #4
        bcs SBCol
        lda #LOWCOL
SBCol   sta COLUPF
        lda #MARKCOL
        sta COLUP0
        lda #5
        sta NUSIZ0              ; double-width marker
        ldy BAR2,x              ; Y = PF2 (timer)
        lda BAR1,x
        ldx SCR+V_LEVEL
        ora PIP1,x              ; A = PF1 (timer + pips 5-6)
        sta WSYNC               ; one blank gap line
        sta WSYNC
        sta PF1                 ; 3
        sty PF2                 ; 6
        lda PIP0,x              ; 10
        sta PF0                 ; 13
        lda SCR+V_MARK          ; 17
        sta GRP0                ; 20
        jsr CallWork
        lda SCR+V_READY
        beq SBWait
        lda INTIM
        cmp #SWAPT
        bcc SBWait
        jsr Swap
        jsr CallWork
SBWait  lda INTIM
        bne SBWait
        sta WSYNC
        lda #0
        sta PF0
        sta PF1
        sta PF2
        sta GRP0
        sta CTRLPF
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
; LoadLevel: A = level.  Sets position, exit, timer, and restarts the builder.
; ---------------------------------------------------------------------------
LoadLevel
        sta SCW+V_LEVEL
        tax
        asl
        asl
        asl
        asl
        asl
        sta lvb
        lda LV_X,x
        sta posXH
        lda LV_Y,x
        sta posYH
        lda #$80
        sta posXL
        sta posYL
        lda LV_A,x
        sta ang
        lda LV_EXIT,x
        sta exitc
        lda LV_T,x
        sta SCW+V_TIMEL
        lda CEILT,x
        sta SCW+V_CEIL
        lda #TSEGS
        sta SCW+V_TIMEH
        lda #0
        sta SCW+V_GAME
        sta SCW+V_STATE
        sta SCW+V_BCOL
        sta SCW+V_READY
        sta cur
        ldx #15
LLClr   sta SCW+D0,x
        dex
        bpl LLClr
        lda #$FF
        sta smask
        sta SCW+V_OMASK
        sta SCW+V_SIG
        rts

; ---------------------------------------------------------------------------
; GameFrame: once per frame - reset switch, sound, timer, game state, ceiling
; ---------------------------------------------------------------------------
GameFrame
        inc frame
        lda SWCHB
        lsr                     ; bit 0 = reset (0 = pressed)
        bcs GFNoRes
        lda #0
        jmp LoadLevel
GFNoRes
        ; ---- sound: type*32 + frames left ----
        lda SCR+V_SND
        and #$1F
        beq SndOff
        sec
        sbc #1
        sta tmp
        lda SCR+V_SND
        and #$E0
        ora tmp
        sta SCW+V_SND
        lsr
        lsr
        lsr
        lsr
        lsr
        tax
        lda SNDC,x
        sta AUDC0
        lda tmp
        and SNDS,x
        clc
        adc SNDF,x
        sta AUDF0
        lda SNDV,x
        sta AUDV0
        jmp GFState
SndOff  sta SCW+V_SND           ; A = 0
        sta AUDV0
        ; ---- game state ----
GFState lda SCR+V_GAME
        bne GFTrans
        lda frame               ; playing: timer ticks every 4th frame
        and #3
        bne GFCeil
        ldx SCR+V_TIMEL
        dex
        stx SCW+V_TIMEL
        bne GFCeil
        ldx SCR+V_LEVEL
        lda LV_T,x
        sta SCW+V_TIMEL
        ldx SCR+V_TIMEH
        dex
        stx SCW+V_TIMEH
        beq GFTimeUp
        cpx #4
        bcs GFCeil
        lda #SND_TICK           ; last segments: tick
        sta SCW+V_SND
        jmp GFCeil
GFTimeUp
        lda #2
        sta SCW+V_GAME
        lda #120
        sta SCW+V_TIMEL
        lda #SND_BUZZ
        sta SCW+V_SND
        jmp GFCeil
GFTrans ldx SCR+V_TIMEL         ; transitions: count down every frame
        dex
        stx SCW+V_TIMEL
        bne GFCeil
        cmp #1
        beq GFNext
        cmp #2
        beq GFRetry
        lda #0                  ; victory over: back to level 1
        jmp LoadLevel
GFRetry lda SCR+V_LEVEL         ; time out: try the level again
        jmp LoadLevel
GFNext  ldx SCR+V_LEVEL
        inx
        cpx #NLEVELS
        bcs GFWin
        txa
        jmp LoadLevel
GFWin   lda #3
        sta SCW+V_GAME
        lda #180
        sta SCW+V_TIMEL
        lda #SND_WIN
        sta SCW+V_SND
        ; ---- ceiling colour ----
GFCeil  lda SCR+V_GAME
        cmp #3
        beq GFRain
        asl
        asl
        asl
        ora SCR+V_LEVEL
        tax
        lda CEILT,x
        ldy SCR+V_GAME
        beq GFSetC
        sta tmp                 ; level done / time out: flash
        lda frame
        and #8
        beq GFNoFl
        lda #0
        jmp GFSetC
GFNoFl  lda tmp
        jmp GFSetC
GFRain  lda frame               ; victory: cycle through the hues
        asl
        and #$F0
        ora #$06
GFSetC  sta SCW+V_CEIL
        rts

; ---------------------------------------------------------------------------
; PosMarker: bearing to the exit -> compass sprite position (uses 2 lines)
; ---------------------------------------------------------------------------
PosMarker
        lda exitc               ; dx = exit - player, in half cells
        and #15
        asl
        ora #1
        sta mb
        lda posXL
        asl
        lda posXH
        rol
        eor #$FF
        sec
        adc mb
        sta prodL
        lda exitc
        lsr
        lsr
        lsr
        lsr
        asl
        ora #1
        sta mb
        lda posYL
        asl
        lda posYH
        rol
        eor #$FF
        sec
        adc mb
        sta prodH
        lda prodL               ; |dx|, |dy|
        bpl PMAx
        eor #$FF
        clc
        adc #1
PMAx    sta tmp
        lda prodH
        bpl PMAy
        eor #$FF
        clc
        adc #1
PMAy    sta mb
        ora tmp
        cmp #16
        bcc PMSm
        lsr tmp                 ; keep both < 16 (angle unchanged)
        lsr mb
PMSm    lda mb
        asl
        asl
        asl
        asl
        ora tmp
        tax
        lda ATN16,x             ; 0..64, first quadrant
        bit prodL
        bpl PMQx
        eor #$FF                ; dx < 0: 128 - a
        sec
        adc #128
PMQx    bit prodH
        bpl PMQy
        eor #$FF                ; dy < 0: -a
        clc
        adc #1
PMQy    sec
        sbc ang                 ; relative bearing (signed)
        clc
        adc #64                 ; 0..128 = within +-90 degrees
        ldy #MARK
        cmp #129
        bcc PMPos
        cmp #192                ; behind: pin to an edge and blink
        lda #128
        bcc PMEdge
        lda #0
PMEdge  sta tmp
        lda frame
        and #16
        beq PMVis
        ldy #0
PMVis   lda tmp
PMPos   sty SCW+V_MARK
        clc
        adc #8                  ; x = 8..136, marker centred at 80 + bearing
        sta WSYNC
        sec
PMDiv   sbc #15
        bcs PMDiv
        eor #7
        asl
        asl
        asl
        asl
        sta HMP0
        sta RESP0
        sta WSYNC
        sta HMOVE
        rts

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
        lda SCR+V_GAME          ; only steer while playing
        beq SwIn
        rts
SwIn    lda posXL               ; remember position for the bump sound
        sta stepX               ; (ray state is free: no ray in progress)
        lda posYL
        sta stepY
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
NoDown  lda SWCHA               ; bump: tried to move but went nowhere
        and #$30
        cmp #$30
        beq SwDone
        lda posXL
        cmp stepX
        bne SwDone
        lda posYL
        cmp stepY
        bne SwDone
        lda SCR+V_GAME
        bne SwDone
        lda SCR+V_SND
        bne SwDone
        lda #SND_BUMP
        sta SCW+V_SND
SwDone  rts

; reached the exit block
ReachExit
        lda SCR+V_GAME
        bne REDone
        lda #1
        sta SCW+V_GAME
        lda #90
        sta SCW+V_TIMEL
        lda #SND_CHIME
        sta SCW+V_SND
REDone  rts

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
        sta tmp                 ; probe cell
        lsr
        lsr
        lsr
        ora lvb
        tay
        lda tmp
        and #7
        tax
        lda MAPS0,y
        and BITS0,x
        beq TXFree
        lda tmp
        cmp exitc
        bne TXDone
        jmp ReachExit
TXFree  lda prodL
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
        sta tmp                 ; probe cell
        lsr
        lsr
        lsr
        ora lvb
        tay
        lda tmp
        and #7
        tax
        lda MAPS0,y
        and BITS0,x
        beq TYFree
        lda tmp
        cmp exitc
        bne TYDone
        jmp ReachExit
TYFree  lda prodL
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
        lsr                     ; packed map: byte = level*32 + cell/8
        lsr
        lsr
        ora lvb
        tay
        lda cell
        and #7
        tax
        lda MAPS1,y
        and BITS1,x
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
        lsr                     ; packed map: byte = level*32 + cell/8
        lsr
        lsr
        ora lvb
        tay
        lda cell
        and #7
        tax
        lda MAPS1,y
        and BITS1,x
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
NoDrop  lda cell
        cmp exitc
        bne NoExit
        lda mb                  ; exit: alternate dark odd / dark even levels
        eor #$FF                ; on every other view -> shimmer
        ldx SCR+V_FRONT
        beq ExOdd
        and smask
        sta smask
        jmp ColEnd
ExOdd   and SCR+V_OMASK
        sta SCW+V_OMASK
        jmp ColEnd
NoExit  lda side
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
CGo     lda SCR+D0,y            ; odd level
        eor #$FF
        and cur
        sta cur
        and SCR+V_OMASK
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
        sta SCW+V_OMASK
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
