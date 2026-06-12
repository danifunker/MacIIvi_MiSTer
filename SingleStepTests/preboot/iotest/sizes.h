#ifndef IOTEST_SIZES_H
#define IOTEST_SIZES_H

#include "bench_types.h"

/* Test size table.
 *
 * Two artifacts share this codebase:
 *   IOTEST_VARIANT_HDA  — SCSI hard disk, 12 sizes (1B .. 4MB)
 *   IOTEST_VARIANT_DSK  — floppy (.SonyDriver), 8 sizes (1B .. 256KB)
 *
 * The shared set (1B..256KB) is identical in both. The floppy variant
 * stops at 256KB because larger files don't comfortably fit on an 800KB
 * volume alongside the boot block + payload + results file.
 *
 * Each entry carries the byte offset of its read source (a pre-baked
 * file in the HFS partition) and its write scratch region. Both are
 * patched in at image-build time by patch_offsets.py once the actual
 * on-disk extents are known. */

typedef struct {
    const char *label;        /* "1B", "512B", "1KB", … — for JSONL + screen */
    u32         length;       /* size of the read/write in bytes */
    u32         read_offset;  /* byte offset of /Read_<label> in the partition */
    u32         write_offset; /* byte offset of /Write_<label> in the partition */
} IoTestSize;

/* Shared sizes (present in both variants). */
#define IOTEST_SHARED_SIZES \
    X("1B",       1) \
    X("512B",     512) \
    X("1KB",      1024) \
    X("2KB",      2048) \
    X("16KB",     16384) \
    X("32KB",     32768) \
    X("64KB",     65536)

/* DSK-only last size. 800K floppy can't fit 256KB read+write files
 * alongside the other sizes, payload, and results, so the floppy
 * variant uses 128KB as its largest test. */
#define IOTEST_DSK_LAST_SIZE \
    X("128KB",    131072)

/* HDA-only large sizes (top of the test range). */
#define IOTEST_HDA_LARGE_SIZES \
    X("256KB",    262144) \
    X("512KB",    524288) \
    X("1MB",      1048576) \
    X("2MB",      2097152) \
    X("4MB",      4194304)

extern IoTestSize g_iotest_sizes[];
extern const u16 g_iotest_n_sizes;

/* I/O buffer is pinned to a fixed high address at runtime (see
 * IOBUF_BASE in diskio_main.c) instead of being a BSS array, so there
 * is no longer a single compile-time maximum. The runtime skips
 * individual tests whose length would extend past MemTop. */

#endif /* IOTEST_SIZES_H */
