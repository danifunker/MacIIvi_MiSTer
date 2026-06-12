/*
 * cpu_test_macii.c -- CPU instruction bench for real Mac II hardware.
 *
 * Companion to gen/mame_cpu_capture.lua: that script produces both
 *   /tmp/cpu_corpus.json   -- MAME oracle results (JSON Lines)
 *   /tmp/cpu_tests.h       -- C header with the same test specs
 *
 * Builds with THINK C 5+ / Symantec C++; runs on any 68030 Mac (Macintosh LC II included).
 *
 * Output: "CPU Results.jsonl" in the app's working directory, in the
 * same JSONL schema MAME emits, so the two files diff line-by-line via
 * cpu_diff_corpus.py.
 *
 * Cross-platform invariant
 * ------------------------
 * The test instruction bytes come straight from cpu_tests.h and are
 * identical to those run under MAME. Memory-touching tests use
 * (A6)/d16(A6) addressing; the harness preloads A6 with this bench's
 * scratch RAM base (&scratch_ram[0]) before each test, so the same bytes
 * run safely on both sides regardless of where scratch RAM actually lives.
 *
 * Tests flagged `privileged` (currently just MOVES) are skipped on Mac
 * since this app runs in user mode. They still ship in the oracle so
 * a supervisor-mode variant can run them later.
 */

#include <stdio.h>
#include <string.h>
#include "cpu_tests.h"

typedef unsigned char  u8;
typedef unsigned short u16;
typedef unsigned long  u32;

typedef struct {
    u32 d[8];                       /* offset 0x00 */
    u32 a[8];                       /* offset 0x20 */
    u8  ccr_high;                   /* offset 0x40 -- always 0x00 (zero-ext) */
    u8  ccr;                        /* offset 0x41 -- the CCR byte */
    u8  pad[2];                     /* offset 0x42..0x43 */
    u8  ram[CPU_SCRATCH_LEN];       /* offset 0x44 */
} Snapshot;

static Snapshot init_snap;
static Snapshot final_snap;

/* Architectural PC at init/final dump time. Computed in build_program()
 * by recording the byte offsets in prog_buffer where execution arrives
 * at the test (init_pc) and at the final dump (final_pc). These are
 * absolute Mac-side addresses, NOT comparable directly to MAME's pc
 * field (different RAM layout), but the DELTA (final.pc - initial.pc)
 * is invariant across platforms and equals test_len. cpu_diff_corpus.py
 * should compare deltas.
 *
 * SR and USP are intentionally omitted: MOVE SR / MOVE USP are 020+
 * privileged and would trap from a user-mode app. MAME and verilator
 * (both run in supervisor mode) remain the SR/USP oracles. */
static u32 init_pc;
static u32 final_pc;

/* Fixed RAM slot used by the test program to preserve A7 across the
 * test instruction. The bench dispatches every test via `jsr (a0) /
 * rts`, so the C return address still has to be poppable off the C
 * stack when the test is done -- which means A7 must point at the
 * C-side stack frame again before the RTS at the end of build_program.
 *
 * Tests that overwrite A7 (EXG A0,A7 and the like -- #639 in this
 * corpus) used to crash the system: A7 became whatever the test left
 * there (typically 0 after the reset-preamble's `SUBA.L A0,A0`), then
 * the dump's MOVE.L Dn,abs.l ran fine (no stack use) but the final
 * RTS popped PC from address 0 -> bus error -> hard crash.
 *
 * The bracket is a 6-byte `MOVE.L A7, saved_a7` planted right before
 * the test instruction and a 6-byte `MOVEA.L saved_a7, A7` planted
 * right after, inside the init_pc / final_pc window so those PC
 * markers still point at the test bytes themselves. The final snap's
 * A7 will reflect the restored value, not whatever the test left in
 * A7 -- but the diff already excludes A7 from comparison anyway
 * (cpu_diff_corpus.py: COMPARE_AREGS = A0..A5), so this is invisible
 * to the diff tool. */
static u32 saved_a7;

/* Scratch RAM region used as the target of all memory-touching tests.
 * Address provided to the test program via A6 (set in the harness preamble). */
static u8 scratch_ram[CPU_SCRATCH_LEN];

/* Single 1KB buffer; flushed before each invocation. */
static u8 prog_buffer[1024];

/* -------------------------------------------------------------------- *
 * Machine-code emitters. Mirror those in mame_cpu_capture.lua so the
 * Mac-side dump lands at the same Snapshot offsets MAME's read_snap()
 * reads back.                                                          *
 * -------------------------------------------------------------------- */
