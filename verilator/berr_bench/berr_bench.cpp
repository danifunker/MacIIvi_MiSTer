// BERR continue-past micro-reproduction (Mac OS ROM $A0DB50/$A0DB5C idiom).
//
// Covers the probe forms the 7.x ROM validators actually use, now with CCR
// (arch flag) checks — a real 68030 replays the faulted read from the
// handler-stuffed DIB, which sets flags for TST/BTST too:
//   #1 move.l ($3c,A6),D0   (d16,An)->Dn, 4 bytes  (ROM $A0DC0C)  -> D0 = DIB
//   #2 movea.l (A1),A0      (An)->An,     2 bytes  (ROM $A0DB92)  -> A0 = DIB
//   #3 tst.b (A0)   DIB=-1  -> resume + CCR: N=1 Z=0
//   #4 btst #6,(A0) DIB=-1  -> resume + CCR: Z=0, N preserved
//   #6 tst.b (A0)   DIB=0   -> resume + CCR: Z=1 N=0
//   #7 btst #6,(A0) DIB=0   -> resume + CCR: Z=1, N and C preserved
//   #5 move.l abs.L,D0      6 bytes, resume-PC stress (kept LAST: run sentinel)
//
// Each probe reads through a bad pointer ($Exxxxx) -> external BERR -> a
// byte-exact ROM temp handler clears SSW.DF (+$0A) + stuffs the DIB (+$2C) +
// RTE. The 030 must resume at the NEXT instruction with the read's arch effect
// (dest register and/or CCR) taken from the DIB. Before each CCR probe the
// flags are forced to the OPPOSITE of the expected result (moveq), so a
// stale-CCR continue-past (the 7.1 wrong-validator-verdict bug) skips the
// flags marker while the resume marker still lands.
// PASS = every resume marker + every flags marker + no derail + 7 BERRs.
//
// Bus model: 16 MiB RAM; $E00000-$EFFFFF raises berr (hold-until-make_berr).

#include <verilated.h>
#include "Vberr_top.h"
#include <cstdio>
#include <cstdint>
#include <vector>
#include <string>

static Vberr_top* top = nullptr;
vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

static std::vector<uint8_t> ram;
static bool g_trace = false;
static bool berr_pend = false;
static int  walk_delay = 0;      // -w N: PMMU walker ack latency in ticks (race hunting)
static int  wcnt = 0;

static constexpr uint8_t BS_FETCH = 0b00, BS_IDLE = 0b01, BS_READ = 0b10, BS_WRITE = 0b11;

static inline uint16_t r16(uint32_t a){ a&=0xFFFFFE; return (uint16_t(ram[a])<<8)|ram[a+1]; }
static inline uint32_t r32(uint32_t a){ a&=0xFFFFFC; return (uint32_t(ram[a])<<24)|(ram[a+1]<<16)|(ram[a+2]<<8)|ram[a+3]; }
static inline void w16(uint32_t a,uint16_t v,bool u,bool l){ a&=0xFFFFFE; if(u)ram[a]=v>>8; if(l)ram[a+1]=v&0xFF; }
static inline void wl(uint32_t a,uint32_t v){ ram[a&0xFFFFFF]=v>>24; ram[(a+1)&0xFFFFFF]=(v>>16)&0xFF; ram[(a+2)&0xFFFFFF]=(v>>8)&0xFF; ram[(a+3)&0xFFFFFF]=v&0xFF; }
static inline bool bad_addr(uint32_t a){ return (a & 0xFFFFFF) >= 0xE00000 && (a & 0xFFFFFF) < 0xF00000; }

static int  mberr_edges = 0, fixw_edges = 0;
static bool mberr_d=false, fixw_d=false;

