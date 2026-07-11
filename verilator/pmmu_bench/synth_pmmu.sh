#!/bin/bash
# Synthesize TG68K_PMMU_030 standalone to Verilog for the focused PMMU bench.
set -e

# GHDL LLVM SONAME shim (Ubuntu ships libLLVM.so.18.1, ghdl wants libLLVM-18.so.18.1)
mkdir -p "$HOME/ghdllib"
ln -sf /lib/x86_64-linux-gnu/libLLVM.so.18.1 "$HOME/ghdllib/libLLVM-18.so.18.1" 2>/dev/null || true
export LD_LIBRARY_PATH="$HOME/ghdllib"

RTL=/mnt/c/Temp/mistercore/MacLCII_MiSTer/rtl/tg68k
OUT=/mnt/c/Temp/mistercore/MacLCII_MiSTer/verilator/pmmu_bench
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

GHDL_FLAGS="-fsynopsys -fexplicit --workdir=$WORK"

cd "$RTL"
echo "=== ghdl version ==="; ghdl --version | head -1
echo "=== Analyzing Pack -> ALU -> PMMU_030 ==="
ghdl -a $GHDL_FLAGS TG68K_Pack.vhd
ghdl -a $GHDL_FLAGS TG68K_ALU.vhd
ghdl -a $GHDL_FLAGS TG68K_PMMU_030.vhd
echo "=== Synthesizing TG68K_PMMU_030 -> standalone Verilog ==="
ghdl synth $GHDL_FLAGS --latches --out=verilog TG68K_PMMU_030 > "$OUT/TG68K_PMMU_030.v.tmp"
mv "$OUT/TG68K_PMMU_030.v.tmp" "$OUT/TG68K_PMMU_030.v"
echo "=== Done. Lines: $(wc -l < "$OUT/TG68K_PMMU_030.v") ==="
echo "=== Module/port header ==="
grep -nE '^module |input |output |inout ' "$OUT/TG68K_PMMU_030.v" | head -120