static u8 *put_w(u8 *p, u16 v) { *p++ = (u8)(v >> 8); *p++ = (u8)v; return p; }
static u8 *put_l(u8 *p, u32 v) {
    *p++ = (u8)(v >> 24); *p++ = (u8)(v >> 16);
    *p++ = (u8)(v >>  8); *p++ = (u8) v;        return p;
}

static u8 *emit_move_l_dn_to_abs(u8 *p, int dn, u32 addr) {
    p = put_w(p, (u16)(0x23C0 | (dn & 7))); return put_l(p, addr);
}
static u8 *emit_move_l_an_to_abs(u8 *p, int an, u32 addr) {
    p = put_w(p, (u16)(0x23C8 | (an & 7))); return put_l(p, addr);
}
static u8 *emit_movea_l_imm_to_an(u8 *p, int an, u32 imm) {
    p = put_w(p, (u16)(0x207C | ((an & 7) << 9))); return put_l(p, imm);
}
static u8 *emit_move_w_imm_to_ccr(u8 *p, u16 imm) {
    p = put_w(p, 0x44FC); return put_w(p, (u16)(imm & 0xFF));
}

/* State dump epilogue -- mirrors lua emit_state_dump byte-for-byte.
 *
 * Two invariants:
 *   1. Must not clobber any general-purpose register (init dump runs
 *      before the test; clobbered residue would corrupt test inputs).
 *   2. CCR is captured at the moment that matches its semantic role:
 *        - INIT dump  (is_init=1): CCR LAST  -- the value the test will
 *                                              actually inherit, after
 *                                              the dump's MOVE.L pollution.
 *        - FINAL dump (is_init=0): CCR FIRST -- the test's clean output
 *                                              CCR, before this dump's
 *                                              MOVE.L pollution.
 *      This makes the corpus self-consistent for tests that don't update
 *      CCR (NOP, LEA, MOVEM, PACK, UNPK): final.ccr will equal initial.ccr
 *      instead of being the dump residue (0x04).
 */
static u8 *emit_state_dump(u8 *p, Snapshot *snap, int is_init)
{
    u32 base = (u32) snap;
    u32 scratch_base = (u32) &scratch_ram[0];
    int n, i;
    if (!is_init) { p = put_w(p, 0x42F9); p = put_l(p, base + 0x40); }
    for (n = 0; n < 8; n++)
        p = emit_move_l_an_to_abs(p, n, base + 0x20 + n * 4);
    for (n = 0; n < 8; n++)
        p = emit_move_l_dn_to_abs(p, n, base + 0x00 + n * 4);
    for (i = 0; i < CPU_SCRATCH_LEN / 4; i++) {
        p = put_w(p, 0x23F9);
        p = put_l(p, scratch_base + i * 4);
        p = put_l(p, base + 0x44 + i * 4);
    }
    if (is_init) { p = put_w(p, 0x42F9); p = put_l(p, base + 0x40); }
    return p;
}

/* Build one test program. Returns the entry point (start of prog_buffer). */
static u8 *build_program(const CpuTestSpec *t)
{
    u8 *entry = prog_buffer;
    u8 *p = entry;
    int n;

    /* 1) Reset D0..D7 and A0..A5. MAME's harness clears these externally
     * via Lua rset(); without this matching step on the Mac side, every
     * test inherits D0/D1/A0/A1 residue from the C caller (memset loop
     * counter, heap pointers, printf return value, etc.) and diff_corpus
     * flags every single test as "unknown" even when the actual test
     * result is identical to MAME. A6 is set in step 2; A7 is the C
     * stack and must be preserved. */
    for (n = 0; n < 8; n++)
        p = put_w(p, (u16)(0x7000 | (n << 9)));     /* MOVEQ #0,Dn */
    for (n = 0; n < 6; n++)
        p = put_w(p, (u16)(0x91C8 | (n << 9) | n)); /* SUBA.L An,An */

    /* 2) A6 = &scratch_ram[0] (harness preamble; tests reference A6) */
    p = emit_movea_l_imm_to_an(p, 6, (u32) &scratch_ram[0]);

    /* 3) Zero CCR */
    p = emit_move_w_imm_to_ccr(p, 0);

    /* 3) Per-test preload */
    if (t->preload_len) {
        memcpy(p, t->preload, t->preload_len);
        p += t->preload_len;
    }

    p = emit_state_dump(p, &init_snap, 1);

    /* Bracket the test instruction with A7 save/restore so a test that
     * overwrites A7 (e.g. EXG A0,A7) doesn't crash the final RTS. See
     * the saved_a7 comment above for the why. */
    p = put_w(p, 0x23CF);                  /* MOVE.L A7, abs.l */
    p = put_l(p, (u32) &saved_a7);

    /* Architectural PC values: address of first byte of the test
     * (init_pc, what PC reads as the test instruction begins to
     * execute) and address of first byte of the final dump (final_pc,
     * what PC reads when the test instruction has committed). */
    init_pc = (u32) p;

    /* 4) Test instruction(s) */
    memcpy(p, t->test, t->test_len);
    p += t->test_len;

    final_pc = (u32) p;

    p = put_w(p, 0x2E79);                  /* MOVEA.L abs.l, A7 */
    p = put_l(p, (u32) &saved_a7);

    p = emit_state_dump(p, &final_snap, 0);

    *p++ = 0x4E; *p++ = 0x75;     /* RTS */
    return entry;
}

