/* diskcopy_main.c — floppy duplicator preboot app.
 *
 * Boots from a floppy, reads an entire 800K source disk into RAM, then
 * writes it back out to a destination floppy. Two modes, chosen by
 * keypress at startup:
 *
 *   1 = single-drive (swap): one physical drive. Read source into RAM,
 *       eject, insert blank destination, write it out. Use this when
 *       source and destination go in the SAME drive.
 *
 *   2 = two-drive: source in the boot drive, blank destination in the
 *       other floppy drive. No swapping during the copy. Use this to
 *       clone a FloppyEmu image onto a physical floppy (boot from the
 *       FloppyEmu, blank disk in the internal drive).
 *
 * The drive we booted from is ALWAYS the source. In two-drive mode the
 * destination is the other floppy drive (1<->2). The whole 800K image
 * fits comfortably in RAM, so we never need both disks mounted at once.
 *
 * All disk access is raw sector _Read/_Write via the .Sony driver
 * (refnum -5), drive selected by ioVRefNum. No File Manager / mounting
 * involved, so this works at boot-block time before System loads. */

#include "bench_types.h"
#include "eject.h"

extern void paint_string(u32 row, u32 col_byte, const char *s, u32 max_chars);

/* Boot handoff (refnum + drive), loaded by payload_entry.s. */
extern i16 g_handoff_refnum;
extern i16 g_handoff_drive;

/* 68k exception recovery (exc_handlers.s) — a faulting trap longjmps
 * back with the vector number instead of crashing to a Sad Mac. */
typedef u32 JmpBuf[12];
extern u32  iotest_setjmp(JmpBuf *buf);
extern void iotest_longjmp(JmpBuf *buf, u32 val) __attribute__((noreturn));
extern JmpBuf g_exc_jmpbuf;
extern u16    g_last_exc_vector;

#define LINE(n) ((n) * 12u)

/* ---- Geometry --------------------------------------------------- */
#define SECTOR_BYTES 512u
#define DISK_BYTES   819200u            /* 800K Mac floppy = 1600 sectors */
#define CHUNK_BYTES  32768u             /* per-transfer chunk for progress */
#define IOBUF_BASE   0x00200000u        /* 2 MB — clear of code + stack */

#define SONY_REFNUM ((i16)-5)

/* ---- KeyMap polling --------------------------------------------- */
#define KEYMAP_BASE 0x00000174u
#define KEY_DOWN(kc) (*(volatile u8 *)(KEYMAP_BASE + ((kc) >> 3)) & (u8)(1u << ((kc) & 7)))
#define KC_1      0x12
#define KC_2      0x13
#define KC_RETURN 0x24
#define KC_ESC    0x35

/* Block until `kc` is seen down, then until it's released (so one
 * physical keypress yields exactly one event). */
static void wait_key(u8 kc)
{
    while (!KEY_DOWN(kc)) { asm volatile (""); }
    while ( KEY_DOWN(kc)) { asm volatile (""); }
}

/* ---- IOParam block (Inside Macintosh: Files offsets) ------------ */
typedef struct {
    u8  pad_qlink[12];
    u32 io_completion;     /* 12 */
    u16 io_result;         /* 16 */
    u32 io_name_ptr;       /* 18 */
    u16 io_vrefnum;        /* 22 — drive number for .Sony */
    u16 io_refnum;         /* 24 — driver refnum (-5 = .Sony) */
    u8  io_versnum;        /* 26 */
    u8  io_permssn;        /* 27 */
    u32 io_misc;           /* 28 */
    u32 io_buffer;         /* 32 */
    u32 io_req_count;      /* 36 */
    u32 io_act_count;      /* 40 */
    u16 io_pos_mode;       /* 44 */
    u32 io_pos_offset;     /* 46 */
    u8  pad_rest[30];
} ParamBlock;

static ParamBlock g_pb;

static i16 trap_read(ParamBlock *pb)
{
    register i16  r asm("d0");
    register ParamBlock *p asm("a0") = pb;
    asm volatile (".word 0xA002\n" : "=d"(r) : "a"(p)
                  : "d1", "d2", "a1", "cc", "memory");
    return r;
}
static i16 trap_write(ParamBlock *pb)
{
    register i16  r asm("d0");
    register ParamBlock *p asm("a0") = pb;
    asm volatile (".word 0xA003\n" : "=d"(r) : "a"(p)
                  : "d1", "d2", "a1", "cc", "memory");
    return r;
}
static i16 trap_control(ParamBlock *pb)
{
    register i16  r asm("d0");
    register ParamBlock *p asm("a0") = pb;
    asm volatile (".word 0xA004\n" : "=d"(r) : "a"(p)
                  : "d1", "d2", "a1", "cc", "memory");
    return r;
}

