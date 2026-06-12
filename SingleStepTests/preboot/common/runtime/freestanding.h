#ifndef FREESTANDING_H
#define FREESTANDING_H

/* Tiny stdlib substitutes — we link with -nostdlib and have no libc. */

#include "bench_types.h"

/* memcpy/memset are provided as global non-inline symbols in
 * freestanding.c so gcc-emitted implicit calls can resolve. */
void *memset(void *dst, int c, u32 n);
void *memcpy(void *dst, const void *src, u32 n);

static inline void *f_memset(void *dst, int c, u32 n) {
    u8 *p = (u8 *)dst;
    while (n--) *p++ = (u8)c;
    return dst;
}

static inline void *f_memcpy(void *dst, const void *src, u32 n) {
    u8 *d = (u8 *)dst;
    const u8 *s = (const u8 *)src;
    while (n--) *d++ = *s++;
    return dst;
}

static inline u32 f_strlen(const char *s) {
    const char *p = s;
    while (*p) p++;
    return (u32)(p - s);
}

/* Append the decimal representation of an unsigned long to *p, return
 * the new tail. Caller ensures at least 11 bytes of headroom. */
static inline char *f_putul(char *p, u32 v) {
    char buf[11];
    int n = 0;
    if (v == 0) { *p++ = '0'; return p; }
    while (v) { buf[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n--) *p++ = buf[n];
    return p;
}

#endif
