#ifndef SCSI_SENSE_H
#define SCSI_SENSE_H

#include "bench_types.h"

/* Public API of scsi_sense.c. See the .c file's header for the design
 * rationale and SCSI Manager call sequence. */

/* Issue REQUEST SENSE against `scsi_id`, fill 18 bytes at out_sense.
 * Returns 0 on success; negative OSErr on SCSI Manager failure;
 * (SCSI_SENSE_EXC_BASE + vector) if a 68k exception was caught while
 * driving the SCSI Manager. On any failure out_sense is left zeroed. */
i16 scsi_request_sense_safe(u8 scsi_id, u8 out_sense[18]);

/* Hardcoded default target ID for the disk under test. Currently 0
 * (Mac II convention + MAME default). Future work: derive from the
 * Device Manager refnum via DCE walk. */
extern u8 g_scsi_id_for_sense;

#endif
