#!/usr/bin/env bash
# run_mame_maclc2.sh — run MAME's `maclc2` (Macintosh LC II, 68030) headless as
# ground truth for the LC II core. Sibling of run_mame.sh (which targets maclc).
# See docs/handoff_asc_chime_mame_2026-06-15.md (ASC startup-chime capture).
#
# Usage:
#   verilator/mame/run_mame_maclc2.sh [extra mame args...]
#
# Example (ASC chime ground truth):
#   ASC_OUT=/tmp/asc_trace.txt verilator/mame/run_mame_maclc2.sh \
#     -autoboot_script verilator/mame/asc_trace.lua -seconds_to_run 20
#
# Env overrides:
#   MAME    : mame binary  (default /opt/homebrew/bin/mame — the 0.288 build that
#             actually knows `maclc2`; /Users/dani/repos/mame/mame does NOT)
#   ROMPATH : ROM search path (default /private/tmp/goodroms; needs maclc2/ +
#             egret/ romsets — see the handoff for how they were assembled)
#   RAMSIZE : -ramsize (default 4M = maclc2 default; configRAMSize $04)
#   SOUND   : -sound module (default `coreaudio`). The V8 FIFO drains inside the
#             ASC sound stream, so the sound system MUST update streams or the
#             FIFO never empties (bit0 never sets) and MAME would falsely "hang"
#             like our core. `-sound none` still updates streams in modern MAME,
#             but coreaudio is the safe default; override with SOUND=none to test.
set -euo pipefail

MAME="${MAME:-/opt/homebrew/bin/mame}"
ROMPATH="${ROMPATH:-/private/tmp/goodroms}"
RAMSIZE="${RAMSIZE:-4M}"
SOUND="${SOUND:-coreaudio}"

cd "$(dirname "$0")/../.."   # repo root (mame must run from a writable cwd)

exec "$MAME" maclc2 \
	-rompath "$ROMPATH" -ramsize "$RAMSIZE" \
	-nothrottle -video opengl -nowindow -sound "$SOUND" \
	"$@"
