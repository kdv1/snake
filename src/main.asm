
.ifdef EMU
   .db "NES", $1a ;identification of the iNES header
   .db 1 ;number of 16KB PRG-ROM pages
   .db 1 ;number of 8KB CHR-ROM pages
   .db $00 ;mapper 0 and vertical mirroring
   .dsb 9, $00 ;clear the remaining bytes
.endif

.include "nes.h"

TV_MODE equ 60
.enum $0000
	TMP_1:
	TMP_ADDR_LO:
	RLE_LOW:	db 0
	
	TMP_2:
	TMP_ADDR_HI:
	RLE_HIGH:	db 0
	RLE_TAG:	db 0
	
	TMP_3:
	TMP_BYTE:
	RLE_BYTE	db 0
	
	TMP_4:		db 0
	
	DIR_LEFT equ 1
	DIR_RIGHT equ 2
	DIR_UP equ 3
	DIR_DOWN equ 4
	
	speed db 0
	head_dir db 0
	head_x db 0
	head_y db 0
	
	; for collision detection
	BBOX_SIDE equ 5
	head_r db 0
	head_d db 0
	collided db 0
	
	frame db 0
	tail_len db 0
	
	HEAD_INC_X equ %00100000
	HEAD_DEC_X equ %00010000
	HEAD_INC_Y equ %00000010
	HEAD_DEC_Y equ %00000001
	head_mov db 0		; %x:00id y:00id
	
	body_oam_start db 0
	body_oam_start2 db 0
	oam_write_cnt db 0
	
	pad1 db 0
	nmi_flag db 0
	RAND_SEED dw 0
	
	TARGET_TILE equ 5
	target_x: db 0
	target_y: db 0
	
	STATE_TITLE equ 1
	STATE_GAME equ 2
	STATE_ROUND equ 3
	game_state db 0
	round db 0
	
	oam_head_y: db 0
	oam_head_tile: db 0
	oam_head_attrs: db 0
	oam_head_x: db 0
.ende
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
HEAD_TILE equ $10
HEAD_TILE2 equ $11
HEAD_TILE_DOWN equ $12
HEAD_TILE_DOWN2 equ $13
BODY_TILE equ $14

.enum $0200
	oam:
.ende
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
.enum $0400
	path_x: db 0
.ende
.enum $0500
	path_y: db 0
.ende
.org $c000
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
Reset:
	sei
	cld

	; Acknowledge and disable interrupt sources during bootup
	ldx #0
	stx PPU_CTRL    ; disable vblank NMI
	stx PPU_MASK    ; disable rendering (and rendering-triggered mapper IRQ)
	lda #$40
	sta $4017      ; disable frame IRQ
	stx $4010      ; disable DPCM IRQ
	bit PPU_STATUS  ; ack vblank NMI
	bit $4015      ; ack DPCM IRQ

	dex            ; set up the stack
	txs

	; Wait for the PPU to warm up (part 1 of 2)
	bit PPU_STATUS
vwait1:
	bit PPU_STATUS
	bpl vwait1	


	; While waiting for the PPU to finish warming up, we have about
	; 29000 cycles to burn without touching the PPU.  So we have time
	; to initialize some of RAM to known values.
	; Ordinarily the "new game" initializes everything that the game
	; itself needs, so we'll just do zero page and shadow OAM.
	ldy #$00
	lda #$F0
	ldx #$00

clear_zp:
	sty $00,x
	sta #oam,x
	inx
	bne clear_zp

	; the most basic sound engine possible
	lda #$0F
	sta $4015

	; Wait for the PPU to warm up (part 2 of 2)
vwait2:
	bit PPU_STATUS
	bpl vwait2
	
	lda #$fd
	sta <RAND_SEED
	sta <RAND_SEED+1
game_over:
	lda #0
	sta collided
	jsr load_graphics
	jmp init_game
	
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	;initialize game parameters
init_game_params:
	lda #1
	sta speed
	
	lda #2
	sta tail_len
	lda #STATE_TITLE
	sta game_state

	; snake head ------------
	lda #128-8
	sta head_x
	sta oam_head_x
	lda #120-8
	sta head_y
	sta oam_head_y
	lda #DIR_RIGHT
	sta head_dir	
	lda #HEAD_TILE
	sta oam_head_tile
	lda #%00000011
	sta oam_head_attrs
		
	lda #1
	sta round

	rts	
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
init_game:
	jsr init_game_params
	jsr init_tail
	jsr init_state

