/* bench_main.c — supervisor-mode CPU bench.
 * Mirrors gen/cpu_test_macii.c but writes via raw sector _Write
 * instead of stdio. Runs privileged tests now (we're already supervisor).
 * hw_unsafe tests still skipped (they'd hang the machine). */

#include "bench_types.h"
#include "eject.h"
#include "freestanding.h"
#include "jsonl_writer.h"
#include "../../gen/cpu_tests.h"
/* (FPU corpus variants were removed in the IIvi port -- the target
 * machine has no FPU. The PMMU corpus header is gen/pmmu_tests.h,
 * consumed by the planned pmmu_bench_main.c.) */

/* Provided by payload_entry_cpu.s — handoff slot at $00041000 */
extern volatile i16 g_handoff_refnum;
extern volatile i16 g_handoff_drive;
extern u32  g_results_offset;     /* compile-time constant, set per variant */
extern u32  g_results_max_bytes;  /* compile-time constant */

/* recovery.s — VBR + longjmp-style exception escape. */
extern void install_vbr(void);
extern int invoke_test_with_recovery(u8 *entry);   /* 0 = OK, !=0 = vector */

/* Scratch buffers */
static Snapshot init_snap;
static Snapshot final_snap;
static u32 init_pc;
static u32 final_pc;
static u8  scratch_ram[CPU_SCRATCH_LEN];
static u8  prog_buffer[1024];

