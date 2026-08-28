#!/usr/bin/env bash
# Cleanly shut down the guest Mac via Finder Special > Shut Down, driven by
# evdev mouse injection into the MiSTer Remote's virtual mouse (mrext-mouse).
# Requires the guest at the Finder desktop. After ~10 s the guest lands on
# the "It is now safe to switch off your Macintosh." screen (the core does
# not implement Egret soft-power-off, so the OS falls back to the classic
# end screen — unambiguous, screenshot-verifiable). HFS volumes are flushed
# and marked clean; a subsequent load_core then boots fresh from a clean
# filesystem. Verify with scripts/grab.sh.
#
# Mechanics (proven 2026-07-16):
# - System 7 menus are NOT sticky: the whole press-hold-drag-release must
#   happen on ONE open fd of the event device (fd close drops button state),
#   with real pacing so the guest's menu tracking sees intermediate motion.
# - Paced 3px relative steps (20 ms apart) arrive ~1:1 in the guest; big
#   unpaced bursts collapse and undershoot. A large negative burst is used
#   deliberately to PIN the pointer at (0,0) for position independence.
# - Menu geometry (640x480, System 7.6.1 Finder): "Special" title spans
#   x~205-260 in the menu bar; "Shut Down" is the bottom item, row
#   y~132-146, menu spans x~205-339.
#
# Usage: bash scripts/mac_clean_shutdown.sh
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
: "${MISTER_SSH_KEY:?set MISTER_SSH_KEY in scripts/local.env}"

MOUSE_DEV=${MOUSE_DEV:-/dev/input/event9}   # mrext-mouse on .143

python - <<'PYEOF' | ssh -i "$MISTER_SSH_KEY" "root@$MISTER_HOST" "cat > $MOUSE_DEV && echo SHUTDOWN_STREAM_DELIVERED"
import struct, sys, time
ev = lambda t,c,v: struct.pack('<IIHHi',0,0,t,c,v)
w = sys.stdout.buffer
def send(*evs, pace=0.02):
    for e in evs: w.write(e)
    w.write(ev(0,0,0)); w.flush(); time.sleep(pace)

# 1. Pin pointer at top-left (0,0): huge negative burst, scaling irrelevant.
for i in range(60): send(ev(2,0,-30), ev(2,1,-30), pace=0.005)
time.sleep(0.3)
# 2. Walk to the Special menu title (~x232, y stays in the menu bar band).
for i in range(78): send(ev(2,0,3))
time.sleep(0.3)
# 3. Press and HOLD — the menu drops and tracks while held.
send(ev(1,272,1)); time.sleep(0.4)
# 4. Drag down to Shut Down (bottom item), drifting right to stay mid-menu.
for i in range(46): send(ev(2,1,3))
for i in range(6):  send(ev(2,0,3))
time.sleep(0.5)
# 5. Release over Shut Down.
send(ev(1,272,0)); time.sleep(0.5)
PYEOF
