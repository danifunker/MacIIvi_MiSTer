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
#include <Files.h>
#include "../gen/cpu_tests.h"

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

/* Set by invoke_program before JSR. Used in two places:
 *   (1) invoke_program's post-JSR `movel g_saved_sp, sp` -- restores SP
 *       so the C epilogue's `moveml (sp)+` pops the right callee-saved
 *       regs even if the test left SP slightly off.
 *   (2) For tests whose final instruction unbalances SP enough that the
 *       test's OWN trailing RTS would pop garbage (e.g. test 452
 *       "BSR.W / RTD #4" leaves SP +4), build_program emits a per-test
 *       epilogue that reloads SP from this variable before the RTS.
 *       That epilogue is opt-in by test name to keep the harness
 *       byte-identical for the other 717/718 tests. Forward declared so
 *       build_program can take its address. */
static unsigned long g_saved_sp;

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

    /* Architectural PC values: address of first byte of the test
     * (init_pc, what PC reads as the test instruction begins to
     * execute) and address of first byte of the final dump (final_pc,
     * what PC reads when the test instruction has committed). */
    init_pc = (u32) p;

    /* 4) Test instruction(s) */
    memcpy(p, t->test, t->test_len);
    p += t->test_len;

    final_pc = (u32) p;

    p = emit_state_dump(p, &final_snap, 0);

    /* Per-test SP-fixup epilogue. Most tests reach this point with SP
     * exactly where they entered, so the trailing RTS pops the JSR
     * return address fine -- no epilogue needed. A handful intentionally
     * leave SP unbalanced (test 452 "BSR.W / RTD #4" lands +4); for
     * those we reload SP from g_saved_sp (= pre-JSR SP), then SUBQ.L #4
     * to land on the JSR return address. Matched by name so the byte
     * sequence is unchanged for the other 717/718 tests. */
    if (strstr(t->name, "RTD #") != NULL &&
        strstr(t->name, "RTD #0") == NULL) {
        p = put_w(p, 0x2E79);           /* MOVE.L (abs.L), A7 */
        p = put_l(p, (u32) &g_saved_sp);
        p = put_w(p, 0x598F);           /* SUBQ.L #4, A7 */
    }

    *p++ = 0x4E; *p++ = 0x75;     /* RTS */
    return entry;
}

/* _HwPriv selector 1 = FlushInstructionCache. System 6.0.4+. */
static void flush_icache(void)
{
    asm volatile (
        "moveq #1, %%d0          \n"
        ".short 0xA198           \n"   /* _HwPriv */
        :
        :
        : "d0", "cc"
    );
}

/* Save callee-saved regs, jsr into the assembled test, restore.
 *
 * Stashes post-moveml SP into g_saved_sp and forcibly restores it after
 * the JSR returns. This covers tests that left SP slightly off but
 * whose own RTS still managed to find a return address. Tests whose
 * trailing RTS itself would crash on a mangled SP (test 452) are
 * handled separately in build_program's per-test epilogue, which uses
 * the same g_saved_sp to reload SP BEFORE their RTS. */
static void invoke_program(u8 *entry)
{
    asm volatile (
        "moveml %%d2-%%d7/%%a2-%%a6, -(%%sp)   \n"
        "movel  %%sp, %0                       \n"
        "movel  %1, %%a0                       \n"
        "jsr    (%%a0)                         \n"
        "movel  %0, %%sp                       \n"
        "moveml (%%sp)+, %%d2-%%d7/%%a2-%%a6   \n"
        : "+m" (g_saved_sp)
        : "g" (entry)
        : "a0", "a1", "d0", "d1", "cc", "memory"
    );
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

#ifndef CPU_OUTPUT_DIR
#define CPU_OUTPUT_DIR "CPU Results"
#endif

/* Idempotent mkdir via the HFS File Manager. Retro68's POSIX mkdir is a
 * no-op stub, so we go straight to PBDirCreateSync. `path` is a partial
 * pathname relative to the app's working directory; nested paths use
 * ":" separators per HFS convention. Errors (including dupFNErr when
 * the folder already exists) are ignored. */
static void mac_mkdir(const char *path)
{
    HParamBlockRec pb;
    Str255 pname;
    size_t n = strlen(path);
    if (n > 255) return;
    pname[0] = (unsigned char)n;
    memcpy(&pname[1], path, n);
    memset(&pb, 0, sizeof(pb));
    pb.fileParam.ioNamePtr = pname;
    pb.fileParam.ioVRefNum = 0;
    pb.fileParam.ioDirID = 0;
    PBDirCreateSync(&pb);
}

/* Compose the per-test output path and ensure its bucket folder exists.
 * Bucket scheme: tests 1..99 -> "1-99", 100..199 -> "100-199", ..., one
 * folder per 100 tests. Bucket folder is created the first time we
 * land in it. */
static void test_output_path(char *buf, int i)
{
    static int last_bucket_lo = -2;
    int test_num = i + 1;
    int lo;
    char dir[80];

    if (test_num <= 99) lo = 1;
    else lo = (test_num / 100) * 100;

    /* Leading ':' makes the partial pathname relative to the working
     * directory; without it HFS treats the first component as a
     * volume name (per IM:Files partial-pathname rules). */
    if (lo == 1) sprintf(dir, ":%s:1-99", CPU_OUTPUT_DIR);
    else         sprintf(dir, ":%s:%d-%d", CPU_OUTPUT_DIR, lo, lo + 99);
    sprintf(buf, "%s:%04d.jsonl", dir, test_num);

    if (lo != last_bucket_lo) {
        mac_mkdir(CPU_OUTPUT_DIR);
        mac_mkdir(dir);
        last_bucket_lo = lo;
    }
}

int main(void)
{
    FILE *f;
    int i;
    char path[128];

    /* Xterm-style OSC sequence sets the Retro68 console window title. */
    printf("\033]0;CPU Bench lbmactwo_MiSTer\007");

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

            /* Per-test line so a freeze reveals exactly which test wedged
             * the machine. Clear the screen every 50 tests to keep the
             * console buffer bounded (per-test printf historically grew
             * unbounded and crashed the Toolbox around test 240). The
             * clear happens BEFORE the new line so the screen is never
             * left blank — the user always sees the current test header. */
            if (i > 0 && (i % 50) == 0)
                printf("\033[H\033[2J");
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

        /* One file per test. Each fopen/fclose creates a new catalog
         * entry, which HFS commits more eagerly than data-block appends,
         * so prior results survive a later crash. */
        test_output_path(path, i);
        f = fopen(path, "w");
        if (f == NULL) {
            printf("Cannot open \"%s\" at test %d.\n", path, i);
            return 1;
        }
        fputc('{', f);
        fprintf(f, "\"name\":"); write_json_name(f, t->name);
        fprintf(f, ",\"initial\":"); write_snap_obj(f, &init_snap,  init_pc);
        fprintf(f, ",\"final\":");   write_snap_obj(f, &final_snap, final_pc);
        fputs("}\n", f);
        fclose(f);
    }
    printf("Done. %u tests written under \"%s\".\n", CPU_N_TESTS, CPU_OUTPUT_DIR);
    return 0;
}