/* ---- Machine-code emitters (identical to cpu_test_macii.c) ---- */
static u8 *put_w(u8 *p, u16 v) { *p++=(u8)(v>>8); *p++=(u8)v; return p; }
static u8 *put_l(u8 *p, u32 v) {
    *p++=(u8)(v>>24); *p++=(u8)(v>>16);
    *p++=(u8)(v>>8);  *p++=(u8) v;       return p;
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

static u8 *emit_state_dump(u8 *p, Snapshot *snap, int is_init)
{
    u32 base = (u32) snap;
    u32 scratch_base = (u32) &scratch_ram[0];
    int n, i;
    if (!is_init) { p = put_w(p, 0x42F9); p = put_l(p, base + 0x40); }
    for (n = 0; n < 8; n++) p = emit_move_l_an_to_abs(p, n, base + 0x20 + n * 4);
    for (n = 0; n < 8; n++) p = emit_move_l_dn_to_abs(p, n, base + 0x00 + n * 4);
    for (i = 0; i < CPU_SCRATCH_LEN / 4; i++) {
        p = put_w(p, 0x23F9);
        p = put_l(p, scratch_base + i * 4);
        p = put_l(p, base + 0x44 + i * 4);
    }
    if (is_init) { p = put_w(p, 0x42F9); p = put_l(p, base + 0x40); }
    return p;
}

static u8 *build_program(const CpuTestSpec *t)
{
    u8 *entry = prog_buffer;
    u8 *p = entry;
    int n;

    for (n = 0; n < 8; n++) p = put_w(p, (u16)(0x7000 | (n << 9)));     /* MOVEQ #0,Dn */
    for (n = 0; n < 6; n++) p = put_w(p, (u16)(0x91C8 | (n << 9) | n)); /* SUBA.L An,An */

    /* Set SFC and DFC to 5 (supervisor data space) so MOVES tests
     * don't bus-error from the default DFC=0 "undefined function
     * code". MOVEC D0,SFC = $4E7B 0000; MOVEC D0,DFC = $4E7B 0001.
     * Need D0 = 5 first. */
    p = put_w(p, 0x7005);             /* MOVEQ #5,D0 */
    p = put_w(p, 0x4E7B); p = put_w(p, 0x0000);   /* MOVEC D0,SFC */
    p = put_w(p, 0x4E7B); p = put_w(p, 0x0001);   /* MOVEC D0,DFC */
    p = put_w(p, 0x7000);             /* MOVEQ #0,D0 (restore) */

    p = emit_movea_l_imm_to_an(p, 6, (u32) &scratch_ram[0]);
    p = emit_move_w_imm_to_ccr(p, 0);

    if (t->preload_len) { f_memcpy(p, t->preload, t->preload_len); p += t->preload_len; }
    p = emit_state_dump(p, &init_snap, 1);
    init_pc = (u32) p;
    f_memcpy(p, t->test, t->test_len);
    p += t->test_len;
    final_pc = (u32) p;
    p = emit_state_dump(p, &final_snap, 0);

    *p++ = 0x4E; *p++ = 0x75;     /* RTS */
    return entry;
}

/* 68030 instruction-cache flush. Writing CACR with bit 3 = CI
 * invalidates the entire IC; bit 0 = EI keeps it enabled. We MUST do
 * this between tests because we keep rewriting prog_buffer and the
 * CPU may execute stale cached bytes from the previous test. */
static void flush_icache(void)
{
    asm volatile (
        "moveq #9, %%d0          \n"   /* CI | EI = 0x09 */
        ".long 0x4E7B0002        \n"   /* movec d0, cacr */
        :
        :
        : "d0"
    );
}

/* Save callee-saved regs, jsr into the assembled test, restore.
 * Re-mask interrupts IMMEDIATELY on return so tests that clear the I
 * field of SR (e.g. ANDI.W #$F8FF,SR at test 180) can't trigger an
 * IRQ before our code restores SR. */
static void invoke_program(u8 *entry)
{
    asm volatile (
        "moveml %%d2-%%d7/%%a2-%%a6, -(%%sp)   \n"
        "movel  %0, %%a0                       \n"
        "jsr    (%%a0)                         \n"
        "movew  #0x2700, %%sr                  \n"
        "moveml (%%sp)+, %%d2-%%d7/%%a2-%%a6   \n"
        :
        : "g" (entry)
        : "a0", "a1", "d0", "d1", "cc", "memory"
    );
}

/* Emit one snapshot as the same JSON shape MAME emits. */
static void write_snap(JsonlWriter *w, const Snapshot *s, u32 pc)
{
    int i;
    jw_puts(w, "{\"d\":[");
    for (i = 0; i < 8; i++) { if (i) jw_putc(w, ','); jw_putul(w, s->d[i]); }
    jw_puts(w, "],\"a\":[");
    for (i = 0; i < 8; i++) { if (i) jw_putc(w, ','); jw_putul(w, s->a[i]); }
    jw_puts(w, "],\"ccr\":"); jw_putul(w, s->ccr);
    jw_puts(w, ",\"pc\":");   jw_putul(w, pc);
    jw_puts(w, ",\"ram\":[");
    for (i = 0; i < CPU_SCRATCH_LEN; i++) {
        if (i) jw_putc(w, ',');
        jw_putul(w, s->ram[i]);
    }
    jw_puts(w, "]}");
}

static void write_name(JsonlWriter *w, const char *name)
{
    jw_putc(w, '"');
    while (*name) {
        if (*name == '"' || *name == '\\') jw_putc(w, '\\');
        jw_putc(w, *name);
        name++;
    }
    jw_putc(w, '"');
}

/* Painted progress: tiny 4-digit decimal at row 56 col 4 of ScrnBase
 * so the operator sees the bench is alive. ~10 LOC of hand-rolled
 * digit drawing kept in the C side so the main asm stays small. */
extern void paint_progress(u32 idx, u32 total);

/* Provided by font_ascii.c */
extern void paint_string(u32 row, u32 col_byte, const char *s, u32 max_chars);

/* Mac low-mem Ticks counter at $016A — 60 Hz, 32-bit. Available
 * after Boot Globals init, which the ROM does before bbEntry. */
#define TICKS_ADDR 0x0000016A
static u32 read_ticks(void) {
    return *(volatile u32 *)TICKS_ADDR;
}

/* Format an unsigned decimal into a 10-char zero-padded buffer for
 * status display. Buffer must be at least 11 bytes. */
static void format_decimal(char *out, u32 v, int width) {
    char tmp[11];
    int n = 0, i;
    if (v == 0) tmp[n++] = '0';
    while (v) { tmp[n++] = (char)('0' + (v % 10)); v /= 10; }
    for (i = 0; i < width - n; i++) *out++ = ' ';
    while (n--) *out++ = tmp[n];
    *out = '\0';
}

/* Keep 'w' static so the 16 KB sector buffer lives in .bss, not on
 * the stack. Recovery code longjmps without unwinding C stack frames;
 * if 'w' were a local we'd lose the 16 KB allocation reservation in
 * a way the compiler doesn't know about, and any further jw_putc
 * would scribble on the new (smaller) stack. */
static JwCtx g_jw_ctx;
static JsonlWriter g_jw;

/* Busy-loop delay. Mac II at 16 MHz, the inner add takes ~2 cycles,
 * so 8M iterations = ~1 second. Crude but interrupt-free. */
static void busy_delay(u32 seconds)
{
    volatile u32 i;
    while (seconds--) {
        for (i = 0; i < 4000000; i++) { asm volatile ("nop"); }
    }
}

/* Render an 8-digit hex string into buf (caller provides 9+ bytes). */
static void format_hex32(char *out, u32 v) {
    const char *digits = "0123456789ABCDEF";
    int i;
    for (i = 7; i >= 0; i--) {
        out[i] = digits[v & 0xF];
        v >>= 4;
    }
    out[8] = '\0';
}

/* One-test bench. Runs the test whose index is hardcoded below
 * (start with the simplest privileged case: MOVES.L D0,(A1)) and
 * paints the resulting CPU state on screen.
 *
 * NOTHING is written to disk — you take a phone photo of the screen
 * and we read the registers from there. Sidesteps every SCSI write
 * issue we've been chasing.
 */
/* Range of tests to run, 0-based, INCLUSIVE both ends. The full
 * corpus is [0 .. CPU_N_TESTS-1]: a single consolidated run covering
 * the normal supervisor tests AND the exception tests, all through the
 * same recovery handler. Narrow the range only for targeted debugging. */
#define FIRST_TEST_INDEX 0
#define LAST_TEST_INDEX  (CPU_N_TESTS - 1)

/* Skip filter applied inside the loop. Set to 1 to run ONLY tests
 * flagged raises_exception; 0 to run every test in [FIRST, LAST].
 * Consolidated run = 0 (run everything). */
#define ONLY_RAISES_EXCEPTION 0

/* Stride-aware screen wipe lives in display_1bpp.c now. */
extern void display_wipe(u32 rows);
static void wipe_screen(void) { display_wipe(480); }

void bench_main(void)
{
    u8 *entry;
    char buf[16];
    int idx;
    u32 n_run = 0, n_ok = 0, n_trap = 0;
    JsonlWriter *w = &g_jw;
    JwCtx wctx;

    install_vbr();

    wctx.refnum      = g_handoff_refnum;
    wctx.drive       = g_handoff_drive;
    wctx.base_offset = g_results_offset;
    wctx.max_bytes   = g_results_max_bytes;
    jw_init(w, &wctx);

    /* Static header painted once; the loop updates fields in place. */
    wipe_screen();
    paint_string(4, 4, "SUPERVISOR CPU BENCH - full corpus", 40);
    paint_string(16, 4, "Test ", 5);
    paint_string(16, 14, ": ", 2);

    for (idx = FIRST_TEST_INDEX; idx <= LAST_TEST_INDEX; idx++) {
        const CpuTestSpec *t = &g_cpu_tests[idx];
        u32 crashed_vec = 0;

        /* hw_unsafe tests can't be run on the Mac bench safely even in
         * supervisor mode (e.g. the raw $A000 Line A trap, which our
         * recovery can't catch because vector 10 is reserved for the
         * _Write disk-output path). Always skip them. */
        if (t->hw_unsafe) continue;

#if ONLY_RAISES_EXCEPTION
        if (!t->raises_exception) continue;
#endif

        /* Live progress only — no per-test wipe / delay. A full-corpus
         * run is 700+ tests; the per-test 1s photo pauses (35+ min) and
         * full register dump are gone. Results all go to JSONL; the
         * screen just shows liveness + a running tally so a hang is
         * attributable to the test index on screen. */
        n_run++;
        format_decimal(buf, idx + 1, 4);
        paint_string(16, 9, buf, 4);
        paint_string(16, 16, t->name, 60);

        f_memset(&init_snap,  0, sizeof(init_snap));
        f_memset(&final_snap, 0, sizeof(final_snap));
        f_memset(scratch_ram, 0, sizeof(scratch_ram));
        if (t->ram_init_present)
            f_memcpy(scratch_ram, t->ram_init, CPU_SCRATCH_LEN);

        entry = build_program(t);
        flush_icache();
        crashed_vec = (u32)invoke_test_with_recovery(entry);
        asm volatile ("move.w #0x2700, %%sr" : : : "memory");

        /* When a test traps, the final state dump didn't run — but the
         * init state dump (right BEFORE the test instruction) DID run,
         * so init_snap captures the state that produced the trap. */
        Snapshot *display_snap = crashed_vec ? &init_snap : &final_snap;
        u32       display_pc   = crashed_vec ? init_pc    : final_pc;

        if (crashed_vec) n_trap++; else n_ok++;

        /* Compact running tally (in place, no wipe). */
        paint_string(28, 4, "run=", 4);   format_decimal(buf, n_run, 4);  paint_string(28, 8,  buf, 4);
        paint_string(28, 14, "ok=", 3);   format_decimal(buf, n_ok, 4);   paint_string(28, 17, buf, 4);
        paint_string(28, 24, "trap=", 5); format_decimal(buf, n_trap, 4); paint_string(28, 29, buf, 4);
        format_hex32(buf, crashed_vec);
        paint_string(28, 36, "lastvec=", 8); paint_string(28, 44, buf + 6, 2);

        /* Append JSON line. For crashed tests we emit "trap_state"
         * (pre-trap snapshot) instead of "final" so the diff tool
         * can distinguish at parse time. */
        jw_putc(w, '{');
        jw_puts(w, "\"name\":"); write_name(w, t->name);
        jw_puts(w, ",\"vec\":"); jw_putul(w, crashed_vec);
        jw_puts(w, crashed_vec ? ",\"trap_state\":" : ",\"final\":");
        write_snap(w, display_snap, display_pc);
        jw_puts(w, "}\n");
    }

    /* All tests done — one final flush writes everything. */
    wipe_screen();
    paint_string(4, 4, "ALL TESTS DONE - writing results...", 40);
    jw_flush(w);

    format_hex32(buf, (u32)(u16)w->last_err);
    paint_string(28, 4, "ioResult=", 9);
    paint_string(28, 13, buf + 4, 4);
    paint_string(52, 4, "Power off and extract /Results.jsonl", 40);

    /* If we booted from a floppy (drive 1 = internal, 2 = external),
     * eject it so the operator doesn't have to manually unmount. On a
     * SCSI boot the drive number isn't a .Sony drive, so the eject call
     * is a harmless no-op (the driver rejects the unknown drive).
     * Show drive number + .Sony ioResult (0 = ejected). */
    if (g_handoff_drive == 1 || g_handoff_drive == 2) {
        i16 ej = eject_floppy(g_handoff_drive);
        paint_string(76, 4, "EJECT drv=", 10);
        format_decimal(buf, (u32)g_handoff_drive, 1);
        paint_string(76, 14, buf, 1);
        paint_string(76, 16, "res=", 4);
        format_hex32(buf, (u32)(u16)ej);
        paint_string(76, 20, buf + 4, 4);
    }

    for (;;) { asm volatile (""); }

#if 0
    /* === legacy single-test display below, kept for reference === */
    paint_string(4, 4, "SUPERVISOR ONE-TEST RUNNER", 30);

    paint_string(16, 4, "STEP 1 hello                   ", 40);
    busy_delay(0);

    format_decimal(buf, ONE_TEST_INDEX + 1, 4);
    paint_string(28, 4, "STEP 2 test ", 12);
    paint_string(28, 16, buf, 4);
    paint_string(28, 20, " = ", 3);
    paint_string(28, 23, t->name, 60);
    busy_delay(0);

    paint_string(40, 4, "STEP 3 zero snap + scratch     ", 40);
    f_memset(&init_snap,  0, sizeof(init_snap));
    f_memset(&final_snap, 0, sizeof(final_snap));
    f_memset(scratch_ram, 0, sizeof(scratch_ram));
    if (t->ram_init_present)
        f_memcpy(scratch_ram, t->ram_init, CPU_SCRATCH_LEN);
    busy_delay(0);

    paint_string(52, 4, "STEP 4 install_vbr             ", 40);
    install_vbr();
    busy_delay(0);

    paint_string(64, 4, "STEP 5 build_program           ", 40);
    entry = build_program(t);
    busy_delay(0);

    paint_string(76, 4, "STEP 6 flush_icache + invoke   ", 40);
    flush_icache();
    crashed_vec = (u32)invoke_test_with_recovery(entry);
    asm volatile ("move.w #0x2700, %%sr" : : : "memory");

    if (crashed_vec) {
        format_hex32(buf, crashed_vec);
        paint_string(88, 4, "STEP 7 *** EXCEPTION VECTOR ", 30);
        paint_string(88, 32, buf, 8);
    } else {
        paint_string(88, 4, "STEP 7 test returned cleanly   ", 40);
    }
    busy_delay(0);

    /* Register dumps. Each row gets 12 pixels. Hex values are 8
     * chars wide; we space them 10 char-cols (80 px) apart so
     * 4 values per row fit comfortably with gaps. */
    paint_string(112, 4, "D0..D3:", 8);
    for (int i = 0; i < 4; i++) {
        format_hex32(buf, final_snap.d[i]);
        paint_string(112, 14 + i*10, buf, 8);
    }
    paint_string(124, 4, "D4..D7:", 8);
    for (int i = 0; i < 4; i++) {
        format_hex32(buf, final_snap.d[4+i]);
        paint_string(124, 14 + i*10, buf, 8);
    }
    paint_string(136, 4, "A0..A3:", 8);
    for (int i = 0; i < 4; i++) {
        format_hex32(buf, final_snap.a[i]);
        paint_string(136, 14 + i*10, buf, 8);
    }
    paint_string(148, 4, "A4..A7:", 8);
    for (int i = 0; i < 4; i++) {
        format_hex32(buf, final_snap.a[4+i]);
        paint_string(148, 14 + i*10, buf, 8);
    }
    format_hex32(buf, final_snap.ccr);
    paint_string(160, 4, "CCR=", 4);
    paint_string(160, 8, buf + 6, 2);

    /* scratch_ram[0..15] dump — 16 bytes on one row. Each byte is
     * 2 hex chars + 1 space = 3 char cells = 24 px. 16 bytes = 384 px
     * wide. Fits in 640 with room to spare. */
    paint_string(180, 4, "scratch_ram[0..15]:", 20);
    for (int j = 0; j < 16; j++) {
        format_hex32(buf, scratch_ram[j]);
        paint_string(192, 4 + j*3, buf + 6, 2);
    }

    /* Write one JSON line containing the test result. Same shape as
     * the corpus-format we use for diffing against MAME — just one
     * line for now. */
    paint_string(220, 4, "Writing /Results.jsonl...      ", 40);
    {
        JsonlWriter *w = &g_jw;
        JwCtx wctx;
        wctx.refnum      = g_handoff_refnum;
        wctx.drive       = g_handoff_drive;
        wctx.base_offset = g_results_offset;
        wctx.max_bytes   = g_results_max_bytes;
        jw_init(w, &wctx);
        jw_putc(w, '{');
        jw_puts(w, "\"name\":"); write_name(w, t->name);
        jw_puts(w, ",\"vec\":"); jw_putul(w, crashed_vec);
        jw_puts(w, ",\"final\":"); write_snap(w, &final_snap, final_pc);
        jw_puts(w, "}\n");
        jw_flush(w);

        format_hex32(buf, (u32)(u16)w->last_err);
        paint_string(220, 4, "Write done. ioResult=    ", 25);
        paint_string(220, 29, buf + 4, 4);
    }

    paint_string(232, 4, "DONE - photo the screen.", 30);
    for (;;) { asm volatile (""); }
#endif
}