mainLoop:
@wait
	lda nmi_flag
	beq @wait
	lda #0
	sta nmi_flag

@logic
	ldx frame
	inx
	cpx #TV_MODE
	beq @reset_fc
	stx frame
	jmp @next
@reset_fc
	lda #0
	sta frame
@next

	jsr read_pad1
	lda game_state
	cmp #STATE_TITLE
	bne +
	; title
	jsr update_title
	jmp ++
+
	cmp #STATE_GAME
	bne +
	; game
	jsr update_game
	jmp ++
+
	cmp #STATE_ROUND
	bne +
	; round screen
	jsr update_round
	;jmp ++
++
    jmp mainLoop
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
init_state:
	lda game_state
	cmp #STATE_TITLE
	bne +
	; title
	; title nametable
	lda #$28
	sta PPU_ADDR
	lda #$00
	sta PPU_ADDR
	lda #<title_nt
	ldx #>title_nt
	jsr _vram_unrle
	
	lda #4
	sta PPU_SCROLL
	lda #0
	sta PPU_SCROLL
	
	lda #BG_ON
	sta PPU_MASK
	lda #VBLANK_NMI|#NT_2800
	sta PPU_CTRL
	
	jmp ++
+
	cmp #STATE_GAME
	bne +
	; game
	; field nametable -------
	lda #$20
	sta PPU_ADDR
	lda #$00
	sta PPU_ADDR
	lda #<field
	ldx #>field
	jsr _vram_unrle
	
	jsr new_target
	lda #0
	sta PPU_SCROLL
	sta PPU_SCROLL
	lda #0
	lda #BG_ON | #OBJ_ON
	sta PPU_MASK
	lda #VBLANK_NMI
	sta PPU_CTRL
	jmp ++
+
	cmp #STATE_ROUND
	bne +
	; round screen
	lda #0
	sta PPU_CTRL
	sta PPU_MASK
	lda #$28
	ldx #0
	jsr fill_nametable
	
	lda #$29
	sta PPU_ADDR
	lda #$8c
	sta PPU_ADDR
	lda #<str_round
	ldx #>str_round
	jsr drawString
	lda round
	jsr drawNumber8
	lda #3
	sta TMP_1	; second counter
	
	lda #0
	sta PPU_SCROLL
	sta PPU_SCROLL	
	lda #BG_ON
	sta PPU_MASK
	lda #VBLANK_NMI|#NT_2800
	sta PPU_CTRL
	; jmp ++
+
++
	rts
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
new_target:
	jsr _rand8
	sta TMP_1

	lda #16
	cmp TMP_1
	bcc +
	sta target_x
	jmp ++
+
	lda #256-16-8
	cmp TMP_1
	bcs +++
	sta target_x
	jmp ++
+++
	lda TMP_1
	sta target_x
++
	jsr _rand8
	sta TMP_1

	lda #16
	cmp TMP_1
	bcc +
	sta target_y
	jmp +++
+
	lda #240-16-8
	cmp TMP_1
	bcs ++
	sta target_y
	jmp +
++
	lda TMP_1
	sta target_y
+
+++
	inc tail_len
	rts
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; draw numbers 00-32 using lookup table
drawNumber8:
	tax
	lda bcd, x
	pha
	lsr
	lsr
	lsr
	lsr
	ora #$40
	sta PPU_DATA	
	pla
	and #$0f
	ora #$40 ; digits
	sta PPU_DATA
	rts
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
drawString:
	tay
	stx <RLE_HIGH
	lda #0
	sta <RLE_LOW
-
	lda (RLE_LOW),y
	beq +
	sta PPU_DATA
	iny
	bne -
	inc <RLE_HIGH
	jmp -
+
	rts
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
fill_nametable:
	sta PPU_ADDR
	lda #0
	sta PPU_ADDR
	txa
	ldy #4
	ldx #0
-
	sta PPU_DATA
	dex
	bne -
	dey
	bne -	
	rts
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
update_title:
	lda pad1
	and #KEY_START
	beq +
	lda #0
	sta PPU_CTRL
	sta PPU_MASK
	lda #STATE_ROUND
	sta game_state
	jsr init_state
