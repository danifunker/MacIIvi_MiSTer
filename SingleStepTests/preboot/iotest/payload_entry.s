| payload_entry.s — IOTest payload entry shim.
|
| Loads the boot handoff (driver refnum + drive number) from $00050000
| (see boot_stub_scsi.s for why $50000 and not $41000), clears the
| screen, then calls bench_main() in C.
|
| Historically this file also painted "IOTEFT" + "DONE" placeholder
| banners via its own micro-font (vertical bars for 'I'/'N', 'F'-shape
| for 'S') so the operator could see the payload had reached C before
| bench_main initialized JsonlWriter. Those paints have been removed:
| bench_main now reliably reaches its own paint_string banner via the
| full 95-glyph font in display_1bpp.c, so the placeholder glyphs were
| pure visual clutter ("IICTEFT" and "DCIIE" on hardware). draw_string_n_d0
| and the placeholder font tables (banner:/done_str:) are gone too.

.ifndef ROW_BYTES
    ROW_BYTES = 80
.endif

    .text
    .global _payload_start
_payload_start:
    move.w  #0x2700, %sr
    move.l  #0x00100000, %sp              | 1 MB high — generous stack

    | --- Load handoff slot ($00050000: refnum word, drive word) ---
    move.w  0x00050000.l, %d0
    move.w  %d0, g_handoff_refnum
    move.w  0x00050002.l, %d0
    move.w  %d0, g_handoff_drive

    | --- Wipe screen ---
    move.l  0x0824.l, %a4
    move.l  %a4, %d0
    beq     .hang
    cmp.l   #0x00100000, %d0
    blo     .hang
    move.l  %a4, %a0
    move.l  #(128*1024/4)-1, %d0
1:  move.l  #0xFFFFFFFF, (%a0)+
    dbra    %d0, 1b

    | --- Install our 68k exception handlers (see exc_handlers.s) so
    | bus error / address error / illegal instruction / zero divide /
    | etc. during a trap call get caught and longjmp'd back to the
    | bench instead of crashing into a Sad Mac. Must happen AFTER the
    | screen wipe so a fault during install would at least leave a
    | clean white screen for any subsequent Sad Mac to draw over. ---
    jsr     install_exc_vectors

    jsr     bench_main

.hang:
1:  bra.s   1b

| --------------------------------------------------------------------
| Globals exported to C (signed words to match Mac OS conventions).
| --------------------------------------------------------------------
    .data
    .align 2
    .global g_handoff_refnum
    .global g_handoff_drive
g_handoff_refnum:   .word 0
g_handoff_drive:    .word 0

| paint_progress / draw_glyph_d0 / hex_font used to live here. bench_main
| no longer calls paint_progress -- each test paints its own result line
| via paint_string + the full 95-glyph font in display_1bpp.c, which makes
| the hex counter redundant. Removed along with the helpers and the
| 128-byte hex_font table.
