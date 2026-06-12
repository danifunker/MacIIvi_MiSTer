#ifndef SCSI_PROBE_H
#define SCSI_PROBE_H

#include "bench_types.h"

/* Read all 8 NCR5380 registers via MMIO into a caller-provided buffer.
 * Bypasses every Mac OS driver layer; suitable for use while the .Scsi
 * driver is wedged. See scsi_probe.c for the full register map. */
void scsi_read_ncr5380(u8 out[8]);

/* Format an 8-register dump as a 23-char "XX XX XX XX XX XX XX XX"
 * hex string into the caller's 24-byte buffer. No trailing NUL. */
void scsi_fmt_ncr5380(char dst[24], const u8 regs[8]);

/* Read + format in one call. Caller-provided 24-byte buffer. */
void scsi_probe_format(char dst[24]);

#endif
