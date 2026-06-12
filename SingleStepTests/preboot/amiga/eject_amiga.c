/* eject_amiga.c — stub for the Mac .Sony eject the shared runners call
 * at shutdown. No-op on Amiga (the operator pops the disk). */
#include "bench_types.h"
i16 eject_floppy(i16 drive) { (void)drive; return 0; }
