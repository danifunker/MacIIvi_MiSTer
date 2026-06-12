/* diskio_main.c — disk I/O bench, supervisor-mode.
 *
 * Per test size we run two measurements:
 *
 *   READ:
 *     _Read N bytes from the pre-baked file /Read_<label>. We time the
 *     _Read trap end-to-end with VIA1 T2 (microsecond resolution).
 *
 *   WRITE:
 *     _Write N bytes of a known pattern to /Write_<label>'s scratch
 *     region, then _Read it back, CRC-check the round-trip, and time
 *     each leg separately so writeback-cache effects don't get rolled
 *     into a single number.
 *
 * Results are emitted as JSONL via the supervisor_bench JsonlWriter:
 *
 *   {"size":"1KB","len":1024,"op":"read","us":NNN,"err":0}
 *   {"size":"1KB","len":1024,"op":"write","us":NNN,"err":0,"verified":1,
 *    "readback_us":NNN}
 *
 * 'verified' is 1 only when the readback bytes match the pattern we
 * wrote. 'err' is the ioResult from the _Read/_Write trap (0 = noErr).
 *
 * The screen displays a single progress line per test as it runs so a
 * hang or driver reset is attributable to a specific size+op. */

#include "bench_types.h"
#include "drive_enum.h"
#include "eject.h"
#include "jsonl_writer.h"
#include "sizes.h"
#include "timing.h"

/* Provided by payload_entry.s — same convention as the CPU bench. */
extern i16 g_handoff_refnum;
extern i16 g_handoff_drive;

/* Provided by exc_handlers.s. iotest_setjmp populates the JmpBuf and
 * returns 0 the first time around. If a 68k exception fires while the
 * same JmpBuf is the active recovery target, common_exc_handler
 * iotest_longjmp's back to that setjmp with the vector number (2..9)
 * as the return value. We then synthesize an EXC_ERR_BASE+vector code
 * so the bench can treat it like any other failed trap. */
typedef u32 JmpBuf[12];
extern u32  iotest_setjmp(JmpBuf *buf);
extern void iotest_longjmp(JmpBuf *buf, u32 val) __attribute__((noreturn));
extern JmpBuf g_exc_jmpbuf;
extern u16    g_last_exc_vector;

#define EXC_ERR_BASE 30000
static i16 vector_to_err(u16 vec)
{
    return (i16)(EXC_ERR_BASE + vec);
}

struct param_block_s;
static i16 trap_with_recovery(i16 (*trap)(struct param_block_s *),
                              struct param_block_s *pb);

/* /Results.jsonl byte offset within the partition. Patched in at
 * image-build time by patch_offsets.py.
 *
 * The marker + the offset live in a single non-const struct so the
 * linker keeps them adjacent in .data. The patch script greps for the
 * 8-byte marker and writes the u32 in the slot that immediately
 * follows. __packed__ guarantees no padding between marker[8] and
 * offset(u32) — both fields are u8/u32 with natural alignment 4, but
 * being explicit prevents future struct-layout surprises. */
/* volatile on both fields keeps the compiler from constant-propagating
 * the placeholder into bench_main()'s callsite, and from discarding the
 * marker as unreferenced. Non-static so external visibility further
 * blocks dead-store elimination. */
struct __attribute__((__packed__)) iotest_results_slot {
    volatile char marker[8];
    volatile u32  offset;
};
struct iotest_results_slot g_results_slot = {
    { 'I','O','R','E','S','L','T','_' }, 0xDEADBEEFu
};

#define g_results_offset (g_results_slot.offset)

/* Paint helpers — same signature as supervisor_bench/font_ascii.c. */
extern void paint_string(u32 row, u32 col_byte, const char *s, u32 max_chars);

/* I/O buffer pinned to a fixed high address — NOT in .bss.
 *
 * Two reasons for the fixed address:
 *   1. A 4 MB BSS array would force the linker to lay symbols (and
 *      our stack) several megabytes past where we load. On a Mac with
 *      less RAM than that, the BSS-zero or stack pointer setup would
 *      bus-error before bench_main() runs.
 *   2. We want to vary the *usable* buffer extent at runtime based on
 *      MemTop, not at link time based on a worst-case define.
 *
 * Placing the buffer at $200000 (2 MB) leaves the 0..2 MB region for
 * payload code + stack, with a comfortable 1 MB+ gap above the stack
 * top ($100000). Tests whose buffer would extend past MemTop are
 * skipped at runtime. */
