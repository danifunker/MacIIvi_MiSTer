/* jsonl_trackdisk.c — Amiga backend for the shared JsonlWriter
 * (jsonl_writer.c compiled with -DJW_BACKEND_EXTERN).
 *
 * Writes each JW_BATCH_BYTES batch to the raw results region of the
 * boot floppy via trackdisk.device CMD_WRITE, using the IOStdReq the
 * Kickstart strap handed to the bootblock (df0:, already open, owned
 * by this very task — so its reply port signals us correctly).
 *
 * The bench runs taken-over (supervisor, SR=$2700, INTENA cleared,
 * our VBR). trackdisk needs the OS alive: its unit task must run
 * (scheduler), its DSKBLK/CIA interrupts must fire, and disk DMA must
 * be on. So each write is bracketed:
 *     INTENA := saved | master, DMACON := disk on
 *     UserState(ssp)            -> user mode, interrupts flow
 *     DoIO(CMD_WRITE), DoIO(CMD_UPDATE)
 *     ssp := SuperState(), SR := $2700, INTENA := cleared
 * Our VBR stays installed throughout: install_vbr() copied the
 * original table, so autovector entries still point at the exec
 * handlers and interrupts are serviced normally.
 *
 * The drive motor is deliberately left running between batches —
 * trackdisk would otherwise spin it up per commit (~0.5 s x several
 * hundred commits on the CPU corpus). It stops when the machine is
 * powered off; harmless in FS-UAE and on MiSTer. */

#include "bench_types.h"
#include "jsonl_writer.h"

extern void use_os_vbr(void);
extern void use_recovery_vbr(void);

extern u8 *g_amiga_ioreq;
extern u8 *g_amiga_execbase;
extern u32 g_super_ssp;
extern u16 g_saved_intena;

#define CUSTOM_INTENA  (*(volatile u16 *)0xDFF09A)
#define CUSTOM_DMACON  (*(volatile u16 *)0xDFF096)

/* IOStdReq offsets */
#define IO_COMMAND 28
#define IO_ERROR   31
#define IO_LENGTH  36
#define IO_DATA    40
#define IO_OFFSET  44
#define CMD_WRITE  3
#define CMD_UPDATE 4

#define LVO_DoIO       (-456)
#define LVO_SuperState (-150)
#define LVO_UserState  (-156)

static void do_io(void)
{
    register u8 *a1 asm("a1") = g_amiga_ioreq;
    register u8 *a6 asm("a6") = g_amiga_execbase;
    asm volatile (
        "jsr    -456(%%a6)"            /* DoIO */
        : "+r" (a1), "+r" (a6)
        :
        : "a0", "d0", "d1", "cc", "memory");
}

static void enter_user(void)
{
    register u32 d0 asm("d0") = g_super_ssp;
    register u8 *a6 asm("a6") = g_amiga_execbase;
    asm volatile (
        "jsr    -156(%%a6)"            /* UserState */
        : "+r" (d0), "+r" (a6)
        :
        : "a0", "a1", "d1", "cc", "memory");
}

static void enter_super(void)
{
    register u32 d0 asm("d0");
    register u8 *a6 asm("a6") = g_amiga_execbase;
    asm volatile (
        "jsr    -150(%%a6)"            /* SuperState */
        : "=r" (d0), "+r" (a6)
        :
        : "a0", "a1", "d1", "cc", "memory");
    g_super_ssp = d0;
    asm volatile ("move.w #0x2700, %%sr" : : : "memory");
}

/* Diagnostic: write a stamped 512-byte sector to the tail of the
 * results region (slot 0 = 0xD8000, bootblock crumb; 1 = entry crumb;
 * 2+ = ours) using the SAME takeover bracket as the writer — so a
 * missing marker pinpoints a broken bracket, not just a broken bench. */
static u8 g_diag_buf[512];
void amiga_diag_marker(u32 slot, u32 tag)
{
    u32 i;
    u8 *io = g_amiga_ioreq;
    for (i = 0; i < 512; i += 4) {
        g_diag_buf[i]   = (u8)(tag >> 24);
        g_diag_buf[i+1] = (u8)(tag >> 16);
        g_diag_buf[i+2] = (u8)(tag >> 8);
        g_diag_buf[i+3] = (u8)tag;
    }
    use_os_vbr();
    CUSTOM_INTENA = (u16)(0xC000 | g_saved_intena);
    CUSTOM_DMACON = 0x8210;
    enter_user();
    *(volatile u16 *)(io + IO_COMMAND) = CMD_WRITE;
    *(volatile u32 *)(io + IO_DATA)    = (u32)g_diag_buf;
    *(volatile u32 *)(io + IO_LENGTH)  = 512;
    *(volatile u32 *)(io + IO_OFFSET)  = 0xD8000u + slot * 0x200u;
    do_io();
    *(volatile u16 *)(io + IO_COMMAND) = CMD_UPDATE;
    *(volatile u32 *)(io + IO_LENGTH)  = 0;
    do_io();
    enter_super();
    CUSTOM_INTENA = 0x7FFF;
    use_recovery_vbr();
}

i16 jw_backend_write(const JwCtx *ctx, u32 batch_idx, const u8 *buf)
{
    u8 *io = g_amiga_ioreq;
    i16 err;

    /* let the OS breathe: the OS's own FULL vector table back in
     * place (exec reaches supervisor mode by deliberately faulting,
     * so every exception vector must be the OS's during OS calls),
     * interrupts + disk DMA on, drop to user mode */
    use_os_vbr();
    CUSTOM_INTENA = (u16)(0xC000 | g_saved_intena);   /* SET|INTEN|saved */
    CUSTOM_DMACON = 0x8210;                           /* SET|MASTER|DISK */
    enter_user();

    *(volatile u16 *)(io + IO_COMMAND) = CMD_WRITE;
    *(volatile u32 *)(io + IO_DATA)    = (u32)buf;
    *(volatile u32 *)(io + IO_LENGTH)  = JW_BATCH_BYTES;
    *(volatile u32 *)(io + IO_OFFSET)  =
        ctx->base_offset + batch_idx * JW_BATCH_BYTES;
    do_io();
    err = (i16)(signed char)*(volatile u8 *)(io + IO_ERROR);

    if (err == 0) {
        *(volatile u16 *)(io + IO_COMMAND) = CMD_UPDATE;  /* flush track */
        *(volatile u32 *)(io + IO_LENGTH)  = 0;
        do_io();
        err = (i16)(signed char)*(volatile u8 *)(io + IO_ERROR);
    }

    /* take the machine back */
    enter_super();
    CUSTOM_INTENA = 0x7FFF;
    use_recovery_vbr();
    return err;
}
