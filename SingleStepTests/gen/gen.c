/*
 * Test corpus generator — uses Musashi as the reference oracle.
 *
 * For each opcode in a configurable list, generates N random test cases:
 *   1. Randomize CPU registers and a small operand RAM window.
 *   2. Place the encoded instruction at a fixed PC.
 *   3. Run Musashi for one instruction.
 *   4. Emit pre/post state as JSON (state-only schema; see SCHEMA.md).
 *
 * Usage: gen <out_dir> [seed]
 *
 * First slice: ADD.l Dx,Dy only. Builds out from there once the bench can
 * consume the format.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <inttypes.h>

#include "m68k.h"

/* ---------- 16 MiB flat RAM backing Musashi -------------------------- */
#define RAM_BYTES (1u << 24)
static uint8_t g_ram[RAM_BYTES];

static inline uint8_t  rd8(unsigned a)  { return g_ram[a & (RAM_BYTES - 1)]; }
static inline uint16_t rd16(unsigned a) {
    a &= (RAM_BYTES - 1);
    return ((uint16_t)g_ram[a] << 8) | g_ram[(a + 1) & (RAM_BYTES - 1)];
}
static inline uint32_t rd32(unsigned a) {
    return ((uint32_t)rd16(a) << 16) | rd16(a + 2);
}
static inline void wr8(unsigned a, uint8_t v)  { g_ram[a & (RAM_BYTES - 1)] = v; }
static inline void wr16(unsigned a, uint16_t v) {
    wr8(a, v >> 8); wr8(a + 1, v & 0xFF);
}
static inline void wr32(unsigned a, uint32_t v) {
    wr16(a, v >> 16); wr16(a + 2, v & 0xFFFF);
}

/* Musashi memory callbacks -------------------------------------------
 *
 * When the bench is generating "run one instruction" snapshots we want
 * to stop the CPU the moment fetching crosses past the test instruction
 * boundary. g_stop_below_pc is set to the address of the byte JUST AFTER
 * the test instruction. Any immediate fetch at >= that address ends the
 * timeslice. */
static uint32_t g_stop_below_pc = 0xFFFFFFFFu;
extern void m68k_end_timeslice(void);

unsigned int m68k_read_memory_8 (unsigned int a)  { return rd8(a); }
unsigned int m68k_read_memory_16(unsigned int a)  {
    if (a >= g_stop_below_pc) m68k_end_timeslice();
    return rd16(a);
}
unsigned int m68k_read_memory_32(unsigned int a)  {
    if (a >= g_stop_below_pc) m68k_end_timeslice();
    return rd32(a);
}
unsigned int m68k_read_immediate_8 (unsigned int a) {
    if (a >= g_stop_below_pc) m68k_end_timeslice();
    return rd8(a);
}
unsigned int m68k_read_immediate_16(unsigned int a) {
    if (a >= g_stop_below_pc) m68k_end_timeslice();
    return rd16(a);
}
unsigned int m68k_read_immediate_32(unsigned int a) {
    if (a >= g_stop_below_pc) m68k_end_timeslice();
    return rd32(a);
}
unsigned int m68k_read_pcrelative_8 (unsigned int a) { return rd8(a); }
unsigned int m68k_read_pcrelative_16(unsigned int a) { return rd16(a); }
unsigned int m68k_read_pcrelative_32(unsigned int a) { return rd32(a); }
unsigned int m68k_read_disassembler_8 (unsigned int a) { return rd8(a); }
unsigned int m68k_read_disassembler_16(unsigned int a) { return rd16(a); }
unsigned int m68k_read_disassembler_32(unsigned int a) { return rd32(a); }
void m68k_write_memory_8 (unsigned int a, unsigned int v) { wr8(a, v); }
void m68k_write_memory_16(unsigned int a, unsigned int v) { wr16(a, v); }
void m68k_write_memory_32(unsigned int a, unsigned int v) { wr32(a, v); }

/* ---------- Tiny seeded RNG (xorshift32) ----------------------------- */
static uint32_t g_rng = 0xC0FFEE01;
static uint32_t r32(void) {
    uint32_t x = g_rng;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return g_rng = x;
}

/* ---------- Test-state snapshot ------------------------------------- */
typedef struct {
    uint32_t d[8], a[8];
    uint32_t pc, sr, usp, ssp, vbr;
} cpu_state_t;

static void snap(cpu_state_t* s) {
    for (int i = 0; i < 8; ++i) s->d[i] = m68k_get_reg(NULL, M68K_REG_D0 + i);
    for (int i = 0; i < 8; ++i) s->a[i] = m68k_get_reg(NULL, M68K_REG_A0 + i);
    s->pc  = m68k_get_reg(NULL, M68K_REG_PC);
    s->sr  = m68k_get_reg(NULL, M68K_REG_SR);
    s->usp = m68k_get_reg(NULL, M68K_REG_USP);
    s->ssp = m68k_get_reg(NULL, M68K_REG_ISP);
    s->vbr = m68k_get_reg(NULL, M68K_REG_VBR);
}

/* ---------- JSON emission ------------------------------------------- */
static void emit_regs(FILE* f, const cpu_state_t* s, const char* indent) {
    fprintf(f, "%s\"d0\":%u,\"d1\":%u,\"d2\":%u,\"d3\":%u,",
            indent, s->d[0], s->d[1], s->d[2], s->d[3]);
    fprintf(f, "\"d4\":%u,\"d5\":%u,\"d6\":%u,\"d7\":%u,\n",
            s->d[4], s->d[5], s->d[6], s->d[7]);
    fprintf(f, "%s\"a0\":%u,\"a1\":%u,\"a2\":%u,\"a3\":%u,",
            indent, s->a[0], s->a[1], s->a[2], s->a[3]);
    fprintf(f, "\"a4\":%u,\"a5\":%u,\"a6\":%u,\"a7\":%u,\n",
            s->a[4], s->a[5], s->a[6], s->a[7]);
    fprintf(f, "%s\"pc\":%u,\"sr\":%u,\"usp\":%u,\"ssp\":%u,\"vbr\":%u",
            indent, s->pc, s->sr, s->usp, s->ssp, s->vbr);
}