static void service_buses() {
    uint8_t bs = top->busstate;
    uint32_t a = top->addr_out;
    bool bad = bad_addr(a);
    static uint32_t last_vecrd = 0xFFFFFFFF;
    if (bs==BS_READ && (a&0xFFFFFF) < 0x400 && a != last_vecrd) {
        printf("  t=%-7llu [VECRD] addr=%06X (vector %d) -> %08X\n",
               (unsigned long long)main_time, a&0xFFFFFF, (a&0x3FF)>>2, r32(a&~3u));
        last_vecrd = a;
    }
    static bool armed13 = false; static int wlog = 0;
    if (bs==BS_FETCH && (a & 0xFFFFFF) == 0xFFFC) { armed13 = true; wlog = 0; }
    if (bs==BS_FETCH || bs==BS_READ) top->data_in = bad ? 0xDEAD : r16(a);
    else if (bs==BS_WRITE && !bad) {
        if (armed13 && wlog < 16) {       // every write after the bsr opcode fetch
            ++wlog;
            printf("  t=%-7llu [WR13] addr=%08X data=%04X uds=%d lds=%d pc=%08X\n",
                   (unsigned long long)main_time, a, top->data_write,
                   !top->nUDS, !top->nLDS, top->pc_out);
        }
        w16(a, top->data_write, !top->nUDS, !top->nLDS);
    }
    if ((bs==BS_READ || bs==BS_WRITE || bs==BS_FETCH) && bad) berr_pend = true;
    if (top->make_berr_out || top->trap_berr_out) berr_pend = false;
    top->berr = berr_pend ? 1 : 0;
    if (top->pmmu_walker_req) {
        if (wcnt > 0) { wcnt--; top->pmmu_walker_ack = 0; }
        else {
            if (top->pmmu_walker_we) wl(top->pmmu_walker_addr, top->pmmu_walker_wdat);
            else top->pmmu_walker_data = r32(top->pmmu_walker_addr);
            top->pmmu_walker_ack = 1;
            wcnt = walk_delay;        // reload latency for the next walk beat
        }
    } else { top->pmmu_walker_ack = 0; wcnt = walk_delay; }
}