#define IOBUF_BASE 0x00200000u

/* Mac low-mem MemTop ($0108) = byte just past last RAM byte. ROM
 * populates this during early boot, well before our boot stub runs. */
#define MEM_TOP (*(volatile u32 *)0x00000108)

static u8 * const g_io_buf = (u8 *)IOBUF_BASE;

/* IOParam parameter block for _Read / _Write. Field offsets must
 * match Inside Macintosh: Files exactly — the Device Manager reads
 * the trap arguments from these byte offsets regardless of how we
 * choose to name them in C.
 *
 *   0  ioQLink       (long)
 *   4  ioQType       (word)
 *   6  ioTrap        (word)
 *   8  ioCmdAddr     (long)
 *  12  ioCompletion  (long)
 *  16  ioResult      (word)         ← signed; 0 = noErr
 *  18  ioNamePtr     (long)
 *  22  ioVRefNum     (word)
 *  24  ioRefNum      (word)         ← driver refnum (signed)
 *  26  ioVersNum     (byte)
 *  27  ioPermssn     (byte)
 *  28  ioMisc        (long)         ← 4 BYTES, not 6 (earlier bug)
 *  32  ioBuffer      (long)
 *  36  ioReqCount    (long)
 *  40  ioActCount    (long)
 *  44  ioPosMode     (word)
 *  46  ioPosOffset   (long)
 *
 * Total 50 bytes through ioPosOffset. Padded to PB_SIZE (80) so the
 * struct length matches what `jsonl_writer.c` already uses. */
typedef struct param_block_s {
    u8  pad_qlink[12];     /* offsets 0..11 (qlink + qtype + ioTrap + ioCmdAddr) */
    u32 io_completion;     /* offset 12 */
    u16 io_result;         /* offset 16 */
    u32 io_name_ptr;       /* offset 18 */
    u16 io_vrefnum;        /* offset 22 */
    u16 io_refnum;         /* offset 24 */
    u8  io_versnum;        /* offset 26 */
    u8  io_permssn;        /* offset 27 */
    u32 io_misc;           /* offset 28 */
    u32 io_buffer;         /* offset 32 */
    u32 io_req_count;      /* offset 36 */
    u32 io_act_count;      /* offset 40 */
    u16 io_pos_mode;       /* offset 44 */
    u32 io_pos_offset;     /* offset 46 */
    u8  pad_rest[30];      /* offsets 50..79 */
} ParamBlock;

static ParamBlock g_pb;

/* The _Read and _Write traps are A002 / A003. Call them by stuffing
 * the trap word inline in assembly. Inputs: A0 = ParamBlock. Outputs:
 * ioResult set in the PB; D0 = ioResult also returned. */
/* The _Read/_Write Device Manager traps clobber D1/D2/A1 in addition to
 * D0 (result) and A0 (param block). The earlier clobber list named only
 * "cc"/"memory", which is a latent miscompile waiting to happen: if the
 * register allocator ever keeps a live value in D1/D2/A1 across the trap
 * it gets silently corrupted. jsonl_writer.c's _Write already lists them;
 * keep these in sync. */
static i16 trap_read(ParamBlock *pb)
{
    register i16  r asm("d0");
    register ParamBlock *p asm("a0") = pb;
    asm volatile (".word 0xA002\n"
                  : "=d"(r)
                  : "a"(p)
                  : "d1", "d2", "a1", "cc", "memory");
    return r;
}

static i16 trap_write(ParamBlock *pb)
{
    register i16  r asm("d0");
    register ParamBlock *p asm("a0") = pb;
    asm volatile (".word 0xA003\n"
                  : "=d"(r)
                  : "a"(p)
                  : "d1", "d2", "a1", "cc", "memory");
    return r;
}

/* Raw block-driver transfers must be whole 512-byte sectors: the
 * Device Manager .Disk/SCSI driver does NO sub-block buffering (that is
 * the File Manager's job, and these _Read/_Write calls go straight to
 * the driver via its refnum, below the File Manager). Issuing a
 * sub-sector ioReqCount like 1 byte drives the NCR5380 + DMA path into
 * a transfer it can't satisfy — fatal on real hardware (hard reset, no
 * Sad Mac) and a no-op/loop under MAME's more forgiving SCSI model.
 *
 * Round the logical test length up to the next sector, one-sector
 * minimum, so the tiny sizes ("1B", "512B") still issue a legal count.
 * The JSONL still reports the logical s->length; only the bytes moved
 * across the bus are rounded. */
