#!/bin/bash
# Run the instrumented sim headless and extract the [BERRFRAME] ground-truth trace.
# Usage:  bash verilator/berrframe_run.sh [frames] [rom] [extra Vemu args...]
#   bash verilator/berrframe_run.sh 1200 ../releases/boot0.rom
#   bash verilator/berrframe_run.sh 1500 ../releases/boot0.rom --scsi0 ../HD20SC-...vhd
# Reads the boot ROM from ../releases/ ; pass disks with --scsi0 <img> / --floppy0 <dsk>.
cd "$(dirname "$0")" || { echo "FATAL cd"; exit 1; }
FRAMES="${1:-1200}"; ROM="${2:-../releases/boot0.rom}"
shift 2 2>/dev/null || shift $#   # remaining args pass through to Vemu
LOG=berrframe_run.log
[ -x ./obj_dir/Vemu ] || { echo "build first: bash berrframe_build.sh"; exit 1; }

echo "=== Vemu --headless --no-cpu-trace --stop-at-frame $FRAMES --rom $ROM $* ==="
./obj_dir/Vemu --headless --no-cpu-trace --stop-at-frame "$FRAMES" --rom "$ROM" "$@" > "$LOG" 2>&1
echo "rc=$?  last frame: $(grep -aoE 'frame [0-9]+' "$LOG" | tail -1)"

echo "=== event counts ==="
printf 'DISP=%s  RTE=%s  landed=%s  fix_write=1:%s  fix_commit=1:%s\n' \
  "$(grep -ac 'BERRFRAME] DISP' "$LOG")" "$(grep -ac 'BERRFRAME] RTE' "$LOG")" \
  "$(grep -ac 'landed_pc' "$LOG")" "$(grep -ac 'fix_write=1' "$LOG")" "$(grep -ac 'fix_commit=1' "$LOG")"

echo "=== distinct DISP fault sites ==="
grep -a 'BERRFRAME] DISP' "$LOG" | grep -aoE 'ssw=[0-9A-F]+\[[^]]+\] long=[0-9] faddr=[0-9A-F]+ opc=[0-9A-F]+ tberr=[0-9] tmmu=[0-9]' | sort | uniq -c | sort -rn | head -25

echo "=== all RTE (continue-past decision) lines ==="
grep -a 'BERRFRAME] RTE' "$LOG" | sed -E 's/.*(\[BERRFRAME\])/\1/' | sort | uniq -c | sort -rn | head -25

echo "=== first 80 BERRFRAME events in order ==="
grep -aE 'BERRFRAME\]' "$LOG" | sed -E 's/.*(\[BERRFRAME\])/\1/' | head -80
echo "(full log: verilator/$LOG)"