static void tick() {
    top->clk = 0; top->eval();
    // Conservative stall model: clkena frozen for the whole translation.
    // NOTE: this is NOT the real tg68k.v pacing (sparse s_state-7 clkena
    // pulses + walk_cycle suppression), so walk-interleave timing bugs (the
    // probe #13 bsr push race) do NOT reproduce faithfully here — the FULL
    // Vemu sim is the arbiter for those. A walker-req-only gate breaks the
    // raw kernel (no wrapper bus pacing); do not "fix" it that way again.
    top->clkena_in = (top->busy_out || top->pmmu_walker_req) ? 0 : 1;
    service_buses(); top->eval();
    top->clk = 1; top->eval(); main_time++;
    service_buses(); top->eval();
    if (top->make_berr_out && !mberr_d) {
        ++mberr_edges;
        printf("  t=%-7llu [BERR#%d] pc=%08X cap_op=%04X nextpc=%08X (->resume %08X) boundary=%08X exe=%08X\n",
               (unsigned long long)main_time, mberr_edges, top->pc_out,
               top->cap_op_out, top->nextpc_out, top->nextpc_out - 2,
               top->boundary_pc_out, top->exe_pc_out);
    }
    mberr_d = top->make_berr_out;
    static bool trap_d = false;
    if (top->trap_berr_out && !trap_d) {
        printf("  t=%-7llu [TRAP2] pc=%08X addr=%08X bs=%d\n",
               (unsigned long long)main_time, top->pc_out, top->addr_out, top->busstate);
    }
    trap_d = top->trap_berr_out;
    if (top->fix_write_out && !fixw_d) {
        ++fixw_edges;
        printf("  t=%-7llu [FIXWRITE#%d] frame_pc=%08X opcode=%04X ssw=%04X dib=%08X\n",
               (unsigned long long)main_time, fixw_edges, top->frame_pc_out,
               top->fix_opcode_out, top->fix_ssw_out, top->fix_dib_out);
    }
    fixw_d = top->fix_write_out;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    for (int i=1;i<argc;++i) {
        if (std::string(argv[i])=="-v") g_trace=true;
        else if (std::string(argv[i])=="-w" && i+1<argc) walk_delay = atoi(argv[++i]);
    }
    wcnt = walk_delay;
    top = new Vberr_top;
    ram.assign(0x01000000, 0x00);

    wl(0x0, 0x00010000);   // SSP
    wl(0x4, 0x00001000);   // PC

    // fault catcher (all vectors except 2) -> marks $2004 and stops
    { uint32_t q=0x1900;
      uint8_t code[]={0x23,0xFC,0xDE,0xAD,0x00,0x00,0x00,0x00,0x20,0x04, 0x4E,0x72,0x27,0x00};
      for(unsigned i=0;i<sizeof(code);++i) ram[q+i]=code[i]; }
    for (uint32_t v=2; v<256; ++v) wl(v*4, 0x00001900);

    // ---- Program @ $1000 ----
    uint32_t p = 0x1000;
    auto emit=[&](std::initializer_list<uint8_t> b){ for(uint8_t x:b) ram[p++]=x; };
    // handler v1 (DIB=0) for the MOVE probes; v2 (DIB=-1) for the first tst/btst pair
    emit({0x41,0xF8,0x20,0x00});             // lea $2000.w,A0   (handler v1)
    emit({0x21,0xC8,0x00,0x08});             // move.l A0,$8.w
    emit({0x21,0xCF,0x30,0x50});             // move.l A7,$3050.w  (A7 BEFORE all probes)
    // --- probe #13b: SAME boundary-bsr geometry but MMU OFF (pure-boundary control) ---
    emit({0x4E,0xF9,0x00,0x02,0xFF,0xF8});   // jmp ($2FFF8).L  (bsr.w at $2FFFC -> return $30000)
    uint32_t cont13b = p;
    // probe #1: move.l ($3c,A6),D0
    emit({0x4D,0xF9,0x00,0xE0,0x00,0x00});   // lea $E00000,A6
    emit({0x70,0x5A});                       // moveq #$5A,D0
    emit({0x20,0x2E,0x00,0x3C});             // move.l ($3c,A6),D0
    emit({0x31,0xFC,0xAA,0xAA,0x30,0x00});   // move.w #$AAAA,$3000.w  marker1
    emit({0x21,0xC0,0x30,0x04});             // move.l D0,$3004.w
    // probe #2: movea.l (A1),A0
    emit({0x43,0xF9,0x00,0xE0,0x00,0x40});   // lea $E00040,A1
    emit({0x20,0x51});                       // movea.l (A1),A0
    emit({0x31,0xFC,0xBB,0xBB,0x30,0x08});   // move.w #$BBBB,$3008.w  marker2
    // install handler v2 (DIB=-1) for tst/btst pair one
    emit({0x41,0xF8,0x20,0x10});             // lea $2010.w,A0
    emit({0x21,0xC8,0x00,0x08});             // move.l A0,$8.w
    // probe #3: tst.b (A0), DIB=-1 -> N=1 Z=0. Pre-force Z=1,N=0 (stale trap).
    emit({0x20,0x7C,0x00,0xE0,0x00,0x80});   // movea.l #$E00080,A0
    emit({0x72,0x00});                       // moveq #0,D1        (Z=1,N=0)
    emit({0x4A,0x10});                       // tst.b (A0)          $4A10
    emit({0x67,0x08});                       // beq.s +8   (stale Z=1 -> skip flags marker)
    emit({0x6A,0x06});                       // bpl.s +6   (N must be 1)
    emit({0x31,0xFC,0xCC,0x77,0x30,0x18});   // move.w #$CC77,$3018.w  flags marker3f
    emit({0x31,0xFC,0xCC,0xCC,0x30,0x0C});   // move.w #$CCCC,$300C.w  resume marker3
    // probe #4: btst #$6,(A0), DIB=-1 -> Z=0, N preserved 0. Pre-force Z=1,N=0.
    emit({0x20,0x7C,0x00,0xE0,0x00,0xC0});   // movea.l #$E000C0,A0
    emit({0x72,0x00});                       // moveq #0,D1        (Z=1,N=0)
    emit({0x08,0x10,0x00,0x06});             // btst #$6,(A0)       $0810 $0006
    emit({0x67,0x08});                       // beq.s +8   (stale Z=1 -> skip)
    emit({0x6B,0x06});                       // bmi.s +6   (N must stay 0)
    emit({0x31,0xFC,0xDD,0x77,0x30,0x1C});   // move.w #$DD77,$301C.w  flags marker4f
    emit({0x31,0xFC,0xDD,0xDD,0x30,0x10});   // move.w #$DDDD,$3010.w  resume marker4
    // re-install handler v1 (DIB=0) for tst/btst pair two
    emit({0x41,0xF8,0x20,0x00});             // lea $2000.w,A0
    emit({0x21,0xC8,0x00,0x08});             // move.l A0,$8.w
    // probe #6: tst.b (A0), DIB=0 -> Z=1 N=0. Pre-force Z=0,N=0.
    emit({0x20,0x7C,0x00,0xE0,0x01,0x40});   // movea.l #$E00140,A0
    emit({0x72,0x01});                       // moveq #1,D1        (Z=0,N=0)
    emit({0x4A,0x10});                       // tst.b (A0)
    emit({0x66,0x08});                       // bne.s +8   (Z must be 1)
    emit({0x6B,0x06});                       // bmi.s +6   (N must be 0)
    emit({0x31,0xFC,0x11,0x77,0x30,0x24});   // move.w #$1177,$3024.w  flags marker6f
    emit({0x31,0xFC,0x11,0x11,0x30,0x20});   // move.w #$1111,$3020.w  resume marker6
    // probe #7: btst #$6,(A0), DIB=0 -> Z=1, N stays 1, C stays 1 (btst preserves
    // everything but Z; catches a MOVE-rule CCR misapplied to btst).
    emit({0x20,0x7C,0x00,0xE0,0x01,0x80});   // movea.l #$E00180,A0
    emit({0x72,0xFF});                       // moveq #-1,D1       (N=1,Z=0,V=0,C=0)
    emit({0x00,0x3C,0x00,0x01});             // ori.b #1,CCR       (C=1)
    emit({0x08,0x10,0x00,0x06});             // btst #$6,(A0)
    emit({0x66,0x0A});                       // bne.s +10  (Z must be 1)
    emit({0x6A,0x08});                       // bpl.s +8   (N must STAY 1)
    emit({0x64,0x06});                       // bcc.s +6   (C must STAY 1)
    emit({0x31,0xFC,0x22,0x77,0x30,0x2C});   // move.w #$2277,$302C.w  flags marker7f
    emit({0x31,0xFC,0x22,0x22,0x30,0x28});   // move.w #$2222,$3028.w  resume marker7
    // --- v6 EA-mode-widening probes (all DIB=0 handler v1, still installed) ---
    // probe #8: move.l abs.L,Dn -> writeback + MOVE CCR for mode 111
    emit({0x74,0x33});                       // moveq #$33,D2      (poison dest)
    emit({0x24,0x39,0x00,0xE0,0x02,0x00});   // move.l $E00200.L,D2 -> D2=0, Z=1, N=0
    emit({0x66,0x08});                       // bne.s +8   (Z must be 1)
    emit({0x6B,0x06});                       // bmi.s +6   (N must be 0)
    emit({0x31,0xFC,0x33,0x77,0x30,0x38});   // move.w #$3377,$3038.w  flags marker8f
    emit({0x21,0xC2,0x30,0x30});             // move.l D2,$3030.w      (expect 00000000)
    emit({0x31,0xFC,0x33,0x33,0x30,0x34});   // move.w #$3333,$3034.w  resume marker8
    // probe #9: tst.b abs.L (CCR only, mode 111)
    emit({0x72,0x01});                       // moveq #1,D1        (Z=0,N=0)
    emit({0x4A,0x39,0x00,0xE0,0x02,0x40});   // tst.b $E00240.L    -> Z=1, N=0
    emit({0x66,0x08});                       // bne.s +8
    emit({0x6B,0x06});                       // bmi.s +6
    emit({0x31,0xFC,0x44,0x77,0x30,0x40});   // move.w #$4477,$3040.w  flags marker9f
    emit({0x31,0xFC,0x44,0x44,0x30,0x3C});   // move.w #$4444,$303C.w  resume marker9
    // probe #10: move.b (d8,An,Xn),Dn -> writeback + CCR for mode 110
    emit({0x70,0x00});                       // moveq #0,D0        (index reg = 0)
    emit({0x78,0x5A});                       // moveq #$5A,D4      (poison dest)
    emit({0x18,0x36,0x00,0x10});             // move.b ($10,A6,D0.w),D4  A6=$E00000 -> $E00010; DIB=0 -> D4=0
    emit({0x66,0x08});                       // bne.s +8   (Z must be 1: byte 00)
    emit({0x6B,0x06});                       // bmi.s +6   (N must be 0)
    emit({0x31,0xFC,0x55,0x77,0x30,0x48});   // move.w #$5577,$3048.w  flags marker10f
    emit({0x21,0xC4,0x30,0x4C});             // move.l D4,$304C.w      (expect 00000000)
    emit({0x31,0xFC,0x55,0x55,0x30,0x44});   // move.w #$5555,$3044.w  resume marker10
    // probe #5: move.l ($E00100).L,D0  (abs.l -> Dn, 6 bytes) -- kept LAST: run sentinel
    emit({0x21,0xCF,0x30,0x54});             // move.l A7,$3054.w  (A7 after the 9 external fault+RTE cycles)
    // ---- PMMU phase: MMU ON (identity early-term table, entry $D INVALID) ----
    // Probes at $D000xx fault IN THE WALK -> the PMMU-dispatch path (SSW bit9=1
    // frames) that the 7.1 validators take with the MMU enabled. Handler v1
    // (DIB=0) still installed: clear DF + stuff DIB + RTE = continue-past.
    emit({0x21,0xCF,0x30,0x58});             // move.l A7,$3058.w  (A7 before PMMU faults)
    // Vector 2 -> the FATAL catcher across the MMU-enable window: a real 68030
    // raises NO fault here, so any vec-2 dispatch during pmove TC is a spurious
    // TG68 fault (the bug candidate) and must abort the run loudly.
    emit({0x41,0xF8,0x19,0x00});             // lea $1900.w,A0   (fault catcher)
    emit({0x21,0xC8,0x00,0x08});             // move.l A0,$8.w
    emit({0xF0,0x39,0x4C,0x00,0x00,0x00,0x1A,0x00}); // pmove ($1A00).L,CRP
    emit({0xF0,0x39,0x40,0x00,0x00,0x00,0x1A,0x08}); // pmove ($1A08).L,TC  (E=1 -> MMU ON)
    // The spurious fault chases the FIRST DATA ACCESS after the enable (nops
    // never trigger it). Plant a harmless valid-page read inside the fatal-
    // catcher window: a real 68030 does not fault here.
    emit({0x4E,0x71});                       // nop
    emit({0x4E,0x71});                       // nop
    emit({0x4A,0x38,0x30,0x00});             // tst.b $3000.w   (valid page, benign read)
    emit({0x4E,0x71});                       // nop
    emit({0x4E,0x71});                       // nop
    emit({0x41,0xF8,0x20,0x00});             // lea $2000.w,A0   (re-install handler v1)
    emit({0x21,0xC8,0x00,0x08});             // move.l A0,$8.w
    // probe #11: tst.b (A0) at an INVALID-descriptor page (walk fault)
    emit({0x20,0x7C,0x00,0xD0,0x00,0x80});   // movea.l #$D00080,A0
    emit({0x72,0x01});                       // moveq #1,D1        (Z=0,N=0)
    emit({0x4A,0x10});                       // tst.b (A0)          -> DIB=0: Z=1, N=0
    emit({0x66,0x08});                       // bne.s +8   (Z must be 1)
    emit({0x6B,0x06});                       // bmi.s +6   (N must be 0)
    emit({0x31,0xFC,0x66,0x77,0x30,0x64});   // move.w #$6677,$3064.w  flags marker11f
    emit({0x31,0xFC,0x66,0x66,0x30,0x60});   // move.w #$6666,$3060.w  resume marker11
    // probe #12: move.l (A1),D5 at an INVALID-descriptor page (walk fault)
    emit({0x43,0xF9,0x00,0xD0,0x01,0x00});   // lea $D00100,A1
    emit({0x7A,0x77});                       // moveq #$77,D5      (poison dest)
    emit({0x2A,0x11});                       // move.l (A1),D5      -> DIB=0: D5=0, Z=1
    emit({0x66,0x08});                       // bne.s +8   (Z must be 1)
    emit({0x6B,0x06});                       // bmi.s +6   (N must be 0)
    emit({0x31,0xFC,0x77,0x88,0x30,0x6C});   // move.w #$7788,$306C.w  flags marker12f
    emit({0x21,0xC5,0x30,0x70});             // move.l D5,$3070.w      (expect 00000000)
    emit({0x31,0xFC,0x77,0x77,0x30,0x68});   // move.w #$7777,$3068.w  resume marker12
    emit({0x21,0xCF,0x30,0x74});             // move.l A7,$3074.w  (A7 after 2 PMMU fault+RTE cycles)
    // --- probe #13: bsr PAGE-CROSS PUSH RACE (the 7.1 wild-rts killer) ---
    // Geometry from the sim trace (frame 1412): a bsr.w whose LAST byte ends a
    // 32K page, so the return address ($10000) and the branch target ($10100)
    // live in a COLD page -> the target fetch triggers a PMMU walk WHILE the
    // return-address push is in flight. On the broken kernel the push is LOST
    // (one ghost fetch appears at the push address) and the callee's rts pops
    // stale memory. Slot poisoned with the fault-catcher address so a lost
    // push = catcher hit + wrong peeked value; walker latency swept via -w.
    emit({0x21,0xCF,0x30,0x84});             // move.l A7,$3084.w      (save SP)
    emit({0x2E,0x7C,0x00,0x04,0x80,0x00});   // movea.l #$48000,A7     (fresh stack page)
    emit({0x2F,0x7C,0x00,0x00,0x19,0x00,0xFF,0xFC}); // move.l #$1900,(-$4,A7)  poison slot (catcher addr) + warm page 8
    emit({0x4E,0xF9,0x00,0x00,0xFF,0xF8});   // jmp ($FFF8).L          (page-1 stub; that fetch warms page 1)
    uint32_t cont_addr = p;                  // #13's landing stub jumps back here
    // --- probe #13c: NON-boundary bsr into a COLD page, MMU ON (coldness-only control) ---
    emit({0x4E,0xF9,0x00,0x01,0x80,0x20});   // jmp ($18020).L  (bsr.w mid-page-3 -> cold page 4)
    uint32_t cont13c = p;                    // #13c's return stub jumps back here (probe #5)
    // probe #5 (sentinel, now external-BERR-under-MMU): $E00xxx translates
    // identity via valid entry $E, then BERRs externally as before.
    emit({0x20,0x39,0x00,0xE0,0x01,0x00});   // move.l $E00100,D0   $2039 $00E0 $0100
    emit({0x31,0xFC,0xEE,0xEE,0x30,0x14});   // move.w #$EEEE,$3014.w  marker5
    emit({0x4E,0x72,0x27,0x00});             // stop #$2700

    // ---- PMMU operands + root table (PMMU phase) ----
    wl(0x1A00, 0x7FFF0003);   // CRP high: limit $7FFF, DT=3 (long table)
    wl(0x1A04, 0x00004000);   // CRP low : root table base $4000 ($3000 = marker area)
    wl(0x1A08, 0x80F84500);   // TC: E=1 PS=32K IS=8 TIA=4 TIB=5
    for (uint32_t i=0; i<16; ++i) {           // 16 x 1MB early-term identity
        wl(0x4000 + i*8 + 0, (i==0xD) ? 0x7FFFFC18   // entry $D: DT=00 INVALID
                                      : 0x7FFFFC19); // others: DT=01 early-term
        wl(0x4000 + i*8 + 4, (i<<20));
    }

    // ---- Handler v1 @ $2000 (ROM $A0DB50: clear DF, DIB=0) ----
    { uint32_t q=0x2000;
      uint8_t code[]={0x02,0x6F,0xFE,0xFF,0x00,0x0A, 0x42,0xAF,0x00,0x2C, 0x4E,0x73};
      for(unsigned i=0;i<sizeof(code);++i) ram[q+i]=code[i]; }
    // ---- Handler v2 @ $2010 (ROM $A0DB5C: clear DF, DIB=-1) ----
    { uint32_t q=0x2010;
      uint8_t code[]={0x02,0x6F,0xFE,0xFF,0x00,0x0A, 0x70,0xFF, 0x2F,0x40,0x00,0x2C, 0x4E,0x73};
      for(unsigned i=0;i<sizeof(code);++i) ram[q+i]=code[i]; }

    // ---- probe #13 stubs (fixed addresses; see the emit-stream comment) ----
    { // page-1 end: two nops then the bsr.w occupying $FFFC-$FFFF (return = $10000)
      uint32_t q=0xFFF8;
      uint8_t code[]={0x4E,0x71, 0x4E,0x71, 0x61,0x00,0x01,0x02};   // nops; bsr.w -> $10100
      for(unsigned i=0;i<sizeof(code);++i) ram[q+i]=code[i]; }
    { // return landing @ $10000: marker + restore SP + jmp back to the main flow
      uint32_t q=0x10000;
      uint8_t code[]={0x31,0xFC,0x7A,0x7A,0x30,0x88,               // move.w #$7A7A,$3088.w
                      0x2E,0x78,0x30,0x84,                          // movea.l $3084.w,A7
                      0x4E,0xF9,
                      (uint8_t)(cont_addr>>24),(uint8_t)(cont_addr>>16),
                      (uint8_t)(cont_addr>>8),(uint8_t)cont_addr};  // jmp (cont).L
      for(unsigned i=0;i<sizeof(code);++i) ram[q+i]=code[i]; }
    { // bsr target @ $10100 (same cold page as the return address)
      uint32_t q=0x10100;
      uint8_t code[]={0x21,0xD7,0x30,0x80,                          // move.l (A7),$3080.w  (peek pushed return)
                      0x4E,0x75};                                   // rts (lost push -> pops poison $1900 -> catcher)
      for(unsigned i=0;i<sizeof(code);++i) ram[q+i]=code[i]; }
    { // probe #13b page-end stub: bsr.w at $2FFFC -> return $30000, target $30100 (MMU OFF)
      uint32_t q=0x2FFF8;
      uint8_t code[]={0x4E,0x71, 0x4E,0x71, 0x61,0x00,0x01,0x02};
      for(unsigned i=0;i<sizeof(code);++i) ram[q+i]=code[i]; }
    { // #13b return landing @ $30000
      uint32_t q=0x30000;
      uint8_t code[]={0x31,0xFC,0x7B,0x7B,0x30,0x8C,               // move.w #$7B7B,$308C.w
                      0x4E,0xF9,
                      (uint8_t)(cont13b>>24),(uint8_t)(cont13b>>16),
                      (uint8_t)(cont13b>>8),(uint8_t)cont13b};
      for(unsigned i=0;i<sizeof(code);++i) ram[q+i]=code[i]; }
    { // #13b target @ $30100
      uint32_t q=0x30100;
      uint8_t code[]={0x21,0xD7,0x30,0x90, 0x4E,0x75};             // peek -> $3090; rts
      for(unsigned i=0;i<sizeof(code);++i) ram[q+i]=code[i]; }
    { // probe #13c: bsr.w mid-page at $18020 -> target $20000 (cold page 4), return $18024
      uint32_t q=0x18020;
      uint8_t code[]={0x61,0x00,0x7F,0xDE,                          // bsr.w -> $20000
                      0x31,0xFC,0x7C,0x7C,0x30,0x94,               // return: move.w #$7C7C,$3094.w
                      0x4E,0xF9,
                      (uint8_t)(cont13c>>24),(uint8_t)(cont13c>>16),
                      (uint8_t)(cont13c>>8),(uint8_t)cont13c};
      for(unsigned i=0;i<sizeof(code);++i) ram[q+i]=code[i]; }
    { // #13c target @ $20000 (cold page)
      uint32_t q=0x20000;
      uint8_t code[]={0x21,0xD7,0x30,0x98, 0x4E,0x75};             // peek -> $3098; rts
      for(unsigned i=0;i<sizeof(code);++i) ram[q+i]=code[i]; }

    top->reset=1; top->data_in=0; top->berr=0;
    top->pmmu_walker_ack=0; top->pmmu_walker_data=0;
    for(int i=0;i<32;++i) tick();
    top->reset=0;

    bool caught=false;
    for (int cyc=0; cyc<300000; ++cyc) {
        tick();
        if (r32(0x2004)==0xDEAD0000u){ caught=true; break; }
        if (r16(0x3014)==0xEEEE){ for(int k=0;k<200;++k) tick(); break; }
    }

    printf("\n==== RESULT ====\n");
    uint16_t m1=r16(0x3000), m2=r16(0x3008), m3=r16(0x300C), m4=r16(0x3010), m5=r16(0x3014);
    uint16_t f3=r16(0x3018), f4=r16(0x301C), m6=r16(0x3020), f6=r16(0x3024), m7=r16(0x3028), f7=r16(0x302C);
    uint16_t m8=r16(0x3034), f8=r16(0x3038), m9=r16(0x303C), f9=r16(0x3040), m10=r16(0x3044), f10=r16(0x3048);
    uint32_t d0=r32(0x3004), d2=r32(0x3030), d4=r32(0x304C);
    printf("probe#1 move.l(d16,An),Dn : marker1=%04X (AAAA) D0=%08X (0)\n", m1, d0);
    printf("probe#2 movea.l(An),An    : marker2=%04X (BBBB)\n", m2);
    printf("probe#3 tst.b(An)  DIB=-1 : resume=%04X (CCCC) flags=%04X (CC77)\n", m3, f3);
    printf("probe#4 btst#6(An) DIB=-1 : resume=%04X (DDDD) flags=%04X (DD77)\n", m4, f4);
    printf("probe#6 tst.b(An)  DIB=0  : resume=%04X (1111) flags=%04X (1177)\n", m6, f6);
    printf("probe#7 btst#6(An) DIB=0  : resume=%04X (2222) flags=%04X (2277)\n", m7, f7);
    printf("probe#8 move.l abs.L,Dn   : resume=%04X (3333) flags=%04X (3377) D2=%08X (0)\n", m8, f8, d2);
    printf("probe#9 tst.b abs.L       : resume=%04X (4444) flags=%04X (4477)\n", m9, f9);
    printf("probe#10 move.b(d8,An,Xn) : resume=%04X (5555) flags=%04X (5577) D4=%08X (0)\n", m10, f10, d4);
    uint16_t m11=r16(0x3060), f11=r16(0x3064), m12=r16(0x3068), f12=r16(0x306C);
    uint32_t d5=r32(0x3070);
    printf("probe#11 tst.b(An) PMMU   : resume=%04X (6666) flags=%04X (6677)\n", m11, f11);
    printf("probe#12 move.l(An) PMMU  : resume=%04X (7777) flags=%04X (7788) D5=%08X (0)\n", m12, f12, d5);
    uint32_t v13=r32(0x3080); uint16_t m13=r16(0x3088);
    printf("probe#13 bsr page-cross   : pushed_ret=%08X (00010000) marker=%04X (7A7A) walkdelay=%d\n",
           v13, m13, walk_delay);
    uint32_t v13b=r32(0x3090); uint16_t m13b=r16(0x308C);
    uint32_t v13c=r32(0x3098); uint16_t m13c=r16(0x3094);
    printf("probe#13b boundary MMU-OFF: pushed_ret=%08X (00030000) marker=%04X (7B7B)\n", v13b, m13b);
    printf("probe#13c cold-pg no-bndry: pushed_ret=%08X (00018024) marker=%04X (7C7C)\n", v13c, m13c);
    printf("probe#5 move.l abs.L,Dn   : marker5=%04X (EEEE)  [external berr UNDER MMU]\n", m5);
    uint32_t a7_before=r32(0x3050), a7_after=r32(0x3054);
    uint32_t a7_pm_before=r32(0x3058), a7_pm_after=r32(0x3074);
    printf("A7 ext 9 faults           : %08X -> %08X  (drift %+d bytes)\n",
           a7_before, a7_after, (int32_t)(a7_after-a7_before));
    printf("A7 pmmu 2 faults          : %08X -> %08X  (drift %+d bytes)\n",
           a7_pm_before, a7_pm_after, (int32_t)(a7_pm_after-a7_pm_before));
    printf("fault catcher hit         : %s\n", caught?"YES (derail!)":"no");
    printf("make_berr edges           : %d (want 10: external only — PMMU faults don't pulse make_berr)\n", mberr_edges);
    bool resume_ok = (m1==0xAAAA)&&(m2==0xBBBB)&&(m3==0xCCCC)&&(m4==0xDDDD)&&(m6==0x1111)&&(m7==0x2222)
                   &&(m8==0x3333)&&(m9==0x4444)&&(m10==0x5555)&&(m5==0xEEEE);
    bool flags_ok  = (f3==0xCC77)&&(f4==0xDD77)&&(f6==0x1177)&&(f7==0x2277)
                   &&(f8==0x3377)&&(f9==0x4477)&&(f10==0x5577)&&(d2==0)&&(d4==0);
    bool pmmu_ok   = (m11==0x6666)&&(f11==0x6677)&&(m12==0x7777)&&(f12==0x7788)&&(d5==0);
    bool bsr_ok    = (v13==0x00010000)&&(m13==0x7A7A);
    bool a7_ok = (a7_after == a7_before) && (a7_pm_after == a7_pm_before);
    // probe #13 is INFORMATIONAL under this harness: the bench's full-freeze
    // clkena model distorts the walk interleave, so the boundary-bsr result
    // here does not track the real integration (Vemu reproduces/validates the
    // real bug). #13b/#13c (no-walk-overlap controls) are still gating.
    bool ok = resume_ok && flags_ok && pmmu_ok && a7_ok && !caught && mberr_edges==10
            && (v13b==0x00030000)&&(m13b==0x7B7B)&&(v13c==0x00018024)&&(m13c==0x7C7C);
    if (!bsr_ok)
        printf("(info) probe#13 boundary-bsr differs under bench clkena model — "
               "verify via the full Vemu 7.1 boot, not here\n");
    if (resume_ok && flags_ok && !a7_ok)
        printf("*** FAIL (A7 DRIFT): every arch effect is right but the stack pointer "
               "moves per fault+RTE — frame push/unwind size mismatch (wild-rts bug) ***\n");
    else if (resume_ok && flags_ok && !pmmu_ok)
        printf("*** FAIL (PMMU PATH): external continue-past is right but the "
               "PMMU-dispatched (SSW bit9=1) continue-past misbehaves — the path "
               "7.1 validators take with the MMU on ***\n");
    else if (resume_ok && !flags_ok)
        printf("*** FAIL (CCR): continue-past resumes correctly but leaves STALE FLAGS "
               "(the wrong-validator-verdict bug) ***\n");
    else
        printf("%s\n", ok ? "PASS: all probe forms continue past with correct register AND CCR effects"
                          : "*** FAIL ***");
    top->final(); delete top;
    return ok?0:1;
}