/* Emit ram_pre as an array of [addr,byte] for every nonzero byte in the
 * operand window. ram_post emits ONLY bytes that differ from ram_pre. */
typedef struct { uint32_t lo, hi; } window_t;

static void emit_ram_initial(FILE* f, const window_t* w) {
    fprintf(f, "[");
    int first = 1;
    for (uint32_t a = w->lo; a < w->hi; ++a) {
        if (g_ram[a] == 0) continue;
        fprintf(f, "%s[%u,%u]", first ? "" : ",", a, g_ram[a]);
        first = 0;
    }
    fprintf(f, "]");
}

static void emit_ram_diff(FILE* f, const window_t* w,
                          const uint8_t* pre, const uint8_t* post) {
    fprintf(f, "[");
    int first = 1;
    for (uint32_t a = w->lo; a < w->hi; ++a) {
        if (pre[a] == post[a]) continue;
        fprintf(f, "%s[%u,%u]", first ? "" : ",", a, post[a]);
        first = 0;
    }
    fprintf(f, "]");
}

/* ---------- One test: ADD.l Dx,Dy ----------------------------------- */
/* Encoding: 1101 ddd 1 10 000 sss → $D080 | (dst<<9) | src
 * (opmode 110 = .L Dn,Dn with src in mode 0 reg sss). */
static uint16_t encode_add_l_dn_dn(int dst, int src) {
    return 0xD080 | ((dst & 7) << 9) | (src & 7);
}

static void gen_add_l(FILE* f, int count) {
    const uint32_t PC = 0x1000;
    const window_t win = { PC, PC + 16 };  /* opcode lives here */

    fprintf(f, "[\n");
    for (int i = 0; i < count; ++i) {
        /* Random src/dst regs (no overlap rule needed for ADD.l Dn,Dn). */
        int src = r32() & 7, dst = r32() & 7;
        uint16_t op = encode_add_l_dn_dn(dst, src);

        /* Place opcode + landing-pad NOP at PC. Plant reset vectors so
         * that pulse_reset() (which reads SSP from $0 and PC from $4)
         * lands us at PC with a clean prefetch state. */
        memset(g_ram, 0, RAM_BYTES);
        wr32(0, 0x00FFFFF8);   /* SSP */
        wr32(4, PC);           /* PC after reset */
        wr16(PC, op);
        wr16(PC + 2, 0x4E71);  /* NOP landing pad */
        m68k_pulse_reset();

        for (int r = 0; r < 8; ++r) {
            m68k_set_reg(M68K_REG_D0 + r, r32());
            /* keep A7 alone (pulse_reset set it from SSP); randomize A0..A6 */
            if (r < 7) m68k_set_reg(M68K_REG_A0 + r, r32() & 0x00FFFFFE);
        }
        m68k_set_reg(M68K_REG_SR, 0x2000);  /* supervisor, no T/I */

        static uint8_t ram_pre[RAM_BYTES];
        cpu_state_t pre;
        snap(&pre);
        memcpy(ram_pre, g_ram, RAM_BYTES);

        /* ADD.l Dn,Dn is a 2-byte op. The fetch at PC+2 is the next
         * instruction's opword — that's our cue to stop. */
        g_stop_below_pc = PC + 2;
        int cyc = m68k_execute(100);
        g_stop_below_pc = 0xFFFFFFFFu;
        (void)cyc;

        cpu_state_t post;
        snap(&post);
        /* Musashi's reported PC is 2 bytes ahead due to prefetch
         * lookahead (the m68k_end_timeslice fires on the next fetch).
         * Normalize to the architectural post-instruction PC. */
        post.pc = PC + 2;  /* ADD.l Dn,Dn is 2 bytes */

        if (i > 0) fprintf(f, ",\n");
        fprintf(f, "  {\n");
        fprintf(f, "    \"name\":\"ADD.l D%d,D%d #%05d\",\n", src, dst, i);
        fprintf(f, "    \"initial\":{\n");
        emit_regs(f, &pre, "      ");
        fprintf(f, ",\n      \"ram\":");
        emit_ram_initial(f, &win);
        fprintf(f, "\n    },\n");
        fprintf(f, "    \"final\":{\n");
        emit_regs(f, &post, "      ");
        fprintf(f, ",\n      \"ram\":");
        emit_ram_diff(f, &win, ram_pre, g_ram);
        fprintf(f, "\n    }\n");
        fprintf(f, "  }");
    }
    fprintf(f, "\n]\n");
}

/* ---------------------------------------------------------------------- */
int main(int argc, char** argv) {
    const char* outdir = (argc > 1) ? argv[1] : ".";
    if (argc > 2) g_rng = (uint32_t)strtoul(argv[2], NULL, 0);

    m68k_init();
    m68k_set_cpu_type(M68K_CPU_TYPE_68030);
    m68k_pulse_reset();

    char path[512];
    snprintf(path, sizeof(path), "%s/ADD.l.json", outdir);
    FILE* f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    gen_add_l(f, 10);
    fclose(f);
    printf("Wrote %s (10 tests, seed=0x%08X)\n", path, g_rng);
    return 0;
}
