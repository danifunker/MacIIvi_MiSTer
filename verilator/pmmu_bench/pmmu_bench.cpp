// Focused standalone testbench for TG68K_PMMU_030.
//
// Goal: reproduce + diagnose the MacLCii boot Sad Mac, which is a PMMU
// mistranslation of the 32-bit ROM alias during the 24->32-bit MMU mode switch.
//
// MAME oracle (the CORRECT walk):
//   TC = $80F84500  (E=1, PS=$F=32K, IS=8, TIA=4, TIB=5, TIC=TID=0)
//   CRP -> root table; root[10] = 7FFFFC19 (HIGH) / 00A00000 (LOW), DT=01
//          long-format early-termination page descriptor, page base $00A00000
//   translate $40A0010E  (FC=6 supervisor program, read/insn fetch)
//     -> IS=8 strips $40 -> $A0010E
//     -> TIA index = bits[23:20] = $A = root[10] (early term)
//     -> physical $00A0010E   (folds low 20 bits into base $00A00000)
//
// TG68 (HW) mistranslates this to high-RAM ~$9FExxx -> derail -> Sad Mac.
//
// This bench drives the PMMU module directly: PMOVE-equivalent register
// writes, a descriptor-memory model, then a translation request, capturing
// the full walk (wstate trail + descriptor reads + final addr_phys).

#include <verilated.h>
#include "VTG68K_PMMU_030.h"

#include <cstdio>
#include <cstdint>
#include <map>
#include <vector>
#include <string>

static VTG68K_PMMU_030* top = nullptr;
vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

// ---- descriptor memory model -------------------------------------------
// The walker reads 32-bit longwords via mem_req/mem_addr -> mem_rdat/mem_ack.
static std::map<uint32_t, uint32_t> g_mem;   // addr -> longword
static uint32_t g_mem_default = 0xDEADBEEFu;  // sentinel for unexpected reads
static bool g_trace_mem = true;

static uint32_t mem_lookup(uint32_t a) {
    a &= ~3u;
    auto it = g_mem.find(a);
    return it == g_mem.end() ? g_mem_default : it->second;
}

// One clock with combinational descriptor-memory service.
// reg_sel encodings (brief 14:10): TT0=00010 TT1=00011 TC=10000 SRP=10010 CRP=10011 MMUSR=11000
static const char* wstate_name(unsigned s) {
    static const char* names[] = {
        "IDLE","ROOT","ROOT_LOW","PTR1","PTR1_LOW","PTR2","PTR2_LOW","PTR3",
        "PTR3_LOW","PTR4","PTR4_LOW","INDIRECT","INDIRECT_LOW","PAGE",
        "TABLE_UPDATE","UPDATE_DESC","PLOAD_FLUSH","FILL","COMPLETE","FAULT"};
    return (s < sizeof(names)/sizeof(names[0])) ? names[s] : "?";
}

static void eval() { top->eval(); }

static void tick(bool trace=false) {
    // Drive descriptor memory combinationally off mem_req/mem_addr.
    top->clk = 0; eval();
    // Service walker memory request (present data + ack while req asserted).
    if (top->mem_req) {
        if (top->mem_we) {
            // descriptor U/M writeback
            g_mem[top->mem_addr & ~3u] = top->mem_wdat;
            if (g_trace_mem)
                printf("    [memW] addr=%08X <= %08X\n", top->mem_addr, top->mem_wdat);
        } else {
            top->mem_rdat = mem_lookup(top->mem_addr);
            if (g_trace_mem)
                printf("    [memR] addr=%08X => %08X\n", top->mem_addr, top->mem_rdat);
        }
        top->mem_ack = 1;
    } else {
        top->mem_ack = 0;
    }
    eval();
    top->clk = 1; eval();
    main_time++;
    if (trace) {
        printf("  t=%-4llu wstate=%-9s busy=%u req=%u memreq=%u memaddr=%08X "
               "addr_phys=%08X fault=%u\n",
               (unsigned long long)main_time, wstate_name(top->debug_wstate),
               top->busy, top->req, top->mem_req, top->mem_addr,
               top->addr_phys, top->fault);
    }
}

static void reg_write(unsigned sel, uint32_t val, unsigned part, unsigned fd=0) {
    top->reg_sel  = sel;
    top->reg_wdat = val;
    top->reg_part = part;
    top->reg_fd   = fd;
    top->reg_we   = 1;
    tick();
    top->reg_we   = 0;
    top->reg_re   = 0;
    tick();
}

// Run one translation; return final addr_phys. Traces the walk.
static uint32_t translate(uint32_t addr_log, unsigned fc, unsigned rw,
                          unsigned is_insn, const char* label) {
    printf("--- translate %s: addr_log=%08X fc=%u rw=%u is_insn=%u\n",
           label, addr_log, fc, rw, is_insn);
    top->addr_log = addr_log;
    top->fc       = fc;
    top->rw       = rw;
    top->is_insn  = is_insn;
    top->rmw      = 0;
    top->req      = 1;
    // Run until the walk completes: busy must rise then fall, then settle.
    bool saw_busy = false;
    uint32_t phys = 0;
    int idle_after = 0;
    for (int i = 0; i < 400; ++i) {
        tick(true);
        if (top->busy) saw_busy = true;
        bool done = (saw_busy && !top->busy && top->debug_wstate == 0);
        if (done) { if (++idle_after >= 3) break; } else idle_after = 0;
    }
    phys = top->addr_phys;
    printf("    => addr_phys=%08X  fault=%u  (saw_busy=%d)\n",
           phys, top->fault, saw_busy);
    top->req = 0;
    tick(); tick();
    return phys;
}