/* Synthetic error code base: a caught CPU exception during a trap
 * surfaces as 30000+vector so callers can tell it from a real ioResult. */
#define EXC_ERR_BASE 30000

/* Low-level format the disk in `drive` via the .Sony driver (csCode 6).
 * This lays down the physical track/sector structure so a subsequent
 * raw _Write succeeds even on an unformatted / foreign disk. The drive
 * is selected by ioVRefNum (offset 22); ioCRefNum (24) = -5 (.Sony);
 * csCode (26) = 6. Wrapped in exception recovery. Returns ioResult, or
 * 30000+vector if a CPU exception fired. */
static i16 sony_format(i16 drive)
{
    u32 v = iotest_setjmp(&g_exc_jmpbuf);
    if (v != 0) return (i16)(EXC_ERR_BASE + v);
    g_last_exc_vector = 0;

    ParamBlock pb;
    u32 *w = (u32 *)&pb; u32 n = sizeof(pb) / 4;
    while (n--) *w++ = 0;
    pb.io_vrefnum = drive;             /* offset 22 — drive to format */
    pb.io_refnum  = SONY_REFNUM;       /* offset 24 — .Sony */
    /* csCode (offset 26) = 6 (format). io_versnum/io_permssn occupy
     * offsets 26/27, so set csCode through them. */
    pb.io_versnum = 0;
    pb.io_permssn = 6;
    return trap_control(&pb);
}

static void pb_init(ParamBlock *pb, i16 drive, u32 buf, u32 offset, u32 len)
{
    u32 *w = (u32 *)pb; u32 n = sizeof(*pb) / 4;
    while (n--) *w++ = 0;
    pb->io_refnum     = SONY_REFNUM;
    pb->io_vrefnum    = drive;
    pb->io_buffer     = buf;
    pb->io_req_count  = len;
    pb->io_pos_mode   = 1;              /* fsFromStart */
    pb->io_pos_offset = offset;
}

/* Wrap a transfer in the exception-recovery barrier. Returns the trap
 * ioResult, or 30000+vector if a CPU exception fired inside the trap. */
static i16 xfer(int is_write, i16 drive, u32 buf, u32 offset, u32 len)
{
    u32 v = iotest_setjmp(&g_exc_jmpbuf);
    if (v != 0) return (i16)(EXC_ERR_BASE + v);
    g_last_exc_vector = 0;
    pb_init(&g_pb, drive, buf, offset, len);
    return is_write ? trap_write(&g_pb) : trap_read(&g_pb);
}

/* ---- Small text/number helpers ---------------------------------- */
static void put_dec(char *out, u32 v, u32 width)
{
    u32 i;
    for (i = 0; i < width; i++) out[i] = ' ';
    char tmp[10]; int ti = 0;
    if (v == 0) tmp[ti++] = '0';
    while (v) { tmp[ti++] = '0' + (v % 10); v /= 10; }
    int pos = (int)width - ti;
    if (pos < 0) pos = 0;
    int k;
    for (k = 0; k < ti && pos + k < (int)width; k++)
        out[pos + k] = tmp[ti - 1 - k];
}

/* Paint "<label> res=±N" so each eject/transfer result is visible. */
static void paint_result(u32 row, const char *label, i16 res)
{
    char line[40];
    u32 m, p;
    for (m = 0; m < sizeof(line); m++) line[m] = ' ';
    for (p = 0; label[p] && p < 24; p++) line[p] = label[p];
    line[p++] = 'r'; line[p++] = 'e'; line[p++] = 's'; line[p++] = '=';
    i32 v = res;
    if (v < 0) { line[p++] = '-'; v = -v; }
    char num[6]; put_dec(num, (u32)v, 5);
    u32 j; int started = 0;
    for (j = 0; j < 5; j++) {
        if (num[j] != ' ') started = 1;
        if (started) line[p++] = num[j];
    }
    if (!started) line[p++] = '0';
    paint_string(row, 1, line, p);
}

/* Copy `len` bytes between RAM and `drive` in CHUNK_BYTES pieces,
 * repainting a "<phase>: NNN/1600 sectors" progress line. Returns the
 * first non-zero ioResult, or 0 on full success. */
