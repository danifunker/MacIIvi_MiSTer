#ifndef DRIVE_ENUM_H
#define DRIVE_ENUM_H

#include "bench_types.h"

/* Drive classification. See classify_refnum() in drive_enum.c for the
 * current heuristic (refnum -5 = floppy, else SCSI). CD-ROM detection
 * is not yet wired up -- it would need the Unit Table walk to read
 * the driver name string. */
typedef enum {
    DRIVE_TYPE_FLOPPY  = 0,
    DRIVE_TYPE_SCSI    = 1,
    DRIVE_TYPE_CDROM   = 2,
    DRIVE_TYPE_UNKNOWN = 3,
} DriveType;

typedef struct {
    i16   drive_num;     /* dQDrive */
    i16   refnum;        /* dQRefNum (negative) */
    u16   fs_id;         /* dQFSID (0=HFS) */
    u32   blocks;        /* drive size in 512B blocks */
    DriveType type;
    u8    is_boot;       /* 1 = this is the boot drive */
    char  name[28];      /* HFS volume name (Pascal -> C); "" if not mounted */
} DriveInfo;

/* Walk Mac OS's DrvQHdr; fill `out` with up to `max_drives` entries.
 * Returns the count of drives found. Volume names are looked up via
 * VCBQHdr by matching dQDrive. Capped at 32 hops in case the linked
 * list is corrupt. */
int enum_drives(DriveInfo *out, int max_drives);

/* Short type label suitable for the 4-char status cell on screen. */
const char *drive_type_name(DriveType t);

/* Human-readable driver name from refnum, or NULL if unknown.
 * Known: -5 ".Sony", -33 ".SCSI", -41 ".AppleCD". */
const char *refnum_name(i16 refnum);

#endif
