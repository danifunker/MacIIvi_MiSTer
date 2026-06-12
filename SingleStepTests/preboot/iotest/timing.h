#ifndef IOTEST_TIMING_H
#define IOTEST_TIMING_H

#include "bench_types.h"

/* Microsecond-resolution timer built on VIA1 timer T2.
 *
 * VIA1 on the Mac II runs at 783360 Hz (~1.276µs per tick). T2 is a
 * 16-bit one-shot counter, so a single span can be at most ~83.7ms.
 * timer_split() must therefore be called inside any operation that
 * could exceed that — for our disk I/O tests, even a 4MB read on
 * spinning rust is well over 83ms, so we run the timer as a *chained*
 * counter: poll for underflow and accumulate into a 32-bit hi word.
 *
 * Public API:
 *   timer_start()        — arm T2 for a fresh measurement
 *   timer_elapsed_us()   — read elapsed microseconds since the last
 *                          timer_start(), accumulating any T2 wraps
 *
 * Internally the routines turn the result into microseconds by
 * multiplying by 100/127 (a close rational approximation of the
 * 1.276µs/tick conversion) so callers can report µs directly. */

void timer_start(void);
u32  timer_elapsed_us(void);

#endif /* IOTEST_TIMING_H */
