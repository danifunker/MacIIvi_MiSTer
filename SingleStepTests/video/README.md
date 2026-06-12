# video/ — IIvi video benches (contract)

Three video paths exist for this core; this bench directory verifies
them against MAME-derived goldens. RTL status:

| Path | RTL | MAME oracle |
|---|---|---|
| NuBus mdc824 (Apple Display Card 8•24) | `rtl/nubus/nubus_video_mdc824.sv` — carried over from the Mac II core, works in any IIvi slot ($C/$D/$E) | `src/devices/bus/nubus/nubus_48gc.cpp` |
| V8 built-in (Macintosh LC / **LC II** — the physical test machine) | to be written | `src/mame/apple/v8.cpp` |
| VASP built-in (the IIvi itself) | to be written | `src/mame/apple/vasp.cpp` |

## Verified facts to build against (from MAME source, 2026-06-12)

Shared model — V8 and VASP have the same programming interface, so one
parameterized module should serve both:

- Depth select via the pseudo-VIA "video config" register
  (`via2_video_config`): 0=1bpp, 1=2bpp, 2=4bpp, 3=8bpp, 4=16bpp.
- Monitor sense (montype): 1 = 15" portrait 640×870, 2 = 12" RGB
  512×384, 6 = 13" RGB 640×480 (default).
- Indexed color through an Ariel-class RAMDAC (Bt450-family clone).

Differences:

| | V8 (LC II) | VASP (IIvi) |
|---|---|---|
| VRAM window | `$540000-$5BFFFF` in the V8 map → CPU `$F40000` (24-bit) / `$50F40000` (32-bit) | `$60000000-$600FFFFF` (VASP map at `$40000000` + internal `$20000000`) |
| Row stride | **1024 bytes** (fixed) | **2048 bytes** (fixed) |
| RAMDAC | Ariel at +`$524000` (CPU `$F24000`) | DAC at `$50024000` |
| VIA1/pseudo-VIA | `$F00000` / `$F26000`-region (mask `$80FFFFFF`) | `$50000000` / `$50026000` (mirror `$00F00000`) |
| Max depth | 8 bpp at 512×384 (16 bpp special-cased) | 16 bpp |
| Pixel clock | 15.6672 MHz (512×384: 640×407 total); 25.175 MHz (640×480: 800×525 total) | same timings |

(Authoritative register-level detail: read the two MAME files; they are
short. `v8.cpp` line ~493 and `vasp.cpp` line ~440 are the
`screen_update` depth/stride switches these numbers come from.)

## Bench plan

1. **Golden-frame bench (verilator)** — instantiate the video module +
   a VRAM model; program depth/palette via the pseudo-VIA/RAMDAC
   interface exactly as the Mac ROM does; fill VRAM with a deterministic
   pattern; capture one frame of pixel output; compare against a golden
   frame rendered by a host-side C model transliterated from MAME's
   `screen_update` (1/2/4/8/16 bpp × three monitor types).
2. **Register-access bench** — read/write the config registers through
   the bus wrapper and compare against a MAME Lua capture of the same
   accesses (same plant-program approach as the CPU/PMMU captures, but
   poking `$50F24000`-class addresses on `maclc2` / `maciivi`).
3. **mdc824 regression** — the carried-over card already worked on the
   Mac II core; re-run its existing sim path in this repo's verilator
   harness once the core top-level exists, then on `maciivi` in MAME
   with `-nbc mdc824` for cross-checking.

Hardware cross-check on the LC II: the preboot display kernel
(`preboot/common/display/display_1bpp.c`) needs a 1024-byte-stride
variant (512×384 ⇒ 64 visible bytes + 960 pad per row) — the existing
diagnostics stubs (`boot_stub_strides.s`, `boot_stub_calibrate.s`) are
the tools to confirm the stride empirically before trusting it.
