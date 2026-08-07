#!/usr/bin/env bash
# Build + run the VRAM-work benches (docs/resume_2026-08-07_vram_1mb.md).
#
#   bash verilator/vram_bench/run.sh sdram   # the important one
#   bash verilator/vram_bench/run.sh scan
#   bash verilator/vram_bench/run.sh ddr
#
# tb_sdram_vid drives the REAL rtl/sdram.v — the main Verilator sim swaps
# sdram.v for sim_ram.v, so this bench is the ONLY pre-hardware coverage the
# controller gets. sdram.v has an `inout` port that Verilator will not
# elaborate in a bench context, so a split-bus copy is GENERATED here from
# the live rtl/sdram.v on every run (never edit sdram_split.v by hand — it is
# regenerated and gitignored).
set -eu
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BENCH="${1:-sdram}"
OUT="verilator/vram_bench"

VFLAGS="--binary --timing --timescale-override 1ns/1ns
  -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL
  -Wno-CASEINCOMPLETE -Wno-INITIALDLY -Wno-BLKSEQ -Wno-MULTIDRIVEN
  -Wno-PINMISSING"

gen_split() {
  python - <<'PY'
src = open('rtl/sdram.v').read()
subs = [
  ("\tinout  reg [15:0]   sd_data,    // 16 bit bidirectional data bus",
   "\toutput reg [15:0]   sd_data_o,\n\toutput reg          sd_data_oe,\n\tinput      [15:0]   sd_data_i,"),
  ("\tsd_data <= 16'bZZZZZZZZZZZZZZZZ;", "\tsd_data_oe <= 1'b0;"),
  ("\t\t\tif (we_latch) begin\n\t\t\t\tsd_data <= din;",
   "\t\t\tif (we_latch) begin\n\t\t\t\tsd_data_o <= din; sd_data_oe <= 1'b1;"),
  ("\t\t\tdout       <= sd_data;", "\t\t\tdout       <= sd_data_i;"),
  ("\t\tvid_q[vid_q_wr] <= {vid_grp_seq, sd_data};",
   "\t\tvid_q[vid_q_wr] <= {vid_grp_seq, sd_data_i};"),
  ("module sdram", "module sdram_split"),
]
for old, new in subs:
    assert old in src, "sdram.v no longer matches split-gen hunk: " + repr(old[:48])
    src = src.replace(old, new)
open('verilator/vram_bench/sdram_split.v', 'w', newline='\n').write(src)
print("sdram_split.v regenerated from rtl/sdram.v")
PY
}

case "$BENCH" in
  sdram)
    gen_split
    verilator $VFLAGS --top-module tb_sdram_vid \
      $OUT/tb_sdram_vid.v $OUT/altddio_out_stub.v $OUT/sdram_split.v \
      rtl/nubus/mdc_scan_fetch.sv -o tb_sdram_vid --Mdir $OUT/obj_sdram
    ./$OUT/obj_sdram/tb_sdram_vid ;;
  scan)
    verilator $VFLAGS --top-module tb_scan_fetch \
      $OUT/tb_scan_fetch.v verilator/sim_ram.v rtl/nubus/mdc_scan_fetch.sv \
      -o tb_scan_fetch --Mdir $OUT/obj_scan
    ./$OUT/obj_scan/tb_scan_fetch ;;
  ddr)
    verilator $VFLAGS --top-module tb_vram_ddr \
      $OUT/tb_vram_ddr.v verilator/sim_ddram.v rtl/nubus/mdc_vram_ddr.sv \
      rtl/nubus/mdc_scan_fetch.sv -o tb_vram_ddr --Mdir $OUT/obj_ddr
    ./$OUT/obj_ddr/tb_vram_ddr ;;
  *) echo "usage: run.sh [sdram|scan|ddr]" >&2; exit 2 ;;
esac
