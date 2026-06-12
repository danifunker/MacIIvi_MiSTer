/* timing.c — VIA1 T2 microsecond-resolution timer.
 *
 * Implementation notes
 * --------------------
 * VIA1 on the Mac II runs at 6 MHz / 10 = 783360 Hz, so 1 tick ≈
 * 1.2766µs. T2 is a 16-bit one-shot: writing the high byte (T2C-H)
 * latches both bytes, arms the counter at 0xFFFF, and starts counting
 * down toward 0. The IFR T2 bit is set when T2 underflows; we use that
 * (rather than polling for 0xFFFF→0xFFFF transitions) to count wraps.
 *
 * For each measurement we:
 *   1. Disable T2 interrupts at the VIA IER so we can poll IFR safely.
 *   2. Load T2C-H = 0xFF to start a fresh 0xFFFF countdown.
 *   3. Remember the start; on read, snapshot T2 and accumulate any
 *      pending IFR wraps into a 32-bit composite.
 *   4. Convert (tick_count) to microseconds via the closed-form
 *      tick_count * 100 / 127  (≈ tick_count * 0.7874, the reciprocal
 *      of 1.2766, ×100 to keep the math integer-only). Accuracy is
 *      ~0.1%, which is well below the SCSI bus jitter we care about. */

#include "timing.h"

/* VIA1 register base + offsets (Mac II). Each register is at an even
 * byte address; the chip's internal stride is 0x200 between regs. */
#define VIA1_BASE   0x00EFE1FE  /* fictitious — actual Mac II VIA1 is 0xEFE1FE */
/* Real Mac II VIA1 base is $50F00000; first register at $50F00000 (vBufB).
 * Each register is at offset 0x200 (the lower address lines aren't
 * decoded by the VIA chip, so each register lives in a 512-byte slot). */
#undef VIA1_BASE
#define VIA1_BASE   0x50F00000

/* Register offsets — selected ones we need. */
#define VIA1_T2CL   (VIA1_BASE + 0x200 * 8)   /* T2 counter low  */
#define VIA1_T2CH   (VIA1_BASE + 0x200 * 9)   /* T2 counter high */
#define VIA1_IER    (VIA1_BASE + 0x200 * 14)  /* interrupt enable */
#define VIA1_IFR    (VIA1_BASE + 0x200 * 13)  /* interrupt flag   */
#define VIA1_ACR    (VIA1_BASE + 0x200 * 11)  /* auxiliary control */

#define IER_T2      0x20

/* High word of accumulated wraps since last timer_start(). */
static u32 g_wrap_count;
/* T2 value right after timer_start() — used to compute elapsed without
 * suffering a wrap-edge race. With T2 starting at 0xFFFF, this is
 * effectively always 0xFFFF, but we read it so the math is general. */
static u16 g_start_t2;

static inline u8 r8(u32 a)         { return *(volatile u8 *)a; }
static inline void w8(u32 a, u8 v) { *(volatile u8 *)a = v;    }

void timer_start(void)
{
    /* Put T2 in one-shot (ACR bit 5 clear) — Mac II already keeps the
     * VIA in this mode by default, but be explicit. Bits 7:6 (T1) and
     * bits 4:2 (shift) are left untouched. */
    u8 acr = r8(VIA1_ACR);
    acr &= ~0x20;
    w8(VIA1_ACR, acr);

    /* Mask the T2 interrupt so we can poll IFR.T2 without the CPU
     * being yanked into the VIA handler. */
    w8(VIA1_IER, IER_T2);  /* bit7=0 means CLEAR these bits */

    g_wrap_count = 0;
    /* Writing T2C-H latches T2C-L (already 0xFF) and starts the
     * countdown. We pre-load 0xFF then 0xFF so T2 = 0xFFFF. */
    w8(VIA1_T2CL, 0xFF);
    w8(VIA1_T2CH, 0xFF);
    /* Clear any pending T2 wrap flag from a prior measurement. */
    w8(VIA1_IFR, IER_T2);
    g_start_t2 = 0xFFFF;
}

/* Read T2 (low then high) and merge with the wrap counter. Note the
 * order: reading T2C-L *clears* the IFR T2 flag, so we must check IFR
 * BEFORE the read or we'll lose a wrap. */
static u32 read_ticks_since_start(void)
{
    /* Drain any pending wraps that happened since the last call. */
    while (r8(VIA1_IFR) & IER_T2) {
        g_wrap_count++;
        w8(VIA1_IFR, IER_T2);
    }
    u8  lo = r8(VIA1_T2CL);  /* this read clears IFR.T2 — but we just drained */
    u8  hi = r8(VIA1_T2CH);
    u16 t2 = ((u16)hi << 8) | lo;
    /* If a wrap fired between draining and the read, we'll see IFR.T2
     * set again — fold it in. Single retry is sufficient because T2
     * takes 65536 ticks (~83ms) to wrap. */
    if (r8(VIA1_IFR) & IER_T2) {
        g_wrap_count++;
        w8(VIA1_IFR, IER_T2);
        lo = r8(VIA1_T2CL);
        hi = r8(VIA1_T2CH);
        t2 = ((u16)hi << 8) | lo;
    }
    /* Ticks elapsed = wraps × 65536 + (start_t2 − current_t2). */
    u32 elapsed = (u32)(g_start_t2 - t2);
    elapsed += (u32)g_wrap_count << 16;
    return elapsed;
}

u32 timer_elapsed_us(void)
{
    u32 ticks = read_ticks_since_start();
    /* ticks * 100 / 127 ≈ ticks * 0.7874 ≈ ticks * 1.2766µs / 1µs.
     * 32-bit safe up to ticks ≈ 42M (≈ 54 seconds), well above any
     * single test we run. */
    return (ticks * 100u) / 127u;
}