#define SECTOR_BYTES 512u
static u32 sector_round_up(u32 n)
{
    if (n == 0) return SECTOR_BYTES;
    return (n + (SECTOR_BYTES - 1u)) & ~(SECTOR_BYTES - 1u);
}

/* Wrap a trap call with the exception-recovery setjmp barrier. Normal
 * path: returns the trap's ioResult. Faulting path: if a 68k exception
 * (vectors 2..9; see exc_handlers.s) fires inside the trap, the handler
 * longjmps back here and we return an EXC_ERR_BASE+vector synthetic
 * code. Call site is identical to a direct trap call. */
static i16 trap_with_recovery(i16 (*trap)(struct param_block_s *),
                              struct param_block_s *pb)
{
    u32 longjmp_val = iotest_setjmp(&g_exc_jmpbuf);
    if (longjmp_val != 0) {
        return vector_to_err((u16)longjmp_val);
    }
    g_last_exc_vector = 0;
    return trap(pb);
}

static void pb_init(ParamBlock *pb, u32 buf, u32 offset, u32 length)
{
    u32 *w = (u32 *)pb;
    u32  n = sizeof(*pb) / 4;
    while (n--) *w++ = 0;
    pb->io_refnum     = g_handoff_refnum;
    pb->io_vrefnum    = g_handoff_drive;
    pb->io_buffer     = buf;
    pb->io_req_count  = sector_round_up(length);  /* whole sectors only */
    pb->io_pos_mode   = 1;  /* fsFromStart */
    pb->io_pos_offset = offset;
}

/* Fill buf with a size-aware pattern: byte i = (i ^ (i >> 8) ^ seed) & 0xFF.
 * Cheap and changes every byte so we'd notice partial-writeback bugs. */
static void fill_pattern(u8 *buf, u32 len, u8 seed)
{
    u32 i;
    for (i = 0; i < len; i++)
        buf[i] = (u8)((i ^ (i >> 8) ^ seed) & 0xFFu);
}

/* Verification result. first_off == VERIFY_MATCH means the buffer matched
 * the expected pattern; otherwise it's the offset of the first mismatched
 * byte and (expected, actual) are the two byte values at that offset.
 * count is the total number of mismatched bytes across the whole buffer
 * (so the operator can tell single-bit corruption from wholesale junk
 * from a wraparound or alignment shift). */
#define VERIFY_MATCH ((u32) -1)
typedef struct {
    u32 first_off;
    u32 count;
    u8  expected;
    u8  actual;
} VerifyResult;

static VerifyResult verify_pattern(const u8 *buf, u32 len, u8 seed)
{
    VerifyResult r = { VERIFY_MATCH, 0u, 0u, 0u };
    u32 i;
    for (i = 0; i < len; i++) {
        u8 ex = (u8)((i ^ (i >> 8) ^ seed) & 0xFFu);
        if (buf[i] != ex) {
            if (r.first_off == VERIFY_MATCH) {
                r.first_off = i;
                r.expected  = ex;
                r.actual    = buf[i];
            }
            r.count++;
        }
    }
    return r;
}

/* Emit a single JSONL line marking a size as skipped because the I/O
 * buffer would extend past physical RAM. One line per skipped test so
 * downstream tools see exactly which sizes couldn't run on this Mac. */
static void emit_skip_line(JsonlWriter *jw, const IoTestSize *s,
                           const char *reason, u32 mem_top)
{
    jw_puts(jw, "{\"size\":\""); jw_puts(jw, s->label);
    jw_puts(jw, "\",\"len\":");  jw_putul(jw, s->length);
    jw_puts(jw, ",\"op\":\"skip\",\"reason\":\""); jw_puts(jw, reason);
    jw_puts(jw, "\",\"mem_top\":0x"); jw_putul(jw, mem_top);
    jw_puts(jw, ",\"iobuf_base\":0x"); jw_putul(jw, IOBUF_BASE);
    jw_puts(jw, "}\n");
    jw_commit_line(jw);
}

/* Emit one JSONL line for a read result. If `sense` is non-NULL the
 * 18-byte SCSI sense buffer is digested into sense_key / asc / ascq /
 * sense_raw fields (the operator usually only needs key/asc/ascq, but
 * the full 18 bytes go out as a hex string for forensic depth). */
