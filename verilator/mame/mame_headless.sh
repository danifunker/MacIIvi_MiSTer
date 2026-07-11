#!/usr/bin/env bash
# mame_headless.sh — run MAME maclc2 FULLY non-interactively (no window, no UI
# prompt) and drop a PNG snapshot. Bypasses the machine info/warning screen that
# otherwise BLOCKS waiting for a keypress (and can leave a window on the user's
# display). Always use this instead of raw `mame` for oracle runs.
#
# Usage:
#   verilator/mame/mame_headless.sh <disk.hd> [ramsize] [snap_frame] [out_subdir]
# Example:
#   verilator/mame/mame_headless.sh scratch/mame755.hd 10M 2400 mamesnap755
# Snapshot lands in scratch/<out_subdir>/maclc2/f0000.png
#
# Non-interactive flags that matter:
#   -skip_gameinfo   skip the info/warning nag (the thing that waits for input)
#   -video none      no window (WSLg would otherwise pop one; a broken X hangs it)
#   -sound none      no audio device (ALSA seq warning is harmless)
#   MAX_FRAME via snap.lua exits the run; -seconds_to_run is the belt-and-braces.
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

DISK="${1:?usage: mame_headless.sh <disk.hd> [ramsize] [snap_frame] [out_subdir]}"
RAM="${2:-10M}"
SNAP="${3:-2400}"
OUT="${4:-mamesnap}"
SECS="${5:-45}"

rm -f "scratch/$OUT/maclc2/"*.png 2>/dev/null || true
SNAP_AT="$SNAP" MAX_FRAME="$((SNAP+50))" \
  mame maclc2 -rompath verilator/mame/roms -ramsize "$RAM" \
    -scsi:0 harddisk -hard1 "$DISK" \
    -skip_gameinfo -video none -sound none -nothrottle \
    -seconds_to_run "$SECS" \
    -autoboot_script verilator/mame/snap.lua \
    -snapname 'maclc2/f%i' -snapshot_directory "scratch/$OUT" 2>&1 | tail -2
echo "snapshot(s):"
ls -la "scratch/$OUT/maclc2/" 2>/dev/null | tail -3