/* _HwPriv selector 1 = FlushInstructionCache. System 6.0.4+. */
static void flush_icache(void)
{
    asm {
        moveq   #1, d0
        dc.w    0xA198          /* _HwPriv */
    }
}

/* Save callee-saved regs, jsr into the assembled test, restore.
 * A6 is callee-saved on C; we clobber it during the test but the test's
 * own A6 dump captures pre-dump value (= scratch base). The compiler's
 * A6 frame pointer is preserved across the asm block by movem.l. */
static void invoke_program(u8 *entry)
{
    asm {
        movem.l d2-d7/a2-a6, -(sp)
        move.l  entry, a0
        jsr     (a0)
        movem.l (sp)+, d2-d7/a2-a6
    }
}

/* -------------------------------------------------------------------- *
 * Output: JSON Lines, schema matches /tmp/cpu_corpus.json:
 *   {"name":..., "initial":{d[],a[],ccr,ram[]}, "final":{...}}
 * -------------------------------------------------------------------- */
static void write_snap_obj(FILE *f, Snapshot *s, u32 pc)
{
    int i;
    fprintf(f, "{\"d\":[");
    for (i = 0; i < 8; i++) fprintf(f, "%s%lu", i ? "," : "", s->d[i]);
    fprintf(f, "],\"a\":[");
    for (i = 0; i < 8; i++) fprintf(f, "%s%lu", i ? "," : "", s->a[i]);
    fprintf(f, "],\"ccr\":%u,\"pc\":%lu,\"ram\":[",
            (unsigned)s->ccr, (unsigned long)pc);
    for (i = 0; i < CPU_SCRATCH_LEN; i++)
        fprintf(f, "%s%u", i ? "," : "", (unsigned)s->ram[i]);
    fprintf(f, "]}");
}

static void write_json_name(FILE *f, const char *name)
{
    const char *p = name;
    fputc('"', f);
    while (*p) {
        if (*p == '"' || *p == '\\') fputc('\\', f);
        fputc(*p, f);
        p++;
    }
    fputc('"', f);
}

int main(void)
{
    FILE *f;
    int i;

#ifndef CPU_OUTPUT_PATH
#define CPU_OUTPUT_PATH "CPU Results.jsonl"
#endif

    f = fopen(CPU_OUTPUT_PATH, "w");
    if (f == NULL) { printf("Cannot open output file.\n"); return 1; }

    printf("Running %u CPU tests on real hardware...\n", CPU_N_TESTS);

    for (i = 0; i < CPU_N_TESTS; i++) {
        const CpuTestSpec *t = &g_cpu_tests[i];
        u8 *entry;

        memset(&init_snap,  0, sizeof(init_snap));
        memset(&final_snap, 0, sizeof(final_snap));
        memset(scratch_ram, 0, sizeof(scratch_ram));
        init_pc = 0;
        final_pc = 0;
        if (t->ram_init_present)
            memcpy(scratch_ram, t->ram_init, CPU_SCRATCH_LEN);

        {
            const char *skip_reason = NULL;
            if (t->privileged)        skip_reason = "  [SKIPPED: privileged]";
            else if (t->raises_exception) skip_reason = "  [SKIPPED: raises exception]";
            else if (t->hw_unsafe)    skip_reason = "  [SKIPPED: hw-unsafe]";
            printf("[%d/%u] %s%s\n", i + 1, CPU_N_TESTS, t->name,
                   skip_reason ? skip_reason : "");

            if (!skip_reason) {
                entry = build_program(t);
                flush_icache();
                invoke_program(entry);
            }
            /* Skipped tests: init_snap and final_snap stay zeroed.
             * The diff tool categorizes them as "skipped". */
        }

        fputc('{', f);
        fprintf(f, "\"name\":"); write_json_name(f, t->name);
        fprintf(f, ",\"initial\":"); write_snap_obj(f, &init_snap,  init_pc);
        fprintf(f, ",\"final\":");   write_snap_obj(f, &final_snap, final_pc);
        fputs("}\n", f);
        fflush(f);
    }
    fclose(f);
    printf("Done. %u tests written to \"%s\".\n", CPU_N_TESTS, CPU_OUTPUT_PATH);
    return 0;
}
