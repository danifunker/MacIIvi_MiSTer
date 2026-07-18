# M10K repack plan — branch `m10k-repack` (2026-07-18)

Port of the MacLC_MiSTer M10K reclamation (2026-07-17, HW-validated there) to
this core. Everything below is verified against this repo's fresh fit report
(`output_files/MacIIvi.fit.rpt`, Jul 17 22:47 — the build that produced the
deployed/validated `ed92857f` rbf) and against the MacLC commits by diff, not
by assumption.

## OUTCOME — DELIVERED + HW-VALIDATED (2026-07-18)

Branch landed in four commits (`e6dbbe6` qsf repair → `6697281` docs →
`2e910af` tier 1 → `8c82738` prefetch). **543 → 495/553 M10K blocks (−48,
8.7% of device)**, content bits 4,339,263 → 4,018,944, STA met on both RTL
commits (worst +0.258 / +0.207, SEED 5).

**Hardware validation on .143** (rbf `9de08c35`, owner-authorized deploy):
boots happy-Mac → 7.6.1 → **Finder on the mdc824 card**; boot-volume window
renders a real HFS catalog (the SCSI pseudo-DMA READ path — the exact
prefetch redesign — returning correct data); ADB mouse tracks; RTC advancing;
**boot chime pitch confirmed correct by the owner** (the regression canary for
any RAM/divider change). Evidence: `releases/hw_143_m10k_*_20260718.png`.
Sim corroboration: `scsi_bench` full alignment sweep 0 fails (pre & post),
1300-frame boot A/B bit-identical to baseline, F2200 soak = 24 reads +
1 write through the prefetch dpram, no timeout/stall/wedge.

Not-yet-exercised (lower risk, bench+soak+MacLC-HW cover the mechanism):
extension-heavy read stress, large-copy write-verify, CD mount.

## Baseline (main @ c7f88b3 + working-tree qsf repair)

| Metric | Value |
|---|---|
| M10K blocks | **543 / 553 (98%)** |
| Block memory content bits | 4,339,263 / 5,662,720 (77%) |
| Block memory implementation bits | 5,560,320 / 5,662,720 (98%) |
| ALM | 35,634 / 41,910 (85%) |
| Registers | 34,624 |
| STA | fully met (no negative slack, SEED 5) |

The 77%-content vs 98%-implementation gap is the disease: whole blocks held
at 1–3% utilization, exactly MacLC's pre-repack shape.

### Census (fit.rpt hierarchy, leaf nodes)

| Blocks | Content bits | What | Verdict |
|---|---|---|---|
| 384 | 3,145,728 | `mdc_vram` (mdc824 framebuffer) | Packed 100% in x8 mode. Leave. (Tier 3: real fb is ~300KB → ~84 reclaimable, touches sad-Mac #9 card sizing.) |
| 65 | 532,480 | `ncr5380` — 6 `scsi_dpram` instances | **39 blocks are ram_c/ram_d mirror copies → prefetch port** |
| 43 | 315,488 | `ascal` (framework scaler) | Efficient 4–6Kbit shifters; MacLC deliberately left these. Leave. |
| 32 | 262,144 | mdc824 declaration ROM (16K×16) | Packed. Leave. (Tier 3: → SDRAM.) |
| 8 | 65,536 | osd ×2 (vga + hdmi buffers) | Full blocks. Leave (but pin — see hygiene). |
| 4 | 3,140 | `shadowmask:HDMI_shadowmask\|vid` shifter | **Junk — tier 1** |
| 1 | 93 | `vga_out:vga_scaler_out\|din1` shifter | **Junk — tier 1** |
| 1 | 90 | `vga_out:vga_out\|din1` shifter (2nd instance; MacLC listed only one) | **Junk — tier 1** |
| 1 | 36 | `yc_out:yc_out\|phase` shifter | **Junk — tier 1** |
| 1 | 128 | `swim:sw` ism_param | **→ MLAB — tier 1** |
| 1 | 64 | `adb_device:adb_dev` kbdFifo | **→ MLAB — tier 1** |
| 1 | 8,192 | `asc` fifo | Full block. Leave. |
| 1 | 6,144 | `ariel` palette (256×24, pinned M10K) | Leave. |

Note: MacLC's other two tier-1 targets (`osd rdout2` 42b, `sys_top dv_de1`
153b) are **not inferred as M10K shift-taps in this core's framework** (map.rpt
altshift_taps inventory: only the five instances above exist here). Their qsf
patterns are included anyway as future-proof no-ops.

## The MacLC recipe (what we're porting)

1. **`9c5d47f` m10k-repack tier 1** (−14 blk there): per-instance
   `AUTO_SHIFT_REGISTER_RECOGNITION OFF` in the core qsf for the junk
   delay-line shifters (framework constrained from the core's qsf, `sys/`
   untouched); `(* ramstyle = "MLAB" *)` on adb kbdFifo + swim ism_param.
   Audit signature there: +386 regs / −442 bits, zero inference flips.