+
	rts
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
update_round:
	lda frame
	bne +
	dec TMP_1
	bne +
	lda #0
	sta PPU_CTRL
	sta PPU_MASK
	lda #STATE_GAME
	sta game_state
	jsr init_state
+
	rts
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
update_game:
	asl	pad1; A
	bcc @check_b
	;A key pressed
	
@check_b:
	asl	pad1 ;B
	bcc @check_select
	;B key pressed
	
@check_select:
	asl	pad1	;SELECT
	bcc @check_start
	;SELECT key pressed

@check_start:
	asl	pad1	;START
	bcc @check_up
	;START key pressed
	
@check_up:
	asl	pad1	;UP
	bcc @check_down
	;UP key pressed
	lda head_dir
	cmp #DIR_DOWN
	beq @check_down
	lda #DIR_UP
	sta head_dir

@check_down:
	asl	pad1	;DOWN
	bcc @check_left
	;DOWN key pressed
	lda head_dir
	cmp #DIR_UP
	beq @check_left
	lda #DIR_DOWN
	sta head_dir

@check_left:
	asl	pad1	;LEFT
	bcc @check_right
	;LEFT key pressed
	lda head_dir
	cmp #DIR_RIGHT
	beq @check_right
	lda #DIR_LEFT
	sta head_dir

@check_right:
	asl	pad1	;RIGHT
	bcc @finish
	;RIGHT key pressed
	lda head_dir
	cmp #DIR_LEFT
	beq @finish
	lda #DIR_RIGHT
	sta head_dir

	; process head direction change ------------------------------------
@finish:
	lda #0
	sta head_mov
	lda head_dir
	
	cmp #DIR_UP
	bne +
	lda #HEAD_TILE_DOWN
	sta oam_head_tile
	lda #%10000011
	sta oam_head_attrs
	lda head_mov
	ora #HEAD_DEC_Y
	sta head_mov
	jmp ++
+
	cmp #DIR_DOWN
	bne +
	lda #HEAD_TILE_DOWN
	sta oam_head_tile
	lda #%00000011
	sta oam_head_attrs
	lda head_mov
	ora #HEAD_INC_Y
	sta head_mov
	jmp ++
+
	cmp #DIR_LEFT
	bne +
	lda #HEAD_TILE
	sta oam_head_tile
	lda #%01000011
	sta oam_head_attrs
	lda head_mov
	ora #HEAD_DEC_X
	sta head_mov
	jmp ++
+
	cmp #DIR_RIGHT
	bne ++
	lda #HEAD_TILE
	sta oam_head_tile
	lda #%00000011
	sta oam_head_attrs
	lda head_mov
	ora #HEAD_INC_X
	sta head_mov
++
	
	; process collision of head with background ------------------------
	lda #16
	cmp head_x
	bcc +
	; left wall collide
	sta head_x
	lda #1
	sta collided
	jmp ++
+
	lda #256-16-8
	cmp head_x
	bcs ++
	; right wall collide
	sta head_x
	lda #1
	sta collided
++
	lda #16
	cmp head_y
	bcc +
	; up wall collide
	sta head_y
	lda #1
	sta collided
	jmp ++
+
	lda #240-16-8
	cmp head_y
	bcs ++
	; down wall collide
	sta head_y
	lda #1
	sta collided
++
	; sprite animation -------------------------------------------------
	lda frame
	and #%0001000
	beq +
	lda oam_head_tile
	ora #1
	sta oam_head_tile
+
	lda head_x
	sta oam_head_x
	lda head_y
	sta oam_head_y

	jsr multi_move_body
	jsr draw_body_flicker
	jsr target_collide

	lda collided
	beq +++
	lda #0
	sta PPU_MASK
	jmp game_over
+++
	rts
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
TARGET_BBOX_SIDE equ 8
target_collide:
	; check for collision with target sprite
	lda target_x
	cmp head_r
	bcs +

	clc
	adc #TARGET_BBOX_SIDE
	sta TMP_1
	lda head_x
	cmp TMP_1
	bcs +

	lda target_y
	cmp head_d
	bcs +
	
	clc
	adc #TARGET_BBOX_SIDE
	sta TMP_1
	lda head_y
	cmp TMP_1
	bcs +
	jsr new_target
+
	rts
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; create tail
init_tail:
	ldy #0
	ldx head_x
	
	lda tail_len
	asl
	asl
	asl ; * 8
	sta TMP_3
	lda #8
	sta TMP_1
