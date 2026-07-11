#!/usr/bin/env bash
# One-shot loop-sample of the live wedge/poll loop on the running FPGA:
# samples PIFD/PADR/PSTA over JTAG, then reconstructs the loop + "what is polled".
# Use at the System-load hang to see WHICH register the stalled SCSI driver polls.
# Don't run while a Quartus compile is using the cable. Existing probes only — no rebuild.
#
#   bash scripts/sample_poll.sh [n_samples]   (default 160)
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
export PATH="/c/intelFPGA_lite/17.0/quartus/bin64:$PATH"

N="${1:-160}"
SAMPLES="${2:-output_files/poll_samples.txt}"

quartus_stp_tcl -t scripts/sample_loop.tcl "$N" 2>&1 \
  | grep -ivE "copyright|license|agreement|partner|foregoing|associated|terms of|subscription|megacore|expressly subject|authorized distrib|including, without|applicable license|please refer|sole purpose|your use of" \
  > "$SAMPLES"

echo "=== raw samples -> $SAMPLES ($(wc -l < "$SAMPLES") lines) ==="
python scripts/loop_disasm.py "$SAMPLES" 2>/dev/null \
  || python3 scripts/loop_disasm.py "$SAMPLES"
