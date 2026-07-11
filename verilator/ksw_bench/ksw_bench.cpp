// Kernel-level mode-switch micro-reproduction.
//
// Plants a tiny supervisor program that mirrors the boot derail:
//   enable MMU (early-term identity table) -> reconfig TC (pmove) -> jmp alias.
// Then checks whether the jmp-target fetch ($40A0010E) translates to the
// correct physical $00A0010E, or derails like the HW Sad Mac.
//
// Bus model: 16 MiB RAM. Services the CPU 16-bit bus (addr_out/busstate) AND
// the PMMU walker 32-bit bus (pmmu_walker_*). clkena pulses every clk; the
// kernel internally parks (busstate=01) while the PMMU walk runs.

#include <verilated.h>
#include "Vksw_top.h"
#include <cstdio>
#include <cstdint>
#include <vector>
#include <string>

static Vksw_top* top = nullptr;
vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

static std::vector<uint8_t> ram;  // 16 MiB physical

static constexpr uint8_t BS_FETCH = 0b00, BS_IDLE = 0b01, BS_READ = 0b10, BS_WRITE = 0b11;

static inline uint16_t r16(uint32_t a){ a&=0xFFFFFE; return (uint16_t(ram[a])<<8)|ram[a+1]; }
static inline uint32_t r32(uint32_t a){ a&=0xFFFFFC; return (uint32_t(ram[a])<<24)|(ram[a+1]<<16)|(ram[a+2]<<8)|ram[a+3]; }
static inline void w16(uint32_t a,uint16_t v,bool u,bool l){ a&=0xFFFFFE; if(u)ram[a]=v>>8; if(l)ram[a+1]=v&0xFF; }
static inline void w8(uint32_t a,uint8_t v){ ram[a&0xFFFFFF]=v; }
static inline void wl(uint32_t a,uint32_t v){ w8(a,v>>24); w8(a+1,v>>16); w8(a+2,v>>8); w8(a+3,v); }

static bool g_trace=false;

static void service_buses() {
    // CPU 16-bit bus
    uint8_t bs = top->busstate;
    uint32_t a = top->addr_out;
    if (bs==BS_FETCH || bs==BS_READ) top->data_in = r16(a);
    else if (bs==BS_WRITE) w16(a, top->data_write, !top->nUDS, !top->nLDS);
    // PMMU walker 32-bit bus
    if (top->pmmu_walker_req) {
        if (top->pmmu_walker_we) { wl(top->pmmu_walker_addr, top->pmmu_walker_wdat); }
        else { top->pmmu_walker_data = r32(top->pmmu_walker_addr); }
        top->pmmu_walker_ack = 1;
    } else top->pmmu_walker_ack = 0;
}

