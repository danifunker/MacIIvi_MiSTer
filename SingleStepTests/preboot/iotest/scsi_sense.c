/* scsi_sense.c — issue REQUEST SENSE via Mac OS SCSI Manager so that
 * a failed _Read/_Write trap can be augmented with the actual SCSI
 * sense bytes the target device returned.
 *
 * Background
 * ----------
 * The Device Manager's _Read/_Write traps translate every flavor of
 * SCSI failure into a small handful of generic Mac OS error codes
 * (ioErr -36, eofErr -39, paramErr -50, etc.). The interesting info
 * lives one layer deeper: when a SCSI target encounters trouble it
 * returns CHECK CONDITION status, and the initiator (us) issues a
 * REQUEST SENSE command to retrieve 18 bytes of sense data. The
 * three fields that matter for triage are:
 *
 *   byte 2  sense_key  -- top-level category:
 *                          0x00 no sense / 0x01 recovered error /
 *                          0x02 not ready / 0x03 medium error /
 *                          0x04 hardware error / 0x05 illegal request /
 *                          0x06 unit attention / 0x07 data protect /
 *                          0x08 blank check / 0x0B aborted command
 *   byte 12 asc        -- additional sense code (specific reason)
 *   byte 13 ascq       -- ASC qualifier (sub-reason)
 *
 * Mac OS keeps these on the SCSI bus side but doesn't surface them
 * through the Device Manager. So we go around the Device Manager and
 * talk to the SCSI Manager (trap $A801..$A815) directly. After every
 * non-zero Device Manager ioResult, the bus should be back in BUS FREE
 * phase (Device Manager already cleaned up); we can re-acquire and
 * issue the command without conflict.
 *
 * SCSI Manager call sequence for REQUEST SENSE
 * --------------------------------------------
 *   1. _SCSIGet                          -- acquire the bus
 *   2. _SCSISelect(id)                   -- select target by SCSI ID
 *   3. _SCSICmd(cdb6, 6)                 -- send the 6-byte CDB:
 *                                            03 00 00 00 12 00
 *                                            (REQUEST SENSE, alloc=18)
 *   4. _SCSIRBlind(tib)                  -- read 18 bytes via TIB
 *   5. _SCSIComplete(&status, &msg, tmo) -- wait for STATUS + MSG IN
 *
 * Each trap returns an OSErr. If any of (1)..(3) fails we abort -- the
 * bus state may be unrecoverable. We always issue _SCSIComplete after
 * _SCSIRBlind so the bus winds up in BUS FREE again for the next
 * Device Manager call. */

#include "bench_types.h"

/* Forward decl — defined in diskio_main.c since it owns iotest_setjmp /
 * iotest_longjmp / g_exc_jmpbuf. We need recovery here too because a
 * misbehaving SCSI Manager state can fault. */
typedef u32 JmpBuf[12];
extern u32  iotest_setjmp(JmpBuf *buf);
extern void iotest_longjmp(JmpBuf *buf, u32 val) __attribute__((noreturn));
extern JmpBuf g_exc_jmpbuf;

/* --- SCSI Manager trap wrappers ------------------------------------ *
 *
 * Each trap's register-level ABI is from Inside Macintosh: Devices,
 * Chapter 4 ("The SCSI Manager"). Conventions:
 *
 *   _SCSIGet      $A801   in:  -                       out: D0 = OSErr
 *   _SCSISelect   $A802   in:  D0.B = SCSI ID          out: D0 = OSErr
 *   _SCSICmd      $A803   in:  A0 = ptr to CDB         out: D0 = OSErr
 *                              D0.W = CDB length
 *   _SCSIRBlind   $A805   in:  A0 = ptr to TIB         out: D0 = OSErr
 *   _SCSIComplete $A804   in:  A0 = &status (u16)      out: D0 = OSErr
 *                              A1 = &msg (u8)
 *                              D0.L = timeout ticks    (60/sec)
 *
 * Clobbers per the SCSI Manager: D1, D2, A1 (scratch). We list them
 * conservatively. */

static i16 scsi_get(void)
{
    register i16 r asm("d0");
    asm volatile (".word 0xA801\n"
                  : "=d"(r)
                  :
                  : "d1", "d2", "a1", "cc", "memory");
    return r;
}

static i16 scsi_select(u8 scsi_id)
{
    register i16 r asm("d0") = (i16)scsi_id;
    asm volatile (".word 0xA802\n"
                  : "+d"(r)
                  :
                  : "d1", "d2", "a1", "cc", "memory");
    return r;
}

