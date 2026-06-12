/* scsi_probe.c -- read the NCR5380 SCSI controller's 8 registers
 * directly via MMIO, bypassing every Mac OS driver layer.
 *
 * Why
 * ---
 * When the FPGA's SCSI implementation misbehaves, the _Read/_Write
 * traps tend to crash to a Sad Mac with vector 10 (line-A trap),
 * because the .Scsi driver internally takes another A-line call that
 * the dispatcher can't handle. By the time the Sad Mac fires, the
 * screen is wiped and we've lost the failure context.
 *
 * This probe sidesteps the entire trap chain: we read the 8 NCR5380
 * registers as plain 8-bit MMIO bytes at $50F1_0000 + (reg << 4) and
 * paint them on screen BEFORE the trap fires. If the trap then
 * Sad-Mac's, you've already seen the pre-trap bus state visually
 * and (more importantly) you can compare hardware vs MAME runs of
 * the same bench to see what differs in the FPGA's controller
 * behaviour.
 *
 * Register map (NCR5380, read side)
 * ---------------------------------
 *   0  CDR  Current SCSI Data       -- whatever's on the bus data lines
 *   1  ICR  Initiator Command Reg   -- RST/ATN/BSY/SEL/ACK/DBSEL bits we drive
 *   2  MR   Mode Register           -- DMA enable, arbitration, monitor flags
 *   3  TCR  Target Command Register -- target-mode phase outputs (unused as init)
 *   4  CSR  Current SCSI Bus Status -- live bus state: REQ/MSG/CD/IO/BSY/SEL/RST/ATN
 *   5  BSR  Bus & Status Register   -- EOP, GROSS_ERR, PARITY_ERR, IRQ, PHASE_MATCH...
 *   6  IDR  Input Data Register     -- PDMA receive latch
 *   7  RST  Reset Parity/Interrupts -- reading clears IRQ; data is don't-care
 *
 * The 4 and 5 readouts are usually the most diagnostic: they show what
 * the controller actually sees on the bus, independent of what Mac OS
 * thinks is going on. A stuck phase (e.g. BSY=1, REQ never asserting)
 * or a parity error fires here, even if the driver hangs blind.
 *
 * Address base
 * ------------
 * Mac II places the NCR5380 at physical $50F1_0000 with each register
 * at a 16-byte stride (the FPGA core's addrDecoder.v decodes A4..A6
 * for the 3-bit register select; address bit A9 is the DMA-handshake
 * flag and must be 0 for plain register access).
 */

#include "bench_types.h"
#include "scsi_probe.h"

#define NCR5380_BASE   0x50F10000u
#define NCR5380_REG(n) (NCR5380_BASE + (((u32)(n)) << 4))

void scsi_read_ncr5380(u8 out[8])
{
    /* Read each register as a byte. Cast through volatile so the
     * compiler doesn't try to combine the reads or skip them on the
     * (mistaken) assumption that they're plain RAM. */
    u32 i;
    for (i = 0; i < 8; i++) {
        out[i] = *(volatile u8 *)NCR5380_REG(i);
    }
}

/* Format an 8-register dump as "00 11 22 33 44 55 66 77 " into dst.
 * Writes exactly 24 chars (23 of dump + a trailing space so paint_string
 * with max_chars=24 doesn't render an uninitialized 25th cell). No NUL. */
void scsi_fmt_ncr5380(char dst[24], const u8 regs[8])
{
    static const char hex[16] = "0123456789ABCDEF";
    u32 i, p = 0;
    for (i = 0; i < 8; i++) {
        dst[p++] = hex[(regs[i] >> 4) & 0xF];
        dst[p++] = hex[ regs[i]       & 0xF];
        if (i < 7) dst[p++] = ' ';
    }
    dst[23] = ' ';   /* trailing pad so paint_string can render 24 cells cleanly */
}

/* Convenience: read + format in one call. */
void scsi_probe_format(char dst[24])
{
    u8 regs[8];
    scsi_read_ncr5380(regs);
    scsi_fmt_ncr5380(dst, regs);
}