-
	dex
	txa
	sta path_x, y
	lda head_y
	sta path_y, y
	iny
	dec TMP_1
	bne -
	lda #8
	sta TMP_1

	cpy TMP_3
	bne -
	rts
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
multi_move_body:
	lda speed
-
	pha
	lda head_mov
	lsr
	bcc +
	dec head_y
	jmp ++
+
	lsr
	bcc +
	inc head_y
	jmp ++
+
	lsr
	lsr
	lsr
	bcc +
	dec head_x
	jmp ++
+
	lsr
	bcc ++
	inc head_x
++
	jsr move_body
	pla
	tax
	dex
	txa
	bne -
	rts
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
move_body:				; 6 (jsr)
	lda head_x			; 3
	sta path_x			; 3
	lda head_y			; 3
	sta path_y			; 3

	ldx tail_len		; 3
	txa					; 2
	asl					; 2
	asl					; 2
	asl	; * 8			; 2
	tax					; 2
	dex					; 2
	
-
	lda #path_x-1, x	; 4+   |
	sta #path_x, x		; 5    |
	lda #path_y-1, x	; 4+   |
	sta #path_y, x		; 5    |
						;      | * 256 = 8192
	dex					; 2    |
	bne -				; 2&3+ |
	rts					; 6
						; total: 8231
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
draw_body_flicker:
	; clear oam 0..32
	lda #$f0
	ldx #0
-
	sta #oam, x
	inx
	cpx #129
	bne -
	
	; head bounding box
	lda head_x
	clc
	adc #BBOX_SIDE
	sta head_r
	lda head_y
	clc
	adc #BBOX_SIDE
	sta head_d

	ldx tail_len
	dex
	txa
	sta TMP_1
	ldx #11	; tail x,y start coords
	
	lda #%11	; head sprite flag & used to skip first sprite of tail
	sta TMP_3
-
	lda body_oam_start
	asl
	asl
	asl
	asl
	asl ; * 32, 8 tiles x 4 bytes
	tay
	
	; write head sprite once
	lda TMP_3
	and #1
	beq +++
	dec TMP_3
	
	; head sprite
	lda oam_head_y
	sta #oam, y
	iny
	lda oam_head_tile
	sta #oam, y
	iny
	lda oam_head_attrs
	sta #oam, y
	iny
	lda oam_head_x
	sta #oam, y
	iny
	
	; target sprite
	lda frame
	and #%10000
	beq ++++++
	lda #7
	sta TMP_2
	jmp ---
++++++
	lda target_y
	sta #oam, y
	iny
	lda #TARGET_TILE
	sta #oam, y
	iny
	lda #0
	sta #oam, y
	iny
	lda target_x
	sta #oam, y
	iny

	lda #6
	sta TMP_2
	jmp ---
+++
	lda #8
	sta TMP_2
---
--
	lda collided
	bne ++++
	; skip first tail sprite
	lda TMP_3
	beq +++++
	lda #0
	sta TMP_3
	jmp ++++

+++++
	; check for collision with head sprite
	lda #path_x, x
	cmp head_r
	bcs ++++
	
	;lda #path_x, x
	clc
	adc #BBOX_SIDE
	sta TMP_4
	lda head_x
	cmp TMP_4
	bcs ++++

	lda #path_y, x
	cmp head_d
	bcs ++++
	
	;lda #path_y, x
	clc
	adc #BBOX_SIDE
	sta TMP_4
	lda head_y
	cmp TMP_4
	bcs ++++

	lda #1
	sta collided

++++
	; setup sprite
	lda #path_y, x
	sta #oam, y
	iny
	lda #BODY_TILE
	sta #oam, y
	iny
	lda #%00000011
	sta #oam, y
	iny
	lda #path_x, x
	sta #oam, y
	iny
	
	txa
	clc
	adc #8
	tax
	
	;inx
	;inx
	;inx
	;inx	
	;inx
	;inx
	;inx
	;inx
	
	dec TMP_1
	beq +
	dec TMP_2
	bne --

	txa
	pha
	ldx body_oam_start
	inx
	txa
	and #%11
	sta body_oam_start
	pla
	tax
	jmp -
+

	lda oam_write_cnt
	bne +++
	lda body_oam_start
	sta body_oam_start2
	jmp ++
