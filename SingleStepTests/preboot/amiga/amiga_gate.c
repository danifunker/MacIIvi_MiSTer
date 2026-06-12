/* amiga_gate.c — the disks support 68030+MMU ONLY (project decision).
 *
 * Two checks, both before any test runs:
 *   1. ExecBase->AttnFlags has AFB_68030 (the OS already probed the CPU).
 *   2. A PMOVE actually executes (run under the recovery handler):
 *      an EC030 — or a TG68K build whose PMMU decode isn't wired up
 *      yet — F-line traps (vector 11) instead.
 *
 * Returns 0 = proceed; nonzero = refused (verdict painted on screen,
 * caller hangs). The results region stays empty on refusal — host-side
 * absence of the reloc header is the machine-readable signal. */

#include "bench_types.h"

extern u8  *g_amiga_execbase;
extern void install_vbr(void);
extern int  invoke_test_with_recovery(u8 *entry);
extern void paint_string(u32 row, u32 col_byte, const char *s, u32 max_chars);
extern void display_wipe(u32 rows);
extern void amiga_diag_marker(u32 slot, u32 tag);

#define ATTNFLAGS_OFF 0x128
#define AFF_68030     (1u << 2)

static u32 g_probe_scratch;
static u8  g_probe_prog[16];

int amiga_gate(void)
{
    u16 attn = *(volatile u16 *)(g_amiga_execbase + ATTNFLAGS_OFF);
    u8 *p = g_probe_prog;
    u32 dst = (u32)&g_probe_scratch;
    int vec;

    /* Recovery vectors FIRST: every disk-marker/jsonl bracket flips
     * between the OS VBR and ours, so ours must be real before any
     * bracket runs. (Idempotent — bench_main calls it again.) */
    install_vbr();

    display_wipe(480);
    paint_string(4, 4, "68030+PMMU TEST DISK (MacIIvi_MiSTer)", 40);
    amiga_diag_marker(2, 0x47415430u);   /* 'GAT0' — bracket works */

    amiga_diag_marker(4, 0x41544E00u | attn);   /* 'ATN' + flags */
    if (!(attn & AFF_68030)) {
        paint_string(16, 4, "REFUSED: this disk requires a 68030", 40);
        paint_string(24, 4, "(AttnFlags has no 68030 bit)", 40);
        return 1;
    }

    /* PMOVE TC,(abs).L ; RTS — F-lines on EC030 / missing PMMU decode */
    amiga_diag_marker(5, 0x56425249u);          /* 'VBRI' */
    *p++ = 0xF0; *p++ = 0x39;
    *p++ = 0x42; *p++ = 0x00;
    *p++ = (u8)(dst >> 24); *p++ = (u8)(dst >> 16);
    *p++ = (u8)(dst >> 8);  *p++ = (u8)dst;
    *p++ = 0x4E; *p++ = 0x75;
    /* flush icache (CACR CI|EI) — we just wrote code */
    asm volatile ("moveq #9,%%d0\n .long 0x4E7B0002\n" : : : "d0");
    vec = invoke_test_with_recovery(g_probe_prog);
    asm volatile ("move.w #0x2700, %%sr" : : : "memory");
    amiga_diag_marker(6, 0x56454300u | (u32)(vec & 0xFF));  /* 'VEC'+n */

    if (vec != 0) {
        paint_string(16, 4, "REFUSED: 68030 without working PMMU", 40);
        paint_string(24, 4, "(PMOVE took an exception)", 40);
        return 2;
    }

    paint_string(16, 4, "gate: 68030+PMMU present", 40);
    amiga_diag_marker(3, 0x47415445u);   /* 'GATE' — gate passed */
    return 0;
}
