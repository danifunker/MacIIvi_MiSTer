# Resume: CPU performance + 16/32 MHz Performa 600 mode

Owner request (2026-08-15, during the CPU-update session): the core feels
slower than the MacLC (68020) core. Goal: (1) close the gap, (2) support BOTH
16 MHz and 32 MHz CPU speeds matching the Mac IIvi / Performa 600 pair, with
the speed selection taking effect ONLY between reboots. All other devices must
keep working (i.e., keep their real-time rates).

## State this doc assumes (end of the 2026-08-15 CPU-update session)

- Branch `update-CPU`: the CPU is the latest Minimig-AGA 030_mmu lineage
  (import commit `ad23427` + the DIVU divide-by-zero silicon fix). Corpus
  720/721 (only the pre-existing CHK.W-negative CCR minutia + the known
  USP-injection harness gap remain), 40-frame ROM boot smoke green.
- `rtl/tg68k/tg68k.v` implements the new wrapper contract: clkena held on
  `pmmu_walker_req` + `pmmu_busy`, released on `pmmu_fault`, `beat_valid`
  real-ack qualifier, bus FSM parked at s_state 0 while busy/faulted.
- 68030 I/D cache RTL is IN THE TREE and CURRENT (TG68K_Cache_030.vhd +
  TG68K_CacheCtrl_030.vhd reference + the wrapper's cache glue/fill engine)
  but DISABLED: `localparam USE_68030_CACHE = 1'b0` in tg68k.v.
- HW validation status of the import build: see the session end / project
  memory (fit was in flight when this doc was written).

## Why the 030 core can feel slower than the 68020 MacLC today

1. **No caches enabled.** A real IIvi beats an LC largely because of the
   030's on-chip I+D caches; ours are off. Every fetch pays the full Mac bus
   cycle (4 phi cycles + slot-start DTACK alignment, 3 of 4 slots) across a
   16-bit bus, plus the mdc824 FSM for every QuickDraw write.
2. **PMMU tax.** With TC.E=1 (System 7 enables the MMU), every access start
   runs the translation-freshness check; ATC misses run multi-descriptor
   table walks over the borrowed bus (with the re-read-until-stable SDRAM
   workaround: up to 6 re-reads per descriptor). The 68020 MacLC pays none
   of this.
3. **busy-park phi alignment (NEW with the 2026-08-15 wrapper — audit me).**
   `pmmu_bus_park` holds s_state at 0 while `pmmu_busy`. On an ATC hit,
   busy is high for ~1-2 clk_sys right after the kernel presents a new
   address (translated_addr freshness, their BUG #416). If that window
   overlaps the phi2 edge where s_state would leave 0, the access is
   delayed a FULL phi period. Whether this bites depends on clk_sys-vs-phi
   alignment of the clkena edge — instrument in sim (count parked-at-phi2
   events / accesses) before optimizing. Possible shave: allow s_state 0→1
   while busy if busy is guaranteed to resolve before AS asserts at
   s_state 1 (the address register loads at the same edge either way), or
   pre-translate: the kernel presents addr at clkena (phi1) and AS is ~2
   clk later — there is slack to hide the 1-2 clk freshness window.

## Phase 1 (recommended): enable the 68030 caches at 16 MHz

- Flip `USE_68030_CACHE = 1'b1` in tg68k.v. The glue is already written
  (read-hit bypass holds s_state at 0 + immediate clkena; line-fill engine
  borrows the parked bus like the PMMU walker; walker excluded during
  fills). It has NEVER been validated — treat as new RTL:
  - The cacheable-region decode in the generate block is the OLD V8 24-bit
    map (`cache_addr_phys[23:20] <= 4'hA` — "RAM $000000-$9FFFFF + ROM
    $A00000-$AFFFFF"). This is STALE for the IIvi 32-bit map (RAM at $0,
    ROM at $40800000, I/O at $50000000 + $00F00000 mirrors, NuBus $Fs/$s).
    REWRITE against rtl/addrDecoder.v's actual map before first enable —
    caching I/O or NuBus is instant death. Keep it conservative: RAM + ROM
    only, honor pmmu_cache_inhibit (already wired via fill_inhibit).
  - CACR gating is real in the new kernel (cacr_ie/de, freezes, CI/CEI/CD/
    CED ops via cache_inv_req/cache_op_*) and the corpus CACR row is
    silicon-adjudicated ($00003313 readback) — the OS can and will turn
    caches on/off; the ROM POST may test them.
  - Validation ladder: corpus (unchanged — bench has no cache),
    check_boot 40 frames, then a LONG sim boot compare (cache on vs off
    must reach identical milestones), then HW: boot + Finder + icon
    integrity (marginality-anchor law) + PoP/game audio + SCSI heavy-read
    (cache vs DMA-less SCSI reads = the coherency risk; the kernel/L2
    invalidate machinery from their BUG #462 helps but OUR wrapper cache
    is separate — check the fill/invalidate paths against SCSI writes to
    RAM. There is NO bus snooping: pseudo-DMA goes through the CPU so
    plain SCSI is safe, but verify sound DMA / IWM / video writes don't
    have a non-CPU RAM writer... on this core all RAM writes ARE CPU
    writes, which is why write-through + no-snoop can work).
- Expected win: instruction fetches dominate the bus; an enabled I-cache
  removes most of them. This alone may close the "slower than MacLC" gap.

## Phase 2: 32 MHz Performa 600 mode

Design constraints agreed with the owner:
- OSD "Machine: Mac IIvi (16 MHz) / Performa 600 (32 MHz)" — the P600
  box-ID select already exists (status bits + $5FFFFFFC = $A55A2017).
  Extend it to also select the CPU grid, LATCHED AT CORE RESET ONLY (same
  pattern as the RAM-size gating: sample status at cold boot, ignore live
  changes; "takes effect between reboots").
- The 2x applies ONLY to the CPU phi grid (phi1/phi2 enables 15.6672 →
  31.3344 MHz toggle rate). Peripheral rates are ABSOLUTE and must not
  change: E/VIA1 783.36 kHz, 60.15 Hz tick, SCC RTxC 3.672 MHz, ASC
  22.26 kHz, Egret HC05 cen, video pixel clocks. Audit every divider that
  currently counts phi or clk16_en — anything CPU-grid-derived must be
  re-based onto clk_sys absolute enables.
- clk_sys is 32.5055804 MHz (pll_0002.v is truth). A 31.3344 MHz phi grid
  does NOT fit under 32.5 MHz (no headroom for the 2-phase FSM: s_state
  needs clk >= 2x phi edge rate; today phi edges run at 2x15.67=31.3M
  edge/s against 32.5M clk — the CPU FSM is nearly clk-limited already!).
  So 32 MHz mode means moving tg68k.v (+ addrController arbitration) to
  the 65 MHz clk_mem domain, or a new PLL output (~62.7 MHz = 4x C15M)
  with proper CDC at every boundary the wrapper touches (dataController
  peripherals, SDRAM controller slots, video). THIS IS THE BIG JOB.
  Investigate first: what does the SDRAM slot schedule allow? RAM
  bandwidth must serve 2x CPU access rate or the 32 MHz CPU just waits
  (real P600 gains ~2x from clock + caches; even a partial gain with
  caches on may satisfy — measure Phase 1 first).
- Alternative cheap approximation to evaluate honestly (and reject or
  ship): keep the bus at 16 MHz and only double the KERNEL's internal
  clkena duty on internal (busstate=01) cycles + cache hits. With caches
  on, a large fraction of beats are internal/hit — an "up to 2x when not
  on the bus" mode. Not cycle-faithful P600, but zero clock-domain work
  and zero peripheral risk. Owner call whether that counts as "32 MHz".
- STA: the design closes at 93% ALM with the 15.67 grid today; a 65 MHz
  CPU domain doubles the timing pressure on the whole tg68k cone. Expect
  seed hunting + possibly the PMMU ATC reduction (22→8, patch sketched in
  the project memory) to make slack.

## Measurement harness (do FIRST, before optimizing anything)

- Sim A/B throughput: instrument instructions/frame over a fixed boot
  window (cpu_trace.log line counts per frame, or a clkena-beat counter
  behind a plusarg) for: old-kernel baseline (git 9c95e42), new kernel
  caches-off, new kernel caches-on. The MacLC repo has the same harness
  shape for a 68020 reference number.
- HW wall-clock: stopwatch a fixed workload on both cores (boot-to-Finder
  time; a Finder folder copy; MacBench if the owner has it). The owner's
  perception ("slower than MacLC") needs a number before and after.

## Files you will touch

- rtl/tg68k/tg68k.v (USE_68030_CACHE, cacheable decode, busy-park shave,
  32 MHz grid), MacIIvi.sv + verilator/sim.v (keep tops in sync: clock
  plumbing, OSD status bit, reset-latch), rtl/addrController_top.v (slot
  timing at 2x), possibly pll config (new output), MacIIvi.sdc (new
  domain constraints), CLAUDE.md (machine quick facts: P600 32 MHz).
- Do NOT touch sys/ (framework law) and keep rtl/tg68k VHDL byte-synced
  to Minimig-AGA (kernel changes land there first).