static void emit_sense_fields(JsonlWriter *jw, const u8 *sense)
{
    static const char hex[16] = "0123456789ABCDEF";
    jw_puts(jw, ",\"sense_key\":"); jw_putul(jw, (u32)(sense[2] & 0x0F));
    jw_puts(jw, ",\"asc\":");       jw_putul(jw, (u32)sense[12]);
    jw_puts(jw, ",\"ascq\":");      jw_putul(jw, (u32)sense[13]);
    jw_puts(jw, ",\"sense_raw\":\"");
    u32 i;
    for (i = 0; i < 18; i++) {
        char b[2]; b[0] = hex[(sense[i] >> 4) & 0xF];
                   b[1] = hex[ sense[i]       & 0xF];
        jw_putc(jw, b[0]); jw_putc(jw, b[1]);
    }
    jw_puts(jw, "\"");
}

static void emit_read_line(JsonlWriter *jw, const IoTestSize *s,
                           u32 elapsed_us, i16 err, const u8 *sense_or_null)
{
    jw_puts(jw, "{\"size\":\""); jw_puts(jw, s->label);
    jw_puts(jw, "\",\"len\":");  jw_putul(jw, s->length);
    jw_puts(jw, ",\"op\":\"read\",\"us\":"); jw_putul(jw, elapsed_us);
    jw_puts(jw, ",\"err\":");    jw_putul(jw, (u32)(i32)err);
    if (sense_or_null) emit_sense_fields(jw, sense_or_null);
    jw_puts(jw, "}\n");
    jw_commit_line(jw);
}

/* Emit one JSONL line for a write+readback result. When verify_pattern
 * found mismatches, also emit the first-mismatch offset, the expected
 * and actual byte values there, and the total mismatch count -- this is
 * what tells single-bit corruption ("@523 e=AB a=AA, cnt=1") apart from
 * wholesale buffer scramble ("@0 e=00 a=FF, cnt=4194304") or alignment
 * shifts ("@512 e=00 a=NN, cnt=NN") at a glance. */
static void emit_write_line(JsonlWriter *jw, const IoTestSize *s,
                            u32 write_us, i16 write_err,
                            u32 read_us,  i16 read_err,
                            const VerifyResult *vr,
                            const u8 *sense_or_null)
{
    int verified = (read_err == 0) && (vr->count == 0);
    jw_puts(jw, "{\"size\":\""); jw_puts(jw, s->label);
    jw_puts(jw, "\",\"len\":");  jw_putul(jw, s->length);
    jw_puts(jw, ",\"op\":\"write\",\"us\":"); jw_putul(jw, write_us);
    jw_puts(jw, ",\"err\":");    jw_putul(jw, (u32)(i32)write_err);
    jw_puts(jw, ",\"readback_us\":"); jw_putul(jw, read_us);
    jw_puts(jw, ",\"readback_err\":"); jw_putul(jw, (u32)(i32)read_err);
    jw_puts(jw, ",\"verified\":"); jw_putul(jw, (u32)verified);
    if (vr->count != 0) {
        jw_puts(jw, ",\"mismatch_offset\":"); jw_putul(jw, vr->first_off);
        jw_puts(jw, ",\"expected\":");        jw_putul(jw, (u32)vr->expected);
        jw_puts(jw, ",\"actual\":");          jw_putul(jw, (u32)vr->actual);
        jw_puts(jw, ",\"mismatch_count\":");  jw_putul(jw, vr->count);
    }
    if (sense_or_null) emit_sense_fields(jw, sense_or_null);
    jw_puts(jw, "}\n");
    jw_commit_line(jw);
}

static JsonlWriter g_jw;

/* paint_string takes a PIXEL row (not a character row), and glyphs are 8
 * pixels tall. LINE(n) places each visible text line on a 12-pixel grid
 * (8-pixel glyph + 4-pixel gap) so adjacent lines are clear of each other.
 *
 * Layout from top to bottom:
 *
 *     LINE(0)        "IOTEST: DISK I/O BENCH"
 *     LINE(1)        "DRIVES" header
 *     LINE(2..5)     up to MAX_DRIVES_SHOWN drive enumeration rows
 *                       "<num> <type> <refnum> <blocks> <name> [BOOT]"
 *     LINE(7)        "SIZE     READ     WRITE" (test column header)
 *     LINE(8..19)    one row per test size
 *     LINE(21)       mismatch detail (last verify failure)
 *
 * Worst case (4 drives + 12 sizes + detail): row 21 at pixel 252 of a
 * 480-px screen. Comfortable margin. */