static void reset_dut() {
    top->nreset = 0; top->cpu_reset = 1;
    top->reg_we = 0; top->reg_re = 0; top->reg_sel = 0; top->reg_wdat = 0;
    top->reg_part = 0; top->reg_fd = 0;
    top->ptest_req = 0; top->pflush_req = 0; top->pload_req = 0;
    top->pmmu_fc = 0; top->pmmu_addr = 0; top->pmmu_brief = 0;
    top->req = 0; top->is_insn = 0; top->rw = 1; top->rmw = 0; top->fc = 0;
    top->addr_log = 0; top->mem_ack = 0; top->mem_berr = 0; top->mem_rdat = 0;
    top->mmu_config_ack = 0; top->mmudis = 0;
    for (int i = 0; i < 16; ++i) tick();
    top->nreset = 1; top->cpu_reset = 0;
    for (int i = 0; i < 4; ++i) tick();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    top = new VTG68K_PMMU_030;

    // ============ Scenario 1: clean fresh walk of the 32-bit alias ========
    // Exactly the MAME oracle inputs. Expect phys = $00A0010E.
    reset_dut();
    g_mem.clear();
    // 10M layout: CRP table base $9FE820, root[10] @ $9FE870.
    g_mem[0x009FE870] = 0x7FFFFC19;  // root[10] HIGH (DT=01 early-term page)
    g_mem[0x009FE874] = 0x00A00000;  // root[10] LOW  (page base)

    printf("==== Scenario 1: fresh clean walk of $40A0010E (oracle inputs) ====\n");
    reg_write(0b10000, 0x80F84500, 0);          // TC
    reg_write(0b10011, 0x7FFF0003, 1);          // CRP HIGH (limit=7FFF, DT=11 long table)
    reg_write(0b10011, 0x009FE820, 0);          // CRP LOW  (root table base)
    printf("debug_tc=%08X debug_crp_hi=%08X debug_crp_lo=%08X tc_enable=%u\n",
           top->debug_tc, top->debug_crp_hi, top->debug_crp_lo, top->tc_enable);

    uint32_t p1 = translate(0x40A0010E, 6, 1, 1, "jmp alias");
    uint32_t exp1 = 0x00A0010E;
    printf("\nRESULT S1: got %08X expected %08X  %s\n\n", p1, exp1,
           p1==exp1 ? "PASS" : "*** FAIL (mistranslation reproduced) ***");

    // ============ Scenario 2: the 24-bit bsr target ($A41B8E) ============
    printf("==== Scenario 2: fresh clean walk of $00A41B8E (24-bit) ====\n");
    uint32_t p2 = translate(0x00A41B8E, 6, 1, 1, "bsr target 24-bit");
    uint32_t exp2 = 0x00A41B8E;
    printf("\nRESULT S2: got %08X expected %08X  %s\n\n", p2, exp2,
           p2==exp2 ? "PASS" : "*** FAIL ***");

    // ============ Scenario 3: boot-faithful order (TC written LAST) ======
    // The boot sets CRP earlier, then `pmove (A3),tc` at $A416B2, then
    // immediately `jmp (A5)`. So TC is the last reg write before the fetch,
    // with minimal settling. Test that ordering with a minimal gap.
    printf("==== Scenario 3: boot order (CRP first, TC last, immediate xlate) ====\n");
    reset_dut();
    g_mem.clear();
    g_mem[0x009FE870] = 0x7FFFFC19;
    g_mem[0x009FE874] = 0x00A00000;
    reg_write(0b10011, 0x7FFF0003, 1);          // CRP HIGH
    reg_write(0b10011, 0x009FE820, 0);          // CRP LOW
    reg_write(0b10000, 0x80F84500, 0);          // TC (last)
    uint32_t p3 = translate(0x40A0010E, 6, 1, 1, "alias after TC-last");
    printf("\nRESULT S3: got %08X expected %08X  %s\n\n", p3, exp1,
           p3==exp1 ? "PASS" : "*** FAIL (reproduced) ***");

    // ============ Scenario 4: stale ATC across TC reconfiguration ========
    // Before the switch the MMU is ON with an old TC; the ATC holds entries.
    // Then `pmove tc` reconfigures (should flush ATC), then translate alias.
    printf("==== Scenario 4: populate ATC, reconfig TC, translate alias ====\n");
    reset_dut();
    g_mem.clear();
    // Old 24-bit-ish identity-ish table also at $9FE820 root[10] early-term,
    // but mapping to a DIFFERENT base so a stale hit would be visible.
    g_mem[0x009FE870] = 0x7FFFFC19;
    g_mem[0x009FE874] = 0x00A00000;
    // Old TC: same geometry. Populate ATC by translating a couple addresses.
    reg_write(0b10011, 0x7FFF0003, 1);
    reg_write(0b10011, 0x009FE820, 0);
    reg_write(0b10000, 0x80F84500, 0);
    translate(0x40A04000, 6, 1, 1, "prime ATC #1");
    translate(0x00A08000, 6, 1, 1, "prime ATC #2");
    printf("  [ATC primed; debug_atc_valid=%08X]\n", top->debug_atc_valid);
    // Now reconfigure TC (same value) -> should flush ATC, then translate alias
    reg_write(0b10000, 0x80F84500, 0);
    uint32_t p4 = translate(0x40A0010E, 6, 1, 1, "alias after reconfig");
    printf("\nRESULT S4: got %08X expected %08X  %s\n\n", p4, exp1,
           p4==exp1 ? "PASS" : "*** FAIL (reproduced) ***");

    top->final();
    delete top;
    int fails = (p1!=exp1) + (p2!=exp2) + (p3!=exp1) + (p4!=exp1);
    printf("==== DONE: %d failure(s) ====\n", fails);
    return 0;
}
