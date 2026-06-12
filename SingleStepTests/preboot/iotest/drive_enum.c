/* drive_enum.c -- walk Mac OS's Drive Queue and Volume Control Block
 * queue to enumerate every online drive the ROM knows about, so the
 * bench can paint a "DRIVES" table at startup. Operator can then see
 * the topology at a glance and tell which drive the bench is reading
 * from / writing to vs. which other drives are sitting idle.
 *
 * Mac OS low-mem globals we read:
 *
 *   DrvQHdr  ($0308)  -- queue header: qFlags(w) qHead(l) qTail(l)
 *                        qHead at $030A points to the first DrvQEl.
 *
 *   VCBQHdr  ($0356)  -- same layout, points to first VCB.
 *
 *   BootDrive ($0210) -- drive# we booted from (so we can flag it
 *                        with '*' in the table).
 *
 * DrvQEl layout (Inside Macintosh: Devices, "The Drive Queue"):
 *
 *   +0   qLink     (long)   next entry, or 0 = end of list
 *   +4   qType     (word)   0 = no dQDrvSz2; 1 = dQDrvSz2 present
 *   +6   dQDrive   (word)   drive number
 *   +8   dQRefNum  (word)   driver refnum (negative)
 *   +A   dQFSID    (word)   filesystem ID (0=HFS, others=MFS/foreign)
 *   +C   dQDrvSz   (word)   drive size: low 16 bits, in 512B blocks
 *   +E   dQDrvSz2  (word)   drive size: high 16 bits (qType==1 only)
 *
 *   Total drive size in blocks = dQDrvSz | (dQDrvSz2 << 16) when
 *   qType==1, else just dQDrvSz (drives <= 32 MB).
 *
 * VCB layout (Inside Macintosh: Files, "Volume Control Block"):
 *
 *   +0   qLink     (long)
 *   +4   qType     (word)
 *   +6   vcbFlags  (word)
 *   ...
 *   +44  vcbVN     (28-byte Pascal string: length byte + up to 27
 *                   name chars). Volume name as the user sees it
 *                   in the Finder.
 *   +72  vcbDrvNum (word)   drive number this volume sits on -- key
 *                           we use to match VCB <-> DrvQEl.
 *   ...
 *
 * Driver class (floppy / SCSI / CD-ROM / etc.) ideally comes from
 * the driver's name string via the Unit Table:
 *
 *   UTableBase  ($011C, long)  pointer to driver handle table
 *   index = ~refnum - 1
 *   *(UTableBase + index*4) = DCtlHandle (handle to DCE)
 *   DCE has dCtlDriver (handle/ptr to DRVR header)
 *   DRVR header offset +18 = driver name (Pascal string, e.g. ".Sony")
 *
 * That's three dereferences + a handle-to-pointer step (the high
 * bit of dCtlFlags decides whether dCtlDriver is a handle or a
 * direct pointer). For the first cut we use a simpler heuristic:
 * refnum -5 = .Sony floppy; anything else assumed SCSI. CD-ROM
 * (.AppleCD) detection would need the Unit Table walk and is left
 * as a follow-up. */

#include "bench_types.h"
#include "drive_enum.h"

/* Low-mem global pointers we treat as constants. */
#define DRVQHDR_QHEAD   (*(volatile u32 *)0x0000030A)
#define VCBQHDR_QHEAD   (*(volatile u32 *)0x00000358)
#define BOOTDRIVE       (*(volatile i16 *)0x00000210)

/* DrvQEl field offsets. */
#define DQE_QLINK       0
#define DQE_QTYPE       4
#define DQE_DRIVE       6
#define DQE_REFNUM      8
#define DQE_FSID        10
#define DQE_DRVSZ       12
#define DQE_DRVSZ2      14

/* VCB field offsets. */
#define VCB_QLINK       0
#define VCB_VN          44       /* 28-byte Pascal string */
#define VCB_DRVNUM      72

