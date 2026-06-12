/* sizes.c — instantiation of g_iotest_sizes[].
 *
 * Selecting which variant is built is done via the IOTEST_VARIANT_*
 * macro (set by the Makefile). The read/write offsets start at 0 and
 * are patched in by patch_offsets.py once the image builder has placed
 * the files in the HFS partition and probed their byte offsets. */

#include "sizes.h"

/* Sentinel placed immediately before g_iotest_sizes[] so patch_offsets.py
 * can locate the table in the linked binary by grepping for these 8
 * bytes. Declared non-const so it lands in .data alongside the array
 * (which is also non-const because the patch script writes into it).
 * If this were const it would go to .rodata and the linker would split
 * marker from table, breaking the "8 bytes then table" assumption. */
char g_iotest_sizes_marker[8] = "IOSZTABL";

IoTestSize g_iotest_sizes[] = {
#define X(label_, length_) { label_, (length_), 0u, 0u },
    IOTEST_SHARED_SIZES
#ifdef IOTEST_VARIANT_HDA
    IOTEST_HDA_LARGE_SIZES
#else
    IOTEST_DSK_LAST_SIZE
#endif
#undef X
};

const u16 g_iotest_n_sizes =
    (u16)(sizeof(g_iotest_sizes) / sizeof(g_iotest_sizes[0]));
