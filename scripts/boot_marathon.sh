#!/usr/bin/env bash
# boot_marathon.sh — N consecutive COLD boots (load_core) of the deployed core,
# each judged from fresh screenshots:
#   SETTLED  = grab md5 == canonical MacAtrium games-desktop (byte-identical law)
#   SADMAC   = 2 consecutive dark grabs (mean luminance < 45; sad-Mac frames
#              measure 34.5, every healthy boot phase >= 150)
#   VIDEODEAD= grab_fresh reports no new frame (historic black-screen fit class)
#   TIMEOUT  = no settle by the per-boot deadline
# Between SETTLED boots: MacAtrium ESC-menu keyboard clean shutdown (keeps HFS
# clean so the next boot has no "not shut down properly" dialog). A non-settled
# boot skips the shutdown (nothing mounted — sad Mac dies pre-disk).
# The marathon STOPS at the first failure (the gate is N *consecutive* clean).
#
# Usage: bash scripts/boot_marathon.sh [N] [outdir]
# Exit 0 = N consecutive clean settles; 1 = a boot failed (evidence in outdir).
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
. scripts/local.env

N=${1:-5}
OUT=${2:-hw_gate/marathon_$(date +%Y%m%d)}
CANON=${MARATHON_CANON:-6f6cc3bcd679c10398becbd4f40fd4d7}
RBF_REMOTE=/media/fat/_Unstable/MacIIvi.rbf
SSH_CMD=(ssh -i "$MISTER_SSH_KEY" -o StrictHostKeyChecking=no "root@$MISTER_HOST")
GRAB_EVERY=12          # seconds between polls
FIRST_GRAB=40          # nothing before this but the gray march
DEADLINE=360           # per-boot settle deadline (cache ~91s no-CD; CD-mounted boots run longer)
SHUTDOWN_WAIT=18       # seconds for the guest shutdown to finish

mkdir -p "$OUT"
LOG="$OUT/marathon.log"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

mean_lum() { # mean luminance of a PNG, integer
  python -c "import sys,numpy as np;from PIL import Image;print(int(np.array(Image.open(sys.argv[1]).convert('L')).mean()))" "$1"
}

clean_shutdown() { # VERIFIED guest shutdown (owner rule 2026-08-16: never
  # load_core over a running guest; the old blind ESC-menu sequence was a
  # landmine — ESC at the carousel is an INSTANT clean Restart, not a menu).
  # Path: quit MacAtrium (Cmd-Q + confirm) -> Finder -> Special/Shut Down via
  # the proven mouse drag -> VERIFY the safe-off screen (black, lum ~15-25)
  # before returning. Verification failure ABORTS the marathon (exit 3) —
  # never fall back to a dirty load_core.
  log "verified clean shutdown: quit MacAtrium -> Finder -> Special/Shut Down"
  python scripts/mac_kbd.py cmd:q sleep:2 key:enter >>"$LOG" 2>&1
  sleep 6
  MOUSE_DEV=${MOUSE_DEV:-/dev/input/event13} bash scripts/mac_clean_shutdown.sh >>"$LOG" 2>&1
  sleep "$SHUTDOWN_WAIT"
  for try in 1 2 3; do
    if bash scripts/grab_fresh.sh "$OUT/shutdown_verify.png" >>"$LOG" 2>&1; then
      slum=$(mean_lum "$OUT/shutdown_verify.png")
      log "shutdown verify: lum=$slum (safe-off screen is ~15-25)"
      [ "$slum" -lt 45 ] && return 0
    fi
    sleep 8
  done
  log "ABORT: could not verify the safe-off screen — refusing to dirty-boot"
  exit 3
}

fails=0
for i in $(seq 1 "$N"); do
  log "=== BOOT $i/$N: load_core (cold boot) ==="
  "${SSH_CMD[@]}" "echo load_core $RBF_REMOTE > /dev/MiSTer_cmd" || { log "SSH load_core FAILED"; exit 2; }
  t0=$(date +%s); verdict=""; dark_streak=0
  sleep "$FIRST_GRAB"
  while :; do
    el=$(( $(date +%s) - t0 ))
    [ "$el" -gt "$DEADLINE" ] && { verdict="TIMEOUT after ${el}s"; break; }
    f="$OUT/boot${i}_${el}s.png"
    if ! bash scripts/grab_fresh.sh "$f" >>"$LOG" 2>&1; then
      verdict="VIDEODEAD at ${el}s"; break
    fi
    md5=$(md5sum "$f" | cut -d' ' -f1)
    if [ "$md5" = "$CANON" ]; then verdict="SETTLED at ${el}s"; break; fi
    lum=$(mean_lum "$f")
    if [ "$lum" -lt 45 ]; then dark_streak=$((dark_streak+1)); else dark_streak=0; fi
    log "  boot$i +${el}s lum=$lum md5=${md5:0:8}"
    [ "$dark_streak" -ge 2 ] && { verdict="SADMAC at ${el}s (lum=$lum)"; break; }
    sleep "$GRAB_EVERY"
  done
  log "BOOT $i verdict: $verdict"
  case "$verdict" in
    SETTLED*) [ "${SKIP_SHUTDOWN:-0}" = 1 ] || clean_shutdown ;;
    *) fails=1; log "MARATHON STOPPED: boot $i failed — evidence in $OUT"; break ;;
  esac
done

if [ "$fails" -eq 0 ]; then
  log "MARATHON PASS: $N consecutive clean settles"
  exit 0
fi
exit 1