#define LINE(n)            ((n) * 12u)
#define LINE_BANNER        LINE(0)
#define LINE_DRIVES_HDR    LINE(1)
#define LINE_DRIVE_ROW(i)  LINE(2u + (i))
#define MAX_DRIVES_SHOWN   4u
#define LINE_HEADER        LINE(7)
#define LINE_RESULT(i)     LINE(8u + (i))
#define LINE_DETAIL        LINE(21u)

/* Per-line byte-column layout (1 byte = 8 pixels on the 1bpp screen).
 * STATUS_W = 8 chars (64 px) wide; fits Mac OS error mnemonics like
 * "ioErr   " or "paramErr" and verify-failure markers like "@1234567"
 * without truncation. */
#define COL_SIZE        1u    /* "1B"..."4MB"  8 cols wide */
#define COL_READ        10u   /* status cell, 8 cols wide */
#define COL_WRITE       20u   /* status cell, 8 cols wide (full mode) */
#define STATUS_W        8u    /* fixed width so old chars overprint cleanly */

/* Mac OS / SCSI driver error mnemonics for the codes that actually show
 * up in disk I/O. Anything not in this table falls back to "E -NNN  "
 * formatting (signed decimal, 4 digits max). Keep entries to <= 7 chars
 * + trailing space so they paint cleanly in an 8-wide cell. */
static const struct { i16 code; const char *name; } g_ioerr_names[] = {
    { -33, "dirFull"  },   /* directory full */
    { -34, "dskFull"  },   /* disk full */
    { -35, "nsvErr"   },   /* no such volume */
    { -36, "ioErr"    },   /* generic I/O error -- most common SCSI fail */
    { -37, "bdNamErr" },   /* bad filename */
    { -38, "fnOpnErr" },   /* file not open */
    { -39, "eofErr"   },   /* end-of-file */
    { -40, "posErr"   },   /* bad positioning */
    { -42, "tmfoErr"  },   /* too many files open */
    { -43, "fnfErr"   },   /* file not found */
    { -49, "opWrErr"  },   /* file already open for writing */
    { -50, "paramErr" },   /* parameter list error */
    { -51, "rfNumErr" },   /* bad reference number */
    { -53, "volOffLn" },   /* volume offline */
    { -54, "permErr"  },   /* permissions error */
    { -55, "volOnLn"  },   /* volume already online */
    { -56, "nsDrvErr" },   /* no such drive */
    { -57, "noMacDsk" },   /* not a Mac disk */
    { -58, "extFSErr" },   /* external FS error */
    { -59, "fsRnErr"  },   /* file system rename error */
    { -60, "badMDB"   },   /* bad master directory block */
    { -61, "wrPermErr"},   /* write permissions error */
    { -64, "lastDsk"  },   /* drive timeout (old SCSI) */
    { -65, "offLine"  },   /* drive offline */
    { -66, "noNibble" },   /* no nibble (disk read failure) */
    { -67, "noAdrMrk" },   /* no address mark (sector header missing) */
    { -68, "dataVerf" },   /* data verify error */
};
#define IOERR_NAMES_N (sizeof(g_ioerr_names) / sizeof(g_ioerr_names[0]))

/* Append n chars of `src` (no NUL) into out, padding with spaces if src
 * is shorter than n. Used to land a variable-length mnemonic in a fixed
 * cell width so paint_string wipes any leftover chars from a prior
 * iteration's longer status. */
static void copy_padded(char *out, u32 n, const char *src)
{
    u32 i;
    for (i = 0; i < n && src[i]; i++) out[i] = src[i];
    for (; i < n; i++)                out[i] = ' ';
}

/* Format an 8-char status cell into `out` (no NUL):
 *   err == 0  -> "pass    "
 *   known err -> "ioErr   " etc. via g_ioerr_names lookup
 *   other err -> "E -NNNN " (signed decimal, padded to 8 chars). */
static void fmt_status(char out[STATUS_W], i16 err)
{
    u32 k;
    for (k = 0; k < STATUS_W; k++) out[k] = ' ';
    if (err == 0) { copy_padded(out, STATUS_W, "pass"); return; }
    for (k = 0; k < IOERR_NAMES_N; k++) {
        if (g_ioerr_names[k].code == err) {
            copy_padded(out, STATUS_W, g_ioerr_names[k].name);
            return;
        }
    }
    /* Unknown -- decimal fallback. */
    i32 v = (i32)err;
    int neg = (v < 0);
    if (neg) v = -v;
    u32 div_table[5] = { 10000, 1000, 100, 10, 1 };
    u32 d, started = 0, pos = 2;
    out[0] = 'E';
    out[1] = neg ? '-' : ' ';
    for (d = 0; d < 5; d++) {
        u32 digit = ((u32)v / div_table[d]) % 10;
        if (digit || started || d == 4) {
            if (pos < STATUS_W) out[pos++] = (char)('0' + digit);
            started = 1;
        }
    }
}

