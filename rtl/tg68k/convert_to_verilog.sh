#!/bin/bash
#
# convert_to_verilog.sh — regenerate TG68KdotC_Kernel.v from the VHDL source.
#
# The VHDL files (TG68K_Pack.vhd, TG68K_ALU.vhd, TG68K_PMMU_030.vhd,
# TG68K_Cache_030.vhd, TG68KdotC_Kernel.vhd) are the SOURCE OF TRUTH for the CPU
# core. Quartus compiles the VHDL directly (see rtl/tg68k/TG68K.qip); Verilator
# compiles the generated .v (see verilator/Makefile). After ANY edit to the VHDL,
# run this script and rebuild the Verilator sim so both toolchains stay in sync.
#
# This is the TG68K.C 030_mmu branch (MC68030 mode, CPU="10"): full PMMU +
# on-chip cache control. lastOpcBit=103, MOVES with SFC/DFC. Do NOT replace the
# VHDL with upstream MacPlus/68000 originals — that drops 030 + MOVES support the
# Mac LC II boot ROM relies on and desyncs sim from FPGA (see bootprogress.md).
#
# Requires ghdl (apt ghdl-llvm 4.1.0 works and produced the committed .v; the
# WSL install needs LD_LIBRARY_PATH=/home/dani/ghdllib for the stashed
# libLLVM-18 — without it ghdl1-llvm fails to load). The ghdl synth output is the
# whole kernel hierarchy with the ALU and PMMU_030 inlined as submodules, so the
# generated TG68KdotC_Kernel.v is self-contained (no separate ALU/PMMU .v needed).
#
# SPEED (2026-08-15): under WSL, run everything in a NATIVE ext4 dir and copy
# results back. Emitting ~6MB of Verilog through the /mnt/c 9p mount crawls at
# ~100KB/min (25+ min); on native fs the whole conversion is ~2 min. This
# script now does that automatically.
#
# Generics: use the entity DEFAULTS (SR_Read=2, VBR_Stackframe=2, extAddr_Mode=2,
# MUL_Mode=2, DIV_Mode=2, BitField=2, BarrelShifter=1, MUL_Hardware=1). GHDL 6.0.0
# rejects -g overrides for these ("out of bounds"), and the defaults already match
# the committed core (validated: byte-for-byte identical boot trace).

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# WSL libLLVM stash (no-op where the lib resolves normally).
[ -d /home/dani/ghdllib ] && export LD_LIBRARY_PATH="/home/dani/ghdllib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Work on a NATIVE filesystem (see SPEED note above): mktemp -d lands on
# tmpfs/ext4, we copy the sources in and the generated .v back out.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp TG68K_Pack.vhd TG68K_ALU.vhd TG68K_PMMU_030.vhd TG68K_Cache_030.vhd \
   TG68KdotC_Kernel.vhd "$WORK/"
cd "$WORK"

GHDL_FLAGS="-fsynopsys -fexplicit --workdir=."

echo "=== Analyzing VHDL (Pack -> ALU -> PMMU_030 -> Cache_030 -> Kernel) ==="
ghdl -a $GHDL_FLAGS TG68K_Pack.vhd
ghdl -a $GHDL_FLAGS TG68K_ALU.vhd
ghdl -a $GHDL_FLAGS TG68K_PMMU_030.vhd
ghdl -a $GHDL_FLAGS TG68K_Cache_030.vhd
ghdl -a $GHDL_FLAGS TG68KdotC_Kernel.vhd

echo "=== Synthesizing TG68KdotC_Kernel -> TG68KdotC_Kernel.v ==="
ghdl synth $GHDL_FLAGS --latches --out=verilog TG68KdotC_Kernel > TG68KdotC_Kernel.v

# The 68030 on-chip I/D cache is a standalone leaf (no submodules), so it is
# synthesized on its own rather than inlined into the kernel hierarchy (the
# kernel does not instantiate it — the Mac bus wrapper tg68k.v does). Quartus
# compiles the .vhd directly (TG68K.qip); Verilator compiles this generated .v.
echo "=== Synthesizing TG68K_Cache_030 -> TG68K_Cache_030.v ==="
ghdl synth $GHDL_FLAGS --latches --out=verilog TG68K_Cache_030 > TG68K_Cache_030.v

cp TG68KdotC_Kernel.v TG68K_Cache_030.v "$SCRIPT_DIR/"
cd "$SCRIPT_DIR"

echo "=== Done. Kernel lines: $(wc -l < TG68KdotC_Kernel.v); Cache lines: $(wc -l < TG68K_Cache_030.v) ==="
echo "REMINDER: the ghdl positional name behind the kernel's usp wire changed —"
echo "  grep 'assign usp = ' TG68KdotC_Kernel.v"
echo "and update SingleStepTests/tg68k/{tg68k_tests.vlt,sim_main.cpp,Makefile}."
echo "Now rebuild the sim: (cd ../../verilator && make clean && make)"
