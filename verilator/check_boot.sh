#!/bin/bash
# check_boot.sh - Verify CPU boot progress from Verilator simulation
#
# Usage:
#   ./check_boot.sh              # Analyze existing cpu_trace.log
#   ./check_boot.sh --run        # Run simulation first (30 frames), then analyze
#   ./check_boot.sh --run 100    # Run simulation for N frames, then analyze
#
# Exit codes:
#   0 - CPU is advancing through ROM (boot progressing)
#   1 - CPU never started or stuck at reset
#   2 - cpu_trace.log not found (run with --run or run simulator first)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$SCRIPT_DIR/cpu_trace.log"
FRAMES=30

# Parse args
if [ "$1" = "--run" ]; then
    FRAMES="${2:-30}"
    echo "Running simulation for $FRAMES frames..."
    cd "$SCRIPT_DIR"
    if [ ! -f obj_dir/Vemu ]; then
        echo "ERROR: obj_dir/Vemu not found. Run 'make' first."
        exit 2
    fi
    ./obj_dir/Vemu --stop-at-frame "$FRAMES" >/dev/null 2>/dev/null
fi

if [ ! -f "$LOG" ]; then
    echo "ERROR: $LOG not found. Run with --run or run the simulator first."
    exit 2
fi

# Filter out frame separator lines for analysis
TRACE_LINES=$(grep -v '^--- frame' "$LOG")
TOTAL_LINES=$(echo "$TRACE_LINES" | wc -l | tr -d ' ')
FIRST_PC=$(echo "$TRACE_LINES" | head -1 | awk '{print $2}' | sed 's/://')
LAST_PC=$(echo "$TRACE_LINES" | tail -1 | awk '{print $2}' | sed 's/://')

# Check if CPU ever left reset vector area
# Note: Egret holds 68020 in reset for ~1M HC05 cycles, so short runs (<20 frames) produce no CPU trace
if [ "$TOTAL_LINES" -lt 100 ]; then
    echo "FAIL: Only $TOTAL_LINES instructions executed - CPU may not have started"
    echo "(Egret holds CPU in reset until ~frame 15. Use --run 30 or more.)"
    exit 1
fi

# Get high-level PC range transitions (unique 4-char prefix changes)
MILESTONES=$(echo "$TRACE_LINES" | awk '{pc=substr($2,1,6); if(pc!=last) {print NR" "pc; last=pc}}')
MILESTONE_COUNT=$(echo "$MILESTONES" | wc -l | tr -d ' ')

# Check for known boot stages.
# Retargeted for the Mac IIvi 2026-07-15: the original LC II stage addresses
# (00A02Exx/00A463xx/00A14Cxx/00A46AF0/00A4685E — 24-bit ROM at $A00000) can
# never occur on this core (1MB ROM at $40800000, overlay-mirrored at $0), so
# the check had FAILed unconditionally since the MacLCII import. IIvi markers
# below were verified against a healthy 30-frame boot trace; same Universal-
# ROM lineage, so the offsets echo the LC list ($xx2Exx POST, $xx14Cxx hw
# init). The box-ID/BoxFlag table is documented at $4084AB4A (CLAUDE.md).
HAS_OVERLAY=$(echo "$MILESTONES" | grep -c " 00002E" || true)
HAS_ROM_HOME=$(echo "$MILESTONES" | grep -Ec " 408" || true)
HAS_EARLY_INIT=$(echo "$MILESTONES" | grep -c " 40802E" || true)
HAS_BOX_ID=$(echo "$MILESTONES" | grep -c " 4084AB" || true)
HAS_STARTUP=$(echo "$MILESTONES" | grep -Ec " 40846[2-8]" || true)
HAS_HW_INIT=$(echo "$MILESTONES" | grep -c " 40814C" || true)

# Check last 1000 lines for stuck loop (same PC repeated)
LAST_UNIQUE=$(echo "$TRACE_LINES" | tail -1000 | awk '{print substr($2,1,8)}' | sort -u | wc -l | tr -d ' ')

# (The LC II version special-cased its ASC boot-chime FIFOSTAT poll at
# $A45E3A, a legitimate 3-PC spin that a mid-chime stop misreads as a hang —
# docs/findings_asc_chime_mame_2026-06-15.md. The IIvi ROM's equivalent poll
# PC hasn't been pinned down yet; if a run reports LOOP in an ASC-polling
# region mid-chime, treat it as benign and re-run with more frames.)

echo "=== CPU Boot Progress ==="
echo "Total instructions: $TOTAL_LINES"
echo "First PC: $FIRST_PC"
echo "Last PC:  $LAST_PC"
echo "PC range transitions: $MILESTONE_COUNT"
echo ""
echo "Boot stages:"
[ "$HAS_OVERLAY" -gt 0 ]    && echo "  [x] POST via \$0 overlay (00002Exx)"     || echo "  [ ] POST via \$0 overlay (00002Exx)"
[ "$HAS_ROM_HOME" -gt 0 ]   && echo "  [x] ROM 32-bit home (\$408xxxxx)"        || echo "  [ ] ROM 32-bit home (\$408xxxxx)"
[ "$HAS_EARLY_INIT" -gt 0 ] && echo "  [x] ROM-home early init (40802Exx)"      || echo "  [ ] ROM-home early init (40802Exx)"
[ "$HAS_BOX_ID" -gt 0 ]     && echo "  [x] Box ID / BoxFlag (4084ABxx)"         || echo "  [ ] Box ID / BoxFlag (4084ABxx)"
[ "$HAS_STARTUP" -gt 0 ]    && echo "  [x] Main startup (40846[2-8]xx)"         || echo "  [ ] Main startup (40846[2-8]xx)"
[ "$HAS_HW_INIT" -gt 0 ]    && echo "  [x] Hardware init (40814Cxx)"            || echo "  [ ] Hardware init (40814Cxx)"
echo ""

if [ "$LAST_UNIQUE" -le 3 ]; then
    echo "Status: LOOP (last 1000 insns only $LAST_UNIQUE unique PCs)"
else
    echo "Status: ADVANCING ($LAST_UNIQUE unique PCs in last 1000 insns)"
fi

# Determine exit code
# Success = got past reset and reached the ROM's 32-bit home ($40800000+)
if [ "$HAS_ROM_HOME" -gt 0 ]; then
    echo "Result: PASS"
    exit 0
else
    echo "Result: FAIL (never reached the ROM home at \$408xxxxx)"
    exit 1
fi