2. **`a2ae04d` pdma-prefetch** (−64 blk there): `scsi_dpram`'s `ram_c`/`ram_d`
   full mirror copies (which existed only to serve same-cycle mac_addr+1/+2
   look-ahead reads for pseudo-DMA word/long assembly) deleted; `ram_ab`
   becomes the only storage; a 3-state controller fetches the two look-ahead
   bytes through idle port-B cycles into `q_c`/`q_d` holding registers.
   Port-B writes always win arbitration; write path uses the same muxed
   address (single-address TDP port — anything else breaks Quartus RAM
   inference, Error 276003). Coherency by snoop-refetch (any-port write
   hitting a held/in-flight look-ahead address discards + refetches).
   `ncr5380.sv` `dma_settle` widened 4→8 (`reg [2:0]`→`[3:0]`) to cover the
   up-to-3 extra port-B disturbance cycles per address advance.
   Interface-identical module — zero instantiation-site changes.
3. **`bae8fd8` bram pinning lore**: Quartus 17 re-rolls small-RAM inference on
   netlist churn; ≥8Kbit victims randomly fall to register fabric (+55K regs
   once). Plain `no_rw_check` does NOT prevent it — only the full
   `"M10K,no_rw_check"` block-type pin does. MacLC pinned scsi_dpram arrays +
   `sys/osd.v` osd_buffer + `sys/ascal.vhd` poly tables.
4. **`0d38a1a` framework-files law + revert** (the corrective, same morning):
   after HW black-screens on the relief-era stack, MacLC put `sys/` back
   bit-stock and instituted the LAW: *sys/ framework files are off-limits
   except wholesale template updates; reconcile from rtl/ + qsf/sdc side
   only.* The `rtl/scsi.v` pins were KEPT (core file). Two more hard facts
   from that commit: **Q17 Lite has no per-instance RAM block-type qsf
   assignment (`RAM_BLOCK_TYPE` is an illegal name)**, and the
   `AUTO_RAM_TO_LCELL_CONVERSION OFF` / `STRICT_RAM_RECOGNITION ON` knobs
   are proven useless against the inference-flip class. Their actual cure
   for the flip disease was the repack itself — **headroom**: at 553/553
   the mapper refused osd_buffer M10K inference; at 489/553 it behaves.

### Port-fit facts (verified by diff today)

- `scsi_dpram` in this repo is **byte-identical** to MacLC `a2ae04d^` —
  the redesign transplants mechanically.
