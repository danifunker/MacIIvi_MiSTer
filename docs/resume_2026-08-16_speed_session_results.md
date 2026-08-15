# Speed session results + handoff (2026-08-15 evening)

Continuation of `docs/resume_2026-08-15_cpu_speed_32mhz.md`. Branch
`update-CPU`, commits `27754dd..HEAD`. Read this TOP TO BOTTOM before
resuming — the failure history changes what "validated" means below.

## What landed (committed)

1. **68030 I-cache ENABLED** (`27754dd` + fixes): the wrapper's cache glue
   audit found and fixed, pre-enable: the stale V8 24-bit cacheable decode
   (now IIvi 32-bit: fitted RAM via new `ram_size_bytes` port + ROM only),
   the `xlate_ready` stale-phys fill hazard, FC=7 cacheability (the ROM's
   must-BERR moves probes), and bus-exact serve/write byte-lane maps.
   D-cache present but tied off (`USE_68030_DCACHE=0`) — with both caches
   the design needs 4353 LABs on a 4191-LAB device; the measured win is
   all I-side anyway (ROM enables only `ie`; dhit=0 everywhere).
2. **Orphaned-AS race FIX** (`2ae8b88`) — the significant RTL find of the
   session, in the ORIGINAL hit-bypass glue: a fill-install pulse lands on
   phi2; the same edge launches the missed access's cycle on pre-install
   hit=0; next phi1 asserts AS while the hit parks the FSM → AS stranded,
   `dtack_en` pre-latches, the NEXT cycle captures unserved SDRAM data.
   sim_ram serves combinationally = sim is constitutionally blind to it.
   Fix: `cache_hit_beat = hit & s_state==0` everywhere + a PERMANENT
   orphaned-AS `$display` tripwire. Fills also redesigned no-stall: normal
   slot-start ack + retrospective per-word `sdram_ram_ready` dirty-check —
   a dirty line is DROPPED (future miss), never installed, never stalls.
3. **ATC 22→8** (`93ce754`): area relief 98%→93% ALM. MacIIvi-local
   parameter in `TG68K_PMMU_030.vhd` — RE-APPLY ON EVERY Minimig RE-SYNC.
   Corpus fail-set A/B vs the committed kernel: IDENTICAL 5 known
   golden-vs-silicon rows ⇒ reconversion behaviorally identical.
4. **IIvx box-ID for the 32 MHz machine** (`93ce754`, NOT YET FITTED):
   `$A55A2017` "Performa 600" was an invented ID — MAME defines only
   2015 (IIvx)/2016 (IIvi) on this ROM, and 2017 was HW-falsified three
   ways in one evening (7.1 model-gate dialog, 7.5.5 unimplemented-trap
   bomb, 7.6.1 mounts-then-rejects; all three boot fine as IIvi). The
   real P600 is a rebadged IIvx ⇒ 32 MHz mode now presents `$A55A2015`;
   OSD relabeled `IIvx-P600 (32MHz)`.
5. **Fill capture hardening** (uncommitted at doc time → commit follows):
   the dirty-check now requires `fill_data_valid` stable for 2 clk at the
   capture edge (razor-edge completion class). Spurious drops retry;
   poisoned lines can't happen.
6. Post-reconvert bench maintenance: ghdl positional regs renumbered
   (regfile n17415/17417→n17490/17492, usp n17577→n17652); vlt+cpp
   updated; probe-regs green on a VERIFIED-FRESH binary (the first two
   runs were the classic stale-binary false-pass — always check
   `[ obj_dir/X -nt kernel.v ]`).

## Measured results (the good news)

- Sim (40f ROM boot): bus fetches 2.03M→150k with caches (93% served
  from I-cache, ~74% window hit rate); the ROM itself enables `ie`.
- Turbo (32 MHz mode) in sim: 2.21x core beats/window in cache-hot code
  after fixing fill starvation (`~cache_fill_pending` gate on the phi2
  arm — an ungated turbo arm eats every 1-beat internal window and the
  phi1-sampled fill engine NEVER fires: 14 fills vs 200 over the same
  window).
- HW boot-to-settled-MacAtrium at 48MB: **~91 s vs 154 s no-cache**
  (−41%); at 8MB ~85-92 s. Welcome ~+35 s vs ~+83 s (the march's fetch
  half vanishes into the I-cache; only its writes remain on the bus).
