#ifndef JSONL_WRITER_H
#define JSONL_WRITER_H

#include "bench_types.h"

/* Driver context. Same struct for floppy (.Sony) and SCSI — the
 * differences are just the values. */
typedef struct {
    i16 refnum;       /* signed driver refnum (-5 for .Sony, dynamic for SCSI) */
    i16 drive;        /* drive number (1 = internal floppy, etc.) */
    u32 base_offset;  /* byte offset of /Results.jsonl on its medium */
    u32 max_bytes;    /* capacity of the pre-allocated file */
} JwCtx;

/* 16 KB batches drop the _Write call count by ~32x, which keeps us
 * well under the SCSI driver's "too many rapid calls" threshold we
 * hit at ~227 single-sector writes. Must be a multiple of 512. */
#define JW_BATCH_BYTES (16 * 1024)

typedef struct {
    JwCtx ctx;
    u8    sector[JW_BATCH_BYTES];     /* working batch */
    u32   used;                       /* bytes used in current batch */
    u32   written;                    /* total bytes written so far */
    i16   last_err;                   /* last _Write ioResult (0 = noErr) */
} JsonlWriter;

void jw_init(JsonlWriter *w, const JwCtx *ctx);
void jw_putc(JsonlWriter *w, char c);
void jw_puts(JsonlWriter *w, const char *s);
void jw_putul(JsonlWriter *w, u32 v);

/* Write the current sector to disk *without advancing* the sector
 * pointer — call after each completed line so partial progress is
 * persisted. Subsequent jw_putc() calls continue filling the same
 * sector and will rewrite it on the next commit. Cheap: just an
 * extra _Write per line. */
void jw_commit_line(JsonlWriter *w);

void jw_flush(JsonlWriter *w);    /* zero-pad and flush, then advance */

#endif