static i16 transfer_all(int is_write, i16 drive, const char *phase, u32 prog_row)
{
    u32 off = 0;
    while (off < DISK_BYTES) {
        u32 chunk = DISK_BYTES - off;
        if (chunk > CHUNK_BYTES) chunk = CHUNK_BYTES;
        i16 r = xfer(is_write, drive, IOBUF_BASE + off, off, chunk);
        if (r != 0) return r;
        off += chunk;

        /* "<phase> NN% (NNNN/1600 sectors)" */
        char line[44]; u32 m;
        for (m = 0; m < sizeof(line); m++) line[m] = ' ';
        for (m = 0; phase[m] && m < 12; m++) line[m] = phase[m];
        u32 pos = 13;
        char pct[4]; put_dec(pct, (off * 100u) / DISK_BYTES, 3);
        for (u32 k = 0; k < 3; k++) if (pct[k] != ' ') line[pos++] = pct[k];
        line[pos++] = '%';
        line[pos++] = ' '; line[pos++] = '(';
        char num[5]; put_dec(num, off / SECTOR_BYTES, 4);
        for (u32 k = 0; k < 4; k++) line[pos++] = num[k];
        const char *suf = "/1600)";
        for (m = 0; suf[m]; m++) line[pos++] = suf[m];
        paint_string(prog_row, 1, line, pos);
    }
    return 0;
}

/* Read source / write dest with a retry loop: on error, show it and
 * wait for RETURN to retry (ESC aborts the whole copy). Returns 0 on
 * success, non-zero if the user aborted. */
static int transfer_with_retry(int is_write, i16 drive, const char *phase,
                               u32 prog_row, u32 msg_row)
{
    for (;;) {
        i16 r = transfer_all(is_write, drive, phase, prog_row);
        if (r == 0) return 0;
        paint_result(msg_row, is_write ? "WRITE failed " : "READ failed ", r);
        paint_string(msg_row + 12u, 1,
                     "RETURN=retry  ESC=abort                 ", 40);
        for (;;) {
            if (KEY_DOWN(KC_RETURN)) { wait_key(KC_RETURN); break; }
            if (KEY_DOWN(KC_ESC))    { wait_key(KC_ESC); return 1; }
        }
        paint_string(msg_row, 1,        "                                        ", 40);
        paint_string(msg_row + 12u, 1,  "                                        ", 40);
    }
}

