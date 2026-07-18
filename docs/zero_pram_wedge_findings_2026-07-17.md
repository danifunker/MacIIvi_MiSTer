# Zero-PRAM happy-Mac wedge — investigation findings (2026-07-17)

**Status: PARKED at a well-defined frontier.** The wedge is NOT fixed, but
the mechanism is mapped to within one decision: System 7's ADBReInit runs a
CORRECT, COMPLETE device-enumeration dance against our ADB device model —
and then repeats the entire dance ~22 times instead of once, forever. The
question left is *why the ROM restarts it*; four crisp candidates below.
User impact is fully masked by shipping a seeded `.nvr` (agreed mitigation):
the wedge needs a factory-zeroed PRAM, which forces the only boot path that
runs this strict enumeration.

## Symptom / repro (unchanged, 7x reproduced byte-identical on HW)

Zero `games/MacIIvi/MacIIvi.nvr` (512 zero bytes) → fresh core load → boot
wedges at the happy-Mac screen (1-bit gray), cursor dead, frame md5
`b5d8473072d6ff27266a1d371aaee96c` on every build tried (20260715 pre-clock
-fix, 20260716, PRAM-fix, ASC-fix, ASC-revert). MAME 0.264 and 0.288 boot
the identical scenario to the desktop. Sim repro: zero `rtl/egret/egret.pram`
(sim's PRAM seed), `--no-memtest --scsi0 <copy>`; the livelock is entered
around F850-F900 (ROM blocked in the Egret driver at `4081490C`, stack
$20FExx). ALWAYS restore the seed after (valid copy:
`scratch/egret.pram.valid_backup`; also it's git-tracked).

## What is PROVEN (each with the run/log that proved it)

1. **The boot livelocks inside ADB device enumeration.** The "storm" =
   per-iteration: Egret autopoll-parameter pokes (host cmd
   `01 08 00 B3 30 20` = direct-memory write of $30/$20 into fw vars
   $B3/$B4 — lands correctly, 162/162, `sim_staging2.log`) + ADB Talks and
   Listen-R3 address moves. The one-second time packets riding alongside are
   healthy traffic, not the cause.
2. **The firmware command machinery all works**: dispatch table at $132D
   (cmd 8 = stream write $17CF via a self-modifying STA-extended trampoline
   staged at $A7-$AA; cmd 9 = RTC write $17F7; cmd C = xPRAM write $184A);
   InitUtil's bulk default writes land; reads echo correctly. Fully mapped
   in `scratch/dasm6805.py` output; receive buffer $B9+ verified byte-exact.
3. **The device-level enumeration dance is CORRECT** (`sim_adb.log`,
   pre-ratio-fix run with ADB_TALK/ADB_LRX_DONE displays): Talk F while
   devices home (probe-empty ✓ 46x), Listen-R3 moves 2→F and back F→2 with
   clean payloads (`0ffe`/`02fe`/`03fe`, RELOCATE honored, 91x), Talk at
   the vacated home address correctly times out. Every observed exchange is
   what a real device would do — EXCEPT it all repeats ~22 times.
4. **Eliminated with hardware/sim/OR-oracle evidence**: mdc824 1bpp video
   (wedge frame renders fine; card untouched across builds), Egret HC05 ISR
   register corruption (entry/exit snapshots bit-identical), ASC IRQ storm
   (silicon-faithful semantics deployed → wedge unchanged, then reverted for
   an unrelated sound regression), pseudoVIA latch (edge-correct by
   inspection), PRAM injection (boot-copy fires, zeros arrive, ROM sees
   invalid signature and enters InitUtil as designed), tick-collision timing
   (identical wedge on builds with dead/one-shot/working one-second IRQs),
   Egret set-time (never implicated once the storm was decoded), and the
   ADB Listen-payload mis-capture theory (payloads decode clean at the
   firmware's real cell rates — the threshold fragility was real but only
   under >=30% rate skew, which the firmware doesn't produce; fixed anyway,
   commit ef79246).

## The frontier: why does ADBReInit restart ~22 times?

Candidates, in current order of suspicion:

1. **Talk R3 response content.** Real ADB devices return a RANDOM address
   in R3 bits[3:0] on Talk R3 (anti-collision), and specific flag bits
   (bit6 exceptional-event, bit5 SRQ-enable). Ours returns its REAL address
   with hardcoded flags `{0,1,1,0}` (adb_device.sv Talk R3 cases) and never
   stores flag/handler updates from Listen R3 (only the address nibble).
   If the ROM sets SRQ-enable / handler via Listen R3 and re-reads R3 to
   verify, our unchanged response could fail the verify → restart. Check
   MAME's macadb.cpp Talk-R3/Listen-R3 handling for the expected content.
2. **SRQ behavior.** `srq_want` asserts on pending kbd FIFO / mouse event
   when another address is polled. If anything queues during enumeration
   (PS2 init junk, mouse_init), the SRQ storm makes the ROM re-enumerate to
   find the requester. Check: display S_SRQ entries during the storm.
3. **Device count/shape.** We present exactly kbd@2 + mouse@3. The ROM
   sweep (addresses 4-E probed once, seen in the log tail) is clean, but
   the per-device dance count (22x) vs 2 devices suggests ~11 restarts of a
   2-device pass — a systematic per-pass failure, consistent with (1).
4. **Interleave with Egret-initiated traffic**: a tick/response packet
   landing mid-dance could make the ROM driver abort-and-retry the pass.
   Ruled UNLIKELY by the 20260715 A/B (one-shot tick build wedges
   identically) but not impossible for the notify-pending flags.

## The tooling that makes resumption cheap (all committed / in scratch)

- **`verilator/adb_bench/`** (committed): standalone Verilator bench for
  adb_device.sv — drives scripted attention/command/Listen-R3 waveforms
  with independent command/payload cell timing. SECONDS per iteration; this
  replaced 90-minute boot replays. Extend `sim_adb_main.cpp` to replay the
  full 22x dance + SRQ scenarios for candidates 1-3 without any boot.
- ADB_TALK / ADB_LRX_DONE displays (committed, adb_device.sv): every Talk
  vs current device addresses; every Listen-R3 payload + decision.
- Egret firmware probes (committed, egret_wrapper.sv): PRAM/RTC/work-RAM
  writes with firmware PC.
- `scratch/dasm6805.py` — minimal 6805 disassembler (ROM at $0F00, use
  `scratch/egret_fw.bin`). `scratch/parse_egret_sessions.py` /
  `parse_mame_sessions.py` — session-level transcripts from sim logs / MAME
  `session_probe.lua` captures. `verilator/mame/session_probe.lua`
  (committed earlier) — byte-level VIA SR/ORB taps for MAME.
- MAME references: `scratch/zeropram_mame/session_run/bytes.log` (0.264
  zero-PRAM InitUtil conversation, byte-exact), `~/repos/mame/iivi`
  (0.288 driver-scoped build, boots zero-PRAM to desktop).
- Key sim logs (scratch/zeropram_sim/): `sim_adb.log` (the enumeration
  trace), `sim_staging2.log` (trampoline + buffer forensics),
  `all_sessions2.txt` (parsed session transcripts; NOTE tx bytes there are
  one-shift stale — destale = rol1; rx bytes are exact).

## Recommended resumption path

Extend the adb_bench to emulate the ROM side of one full enumeration pass
(the exact command sequence is in `sim_adb.log` / MAME `bytes.log`),
asserting after each step what a real device would answer (from MAME
macadb.cpp as oracle). The first divergence — R3 content, SRQ, or flag
handling — is the fix. Then the standard ladder: zero-PRAM sim boots past
F900, check_boot, build, scripted HW zero-PRAM retest
(`b5d84730...` md5 must NOT reappear; desktop must).
