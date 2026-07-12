#!/usr/bin/env bash
# run_cursor_bp.sh — golden cursor-blit register capture (see cursor_blit_bp.dbg).
# Boots maciivi+mdc824 headless with the cursor_ctx.lua mouse wiggle AND the
# debugger breakpoints; summarizes the captured HIDE-ENTRY/BLIT-PARAMS lines.
set -e
cd "$(dirname "$0")/../.."
rm -f ~/.mame/cfg/maciivi.cfg ~/.mame/nvram/maciivi/egret
CTX_FRAMES=${CTX_FRAMES:-1800} CTX_OUT=/tmp/mame_ctx_bp.txt \
  verilator/mame/run_mame_maciivi.sh -nbe mdc824 \
  -autoboot_script verilator/mame/cursor_ctx.lua \
  -debug -debugger none -debugscript verilator/mame/cursor_blit_bp.dbg \
  -seconds_to_run "${SECS:-40}" -video none > /tmp/mame_bp_run.log 2>&1
echo "MAME_EXIT=$?"
echo "== capture counts:"
grep -c 'HIDE-ENTRY' /tmp/mame_bp_run.log || true
grep -c 'BLIT-PARAMS' /tmp/mame_bp_run.log || true
echo "== first hits:"
grep -m6 -E 'HIDE-ENTRY|BLIT-PARAMS' /tmp/mame_bp_run.log || true
echo "== distinct BLIT-PARAMS (top):"
grep 'BLIT-PARAMS' /tmp/mame_bp_run.log | sort | uniq -c | sort -rn | head -8 || true
echo "== distinct callers:"
grep -o 'HIDE-ENTRY ret=........' /tmp/mame_bp_run.log | sort | uniq -c | sort -rn | head -8 || true
