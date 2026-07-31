# Resume: MacIIvi BlueSCSI Toolbox transport — 2026-07-31

Branch `cd-audio` @ `069acc8` (**unpushed, unmerged**, 4 commits past the
07-30 family-sync validation point). `MacIIvi.qsf` is dirty (SEED, mid-sweep).

---

## 0. STOP — read this first

**The core currently on the MiSTer is BROKEN.** It is the `7ec4e2b` build
(`md5 37035cef0a82f72c75baf3d3ea7775b7`, pushed 08:19). On it **every** BlueSCSI
Toolbox command returns CHECK CONDITION: MacAtrium lists no shared files and no
CDs. The CD-ROM data path, audio, disks and boot are unaffected.

The fix is committed (`d4c70e6`) but **has not been built into a deployable
RBF** — a Quartus seed sweep was still running when this was written.

**Rollback (30 s, no rebuild):**
```bash
ssh -i ~/.ssh/mister_only root@$MISTER_HOST \
  "cp /media/fat/_Unstable/MacIIvi.rbf.prev_20260731_0535 /media/fat/_Unstable/MacIIvi.rbf && sync"
```
That restores `md5 9fd8bbd6032ddc238fa1f0c3b45f23aa` (the 05:35 build =
`52715a7` RTL). On it the Toolbox works but large Mac→SD copies still abort —
that is the bug this whole effort is about. Reload the core after swapping.

---

## 1. Three distinct bugs — status

| # | Bug | Status |
|---|---|---|
| 1 | Mac→SD copies lost 16 bytes per 512-byte block | **FIXED, deployed, HW-confirmed** |
| 2 | Mac→SD copy aborts mid-file: "The SD card refused the transfer" | **FIXED in `d4c70e6`, NOT yet built** |
| 3 | GET (SD→Mac) under a stalled HPS silently corrupts | **KNOWN GAP, pre-existing, untouched** |

### Bug 1 — the 16-byte hole (done)

The transport packs the 10-byte CDB and the DataOut payload into ONE 512-byte
block with the payload at byte 16, leaving only 496 bytes for a 512-byte chunk.
The core's buffer word address wrapped (`11'd8 + data_cnt[8:1]` sliced to
`TB_ADDRW=8`), so payload bytes 496..511 landed back at buffer words 0..7.

Arithmetic that identified it (from the shared folder listing):
- `Machine Data.bin` 102896 = 200×512 + 496
- `TIM Audio.bin` 45552 = 88×512 + 496
- `Machine Info.bin` 12784 = 24×512 + 496

All three are ≡112 mod 128, but a genuine MacBinary file is **always** a
multiple of 128. Each was exactly 16 bytes short.

Fixed core-side by shipping the payload's 16-byte tail as a second request
block at LBA 1 (`205800b`, `7efe80e`) and host-side by reassembling it
(Main `96caa9d`). **Confirmed on HW:** `Machine Data.bin` is now 102912 =
201×512 = 804×128. ✅

### Bug 2 — the slow-HPS abort (the live one)

**Symptom:** a ~2.7 MiB Mac→SD copy died with "The SD card refused the
transfer", leaving exactly **905728 bytes = 1769 × 512** — a clean block
boundary, no partial block. Small files always worked.

**Root cause.** `/media/fat` is exFAT mounted **`sync,dirsync`** (verify with
`mount | grep fat`). Every SEND chunk is a synchronous card write. When the card
hits an internal erase cycle the HPS handler does not answer inside the core's
~8 ms watchdog (`tb_to` is 18 bits ≈ 262144 cycles @ 32.5 MHz). `TBS_LATCH`
then found the buffer still holding the CDB it wrote — no `0xB5` signature —
and concluded *no handler*, returning `tb_status <= 8'h02` = CHECK CONDITION.
One slow round trip out of ~1770 kills the whole copy.