static i16 scsi_cmd(const u8 *cdb, u16 cdb_len)
{
    register i16 r asm("d0") = (i16)cdb_len;
    register const u8 *a asm("a0") = cdb;
    asm volatile (".word 0xA803\n"
                  : "+d"(r)
                  : "a"(a)
                  : "d1", "d2", "a1", "cc", "memory");
    return r;
}

static i16 scsi_rblind(const u32 *tib)
{
    register i16 r asm("d0");
    register const u32 *a asm("a0") = tib;
    asm volatile (".word 0xA805\n"
                  : "=d"(r)
                  : "a"(a)
                  : "d1", "d2", "a1", "cc", "memory");
    return r;
}

static i16 scsi_complete(u16 *out_status, u8 *out_msg, u32 timeout_ticks)
{
    register i32 d0 asm("d0") = (i32)timeout_ticks;
    register u16 *a0 asm("a0") = out_status;
    register u8  *a1 asm("a1") = out_msg;
    asm volatile (".word 0xA804\n"
                  : "+d"(d0), "+a"(a1)
                  : "a"(a0)
                  : "d1", "d2", "cc", "memory");
    return (i16)d0;
}

/* TIB opcode constants (Inside Macintosh: Devices, "Transfer
 * Instruction Blocks"). 0=scInc transfers count bytes incrementing
 * the address; 6=scStop terminates the TIB. */
#define TIB_INC   0
#define TIB_STOP  6

/* REQUEST SENSE CDB (SCSI-2 § 8.2.14):
 *
 *   bytes 0   = 0x03 (OPERATION CODE)
 *         1   = LUN<<5 | reserved
 *         2-3 = reserved
 *         4   = allocation length (max bytes target may return)
 *         5   = CONTROL byte (= 0)
 */
static const u8 g_cdb_request_sense[6] = {
    0x03, 0x00, 0x00, 0x00, 0x12, 0x00     /* alloc = 0x12 = 18 bytes */
};

/* Default SCSI ID. The Mac II boot drive is conventionally ID 0; MAME
 * places the -hard1 disk at ID 0 as well. Hardcoded for now. A future
 * version can derive the right ID from the Device Manager refnum by
 * walking the DCE (Device Control Entry) and inspecting the SCSI
 * driver's private data. */
#define SCSI_ID_DEFAULT 0u

/* Public API: issue REQUEST SENSE and fill *out_sense (18 bytes).
 * Returns 0 on success, negative OSErr on failure. On failure
 * out_sense is left zeroed -- caller can still emit it with sense_key
 * = 0 ("no sense available"). */
i16 scsi_request_sense(u8 scsi_id, u8 out_sense[18])
{
    /* TIB: read 18 bytes incrementing into out_sense, then stop. */
    u32 tib[6];
    tib[0] = TIB_INC;  tib[1] = 18;  tib[2] = (u32)out_sense;
    tib[3] = TIB_STOP; tib[4] = 0;   tib[5] = 0;

    /* Zero the buffer up front so a partial trap leaves a clean slate. */
    {
        u8 *p = out_sense;
        u32 i; for (i = 0; i < 18; i++) p[i] = 0;
    }

    i16 r = scsi_get();             if (r != 0) return r;
    r = scsi_select(scsi_id);       if (r != 0) goto cleanup;
    r = scsi_cmd(g_cdb_request_sense, 6); if (r != 0) goto cleanup;
    r = scsi_rblind(tib);
    /* Always complete the command so the bus returns to BUS FREE,
     * even if the read failed. */
cleanup:
    {
        u16 status = 0;
        u8  msg    = 0;
        (void)scsi_complete(&status, &msg, 60 /* ticks ~= 1 second */);
    }
    return r;
}

/* Recovery-wrapped variant for the bench. If the SCSI Manager itself
 * faults (vectors 2..9), the exception handler longjmps back here and
 * we return an EXC_ERR_BASE+vector synthetic code so the caller can
 * tell "sense bytes are bogus, don't trust them" apart from "sense
 * read fine but key is 0x00 = no sense". */
#define SCSI_SENSE_EXC_BASE 30000
i16 scsi_request_sense_safe(u8 scsi_id, u8 out_sense[18])
{
    u32 lj = iotest_setjmp(&g_exc_jmpbuf);
    if (lj != 0) {
        u8 *p = out_sense;
        u32 i; for (i = 0; i < 18; i++) p[i] = 0;
        return (i16)(SCSI_SENSE_EXC_BASE + lj);
    }
    return scsi_request_sense(scsi_id, out_sense);
}

/* SCSI-default ID for the bench. Exposed so future code can override
 * it without recompiling this file. */
u8 g_scsi_id_for_sense = SCSI_ID_DEFAULT;
