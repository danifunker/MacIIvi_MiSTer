#include "jsonl_writer.h"
#include "freestanding.h"

/* IOParam offsets (Inside Macintosh: Files) */
#define PB_OFF_IORESULT     16
#define PB_OFF_IOVREFNUM    22
#define PB_OFF_IOREFNUM     24
#define PB_OFF_IOBUFFER     32
#define PB_OFF_IOREQCOUNT   36
#define PB_OFF_IOACTCOUNT   40
#define PB_OFF_IOPOSMODE    44
#define PB_OFF_IOPOSOFFSET  46
#define PB_SIZE             80

static u8 g_pb[PB_SIZE];

/* Single-sector _Write at byte offset (ctx.base_offset + sector_idx * 512).
 * Returns ioResult (0 = noErr). Inline asm calls $A003 _Write. */
static i16 driver_write_sector(const JwCtx *ctx, u32 sector_idx, const u8 *buf)
{
    u8 *pb = g_pb;
    u32 i;
    for (i = 0; i < PB_SIZE; i++) pb[i] = 0;
    *(i16 *)(pb + PB_OFF_IOREFNUM)   = ctx->refnum;
    *(i16 *)(pb + PB_OFF_IOVREFNUM)  = ctx->drive;
    *(u32 *)(pb + PB_OFF_IOBUFFER)   = (u32)buf;
    *(u32 *)(pb + PB_OFF_IOREQCOUNT) = JW_BATCH_BYTES;
    *(i16 *)(pb + PB_OFF_IOPOSMODE)  = 1;     /* fsFromStart */
    *(u32 *)(pb + PB_OFF_IOPOSOFFSET) = ctx->base_offset + (u32)sector_idx * JW_BATCH_BYTES;

    asm volatile (
        "movel %0, %%a0   \n"
        ".short 0xA003    \n"   /* _Write */
        :
        : "g" (pb)
        : "a0", "a1", "d0", "d1", "d2", "cc", "memory"
    );

    return *(i16 *)(pb + PB_OFF_IORESULT);
}

void jw_init(JsonlWriter *w, const JwCtx *ctx)
{
    f_memset(w, 0, sizeof(*w));
    w->ctx = *ctx;
}

/* Internal: write the current batch (zero-padding any unused tail) to
 * disk at base_offset + batch_idx*JW_BATCH_BYTES. Caller decides
 * whether to advance `written` to start a new batch (true flush) or
 * leave it alone (partial-progress commit). */
static void write_current_batch(JsonlWriter *w)
{
    if (w->used < JW_BATCH_BYTES)
        f_memset(w->sector + w->used, 0, JW_BATCH_BYTES - w->used);
    u32 batch_idx = w->written / JW_BATCH_BYTES;
    i16 r = driver_write_sector(&w->ctx, batch_idx, w->sector);
    if (r != 0 && w->last_err == 0) w->last_err = r;
}

static void flush_sector(JsonlWriter *w)
{
    /* Full advance: write the batch then move to the next one. */
    write_current_batch(w);
    w->written += JW_BATCH_BYTES;
    w->used = 0;
}

void jw_putc(JsonlWriter *w, char c)
{
    if (w->written + w->used >= w->ctx.max_bytes) return;  /* full */
    w->sector[w->used++] = (u8)c;
    if (w->used == JW_BATCH_BYTES) flush_sector(w);
}

void jw_puts(JsonlWriter *w, const char *s)
{
    while (*s) jw_putc(w, *s++);
}

void jw_putul(JsonlWriter *w, u32 v)
{
    char tmp[12];
    char *t = f_putul(tmp, v);
    char *p;
    for (p = tmp; p < t; p++) jw_putc(w, *p);
}

/* Write the current batch to disk without advancing `written`.
 *
 * Each call costs one full JW_BATCH_BYTES (16 KB) SCSI write. The cost
 * buys us per-record persistence: if the bench hangs partway through a
 * size sweep, every JSONL line emitted before the hang is on disk and
 * can be extracted post-mortem via `rb-cli get IMG@1 /Results.jsonl`.
 *
 * The advance-on-full path (flush_sector) is unchanged; once the
 * batch fills, it gets written and `written` advances normally. So
 * this scheme degrades to ~1 commit per record while a batch is
 * actively being filled, plus the usual one-write-per-full-batch.
 * For a 24-record iotest run that's 24 writes of 16 KB = 384 KB,
 * negligible compared to the bench's read/write traffic. */
void jw_commit_line(JsonlWriter *w)
{
    if (w->used == 0) return;  /* nothing new since last commit */
    write_current_batch(w);
}

void jw_flush(JsonlWriter *w)
{
    if (w->used > 0) flush_sector(w);
}