- Settled desktop grabs BYTE-IDENTICAL across builds and boots (cache
  boot1 = boot2 = the no-cache baseline settled grab, md5 6f6cc3bc) —
  the strongest icon-integrity pass available.
- Prince of Persia: 256-color title + intro cutscene running (grabs).

## The open problem (the bad news — READ FIRST WHEN RESUMING)

**The 93%-ALM I-cache build has an INTERMITTENT boot failure at 48MB:**
2 clean settles, then 1 sad Mac `$0F/$0003` (illegal instruction) on the
third boot. The 98% builds failed EVERY boot (`$0F/$000A` F-line at 48MB
— the ROM's *expected* FPU-probe F-line whose dispatch path executed
corrupted fetches — and a System-load freeze at 8MB). Area relief
reduced but did not eliminate the corrupted-fetch class.

Standing hypotheses, in order:
1. Residual capture-race in the fill path (the §5 hardening targets
   exactly this — UNVALIDATED on HW, fit pending).
2. Utilization marginality persisting at 93% (the anchor law's cures:
   more area headroom, anchor registers over the new cache cones, seed
   hunting; historical precedent is strong).
3. A rarer RTL race not yet derived (the orphan bug shows the class
   exists and that sim data-masks it — trust invariants, not data).

## Device / repo state at handoff

- **Device (.143): ROLLED BACK to the fully-validated no-cache new-CPU
  rbf `dea200c6`** (= `output_files/MacIIvi_latest_68030_CPU.rbf`),
  games volume auto-mounting, CFG restored (48MB, Machine=IIvi),
  s0 restored to `Mac68KColorGames_v1.hda`, the `HD10_761_speedtest.hda`
  test copy deleted. Verify the settled desktop grab in the session log.
- `output_files/MacIIvi.rbf` on disk = the ATC-8 build (`5a14a511`,
  OLD 2017 ID) — do NOT deploy it as-is; the next fit supersedes.
- The Quartus box had the OWNER'S MacLC GUI fit running at session end —
  the queued IIvx-ID+hardening flow was withdrawn to stay out of their
  way. **Next session: run `bash scripts/build.sh` when the box is free.**
- `releases/boot0-fastmem.rom` = committed fast-march ROM for deep-boot
  sims (`--rom ../releases/boot0-fastmem.rom`); regenerate any time with
  `verilator/patch_fast_ramtest.py`.

## Next session ladder

1. Fit the tree (IIvx ID + capture hardening), STA check, deploy.
2. 48MB boot MARATHON — the intermittency needs ≥5 consecutive clean
   boots (script the loop; ~4 min/boot), plus the 8MB spot check.
3. If a sad Mac recurs: pivot to the marginality levers (anchor regs
   over `gen_cache`/fill cones, seed sweep, or shrink further — e.g.
   drop `WALK_MAX_TRIES`, or the mdc824 decl-ROM→SDRAM −32 M10K item)
   and/or instrument: the sad-Mac minor codes vary with the corrupted
   opcode — a JTAG fline/exe_pc probe build pins the faulting fetch.
4. 32 MHz validation with the IIvx ID: expect even the 7.1 games volume
   to boot (IIvx is 7.1-native). Gates: boot, desktop byte-compare, PoP,
   two boots, About This Macintosh (should say IIvx family), and the
   turbo speed number (boot time + PoP feel).
5. Only then: merge call to the owner (16 MHz cache default; 32 MHz
   option), release notes, README.

## Session laws confirmed/added

- sim_ram's combinational serve BLINDS the sim to early-DTACK data
  hazards — guard with INVARIANT tripwires (orphaned-AS stays in).
- 40-frame sims cover 0.66 s of guest time; the 48MB gray phase alone is
  ~80 s. Deep-boot claims need the fastmem ROM + hundreds of frames.
- `regen_tg68k.sh` does NOT analyze PMMU/Cache (stale work-obj masked
  it): clean-room order is Pack→ALU→PMMU→Cache→Kernel, then synth.
- MiSTer CFG = 16 raw status bytes at `config/MacIIvi.CFG` (byte0 bit1 =
  Machine, bits 2:4 = Memory); `.s0` rel-path mounts REQUIRE a
  space-free filename (space-named .hda silently fails to mount).
- MacAtrium's ESC Quick-Launch menu has keyboard Restart/Shut Down —
  the clean-shutdown path when the browse screen is up (8 downs from
  Settings to Shut Down, then Return).
