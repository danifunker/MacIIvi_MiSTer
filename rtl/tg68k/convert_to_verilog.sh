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
# Requires ghdl (tested with GHDL 6.0.0 / LLVM). The ghdl synth output is the
# whole kernel hierarchy with the ALU and PMMU_030 inlined as submodules, so the
# generated TG68KdotC_Kernel.v is self-contained (no separate ALU/PMMU .v needed).
#
# Generics: use the entity DEFAULTS (SR_Read=2, VBR_Stackframe=2, extAddr_Mode=2,
# MUL_Mode=2, DIV_Mode=2, BitField=2, BarrelShifter=1, MUL_Hardware=1). GHDL 6.0.0
# rejects -g overrides for these ("out of bounds"), and the defaults already match
# the committed core (validated: byte-for-byte identical boot trace).

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

GHDL_FLAGS="-fsynopsys -fexplicit --workdir=$WORK"

echo "=== Analyzing VHDL (Pack -> ALU -> PMMU_030 -> Cache_030 -> Kernel) ==="
ghdl -a $GHDL_FLAGS TG68K_Pack.vhd
ghdl -a $GHDL_FLAGS TG68K_ALU.vhd
ghdl -a $GHDL_FLAGS TG68K_PMMU_030.vhd
ghdl -a $GHDL_FLAGS TG68K_Cache_030.vhd
ghdl -a $GHDL_FLAGS TG68KdotC_Kernel.vhd

echo "=== Synthesizing TG68KdotC_Kernel -> TG68KdotC_Kernel.v ==="
ghdl synth $GHDL_FLAGS --latches --out=verilog TG68KdotC_Kernel > TG68KdotC_Kernel.v.tmp
mv TG68KdotC_Kernel.v.tmp TG68KdotC_Kernel.v

echo "=== Done. Lines: $(wc -l < TG68KdotC_Kernel.v) ==="
echo "Now rebuild the sim: (cd ../../verilator && make clean && make)"
