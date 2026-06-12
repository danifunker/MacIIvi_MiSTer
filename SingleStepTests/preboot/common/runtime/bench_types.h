#ifndef BENCH_TYPES_H
#define BENCH_TYPES_H

typedef unsigned char  u8;
typedef unsigned short u16;
typedef unsigned long  u32;
typedef signed   short i16;
typedef signed   long  i32;

/* Layout matches cpu_test_macii.c's Snapshot — diff_corpus.py reads
 * the same fields. CCR is captured as 0x00 (zero-ext) followed by
 * the 1-byte CCR.
 *
 * Supervisor variant adds SR (full 16-bit) which is intentionally
 * zero on the user-mode bench. Also adds exception_taken / vector
 * for raises_exception tests. */
typedef struct {
    u32 d[8];                    /* 0x00 */
    u32 a[8];                    /* 0x20 */
    u8  ccr_high;                /* 0x40 */
    u8  ccr;                     /* 0x41 */
    u16 sr;                      /* 0x42 */
    u8  ram[64];                 /* 0x44 -- CPU_SCRATCH_LEN bytes */
    u32 exception_vector;        /* 0x84 -- 0 if none */
    u32 exception_taken;         /* 0x88 -- 0 / 1 */
} Snapshot;

#endif
