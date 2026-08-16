# Suggested tasks (parked for later)

Logged 2026-08-16 from the night-run session (see
`docs/resume_2026-08-16_night_run.md` for the full context). Each entry is
self-contained enough to start cold.

## 1. ~~Probe why 68030 cache fills drag instead of paying on HW~~ RESOLVED 2026-08-16

**Closed analytically the same day — no probe build was needed.** See
`docs/resume_2026-08-16_capture_on_ready.md`: ram_ready is AS-gated-decode
+ extra-slot-clobber + latched-din constrained, the old fixed sample
points were structurally blind, and the capture-on-strobe rewrite
(commit on update-CPU) re-enabled the I-cache with Speedometer CPU
1.805→3.435 / video 0.523→0.711 on HW. The chip task_843cfb7f is
superseded. Original text kept below for the record.

### (historical) 1. Probe why 68030 cache fills drag instead of paying on HW

**Why it matters: this is the unlock for re-enabling the I-cache** (and the
path to Friday-class −41% boots, later the D-cache via M10K rework).

The TG68K 68030 I-cache fill engine is a measured NET LOSS on hardware and
was parked 2026-08-16 (`rtl/tg68k/tg68k.v` `USE_68030_CACHE=0`, see the
comment block there). Evidence, all same-night / same-volume / same-UI-state
/ same-CD 48MB boots: no-cache `dea200c6` settles ~100s; ALL three
2026-08-15 cache builds run 213–225s (~2x) — poison-per-line (`e4253e7`),
per-word-retry (`b38c9ac`), and kernel-point capture-v2 (`962d60c`) land
within seconds of each other, so the capture policy is NOT the variable.
Yet Friday 2026-08-15's same-day A/B (91s cache vs 154s no-cache, the
`5a14a511` single-sample-s6 build) showed the engine CAN pay. Stability is
proven (25 consecutive clean boots night-of, clean-only installs held).

Open question: when does `ram_ready` (`rtl/sdram.v:173`,
`dout_valid && dout_addr == addr`) actually rise for a fill-BORROWED bus
read on HW — in-slot before the phi1/s7 capture, or later (making every
fill retry/drop = 8–15 wasted borrow slots per attempt, retried forever
since the cache holds `i_fill_req`)? Sim cannot answer: verilator sim_ram
serves combinationally and `fill_data_valid` is tied `1'b1` in
`verilator/sim.v`.

Plan: build a JTAG/ISSP counter-probe build (`USE_ADB_ISSP` precedent in
the qsf; `dbg_*` infrastructure exists): count fills started /
ready-high-at-capture / retries / installs (`i_fill_valid_r`) / drops over
a boot; deploy (ask-first), read counters, and answer why fills serve on
time in Friday's build but apparently never in the newer ones. Suspects:
the retry loop re-running non-served slots forever vs Friday's fast-fail
poison (compare per-attempt slot cost), fill borrow slots not actually
reaching an SDRAM service slot (addrController slot rotation), or ready
synchronizer lag.

## 2. Fix scsi_bench sweep rot (532 failing cells)

**Why it matters: CLAUDE.md names this sweep the fast regression gate for
the whole SCSI read/write path — right now it can't bless anything** (the
32KB ring change had to be HW-gated instead).

`verilator/scsi_bench` full sweep (`make && ./obj_dir/Vscsi_bench_top`,
WSL) reports "TOTAL failing cells: 532" on an UNMODIFIED tree (verified
2026-08-15 ~22:55 on update-CPU, baseline A/B with the ring edit stashed).
The July 2026 baseline was 0 failing cells (m10k-repack era). The bench
compiles `rtl/ncr5380.sv` + `rtl/scsi.v` directly
(`verilator/scsi_bench/Makefile` V_SRC); suspects are model-contract drift
from the CD-changer / toolbox / CD-audio churn since July
(`sd_buff_addr_hi` burst addressing, `cdtb_*` ports, the `tb_ack_hold`
model in `scsi_bench.cpp`). Diagnose why the matrix fails uniformly
(likely harness/handshake mismatch, not RTL corruption — the same RTL
passes on real hardware), fix the bench or its C++ HPS model, and restore
the 0-failing-cells baseline so the gate is trustworthy again.
