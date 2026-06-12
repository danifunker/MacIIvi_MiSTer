# Test JSON schema (state-only)

Each `.json` file in a corpus is an array of test entries. One entry per
single instruction.

## CPU entry (TG68K bench)

```json
{
  "name": "ADD.l 00001",
  "initial": {
    "d0": 305419896, "d1": 0, "d2": 0, "d3": 0,
    "d4": 0, "d5": 0, "d6": 0, "d7": 0,
    "a0": 1024, "a1": 0, "a2": 0, "a3": 0,
    "a4": 0, "a5": 0, "a6": 0, "a7": 16776192,
    "pc": 4096,
    "sr": 8192,
    "usp": 0,
    "ssp": 16776192,
    "vbr": 0,
    "ram": [[4096, 208], [4097, 129]]
  },
  "final": {
    "d0": 305419896, "d1": 305419896,
    ... all regs ...,
    "pc": 4098,
    "sr": 8192,
    "ram": []
  }
}
```

Rules:
- All integer fields are unsigned decimal (json doesn't allow hex literals).
- `ram` is a list of `[address, byte]` pairs. `initial.ram` is the
  pre-state; `final.ram` lists only bytes that DIFFER from `initial`
  (so empty array = unchanged).
- Reg names match Musashi: `d0..d7`, `a0..a7`, `pc`, `sr`, `usp`, `ssp`,
  `vbr`. `a7` and `ssp`/`usp` are redundant per supervisor state; bench
  uses `a7` and ignores the other two for now (kept for future
  privileged-mode tests).
- `pc` is the address of the next instruction (post-fetch).
- No cycle counts. The bench runs until the CPU returns to idle
  (busstate=01) after consuming the instruction.

## PMMU entry (68030 PMMU bench)

One JSON object per line (JSON Lines), produced by
`gen/mame_pmmu_capture.lua`. Baseline corpus:
`results/pmmu/mame_baseline_2026-06-12.json` (40 tests, captured from
MAME `maciici` — the MC68030 oracle is driver-independent).

```json
{
  "name": "PTESTW #5,(A0),#7 write-protected page (W)",
  "flags": {
    "privileged": true,          // all PMMU tests (supervisor-only)
    "mmu_live": false,           // test enables translation (TC.E=1)
    "raises_exception": false,   // expected berr / MMU-config fault
    "hw_unsafe": false           // skip on real LC II / IIvi hardware
  },
  "timed_out": false,            // capture-side timeout (should be false)
  "initial": {
    "d": [8],  "a": [8],         // D0..D7 / A0..A7 (a[7] = SSP)
    "pc": 4096, "sr": 9984, "usp": 0,
    "mmu": {
      "tc": 12618816,            // E always 0 initially; live tests
      "tt0": 0, "tt1": 0,        //   enable via PMOVE inside the test
      "crp_limit": 2147418114, "crp_aptr": 12288,
      "srp_limit": 2147418114, "srp_aptr": 16384,
      "psr": 0
    },
    "ram": [[12288, 0], [12289, 0], ...]   // planted bytes (tables, data)
  },
  "final": { ... same shape ...,
    "ram": []                    // only bytes that DIFFER from initial
  }
}
```

Rules (in addition to the CPU rules above):

- Program layout per test is `[test bytes][CATCHER]` at `$1000`, where
  the catcher is `PMOVE ($17F8).L,TC ; JMP self` and `$17F8` holds 0.
  All 256 vectors point at the catcher, so faulting tests converge
  there with translation forcibly re-disabled. **Consequence:
  `final.mmu.tc` is always 0** — a test's own TC effect is observed
  through its memory readback (`final.ram`), not `final.mmu.tc`.
- A test that took an exception shows `final.a[7] < initial.a[7]`; the
  pushed frame is captured in the stack window
  (`$7FFA0..$7FFFF`, SSP starts at `$80000`). Bus errors push the
  68030 format `$B` 92-byte frame; the MMU-configuration exception
  (vector 56) pushes a format `$2` 12-byte frame.
- Snapshot windows (zeroed before plant, diffed after):
  data `$1800`, root table `$3000`, level-B `$3100`, level-C `$3200`,
  SRP table `$4000`, remap pages `$9000`/`$A000`, stack `$7FFA0`.
  Descriptor U/M-bit updates by table walks land in these diffs — they
  are part of the expected behavior, not noise.
- `mmu.psr` only changes on PTEST (and explicit PMOVE-to-PSR); faults
  do not update it. Matches real 68030 behavior.
- Known oracle quirks (MAME `acad9ca235f`), tracked in
  test-blockers.md: depth-limited PTEST (#1..#6) ending on a table
  descriptor is fatal to MAME and absent from the corpus; root-limit
  violations report PSR I (+N) where real silicon also sets L.
  Cross-check against the physical LC II before treating those rows
  as gospel.