/* Format a verify-fail cell: "Mismatched byte @N ex:XX ac:YY" painted
 * across two screen lines.  The first line (out_line1, STATUS_W chars)
 * gets "Mism @NN" and the second (out_line2) gets "ex:XX/YY" so the
 * operator sees the offset AND the byte values without pulling JSONL. */
static void fmt_verify_fail(char out[STATUS_W], const VerifyResult *vr)
{
    static const char hex[16] = "0123456789ABCDEF";
    u32 k;
    for (k = 0; k < STATUS_W; k++) out[k] = ' ';
    /* "@N XX/YY" — offset (up to 2 digits), then expected/actual hex.
     * Fits in 8 chars for offsets 0..99; larger offsets truncate the
     * hex pair but those are less common on the FPGA (byte-order bugs
     * show up at offset 0 or 1). */
    out[0] = '@';
    u32 off = vr->first_off;
    u32 pos = 1;
    if (off >= 10 && pos < STATUS_W) out[pos++] = (char)('0' + (off / 10) % 10);
    if (pos < STATUS_W) out[pos++] = (char)('0' + off % 10);
    if (pos < STATUS_W) out[pos++] = ' ';
    if (pos < STATUS_W) out[pos++] = hex[(vr->expected >> 4) & 0xF];
    if (pos < STATUS_W) out[pos++] = hex[ vr->expected       & 0xF];
    if (pos < STATUS_W) out[pos++] = '/';
    if (pos < STATUS_W) out[pos++] = hex[(vr->actual >> 4) & 0xF];
    if (pos < STATUS_W) out[pos++] = hex[ vr->actual       & 0xF];
}

/* Paint a full-width detail line below the results table showing the
 * most recent verify mismatch: "Mismatched byte @N ex:XX ac:YY cnt:NNNNN"
 * so the operator can see the byte values without extracting JSONL. */
static void paint_mismatch_detail(const VerifyResult *vr)
{
    static const char hex[16] = "0123456789ABCDEF";
    char line[48];
    u32 k;
    for (k = 0; k < sizeof(line); k++) line[k] = ' ';
    /* "Mismatched byte @" */
    const char *prefix = "Mismatched byte @";
    for (k = 0; prefix[k]; k++) line[k] = prefix[k];
    /* offset (decimal, up to 7 digits) */
    u32 off = vr->first_off;
    u32 div_table[7] = { 1000000, 100000, 10000, 1000, 100, 10, 1 };
    u32 d, started = 0, pos = k;
    for (d = 0; d < 7; d++) {
        u32 digit = (off / div_table[d]) % 10;
        if (digit || started || d == 6) {
            if (pos < sizeof(line)) line[pos++] = (char)('0' + digit);
            started = 1;
        }
    }
    /* " ex:XX ac:YY" */
    if (pos < sizeof(line)) line[pos++] = ' ';
    if (pos < sizeof(line)) line[pos++] = 'e';
    if (pos < sizeof(line)) line[pos++] = 'x';
    if (pos < sizeof(line)) line[pos++] = ':';
    if (pos < sizeof(line)) line[pos++] = hex[(vr->expected >> 4) & 0xF];
    if (pos < sizeof(line)) line[pos++] = hex[ vr->expected       & 0xF];
    if (pos < sizeof(line)) line[pos++] = ' ';
    if (pos < sizeof(line)) line[pos++] = 'a';
    if (pos < sizeof(line)) line[pos++] = 'c';
    if (pos < sizeof(line)) line[pos++] = ':';
    if (pos < sizeof(line)) line[pos++] = hex[(vr->actual >> 4) & 0xF];
    if (pos < sizeof(line)) line[pos++] = hex[ vr->actual       & 0xF];
    paint_string(LINE_DETAIL, COL_SIZE, line, pos);
}

/* Paint one result row's fixed parts (size label + cells set to "....").
 * Called once per size before its test runs so the operator sees the row
 * appear in advance and watches the cells fill in. */