static u16 rd_w(u32 addr) { return *(volatile u16 *)addr; }
static i16 rd_i16(u32 addr) { return *(volatile i16 *)addr; }
static u32 rd_l(u32 addr) { return *(volatile u32 *)addr; }

/* Copy a Pascal string (length byte + chars) at `src` into `dst` as a
 * NUL-terminated C string, capped at dst_max-1 chars. */
static void pstr_to_cstr(char *dst, u32 dst_max, u32 src_addr)
{
    u32 len = *(volatile u8 *)src_addr;
    if (len >= dst_max) len = dst_max - 1;
    u32 i;
    for (i = 0; i < len; i++) {
        dst[i] = *(volatile char *)(src_addr + 1 + i);
    }
    dst[len] = '\0';
}

/* Walk VCBQHdr looking for a VCB whose vcbDrvNum matches `drive`.
 * Returns the volume name as a C string into `out_name` (or "" if
 * no mounted volume on that drive). Caller passes a buffer >= 28
 * bytes. */
static void find_volume_name(i16 drive, char *out_name, u32 out_max)
{
    out_name[0] = '\0';
    u32 vcb = rd_l(0x00000356 + 2);   /* VCBQHdr.qHead at $0358 */
    /* Sanity hop counter so a corrupt list doesn't hang us. */
    u32 hops = 0;
    while (vcb != 0 && hops < 32) {
        if ((i16)rd_w(vcb + VCB_DRVNUM) == drive) {
            pstr_to_cstr(out_name, out_max, vcb + VCB_VN);
            return;
        }
        vcb = rd_l(vcb + VCB_QLINK);
        hops++;
    }
}

/* Refnum -> drive type. Mac II standard Unit Table assignments:
 *   -5  = .Sony (floppy)
 *   -33 = .SCSI (Apple HD SC / SCSI disk driver)
 *   -41 = .AppleCD (CD-ROM driver)
 * Everything else is unknown; label it "SCSI" as a safe default
 * since most non-floppy drives on a Mac II are SCSI. */
static DriveType classify_refnum(i16 refnum)
{
    if (refnum == -5)  return DRIVE_TYPE_FLOPPY;
    if (refnum == -41) return DRIVE_TYPE_CDROM;
    return DRIVE_TYPE_SCSI;
}

const char *refnum_name(i16 refnum)
{
    switch (refnum) {
        case  -5: return ".Sony";
        case -33: return ".SCSI";
        case -41: return ".AppleCD";
        default:  return 0;
    }
}

int enum_drives(DriveInfo *out, int max_drives)
{
    int n = 0;
    i16 boot_drive = BOOTDRIVE;
    u32 dqe = rd_l(0x0000030A);   /* DrvQHdr.qHead */
    u32 hops = 0;

    while (dqe != 0 && n < max_drives && hops < 32) {
        DriveInfo *d = &out[n];
        u16 qtype = rd_w(dqe + DQE_QTYPE);
        d->drive_num = rd_i16(dqe + DQE_DRIVE);
        d->refnum    = rd_i16(dqe + DQE_REFNUM);
        d->fs_id     = rd_w (dqe + DQE_FSID);
        d->blocks    = rd_w (dqe + DQE_DRVSZ);
        if (qtype == 1) {
            d->blocks |= ((u32)rd_w(dqe + DQE_DRVSZ2)) << 16;
        }
        d->type      = classify_refnum(d->refnum);
        d->is_boot   = (d->drive_num == boot_drive);
        d->name[0]   = '\0';
        n++;
        dqe = rd_l(dqe + DQE_QLINK);
        hops++;
    }
    return n;
}

const char *drive_type_name(DriveType t)
{
    switch (t) {
        case DRIVE_TYPE_FLOPPY:  return "FLP ";
        case DRIVE_TYPE_SCSI:    return "SCSI";
        case DRIVE_TYPE_CDROM:   return "CD  ";
        default:                 return "?   ";
    }
}
