#!/usr/bin/env bash
# HIGHLIGHT (do NOT launch) a core inside _Unstable on the MiSTer main menu,
# using the procedure that beats the menu's ~5s cursor timeout (slow keystrokes
# get silently dropped):
#
#   1. RESET   : reboot to a clean menu
#   2. WAIT 5s : let the menu settle (cursor at the top / Arcade)
#   3. OSD     : press OSD to activate menu navigation
#   4. PRESSES : fast (0.12s) button presses, NO final confirm -> only highlights
#        down x<UNST>  -> _Unstable (8th main-menu folder = 7 down from Arcade)
#        confirm       -> enter the folder
#        down x<CORE>  -> the core
#
# After it stops, SCREENSHOT the display promptly. Nudge the landing row by passing
# different counts, e.g. one row lower: menu_highlight.sh 7 33
#
#   bash scripts/menu_highlight.sh [downs_to_unstable=7] [downs_to_core=32]
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
. scripts/local.env
UNST="${1:-7}"; CORE="${2:-32}"
HTTP="http://$MISTER_HOST:$MISTER_HTTP_PORT"
DU=$(printf 'down %.0s' $(seq "$UNST"))
DC=$(printf 'down %.0s' $(seq "$CORE"))

echo "[hl] 1. RESET (reboot) at $(date +%H:%M:%S)"
curl -s -X POST "$HTTP/api/settings/system/reboot" >/dev/null 2>&1 || true
sleep 20
for i in $(seq 1 60); do
  sleep 4
  curl -sf -o /dev/null --max-time 4 "$HTTP/api/sysinfo" 2>/dev/null && { echo "[hl]    menu service up (~$((20+i*4))s)"; break; }
done
echo "[hl] 2. WAIT 5s (settle)"
sleep 5
echo "[hl] 3. OSD  4. PRESSES: down x$UNST (_Unstable), confirm, down x$CORE (core), NO launch -- $(date +%H:%M:%S)"
python scripts/mister_ws.py --delay 0.12 osd sleep:0.4 $DU confirm sleep:0.7 $DC 2>&1 | grep -ivE "kbd:"
echo "[hl] DONE at $(date +%H:%M:%S) -> core HIGHLIGHTED. SCREENSHOT NOW."