+++
	cmp #1
	beq ++

	lda body_oam_start
	cmp body_oam_start2
	bne ++
	tax
	inx		; shuffle oam
	txa
	and #3
	sta body_oam_start
++
	ldx oam_write_cnt
	inx
	txa
	cmp #3
	bne +
	lda #0
+
	sta oam_write_cnt
	rts
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
load_graphics:
	bit PPU_STATUS
    ; palette ---------------
    lda #$3F
    sta PPU_ADDR
    lda #$00
    sta PPU_ADDR
    
    ldx #0
-
	lda palette, x
	sta PPU_DATA
	inx
	cpx #16
	bne -
	ldx #0
--
	lda palette, x
	sta PPU_DATA
	inx
	cpx #16
	bne --
rts  
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; from shiru's nes lib
_vram_unrle:
	tay
	stx <RLE_HIGH
	lda #0
	sta <RLE_LOW

	lda (RLE_LOW),y
	sta <RLE_TAG
	iny
	bne @1
	inc <RLE_HIGH

@1:

	lda (RLE_LOW),y
	iny
	bne @11
	inc <RLE_HIGH

@11:

	cmp <RLE_TAG
	beq @2
	sta PPU_DATA
	sta <RLE_BYTE
	bne @1

@2:

	lda (RLE_LOW),y
	beq @4
	iny
	bne @21
	inc <RLE_HIGH

@21:

	tax
	lda <RLE_BYTE

@3:

	sta PPU_DATA
	dex
	bne @3
	beq @1

@4:
	rts
	
;Galois random generator, found somewhere
;out: A random number 0..255
rand1:

	lda <RAND_SEED
	asl a
	bcc @1
	eor #$cf

@1:

	sta <RAND_SEED
	rts

rand2:

	lda <RAND_SEED+1
	asl a
	bcc @1
	eor #$d7

@1:

	sta <RAND_SEED+1
	rts

_rand8:

	jsr rand1
	jsr rand2
	adc <RAND_SEED
	rts

_set_rand:
	sta <RAND_SEED
	stx <RAND_SEED+1
	rts
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
read_pad1:
	lda #1
	sta P1
	lsr
	sta P1
	
	lda #0
	sta pad1
	ldx #8
-
	lda P1
	lsr
	rol pad1
	dex
	bne -
	
	rts
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
NMI:
	pha
	lda game_state
	cmp #STATE_TITLE
	bne +
	; title
	lda #$3f
	sta PPU_ADDR
	lda #$06
	sta PPU_ADDR
	
	lda frame
	and #%10000
	bne ++
	lda #$0f
	sta PPU_DATA
	jmp +++
++
	lda #$10
	sta PPU_DATA
+++
	lda #BG_ON
	sta PPU_MASK
	lda #VBLANK_NMI|#NT_2800
	sta PPU_CTRL
	
	lda #4
	sta PPU_SCROLL
	lda #0
	sta PPU_SCROLL
	jmp ++++
+
	;-------------------
	cmp #STATE_GAME
	bne +
	; game
	; stabilize scroll
	lda #0
	sta $2005
	sta $2005
	
	lda #>oam
	sta $4014
	jmp ++++
+
	cmp #STATE_ROUND
	bne +
	lda #0
	sta PPU_SCROLL
	sta PPU_SCROLL
	jmp ++++
+
++++
	pla
	inc nmi_flag
	rti
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
IRQ:
   rti

palette:
	.db $0f,$00,$10,$30,$0f,$0c,$1c,$13,$0f,$07,$15,$26,$0f,$09,$19,$29

field:
	.incbin "../assets/field.rle"
	
title_nt:
	.incbin "../assets/title.rle"

str_round:
	.db $31, $2e, $34, $2d, $23, $3d, $00

bcd:
	.db 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, $10, $11, $12, $13, $14, $15
	;.db $16, $17, $18, $19, $20, $21, $22, $23, $24, $25, $26, $27
	;.db $28, $29, $30, $31, $32 ; space, space...

;----------------------------------------------------------------
; interrupt vectors
;----------------------------------------------------------------

.ifdef EMU
   .org $fffa
.else
; $07ff - max address for 2kb ram chip
   .org $C7FA
.endif

   .dw NMI
   .dw Reset
   .dw IRQ
   
.ifdef EMU
;----------------------------------------------------------------
; CHR-ROM bank
;----------------------------------------------------------------

   .incbin "../assets/tiles.chr"
.endif
