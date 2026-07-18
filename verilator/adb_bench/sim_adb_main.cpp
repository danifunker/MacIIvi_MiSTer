// Standalone adb_device bench: replays the Egret's Listen-R3 dance at scripted
// cell timings and lets the DUT's SIMULATION $displays (ADB_TALK/ADB_LRX_DONE)
// report what it captured. Sweeps command/payload cell timing independently to
// map the capture margin around the fixed T_BITTH=470 threshold.
#include "Vtb_adb.h"
#include "verilated.h"
#include <cstdio>

static Vtb_adb *tb;
static vluint64_t tcyc = 0;

static void step(int cycles, int line) {
    tb->line_drive = line;
    for (int i = 0; i < cycles; i++) {
        tb->clk = 0; tb->eval();
        tb->clk = 1; tb->eval();
        tcyc++;
    }
}

// one ADB bit cell: low phase then high phase (device samples the HIGH length
// at the next falling edge)
static void cell(int lo, int hi) { step(lo, 0); step(hi, 1); }

static void byte_cells(int v, int lo0, int hi0, int lo1, int hi1) {
    for (int b = 7; b >= 0; b--) {
        if ((v >> b) & 1) cell(lo1, hi1);
        else              cell(lo0, hi0);
    }
}

// full host transaction: attention + sync + command + stop, then (for Listen)
// Tlt + start bit + 16 payload bits + stop
static void listen_r3(int cmd, int payload,
                      int c_lo0, int c_hi0, int c_lo1, int c_hi1,
                      int p_lo0, int p_hi0, int p_lo1, int p_hi1) {
    step(6000, 1);            // idle
    step(3500, 0);            // attention (> T_ATTN=3000)
    step(70, 1);              // sync high
    // command byte: first fall enters S_BITS, so emit a dummy leading fall via
    // the first cell; the FSM samples 8 bits on the 8 falls AFTER entering.
    byte_cells(cmd, c_lo0, c_hi0, c_lo1, c_hi1);
    cell(c_lo0, c_hi0);       // stop bit (0) — its fall completes bit 8
    step(1400, 1);            // Tlt gap (host keeps line high)
    cell(p_lo1, p_hi1);       // start bit ("1")
    for (int b = 15; b >= 0; b--) {
        if ((payload >> b) & 1) cell(p_lo1, p_hi1);
        else                    cell(p_lo0, p_hi0);
    }
    cell(p_lo0, p_hi0);       // stop bit (0) — final fall latches bit 16
    step(4000, 1);            // idle out
}

static void talk(int cmd, int c_lo0, int c_hi0, int c_lo1, int c_hi1) {
    step(6000, 1);
    step(3500, 0);
    step(70, 1);
    byte_cells(cmd, c_lo0, c_hi0, c_lo1, c_hi1);
    cell(c_lo0, c_hi0);
    step(6000, 1);            // give the device room to respond (we ignore data)
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    tb = new Vtb_adb;
    tb->reset = 1; step(20, 1);
    tb->reset = 0; step(20, 1);

    // Profile A: nominal tuned cells (matches command decode: 340/600)
    printf("=== nominal 340/600 both phases: Listen kbd R3 -> addr F handler FE\n");
    listen_r3(0x2B, 0x0FFE, 600, 340, 340, 600, 600, 340, 340, 600);
    talk(0xFF, 600, 340, 340, 600);   // Talk addr F R3 — device should be there
    talk(0x2F, 600, 340, 340, 600);   // Talk addr 2 R3 — should be empty now

    // Profile sweep: payload cells scaled while command stays nominal
    for (int pct = 60; pct <= 140; pct += 10) {
        int lo0 = 600 * pct / 100, hi0 = 340 * pct / 100;
        int lo1 = 340 * pct / 100, hi1 = 600 * pct / 100;
        printf("=== payload cells at %d%% (hi0=%d hi1=%d, threshold 470)\n",
               pct, hi0, hi1);
        tb->reset = 1; step(20, 1); tb->reset = 0; step(20, 1);
        listen_r3(0x2B, 0x0FFE, 600, 340, 340, 600, lo0, hi0, lo1, hi1);
        talk(0xFF, 600, 340, 340, 600);
    }

    delete tb;
    return 0;
}
