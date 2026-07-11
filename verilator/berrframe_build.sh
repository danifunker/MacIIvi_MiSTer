#!/bin/bash
# Build the Verilator sim with the [BERRFRAME] 68030 bus-fault instrumentation.
# Portable (macOS/Linux). Run from anywhere:  bash verilator/berrframe_build.sh
#
# --public-flat-rw exposes ALL signals in flat (emu__DOT__) form. This is REQUIRED:
# the committed sim_main.cpp has debug taps ([SR]/SCC/Egret/HC05) that read internal
# signals recent Verilator (>=5.x) optimizes away; without this flag g++ fails with
# "class Vemu___024root has no member named emu__DOT__dc0__DOT__via__DOT__cb2_i".
# It does NOT meaningfully slow this sim (verified: boots hundreds of frames/sec).
set -o pipefail
cd "$(dirname "$0")" || { echo "FATAL cd"; exit 1; }
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

echo "=== taps present? (expect sim_main.cpp>=4, tg68k_debug.vlt>=2) ==="
grep -c BERRFRAME sim_main.cpp; grep -c rte_mmu_fix_write tg68k_debug.vlt

echo "=== clean obj_dir ==="
rm -rf obj_dir

echo "=== verilate ==="
make V_OPT="--x-assign fast --x-initial fast --noassert --public-flat-rw" obj_dir/Vemu.cpp || {
    echo "VERILATE FAILED"; exit 1; }

echo "=== compile + link (-j$JOBS) ==="
( cd obj_dir && make -j"$JOBS" -f Vemu.mk ) || { echo "COMPILE FAILED"; exit 1; }

ls -la obj_dir/Vemu && echo "BUILD OK"