- The prefetch mechanism is **stable in MacLC**: `a2ae04d`'s scsi_dpram ==
  MacLC HEAD's, zero diff. Every later scsi.v commit is cd-audio/toolbox
  (features this core doesn't have). Nothing else to pick up.
- `ncr5380.sv` dma_settle region here is at the exact pre-prefetch state
  (`reg [2:0]`, settle=4) — the widening applies as-is.
- Ring sizes differ from MacLC (SCSI-1 + CD rings were already trimmed here
  on 2026-07-13): t0=8KB, t1=4KB, CD=1KB. Mirror inventory:
  t0.b0 16 + t0.b1 8 + t1.b0 8 + t1.b1 4 + cd.b0 2 + cd.b1 1 =
  **39 blocks / 319,488 content bits**.
- The CD target instantiates the same scsi_dpram → gets the prefetch for
  free; MacLC's whole cd-audio campaign ran ON the prefetch dpram afterward
  (extra confidence in the mechanism under CD-read patterns).
- `ram_ab` pin: a2ae04d shipped the redesign UNPINNED (the 2544a1f merge had
  silently dropped bae8fd8's pin), and MacLC re-added it 2026-07-18 in
  `effb436` after this port review flagged it. Our transplanted module
  carries the `(* ramstyle = "M10K,no_rw_check" *)` pin from day one.
- `sys/` stays untouched (see provenance below). The framework RAMs
  (osd_buffer, ascal tables) are unpinned here, same as MacLC post-law;
  protection = the headroom this branch creates + the per-commit zero-flip
  audit gate. If a flip bites mid-branch (MacLC's vga_osd episode), the
  recorded remedy is to keep landing the block-freeing commits — reorder
  (prefetch first) rather than reach for sys/ edits or the proven-useless
  qsf knobs.

## sys/ provenance (checked 2026-07-18)

Exactly **two commits** have ever touched `sys/` here — `9bb652b`
(2026-06-14, template seed, 57 files) and `059b8d7` (2026-07-11, the
MacLCII @ a254a02 verbatim import) — **zero hand-edits since seeding**,
matching the intended policy. Vintage: the seed is the same f35083f-era
template drop MacLC synced to on 2026-06-04 (`Template_MiSTer` sibling
checkout == f35083f, 2026-05-13); the import overlaid some files with
MacLCII-vintage copies (osd.v among them; ascal.vhd matches the sibling
template byte-for-byte). The framework state matches the HW-validated
MacLC family where it matters, and the junk shifters targeted by tier 1
exist in the current template too (MacLC hit them post-sync) — a wholesale
template refresh would gain nothing for this effort and is NOT part of this
branch. Adopt MacLC's framework-files law into our CLAUDE.md (commit 0).

## Projected result

543 − 39 (mirrors) − 7 (shifters) − 2 (MLAB tinies) = **~495/553 (89%)**,
−~323K content bits, +~850 regs. ≈ 48 blocks = 8.7% of the device freed —
the same "almost 10%" MacLC got, from the same moves.

## Commit sequence (each with its own A&E audit)

0. **qsf repair + doc truth** (repair already sitting in the working tree,
   uncommitted): restore the five `_FILE` entries the committed qsf lost
   (`sys/pll_cfg.qip`, `rtl/dbg_probes.sv`, `rtl/mfm_track_encoder.v`,
   `rtl/vram_bram.sv`, `rtl/pll_video.v` — all instantiated; committed main
   **cannot elaborate** without them), drop the two contradictory duplicate
   assignments at the top (`ROUTER_LCELL_INSERTION_AND_LOGIC_DUPLICATION ON`,
   `PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION ON` — both re-set OFF at the
   bottom; later assignment wins, so this is behavior-neutral dedupe), fix
   the missing trailing newline. Same qsf-corruption family as `cda21e4`;
   this is the qsf that produced last night's successful fit. Also two
   CLAUDE.md corrections: retire the stale "simulator-first phase" deploy
   wording (HW validation is standard practice; deploys stay ask-first,
   owner-authorized) and codify the framework-files law (sys/ off-limits
   except wholesale template updates; constrain from rtl/ + qsf/sdc only).
1. **tier 1** (LANDED as `2e910af`, outcome differs from the MacLC recipe):
   `AUTO_SHIFT_REGISTER_RECOGNITION OFF` **globally**, not per-instance —
   three fit iterations proved Q17's shift-taps conversion works a global
   budget, so pinning the five known instances just rolled the block onto
   the next candidate each time (ascal `o_v_poly_phase` 320b → vga_out
   `csync1` 78b → vga_osd `de2` 78b). This core's complete altshift_taps
   inventory is junk-class (largest 324b; no 4–6Kbit ascal shifters like
   MacLC kept), so global OFF costs ≤~640 regs and retires the class.
   Plus `(* ramstyle = "MLAB" *)` on kbdFifo/ism_param (9c5d47f port).
   Landed audit: 534/553 (−9 blk), −831 bits, +779 regs, ALM −180, pure-
   deletion RAM diff (zero flips), STA met (+0.258 worst, SEED 5).
2. **pdma-prefetch port**: transplant `a2ae04d`'s scsi_dpram module (its
   `ram_ab` `"M10K,no_rw_check"` pin comes with it) + the ncr5380
   dma_settle 4→8 widening. Expect −39 blk, −319,488 bits, +~500 regs,
   all six dpram instances single-array in the RAM summary.

## Validation (sim smoke → Quartus audit → hardware gates, per commit)

Hardware is this project's decisive validation loop; deploys are
owner-authorized per standing policy (ask before any deploy/reboot, never
auto-deploy). Mirror MacLC's HW gates, with sim as the pre-deploy smoke:

- **Verilator smoke** (WSL): rebuild + `./check_boot.sh --run` PASS (ROM-home
  gate). For the prefetch commit additionally: `--scsi0` run on a COPY of the
  7.5.5 image far enough to cover boot-block + driver pDMA reads (~150–200
  frames, background — the exact word/long-assembly path the redesign
  changes), zero pseudo-DMA-timeout hits, A/B `cpu_trace.log` vs a baseline
  run for SCSI-phase divergence.
- **Quartus A&E audit**: full compile; map.rpt RAM-summary diff vs baseline —
  targeted rows gone / dprams single-array and **zero unrelated inference
  flips** (the bae8fd8 disease signature); fit block/bit/reg deltas match the
  expectations above; STA no new negative domains (SEED 5 today; the qsf
  ~line 365 seed-history discipline applies — a reseed is acceptable fallout,
  chasing framework HDMI slack with core edits is not).
- **Hardware gates** (owner go per deploy, .143):
  - tier 1: boot chime (pitch canary), 7.5.5 to Finder on the card, ADB
    mouse/keyboard sanity (kbdFifo moves to MLAB), video clean — the MacLC
    tier-1 gate set.
  - prefetch: the MacLC prefetch gate set — boot + desktop + heavy-read
    stress (extension-rich boot / Control Panels / large copies) +
    write-verify + CD mount (cdrom_target shares the dpram) + chime canary.
- Merge `m10k-repack` → main only after the HW gates pass (branch policy).

## Tier 3 (recorded, NOT in scope)

- mdc824 declaration ROM → SDRAM: −32 blocks; needs NuBus slot-read
  arbitration into SDRAM; touches the sad-Mac #9 card-sizing history.
- Framebuffer right-sizing (384KB BRAM vs ~300KB used): −~84 blocks; same
  risk family. Biggest single lever after this branch lands.
- ascal/osd framework blocks: efficient; leave.
