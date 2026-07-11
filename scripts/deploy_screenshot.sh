#!/usr/bin/env bash
# MacIIvi deploy: verify the Quartus build, then hand off to the reusable launcher
# tools/misterdeploy/launch_unstable_core.py, which pushes the rbf (scp, md5-verified),
# reboots the MiSTer for a clean menu, and selects the core via the OSD. The OSD
# keystroke sequence is generated from the live menu listing, so nothing about the
# menu layout is hard-coded. All machine config comes from scripts/local.env.
#
# Usage: bash scripts/deploy_screenshot.sh
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi

: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
: "${MISTER_SSH_KEY:?set MISTER_SSH_KEY in scripts/local.env}"
: "${MISTER_HTTP_PORT:=8182}"
: "${RBF_NAME:=MacIIvi.rbf}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

log "=== Verify build artifact ==="
if [ ! -f "output_files/$RBF_NAME" ]; then
    log "ERROR: output_files/$RBF_NAME does not exist - build failed?"
    exit 1
fi
# Refuse to deploy a stale rbf left by a failed Quartus run: trust the first line of
# MacIIvi.fit.summary ("Fitter Status : Successful" vs "...: Failed").
FIT_STATUS=$(awk 'NR==1' output_files/MacIIvi.fit.summary 2>/dev/null)
case "$FIT_STATUS" in
    *Successful*) ;;
    *Failed*)
        log "ERROR: Quartus Fitter reported Failed in MacIIvi.fit.summary:"
        log "  $FIT_STATUS"
        exit 1 ;;
    *)
        log "WARN: no parseable Fitter Status in MacIIvi.fit.summary. Build state unknown — continuing." ;;
esac

log "=== Push rbf + seed PRAM + reboot + OSD-select via the reusable launcher ==="
# git-bash/MSYS rewrites bare "/media/fat/..." args into Windows paths; disable that
# so the absolute --seed-remote/--seed-mount-cfg paths reach the MiSTer unmangled.
export MSYS_NO_PATHCONV=1
# PRAM NVRAM lives in games/MacIIvi/MacIIvi.nvr, auto-mounted to SD slot 2 via
# config/MacIIvi.s2. Both are seeded create-only-if-missing, so a saved PRAM and
# its mount survive subsequent deploys (only the rbf is always overwritten).
exec python tools/misterdeploy/launch_unstable_core.py \
    --host "$MISTER_HOST" --port "$MISTER_HTTP_PORT" \
    --ssh-key "$MISTER_SSH_KEY" \
    --core "$RBF_NAME" \
    --push "output_files/$RBF_NAME" \
    --seed-file "releases/MacIIvi.nvr" \
    --seed-remote "/media/fat/games/MacIIvi/MacIIvi.nvr" \
    --seed-mount-cfg "/media/fat/config/MacIIvi.s2" \
    --seed-mount-rel "games/MacIIvi/MacIIvi.nvr"