static void tick() {
    top->clk = 0; top->eval();
    // Gate clkena like tg68k.v: suppress while the PMMU walker borrows the bus
    // (pmmu_busy), so the CPU pipeline does not advance during a table walk.
    top->clkena_in = (top->busy_out || top->pmmu_walker_req) ? 0 : 1;
    service_buses();
    top->eval();
    top->clk = 1; top->eval();
    main_time++;
    service_buses();   // keep walker data/ack stable across the edge
    top->eval();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc>1 && std::string(argv[1])=="-v") g_trace=true;
    top = new Vksw_top;
    ram.assign(0x01000000, 0x00);

    // ---- Reset vectors ----
    wl(0x0, 0x00010000);   // SSP
    wl(0x4, 0x00001000);   // PC

    // ---- Program @ $1000 (identity-mapped: physical == logical) ----
    uint32_t p = 0x1000;
    auto emit=[&](std::initializer_list<uint8_t> b){ for(uint8_t x:b) ram[p++]=x; };
    emit({0x2A,0x7C,0x40,0xA0,0x01,0x0E});             // movea.l #$40A0010E,A5
    emit({0xF0,0x39,0x4C,0x00,0x00,0x00,0x19,0x00});   // pmove ($1900).L,CRP
    emit({0xF0,0x39,0x40,0x00,0x00,0x00,0x19,0x08});   // pmove ($1908).L,TC  (E=1 -> MMU ON)
    emit({0x4E,0x71});                                  // nop
    emit({0x4E,0x71});                                  // nop
    emit({0xF0,0x39,0x40,0x00,0x00,0x00,0x19,0x08});   // pmove ($1908).L,TC  RECONFIG (glitch)
    emit({0x4E,0xD5});                                  // jmp (A5)  -> fetch $40A0010E

    // ---- Fault catcher @ $1800: stop ----
    ram[0x1800]=0x4E; ram[0x1801]=0x72; ram[0x1802]=0x27; ram[0x1803]=0x00;  // stop #$2700
    // also drop a marker before stop so we can tell a fault happened
    // (put marker write first): move.l #$DEAD0000,($2004).L ; stop
    {
        uint32_t q=0x1808;
        uint8_t code[]={0x23,0xFC,0xDE,0xAD,0x00,0x00,0x00,0x00,0x20,0x04, 0x4E,0x72,0x27,0x00};
        for(unsigned i=0;i<sizeof(code);++i) ram[q+i]=code[i];
    }
    // point all exception vectors (2..255) at the fault catcher $1808
    for (uint32_t v=2; v<256; ++v) wl(v*4, 0x00001808);

    // ---- CRP/TC operands ----
    wl(0x1900, 0x7FFF0003);   // CRP high: limit $7FFF, DT=3 (long table)
    wl(0x1904, 0x00003000);   // CRP low : root table base $3000
    wl(0x1908, 0x80F84500);   // TC: E=1 PS=32K IS=8 TIA=4 TIB=5

    // ---- Root table @ $3000: 16 long-format early-term identity descriptors ----
    for (uint32_t i=0; i<16; ++i) {
        wl(0x3000 + i*8 + 0, 0x7FFFFC19);          // HIGH: DT=01 early-term, U/M set
        wl(0x3000 + i*8 + 4, 0x00000000 | (i<<20));// LOW : page base $00i00000
    }

    // ---- Target @ $00A0010E (where $40A0010E should translate) ----
    // Trivial self-loop so we can confirm the jmp landed + executes without
    // depending on a complex longword-write instruction.
    { ram[0x00A0010E]=0x60; ram[0x00A0010F]=0xFE; }   // bra.s . (loop at $00A0010E)

    // ---- Reset ----
    top->reset=1; top->data_in=0; top->pmmu_walker_ack=0; top->pmmu_walker_data=0;
    for(int i=0;i<32;++i) tick();
    top->reset=0;

    // ---- Run, tracing bus + PMMU state ----
    bool mmu_on=false; uint32_t last_log=0xFFFFFFFF; int jmp_seen=0;
    uint32_t alias_phys=0; bool alias_fetched=false;
    int last_activity=0;
    for (int cyc=0; cyc<200000; ++cyc) {
        tick();
        uint8_t bs=top->busstate;
        if (g_trace && top->pmmu_walker_req) {
            printf("  t=%-6llu [WALK] req addr=%08X we=%u data=%08X ack=%u bs=%u tc_en=%u pc=%08X\n",
                (unsigned long long)main_time, top->pmmu_walker_addr, top->pmmu_walker_we,
                top->pmmu_walker_data, top->pmmu_walker_ack, bs, top->tc_en_out, top->pc_out);
            last_activity=cyc;
        }
        if (bs!=BS_IDLE) {
            last_activity=cyc;
            uint32_t log=top->pmmu_addr_log, phys=top->pmmu_addr_phys, ao=top->addr_out;
            bool changed = (top->pc_out!=last_log);
            // Always log fetches/accesses to the alias or target region, plus tc_en edges
            bool interesting = (log==0x40A0010E)||((log&0xFFF00000)==0x40A00000)||
                               ((ao&0xFFFFFF00)==0x00A00100)||((log&0xFFFFFF00)==0x00A00100);
            if (top->tc_en_out && !mmu_on){ mmu_on=true; if(g_trace) printf("  [MMU ON] t=%llu pc=%08X\n",(unsigned long long)main_time, top->pc_out); }
            if (interesting || g_trace) {
                printf("  t=%-6llu bs=%u fc=%u log=%08X phys=%08X addr_out=%08X tc_en=%u grace=%u pc=%08X wreq=%u waddr=%08X%s\n",
                    (unsigned long long)main_time, bs, top->fc, log, phys, ao, top->tc_en_out, top->grace_out, top->pc_out,
                    top->pmmu_walker_req, top->pmmu_walker_addr,
                    (log==0x40A0010E && bs==BS_FETCH)?"  <<< JMP TARGET FETCH":"");
            }
            if (log==0x40A0010E && bs==BS_FETCH){ if(!alias_fetched){alias_fetched=true; alias_phys=ao;} jmp_seen++; }
        }
        // success: the self-loop target executed (alias fetched repeatedly)
        if (jmp_seen>=4){ printf("  [SUCCESS: self-loop target executing, %d fetches of $40A0010E]\n", jmp_seen); break; }
        if (r32(0x2004)==0xDEAD0000u){ printf("  [FAULT catcher hit @ $1808]\n"); break; }
        if (mmu_on && cyc-last_activity > 1000){
            printf("  [STALL: no bus/walker activity for >1000 cyc; bs=%u walker_req=%u waddr=%08X tc_en=%u pc=%08X]\n",
                top->busstate, top->pmmu_walker_req, top->pmmu_walker_addr, top->tc_en_out, top->pc_out);
            break;
        }
    }

    printf("\n==== RESULT ====\n");
    printf("alias $40A0010E fetched: %s, addr_out(physical)=%08X (expected 00A0010E), jmp_seen=%d\n",
           alias_fetched?"yes":"NO", alias_phys, jmp_seen);
    bool ok = alias_fetched && alias_phys==0x00A0010E && jmp_seen>=4;
    printf("%s\n", ok ? "PASS: mode switch translated alias correctly + target executes"
                      : "*** FAIL: derail/stall ***");
    top->final(); delete top;
    return ok?0:1;
}