**The fix (`d4c70e6`), one branch in `TBS_LATCH`:** on a missing signature,
**re-issue the read** (`tb_rd_r <= 1'b1; tb_lba_r <= 32'd0; tb_to <= 0`) and
look again, up to `TB_RETRY_MAX` (7'd96 ≈ 0.8 s), before declaring CHECK.

Re-issuing is the whole point — see §2.

### Bug 3 — GET under stall (known gap, DO NOT casually "fix")

`TBS_DATA` advances on the bare watchdog, and a data block carries **no
signature**, so a stalled sector serves the previous sector's bytes. Verified
pre-existing: the same probe fails identically on `52715a7`. Reproduce with
`scsi_bench --mode toolboxslow` — it reports:

```
toolboxslow: KNOWN GAP (pre-existing, not a regression) - GET under a stalled
HPS corrupts 2552/4096 bytes; TBS_DATA has no fill evidence to wait on.
```

It is reported, deliberately **not** counted as a failure, so the gate stays
meaningful. Fixing it needs positive fill evidence in the core — which is
exactly what blew up in §2. **Do not attempt it without first building an
HW-faithful model of the ack handshake.**

---

## 2. The `7ec4e2b` regression — what went wrong, so it is not repeated

`7ec4e2b` tried to fix Bug 2 *and* Bug 3 by rewriting the round-trip completion
logic. It broke **every** Toolbox command on hardware while passing every bench
mode. Two wrong assumptions:

**(a) The retry assumed the read request was still asserted.** It only re-armed
the timer. But `TBS_STAT` contains `if (tb_ack) tb_rd_r <= 1'b0;` — and
`tb_ack` is *always* observed as a level, because `tb_hps_wr = sd_buff_wr &
tb_ack` is what fills the buffer at all. So by retry time no request was
outstanding, the HPS never re-filled, all 96 retries re-read the same stale
bytes, and every command ended in CHECK.

**(b) Gating the watchdog on `tb_ack`** (`tb_to <= tb_ack ? 0 : tb_to+1`)
removed the fixed ~8 ms force-latch.

Also introduced and reverted: `tb_fill_done` (a count of the 256 `sd_buff_wr`
strobes per block) and `tb_ack_seen` (requiring a fresh ack **rise** per
transfer). `tb_fill_done` completes a fetch *before* the HPS drops `tb_ack`;
the next state then raises `tb_rd` and the still-high stale ack clears it again
on the next cycle, so the HPS never sees the request and the round trip wedges.

**Why the bench missed it:** the HPS model completes on the ack fall at
`latency = 600` cycles against a 262144-cycle watchdog. The timeout path — the
one that matters on HW — was never exercised.

### The corrected mental model (important)

`rtl/scsi.v` carried a comment from 2026-07-21 claiming the tb READ ack "is not
observed by the core" on HW. **Taken literally that is false**, and believing it
caused this regression. Proof: `--mode toolboxwdog` holds `tb_ack` high past the
force-latch, and under that model even the silicon-proven `52715a7` fails
(`TBS_DATA` clears `tb_rd_r` on the stale ack, the fetch never issues, and the
status block gets served as LIST data). LIST demonstrably works on real
hardware, therefore **the ack fall IS normally caught; the watchdog only covers
occasional misses.** The comment in `scsi.v` has been corrected.

---

## 3. Why the current fix is believed safe

- It is a **one-branch delta** from `52715a7`. `TBS_REQ2` / `TBS_REQ` /
  `TBS_STAT` / `TBS_DATA` are back to the silicon-proven logic verbatim.
- **The branch is provably inert on the normal path.** Instrumented `tb_retry`
  over `--mode toolbox +tb_debug`: `retry=0` in **all 80** state transitions.
  Under `--mode toolboxslow` it goes 1 → 2. So outside the case where the old
  code returned CHECK, behaviour is bit-identical to what works on HW today.
- `--mode toolboxwdog` gives **byte-for-byte identical output to `52715a7`**
  (see the differential signatures in §4).

---

## 4. Desk regression — commands and expected output

```bash
wsl -e bash -lc "cd /mnt/c/Temp/mistercore/MacIIvi_MiSTer/verilator/scsi_bench && make -j\$(nproc) && for m in toolbox toolboxslow gapcmds cdvol wbyte wword; do ./obj_dir/Vscsi_bench_top --mode \$m; done && ./obj_dir/Vscsi_bench_top"
```

Expected: `toolbox` PASS, `toolboxslow` PASS (+ the KNOWN GAP line),
`gapcmds` PASS, `cdvol` PASS, `wbyte`/`wword` `mismatches=0`, full sweep
`TOTAL failing cells: 0`.

**⚠ ALWAYS check the build actually succeeded.** Earlier in this session a
`%Error` scrolled past a `grep` filter and the *stale* binary reported PASS,
which was reported as evidence. Guard every run:
```bash
rm -f obj_dir/Vscsi_bench_top && make -j$(nproc) && test -x obj_dir/Vscsi_bench_top || echo "BUILD FAILED"
```

### Bench modes (all in `verilator/scsi_bench/scsi_bench.cpp`)

| Mode | Covers |
|---|---|
| `toolbox` | COUNT/LIST/SEND/GET round trips, fast HPS (`latency=600`) |
| `toolboxslow` | Every 3rd tb READ stalled 786432 cycles (3 watchdog periods) — **the Bug 2 gate** |
| `toolboxwdog` | `tb_ack` held 300000 cycles past the force-latch — **differential probe, NOT pass/fail** |

`toolboxwdog` differential signatures — a candidate that fails *earlier or
differently* than `52715a7` has changed the handshake and must not ship:

```
52715a7 (good) : LIST corrupt at byte 1, SEND stalls at byte 23
7ec4e2b (bad)  : dies on the FIRST command (COUNT)  <- the HW symptom
d4c70e6 (fix)  : byte-for-byte identical to 52715a7 => no divergence
```

Useful knobs added this session: `Hps::tb_slow_every`, `Hps::tb_slow_latency`,
`Hps::tb_ack_hold`, and the global `csr_patience` (initiator CSR-poll budget;
default 50000 is far too small when a stall legitimately holds the target —
raise it to ~3e6 for stall tests). RTL trace: build with `SIMULATION` and run
with `+tb_debug` for one line per tb state transition.

### ⚠ The biggest remaining coverage hole

`scsi_bench_top.v` instantiates `ncr5380 #(.DEVS(2))` but **does not connect
`cdtb_mounted` / `cdtb_lba` / `cdtb_rd` / `cdtb_wr` / `cdtb_ack` /
`cdtb_buff_din` at all** (see the port list ~line 109). The CD-changer Toolbox
target (ID 3, `CDCHANGER_ENABLE(1)`, `TB_ADDRW(11)`) has **zero simulation
coverage**. Both toolbox targets share the same `scsi.v` round-trip FSM, so any
change to it is untested against the changer. **Wiring this up is the highest
-value next piece of test infrastructure.**

---

## 5. Netlist / seed state

Per-fit seed law: every netlist change is a fresh roll. Confirmed hard this
session — SEED 4 fitted `7ec4e2b` at **+0.058** and `d4c70e6` at **−0.123**.

`7ec4e2b` sweep (`output_files/seed_sweep_slowhps/`):
`s2 −0.007`, `s1 −0.001` (ALM 98%), `s3 −0.054`, **`s4 +0.058` WINNER**.

`d4c70e6` sweep (`output_files/seed_sweep_minfix/`), **in progress**:
`s4 −0.123` fail; `s2` was compiling. Order tried: 4, 2, 1, 3, 5, 6.

All misses are on the `pll_hdmi` pixel-clock domain, by picoseconds — nowhere
near the SCSI or CPU paths. The design sits at 97–98% ALM / 95% M10K, so the
fitter reshuffles globally on any edit.

Sweep script: `scratchpad/seed_sweep_minfix.sh` (edits `-name SEED` in the qsf,
calls `scripts/build.sh`, archives `sta`/`fit`/`rbf` per seed, stops at zero
negative-slack lines, one retry per seed for transient fitter crashes —
`quartus_fit.exe` threw an `Access Violation` once at SEED 2 and succeeded on
retry).

Resume the sweep with:
```bash
bash "$SCRATCH/seed_sweep_minfix.sh"    # re-runs from SEED 4; edit the list to skip
```

Reference numbers for a good fit: ALM ≈ 40,6xx/41,910 (97%), M10K 524/553 (95%),
DSP 52/112, block memory 74%.

---

## 6. Deploy + validation protocol

**Push only (no reboot, no OSD keys, no input injection):**
```bash
export MSYS_NO_PATHCONV=1
ssh -i ~/.ssh/mister_only root@$MISTER_HOST "cp -a /media/fat/_Unstable/MacIIvi.rbf /media/fat/_Unstable/MacIIvi.rbf.prev_$(date +%Y%m%d_%H%M)"
scp -i ~/.ssh/mister_only output_files/MacIIvi.rbf root@$MISTER_HOST:/media/fat/_Unstable/MacIIvi.rbf.new
ssh -i ~/.ssh/mister_only root@$MISTER_HOST "md5sum /media/fat/_Unstable/MacIIvi.rbf.new && mv /media/fat/_Unstable/MacIIvi.rbf.new /media/fat/_Unstable/MacIIvi.rbf && sync"
```
Verify the md5 matches `output_files/MacIIvi.rbf` before and after the swap.
`scripts/deploy_screenshot.sh` also works but hard-reboots the MiSTer and
OSD-selects the core — only use it when the guest is not running.

**Validation, in order:**
1. Boot; check **Finder colour icons render clean**. That is the marginality
   gate for a fresh fit, not "the desktop appeared" — this core has a documented
   history of probe-less fits corrupting the SCSI read path while STA was met.
2. MacAtrium → Toolbox: **Shared Files must list**, and **CDs must list**
   (`games/MacIIvi/CD3` holds `TIM_3-mac.BIN/.CUE/.chd`; LIST CDS should return
   2 entries — the `.BIN` correctly collapses into the `.CUE`).
3. Copy a **>2 MiB** file Mac→SD. Then **byte-compare**, not size-compare:
   `md5sum` on the device against the Mac-side original. A plausible size is
   exactly what hid Bug 1.
4. Repeat with a second, larger copy — the failure was probabilistic (one stall
   in ~1770 round trips), so one success is not proof.

**Gating law reminders:** a CD attached at boot can hang intermittently on ANY
build — to gate, move `config/MacIIvi.s4` aside, boot, judge, remount. One boot
is never a verdict.

---

## 7. Machine + repo state

**`.143`** (`MISTER_HOST` in `scripts/local.env`, key `~/.ssh/mister_only`):

| Path | md5 / note |
|---|---|
| `/media/fat/_Unstable/MacIIvi.rbf` | `37035cef…` — **BROKEN `7ec4e2b` build** |
| `/media/fat/_Unstable/MacIIvi.rbf.prev_20260731_0535` | `9fd8bbd6…` — `52715a7`, toolbox works |
| `/media/fat/MiSTer` | `3cb3952c…` — owner's PR-prep build **with the SEND speedup**, live |
| `/media/fat/MiSTer.prev` | `0e2b1026…` — built from Main `96caa9d` |
| `config/MacIIvi.s0` | `Mac68KColorGames_v1.hda` — the working boot volume |
| `config/MacIIvi.s2` | PRAM `MacIIvi.nvr` |
| `config/MacIIvi.s3.stale_20260731` | stale CHD parked aside (slot 3 is now Toolbox) — leave it |
| `config/MacIIvi.s4` | CD mounted (`TIM_3-mac.chd`) |

Shared folder is **`/media/fat/games/MacLC/shared`** (global `MiSTer.ini`
`shared_folder=`, shared by both cores) — *not* `games/MacIIvi/shared`.
MiSTer stdout is captured to **`/tmp/verify4.log`** — grep it for
`BlueSCSI Toolbox:` / `BlueSCSI CD Changer:` to confirm Main announced the slots.

**Main_MiSTer** (`../Main_MiSTer`, branch `add-bluescsi-toolbox-for-MacLC`):
owner is preparing a PR and is actively committing — **do not edit or build it
from this session**. `toolbox.cpp` moved to `support/mac/mac_toolbox.cpp` in the
`56ed556` restructure. The SEND speedup handoff is in
`docs/handoff_main_toolbox_send_speedup.md`.

**Repo** — branch `cd-audio`, unpushed:
`205800b`, `7efe80e` (Bug 1) → `52715a7` (docs) → `7ec4e2b` (**the regression**)
→ `6e0ffde` (its seed) → `d4c70e6` (**revert + minimal fix**) → `069acc8`
(differential probe + comment correction).

Push mechanism: SSH to GitHub is broken in this env — use `gh auth setup-git`
then an explicit HTTPS URL, and resync with
`git fetch <httpsurl> main:refs/remotes/origin/main`.

---

## 8. Next steps

1. Finish the seed sweep; deploy the first all-met fit; run §6 validation.
2. Once green: merge `cd-audio` → `main`, push, cut a release RBF.
3. Wire `cdtb_*` into `scsi_bench` (§4) — the CD changer has no coverage.
4. Only then revisit Bug 3 (GET under stall), with that coverage in place.
5. Port the whole thing back to `../MacLC_MiSTer` — `rtl/scsi.v` syncs
   WHOLESALE from MacLC master per CLAUDE.md, so MacLC has the same bugs.

## 9. Process lessons from this session

- **Never inject keys into the guest without asking.** `ws_send.py`'s
  `sleep:<n>` is **seconds**; a `kbdRawDown:1 "sleep:80" kbdRawUp:1` call was
  killed by a 60 s tool timeout, orphaning the key-up and latching ESC down —
  which auto-repeated into MacAtrium and looked like a core fault.
- **A green bench is not evidence unless it covers the path in question.**
  Both this session's regressions passed every existing mode.
- **Always confirm the binary was rebuilt** before believing a PASS.
- **Do not trust load-bearing comments** — the "ack is not observed" comment
  was wrong and directly caused the regression.