void bench_main(void)
{
    i16 src = g_handoff_drive;

    paint_string(LINE(0), 1, "DISKCOPY: 800K floppy duplicator", 32);
    paint_string(LINE(2), 1, "Boot/source drive:", 18);
    {
        char d[2]; put_dec(d, (u32)src, 1);
        paint_string(LINE(2), 20, d, 1);
    }

    /* ---- Mode selection ---- */
    paint_string(LINE(4), 1, "Choose copy mode:", 17);
    paint_string(LINE(5), 1, "  1 = single-drive (swap source then dest)", 42);
    paint_string(LINE(6), 1, "  2 = two-drive (source=boot drive, dest=other)", 47);
    paint_string(LINE(7), 1, "Press 1 or 2 ...", 16);

    int two_drive;
    for (;;) {
        if (KEY_DOWN(KC_1)) { wait_key(KC_1); two_drive = 0; break; }
        if (KEY_DOWN(KC_2)) { wait_key(KC_2); two_drive = 1; break; }
    }

    i16 dst = two_drive ? (i16)((src == 1) ? 2 : 1) : src;

    /* Clear the menu area; paint the chosen mode. */
    for (u32 r = LINE(4); r <= LINE(7); r += 12u)
        paint_string(r, 1, "                                                  ", 50);
    paint_string(LINE(4), 1, two_drive ? "Mode: TWO-DRIVE" : "Mode: SINGLE-DRIVE (swap)", 25);
    {
        char d[2];
        paint_string(LINE(5), 1, "Source drive:", 13);
        put_dec(d, (u32)src, 1); paint_string(LINE(5), 15, d, 1);
        paint_string(LINE(5), 18, "Dest drive:", 11);
        put_dec(d, (u32)dst, 1); paint_string(LINE(5), 30, d, 1);
    }

    /* ---- Data-loss warning ---- */
    paint_string(LINE(7), 1, "*** WARNING ***", 15);
    {
        char wl[44]; u32 m;
        for (m = 0; m < sizeof(wl); m++) wl[m] = ' ';
        const char *p = "ALL DATA on DEST drive ";
        for (m = 0; p[m]; m++) wl[m] = p[m];
        char d[2]; put_dec(d, (u32)dst, 1); wl[m++] = d[0];
        const char *q = " will be ERASED";
        for (u32 k = 0; q[k]; k++) wl[m++] = q[k];
        paint_string(LINE(8), 1, wl, m);
    }
    paint_string(LINE(9), 1, "(destination is low-level formatted first)", 42);
    paint_string(LINE(10), 1, "RETURN=continue   ESC=abort", 27);
    for (;;) {
        if (KEY_DOWN(KC_RETURN)) { wait_key(KC_RETURN); break; }
        if (KEY_DOWN(KC_ESC))    { wait_key(KC_ESC); goto aborted; }
    }
    for (u32 r = LINE(7); r <= LINE(10); r += 12u)
        paint_string(r, 1, "                                                  ", 50);

    /* ---- Stage the source disk ---- */
    /* Eject the disk we booted from so the operator can put the SOURCE
     * disk in the boot drive (on a FloppyEmu, switch to the source
     * image). */
    {
        i16 ej = eject_floppy(src);
        paint_result(LINE(7), "Eject boot disk ", ej);
    }

    if (two_drive) {
        paint_string(LINE(9),  1, "Insert SOURCE in boot drive,", 28);
        paint_string(LINE(10), 1, "blank DEST in other drive.", 26);
    } else {
        paint_string(LINE(9),  1, "Insert SOURCE disk in the drive.", 32);
        paint_string(LINE(10), 1, "(destination comes later)", 25);
    }
    paint_string(LINE(11), 1, "Press RETURN when ready ...", 27);
    wait_key(KC_RETURN);
    paint_string(LINE(11), 1, "                                        ", 40);

    /* ---- Read source into RAM ---- */
    if (transfer_with_retry(0, src, "Reading", LINE(13), LINE(16)))
        goto aborted;

    /* ---- Single-drive: swap in the destination ---- */
    if (!two_drive) {
        i16 ej = eject_floppy(src);
        paint_result(LINE(11), "Eject source ", ej);
        paint_string(LINE(9),  1, "Insert DEST disk (will be erased).      ", 40);
        paint_string(LINE(10), 1, "                                        ", 40);
        paint_string(LINE(12), 1, "Press RETURN when ready ...", 27);
        wait_key(KC_RETURN);
        paint_string(LINE(12), 1, "                                        ", 40);
    }

    /* ---- Format the destination ---- */
    /* Lay down the physical track/sector structure so the raw _Write
     * lands cleanly even on an unformatted or foreign disk. Retry on
     * error (e.g. write-protected or no disk). */
    for (;;) {
        paint_string(LINE(13), 1, "Formatting dest ...                     ", 40);
        i16 fr = sony_format(dst);
        if (fr == 0) {
            paint_string(LINE(13), 1, "Formatting dest ... done                ", 40);
            break;
        }
        paint_result(LINE(16), "FORMAT failed ", fr);
        paint_string(LINE(17), 1, "RETURN=retry   ESC=abort                ", 40);
        for (;;) {
            if (KEY_DOWN(KC_RETURN)) { wait_key(KC_RETURN); break; }
            if (KEY_DOWN(KC_ESC))    { wait_key(KC_ESC); goto aborted; }
        }
        paint_string(LINE(16), 1, "                                        ", 40);
        paint_string(LINE(17), 1, "                                        ", 40);
    }

    /* ---- Write RAM to destination ---- */
    if (transfer_with_retry(1, dst, "Writing", LINE(14), LINE(16)))
        goto aborted;

    /* ---- Eject everything ---- */
    if (two_drive) {
        i16 e1 = eject_floppy(src);
        i16 e2 = eject_floppy(dst);
        paint_result(LINE(16), "Eject source ", e1);
        paint_result(LINE(17), "Eject dest ",   e2);
    } else {
        i16 e2 = eject_floppy(dst);
        paint_result(LINE(16), "Eject dest ", e2);
    }

    paint_string(LINE(19), 1, "COPY COMPLETE. Power-cycle when done.", 37);
    for (;;) { asm volatile (""); }

aborted:
    paint_string(LINE(19), 1, "ABORTED. Power-cycle when done.", 31);
    for (;;) { asm volatile (""); }
}
