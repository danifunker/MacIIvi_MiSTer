#!/usr/bin/env bash
# run_mame_maciivi.sh — run MAME's `maciivi` (Macintosh IIvi, 68030/VASP)
# headless as ground truth for this core. WSL/Linux sibling of the macOS
# run_mame_maclc2.sh the LC II campaign used.
#
# Usage:
#   verilator/mame/run_mame_maciivi.sh [extra mame args...]
#
# Examples:
#   # golden early-boot instruction trace (writes /tmp/maincpu.tr):
#   verilator/mame/run_mame_maciivi.sh -debug -debugger none \
#       -debugscript verilator/mame/mame_trace.dbg -seconds_to_run 10
#   # register/memory taps:
#   verilator/mame/run_mame_maciivi.sh -autoboot_script verilator/mame/tap.lua \
#       -seconds_to_run 30
#
# Env overrides:
#   MAME    : mame binary   (default /usr/games/mame — Ubuntu 24.04 pkg, 0.264,
#             verified: `romset maciivi is good` against verilator/mame/roms)
#   ROMPATH : ROM search path (default <this dir>/roms; needs maciivx/ with
#             4957eb49.rom + 341s0851.bin + 341s0850.bin + 344s0100.bin —
#             all copies of files already in this repo, see rom/ + rtl/egret/)
#   RAMSIZE : -ramsize (default 4M = the IIvi base config; OSD "4MB")
#   SOUND   : -sound module (default none; modern MAME still updates streams
#             with -sound none, which the ASC FIFO drain requires)
#
# Gotchas (inherited from the LC II campaign, docs/mame_compare.md):
#   * run headless with -video none: an offscreen -window pauses without focus
#   * never run two captures concurrently (both write /tmp files)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAME="${MAME:-/usr/games/mame}"
ROMPATH="${ROMPATH:-$SCRIPT_DIR/roms}"
RAMSIZE="${RAMSIZE:-4M}"
SOUND="${SOUND:-none}"

cd "$SCRIPT_DIR/../.."   # repo root (mame must run from a writable cwd)

exec "$MAME" maciivi \
	-rompath "$ROMPATH" -ramsize "$RAMSIZE" \
	-nothrottle -video none -sound "$SOUND" \
	-skip_gameinfo \
	"$@"