static void paint_row_skeleton(u16 i, const char *label)
{
    char dots[STATUS_W] = {'.',' ','.',' ','.',' ','.',' '};
    paint_string(LINE_RESULT(i), COL_SIZE,  label, 8);
    paint_string(LINE_RESULT(i), COL_READ,  dots,  STATUS_W);
#ifndef IOTEST_READ_ONLY
    paint_string(LINE_RESULT(i), COL_WRITE, dots,  STATUS_W);
#endif
}

static void paint_cell(u16 i, u32 col, const char *six)
{
    paint_string(LINE_RESULT(i), col, six, STATUS_W);
}

void bench_main(void)
{
    JwCtx ctx;
    u16 i;
    char status[STATUS_W];

    ctx.refnum      = g_handoff_refnum;
    ctx.drive       = g_handoff_drive;
    ctx.base_offset = g_results_offset;
    ctx.max_bytes   = 32 * 1024;            /* same allocation as build_*.sh */
    jw_init(&g_jw, &ctx);

#ifdef IOTEST_VARIANT_HDA
    paint_string(LINE_BANNER, COL_SIZE, "IOTEST: HARD DISK I/O BENCH", 28);
#else
    paint_string(LINE_BANNER, COL_SIZE, "IOTEST: FLOPPY DISK I/O BENCH", 30);
#endif

    /* DRIVES table -- one row per online drive the ROM knows about.
     * Wrapped in exception recovery: on real hardware the Drive Queue
     * or VCB Queue walk can fault if the ROM hasn't fully populated
     * the low-mem globals by boot-block time. If that happens we
     * paint an error and continue to the actual I/O tests. */
    {
        u32 exc = iotest_setjmp(&g_exc_jmpbuf);
        if (exc != 0) {
            char msg[40] = "DRIVES: exception vec ";
            u32 p = 22;
            if (exc >= 10) msg[p++] = (char)('0' + (exc / 10) % 10);
            msg[p++] = (char)('0' + exc % 10);
            paint_string(LINE_DRIVES_HDR, COL_SIZE, msg, p);
        } else {
            DriveInfo drives[MAX_DRIVES_SHOWN];
            int n = enum_drives(drives, (int)MAX_DRIVES_SHOWN);
            paint_string(LINE_DRIVES_HDR, COL_SIZE,
                         "DRIVES", 6);
            int j;
            for (j = 0; j < n; j++) {
                const DriveInfo *d = &drives[j];
                char line[48];
                u32 k, pos;
                for (k = 0; k < sizeof(line); k++) line[k] = ' ';
                pos = 0;
                /* drive_num */
                i16 dn = d->drive_num;
                if (dn >= 10) line[pos++] = '0' + (dn / 10) % 10;
                line[pos++] = '0' + dn % 10;
                line[pos++] = ' ';
                /* human type: "Floppy", "SCSI Disk", "CD-ROM", or "Drive" */
                const char *type_str;
                switch (d->type) {
                    case DRIVE_TYPE_FLOPPY: type_str = "Floppy";    break;
                    case DRIVE_TYPE_CDROM:  type_str = "CD-ROM";    break;
                    case DRIVE_TYPE_SCSI:   type_str = "SCSI Disk"; break;
                    default:               type_str = "Drive";      break;
                }
                for (k = 0; type_str[k]; k++) line[pos++] = type_str[k];
                line[pos++] = ' ';
                /* human size from blocks: KB, MB, or GB */
                {
                    u32 bytes = d->blocks * 512u;
                    u32 val; char suffix;
                    if (bytes >= 1048576u) {
                        val = (bytes + 524288u) / 1048576u;
                        suffix = 'M';
                    } else {
                        val = (bytes + 512u) / 1024u;
                        suffix = 'K';
                    }
                    char tmp[6]; int ti = 0;
                    if (val == 0) tmp[ti++] = '0';
                    while (val) { tmp[ti++] = '0' + (val % 10); val /= 10; }
                    for (k = 0; (int)k < ti; k++) line[pos++] = tmp[ti - 1 - k];
                    line[pos++] = suffix;
                    line[pos++] = 'B';
                }
                /* BOOT marker */
                if (d->is_boot) {
                    line[pos++] = ' ';
                    line[pos++] = '*';
                    line[pos++] = 'B';
                    line[pos++] = 'O';
                    line[pos++] = 'O';
                    line[pos++] = 'T';
                }
                paint_string(LINE_DRIVE_ROW(j), COL_SIZE, line, pos);
            }
            for (; j < (int)MAX_DRIVES_SHOWN; j++) {
                paint_string(LINE_DRIVE_ROW(j), COL_SIZE,
                             "                                        ", 40);
            }
        }
    }

#ifndef IOTEST_READ_ONLY
    paint_string(LINE_HEADER, COL_SIZE,  "SIZE",  4);
    paint_string(LINE_HEADER, COL_READ,  "READ",  4);
    paint_string(LINE_HEADER, COL_WRITE, "WRITE", 5);
#else
    paint_string(LINE_HEADER, COL_SIZE, "SIZE", 4);
    paint_string(LINE_HEADER, COL_READ, "READ", 4);
#endif

    u32 mem_top = MEM_TOP;

    for (i = 0; i < g_iotest_n_sizes; i++) {
        const IoTestSize *s = &g_iotest_sizes[i];
        u32 t_us;
        i16 err;

        paint_row_skeleton(i, s->label);

        /* RAM check: the buffer at IOBUF_BASE must hold s->length
         * bytes. If MemTop is below the buffer end, the test can't run
         * on this Mac — mark the row "SKIP" in both cells and continue. */
        if ((u32)IOBUF_BASE + s->length > mem_top ||
            s->length > mem_top - (u32)IOBUF_BASE) {
            paint_cell(i, COL_READ,  "SKIP    ");
#ifndef IOTEST_READ_ONLY
            paint_cell(i, COL_WRITE, "SKIP    ");
#endif
            emit_skip_line(&g_jw, s, "insufficient_ram", mem_top);
            continue;
        }

        /* ----- READ ----- */
        pb_init(&g_pb, (u32)g_io_buf, s->read_offset, s->length);
        timer_start();
        err = trap_with_recovery(trap_read, &g_pb);
        t_us = timer_elapsed_us();
        emit_read_line(&g_jw, s, t_us, err, (const u8 *)0);
        fmt_status(status, err); paint_cell(i, COL_READ, status);

#ifndef IOTEST_READ_ONLY
        /* ----- WRITE + READBACK ----- */
        fill_pattern(g_io_buf, s->length, (u8)i);
        pb_init(&g_pb, (u32)g_io_buf, s->write_offset, s->length);
        timer_start();
        err = trap_with_recovery(trap_write, &g_pb);
        t_us = timer_elapsed_us();

        u32 wr_us = t_us; i16 wr_err = err;

        /* Clear the buffer so we know readback isn't a false match. */
        {
            u32 *w = (u32 *)g_io_buf;
            u32  n = (s->length + 3) / 4;
            while (n--) *w++ = 0;
        }
        pb_init(&g_pb, (u32)g_io_buf, s->write_offset, s->length);
        timer_start();
        err = trap_with_recovery(trap_read, &g_pb);
        t_us = timer_elapsed_us();

        VerifyResult vr = verify_pattern(g_io_buf, s->length, (u8)i);

        emit_write_line(&g_jw, s, wr_us, wr_err, t_us, err, &vr, (const u8 *)0);

        /* WRITE cell precedence (most-actionable-first):
         *   wr_err != 0          -> show the trap error mnemonic (driver
         *                           rejected the write; verify is moot)
         *   readback err != 0    -> show the readback trap error
         *   verify mismatch      -> show "@NNNNNNN" with first bad byte
         *                           offset (full byte details in JSONL)
         *   else                 -> "pass"
         */
        if (wr_err != 0)              fmt_status(status, wr_err);
        else if (err != 0)            fmt_status(status, err);
        else if (vr.count != 0)       { fmt_verify_fail(status, &vr); paint_mismatch_detail(&vr); }
        else                          fmt_status(status, 0);
        paint_cell(i, COL_WRITE, status);
#endif
    }

    jw_flush(&g_jw);
    paint_string(LINE_DETAIL + 12u, COL_SIZE, "Done!", 5);
#ifdef IOTEST_VARIANT_DSK
    /* Eject the floppy so the operator doesn't have to manually
     * unmount the test disk before the next boot. Show the .Sony
     * Control ioResult (0 = ejected) as a status cell. */
    {
        i16 ej = eject_floppy(g_handoff_drive);
        char ejs[STATUS_W];
        paint_string(LINE_DETAIL + 24u, COL_SIZE, "EJECT:", 6);
        fmt_status(ejs, ej);
        paint_string(LINE_DETAIL + 24u, COL_READ, ejs, STATUS_W);
    }
#endif
}
