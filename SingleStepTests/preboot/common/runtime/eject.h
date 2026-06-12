#ifndef PREBOOT_EJECT_H
#define PREBOOT_EJECT_H

#include "bench_types.h"

/* Eject the floppy in `drive` via the .Sony driver (refnum -5) using a
 * Device Manager _Control call (csCode 7). Best-effort: returns the
 * trap's ioResult but callers typically ignore it. Only meaningful on
 * a floppy-booted run; harmless to call with a non-floppy drive number
 * (the .Sony driver simply reports an error for an unknown drive). */
i16 eject_floppy(i16 drive);

#endif /* PREBOOT_EJECT_H */
