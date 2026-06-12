# preboot/ — Macintosh IIvi / LC II pre-OS test kit

Benches that run **before Mac OS boots**. Each bench produces a flat
boot block + freestanding payload pair that the Mac ROM loads from
disk (floppy or SCSI HDA) and executes in supervisor mode. No Toolbox,
no Memory Manager, no Finder — just a payload that drives the hardware
directly and writes JSONL results back to disk for the host to read.
Supervisor mode is what makes this the home of the privileged-
instruction and PMMU benches.

For the Mac OS app (CpuBench), see `SingleStepTests/macos_bench/`.
That runs **on top of** Mac OS via Retro68 and uses Toolbox APIs.

## Directory layout

```
preboot/
├── common/                  shared across benches
│   ├── runtime/             freestanding C runtime + linker scripts
│   │   ├── bench_types.h    u8/u16/u32 typedefs
│   │   ├── freestanding.{c,h}
│   │   ├── jsonl_writer.{c,h}
│   │   ├── recovery.s       longjmp-style exception recovery
│   │   ├── exception_handlers.s
│   │   ├── payload.ld       linker script: payload @ 0x40000
│   │   └── boot_stub.ld     linker script: boot block ≤ 1024 bytes
│   ├── boot/
│   │   ├── boot_stub_scsi.s             canonical (PAYLDOFF-patchable)
│   │   ├── boot_stub_scsi_fixed_offset.s historical (hardcoded 0x51600)
│   │   └── boot_stub_floppy.s           floppy boot block
│   ├── display/             paint kernels + framebuffer tools
│   │   ├── display_1bpp.c   active 1 bpp paint (was: font_ascii.c)
│   │   ├── diagnostics/     hardware-probe boot stubs
│   │   │   ├── boot_stub_minimal.s      "is boot path alive" probe
│   │   │   ├── boot_stub_probe.s        4-stripe polarity probe
│   │   │   ├── boot_stub_calibrate.s    200x200 stride ruler
│   │   │   ├── boot_stub_strides.s      4-stride bracket
│   │   │   └── build_probe.sh           one-shot probe disk builder
│   │   └── old/             deferred 8 bpp scaffolding (needs depth-switch init)
│   ├── tools/
│   │   ├── patch_offsets.py             writes file offsets into binaries
│   │   ├── raw_to_dc42.py               wrap raw disk image as Disk Copy 4.2
│   │   └── old/patch_results_offset.py  legacy single-offset patcher
│   └── make/common.mk        toolchain + paths included by every bench Makefile
├── supervisor_bench/         CPU / PMMU instruction-correctness tests
│   ├── bench_main.c          CPU runner + JSONL emitter (gen/cpu_tests.h)
│   ├── pmmu_bench_main.c     PMMU runner (gen/pmmu_tests.h) — PLANNED,
│   │                         see 68030_PMMU_TESTBENCH.md at repo root
│   (test corpora are included via relative path; cpu_tests.h /
│    pmmu_tests.h live in gen/)
│   ├── variant_cpu_scsi.s    SCSI-medium glue (shared by the benches)
│   ├── payload_entry_cpu.s   bench-specific entry shim (shared)
│   ├── build_cpu_{hda,dsk}.sh   CPU bench image builders
│   ├── build_cpu_scsi.sh     image build (uses legacy api hfs verbs)
│   ├── build_image*.sh       skeleton image builders
│   └── Makefile              includes ../common/make/common.mk
└── iotest/                   disk-I/O timing bench
    ├── diskio_main.c         per-size read/write/verify loop
    ├── sizes.{c,h}           size table (HDA: 12 sizes, DSK: 8 sizes)
    ├── timing.{c,h}          VIA1 T2 microsecond timer
    ├── payload_entry.s       bench-specific entry shim
    ├── build_hda.sh          image build (uses flat rb-cli verbs)
    ├── build_dsk.sh          image build (uses flat rb-cli verbs)
    └── Makefile              includes ../common/make/common.mk
```

## Toolchain

Builds use the **Retro68 cross-compiler**. Install location is set in
`common/make/common.mk`; override from the environment if yours is
elsewhere:

```bash
export RETRO68=/path/to/Retro68-build/toolchain
```

Required binaries: `m68k-apple-macos-gcc`, `as`, `ld`, `objcopy`. The
default path is `$HOME/repos/Retro68-build/toolchain/bin/`.

Disk-image manipulation uses **rb-cli** (rusty-backup):

```bash
export RB=$HOME/repos/rusty-backup/target/release/rb-cli
```

iotest scripts use the flat verbs (`put`, `locate`, `--print-offset`).
supervisor_bench scripts still use the deprecated `api hfs *` namespace
— migrating is a follow-up task.

## Building

### iotest (disk-I/O timing)

```bash
cd preboot/iotest
make hda             # produces build/payload_iotest_hda.bin + boot_stub.bin
make dsk             # produces build/payload_iotest_dsk.bin + boot_stub.bin
./build_hda.sh       # assembles /tmp/iotest.hda (APM, 12 sizes 1B..4MB)
./build_dsk.sh       # assembles /tmp/iotest.dsk (800 KB HFS, 8 sizes 1B..128KB)
```

`build_hda.sh` accepts a template HDA as its first arg (default
`~/testdisk.hda`). The output HDA is APM-wrapped with Apple_HFS at
partition 1. `build_dsk.sh` creates a fresh 800 KB HFS floppy from
scratch.

**Read-only vs full mode (`IOTEST_MODE`).** Each size test has two
phases:

1. **READ** — `_Read` `s->length` bytes from `/Read_<label>` into the
   I/O buffer at `IOBUF_BASE` ($200000). Timed via VIA1 T2.
2. **WRITE + READBACK-VERIFY** — fill the buffer with a pattern,
   `_Write` it to `/Write_<label>`, clear the buffer, `_Read` it back,
   memcmp. Three trap invocations per size, two of them timed.

`IOTEST_MODE` selects which phases get compiled in:

| Value | Phases | When to use |
|---|---|---|
| `read` (default) | READ only | Isolate the SCSI/Sony read path before introducing write complexity. The bench loops over the size table doing just one `_Read` per size. |
| `full` | READ + WRITE + VERIFY | After read is verified working. Emits a `"write"` JSONL record per size with `verified:0/1`. |

```bash
# Read-only (default):
make
./build_hda.sh

# Full:
rm -rf build         # IOTEST_MODE isn't a Make dependency, so clean first
make IOTEST_MODE=full
./build_hda.sh
```

Make rejects any other `IOTEST_MODE` value with a clear error. The
build is **single-binary** — there's no separate read-only/full
output filename; rebuild whichever variant you want and run the
build script again.

#### Exception-handler smoke test

`iotest/exc_handlers.s` installs handlers at 68k vectors 2..9 (bus
error, address error, illegal instr., zero divide, CHK, TRAPV,
privilege, trace) so a fault inside a `_Read`/`_Write` trap is caught
and reported as a synthetic `err = 30000 + vector` instead of
crashing the bench into a Sad Mac. The recovery is plumbed via a
custom `iotest_setjmp` / `iotest_longjmp` pair tuned for the
exception-frame stack layout (the CPU's pushed frame would otherwise
clobber `setjmp`'s saved return-PC slot — `iotest_longjmp` pushes a
clean copy from `JmpBuf[0]` to compensate).

To verify the catch path actually works under MAME, drop a synthetic
zero-divide right inside the setjmp window (i.e. after `iotest_setjmp`
returns 0, before the trap actually fires). One-shot so the bench
keeps running through the rest of the size table:

```c
// diskio_main.c, inside trap_with_recovery, right before `return trap(pb);`:
static int g_inject_once = 1;    // file-scope, TEST-ONLY
...
    g_last_exc_vector = 0;
    if (g_inject_once) {
        g_inject_once = 0;
        asm volatile(".short 0x81FC, 0x0000" : : : "d0", "cc");  // DIVS.W #0, D0
    }
    return trap(pb);
```

Then build full mode, run, extract `/Results.jsonl`, and confirm the
first read record carries the synthetic code while subsequent records
are clean:

```bash
make clean && make hda IOTEST_MODE=full
./build_hda.sh ~/testdisk.hda /tmp/iotest_exc.hda
SDL_VIDEODRIVER=offscreen mame maciici -rompath ~/repos/mame/roms \
    -skip_gameinfo -ramsize 8M -hard1 /tmp/iotest_exc.hda \
    -nothrottle -seconds_to_run 60 -window
~/repos/rusty-backup/target/release/rb-cli get --quiet \
    /tmp/iotest_exc.hda@1 /Results.jsonl /tmp/r.jsonl
tr -d '\000' < /tmp/r.jsonl | head -4
# Expected:
#   {"size":"1B","len":1,"op":"read","us":18,"err":30005}   <- caught vector 5
#   {"size":"512B","len":512,"op":"read","us":414,"err":0}  <- recovered, runs normally
#   {"size":"1KB", ...,"err":0}
#   {"size":"2KB", ...,"err":0}
```

The `us:18` on the failed record (vs ~414 µs for a real read) is the
signature that the trap was aborted before it actually talked to the
SCSI bus. `err:30005 = 30000 + vector 5`. Other catchable vectors:
30002 (bus), 30003 (addr), 30004 (illegal), 30006 (CHK), 30007
(TRAPV), 30008 (privilege), 30009 (trace).

Remember to remove the injection before committing — it's
deliberately not gated behind a build flag because it should only
ever be enabled as a one-off in-source patch when debugging the
recovery path itself.

#### SCSI sense capture

`iotest/scsi_sense.c` augments any non-zero `_Read`/`_Write` ioResult
with the SCSI device's actual sense data — the `sense_key` / `asc` /
`ascq` triple that tells "medium error" apart from "hardware error"
apart from "write protected" apart from "unit attention", and the
full 18-byte raw sense buffer in hex. Mechanism:

1. After every trap call whose return is in the standard Mac OS error
   range (negative i16), bench_main calls `scsi_request_sense_safe()`.
2. That function issues the SCSI Manager sequence
   `_SCSIGet` → `_SCSISelect(id)` → `_SCSICmd(REQUEST SENSE)` →
   `_SCSIRBlind(18 bytes)` → `_SCSIComplete` against SCSI ID 0 (the
   conventional boot-drive ID; hardcoded TODO).
3. If any step faults, the exception handler (see above) catches it
   and `scsi_request_sense_safe` returns `30000 + vector`, leaving
   `sense_raw` zeroed. Callers can distinguish "SCSI Manager said
   no sense" (key=0x00) from "we couldn't reach the SCSI Manager"
   (return code 30002..30009).
4. The JSONL writer adds these fields only when sense was requested:

   ```json
   {"size":"4MB","len":4194304,"op":"read","us":83562,"err":-36,
    "sense_key":3,"asc":17,"ascq":0,
    "sense_raw":"70000300000000000A000000110000000000"}
   ```

   sense_key 3 = medium error; ASC 0x11 = read error; ASCQ 0 = generic.

**Known limitation:** the SCSI Manager calls hang or Sad-Mac the
bench under MAME's `maciihmu` driver (vector 10 / Line-A trap) — most
likely because `maciihmu`'s ROM doesn't fully wire up the
`_SCSIGet`/`_SCSISelect` family, or our supervisor-mode hijack
disrupted SCSI Manager state in a way that only matters when those
specific traps fire. The baseline (no errors → sense never fires)
runs cleanly, and the path is strictly opt-in (only invoked on a
failing trap). Real hardware should exercise this naturally on any
SCSI failure — when you see a `30002..30009` synthetic code in
`sense_raw`'s place, that's the recovery firing.

To exercise on hardware: simulate a failing trap by injecting a
fake `-36` after `trap_with_recovery`, same recipe as the exception
test above:

```c
// diskio_main.c, after the trap_with_recovery returns:
err = trap_with_recovery(trap_read, &g_pb);
t_us = timer_elapsed_us();
if (i == 0) err = -36;  // TEST-ONLY -- forces sense capture
```

If hardware crashes the bench, the SCSI Manager path is the issue
and we'll want to fall back to a simpler probe (e.g. `_SCSIStat`).

### supervisor_bench (CPU / PMMU correctness)

Bench artifacts share the boot stub, entry shim, results-offset glue,
runtime, and 1 bpp display kernel:

| Bench | Corpus | `make` target | Image builders |
|---|---|---|---|
| CPU correctness | `gen/cpu_tests.h` | `cpu` / `cpu_auto` | `build_cpu_{hda,dsk}.sh`, `build_prebuilts.sh` |
| PMMU correctness (hw-safe rows) | `gen/pmmu_tests.h` | `pmmu` / `pmmu_auto` | `build_prebuilts.sh` |
| PMMU full (live MMU + faults) | `gen/pmmu_tests.h` | `pmmu_full` / `pmmu_full_auto` | `build_prebuilts.sh` |

`*_auto` = runtime ScrnRow stride detection (one binary for mdc824 /
LC II V8 / IIvi VASP displays). Prebuilt images + manifest:
`SingleStepTests/prebuilt/`.

```bash
cd preboot/supervisor_bench
make cpu             # CPU bench  -> boot_stub_patch.bin + payload_cpu_scsi.bin

# legacy / scaffolding targets:
make cpu_scsi        # CPU bench on the older fixed-offset SCSI boot stub
make all             # skeleton boot + payload
make scsi            # skeleton SCSI variant
make minimal         # diagnostic: "is boot path alive"
make probe           # diagnostic: framebuffer polarity (4 stripes)
make calibrate       # diagnostic: stride ruler (200×200 square)
make strides         # diagnostic: 4 strides bracketed
```

The benches run privileged out of the boot block, recover from
faulting tests via `common/runtime/recovery.s` (so one bad test reports
`vec=N` instead of crashing the run), and write `/Results.jsonl` for
host-side extraction with `rb-cli get IMG@1 /Results.jsonl out.jsonl`.

**Output schemas** (one JSON line per test):

- CPU: `{"name","vec","final"/"trap_state":{d,a,ccr,pc,ram}}` (see
  `results/cpu_supervisor/README.md`).

**PMMU runner** (`pmmu_bench_main.c` — the artifact the physical LC II
boots). Consumes `gen/pmmu_tests.h`; relocates the corpus's fixed
addresses into payload statics (low RAM belongs to the ROM); saves and
restores the ROM's own MMU state around every test (32-bit-clean ROMs
boot with TC.E=1); guards startup with an on-screen + JSONL identity
probe (see `prebuilt/MANIFEST.md`); emits JSONL for offline diff via
`gen/pmmu_diff_corpus.py`. Functionally verified 40/40 against the MAME
baseline via the `pmmu_harness` build (Lua-injected flat-map run on
MAME `maciici`). The safe build skips `hw_unsafe` rows; `-DPMMU_FULL`
runs everything. See `68030_PMMU_TESTBENCH.md` at the repo root.

The `make cpu_scsi_8bpp` target also exists but is **deferred** — it
compiles successfully but the resulting payload won't render on
hardware until depth-switch init code is written (see
`common/display/old/` headers for details).

## Display modes

Everything paints in **1 bpp** through the Mac II built-in ScrnBase
(`$0824`). The kernel (`common/display/display_1bpp.c`) handles every
Mac II display path the FPGA core supports — what differs between
cards is the **row stride**, which each card's declaration ROM
programs into the TFB / CRTC at boot.

| Card | Row stride (1 bpp) | Notes |
|---|---:|---|
| **Toby** (Mac II Video Card, 342-0008-a) | 80 | 1 bpp only, exact 640-px buffer |
| **Apple Macintosh II High Resolution Card (m2hires)** | **128** | 1024-px-wide buffer, only first 640 visible; supports 1/2/4/8 bpp but powers up in 1 bpp |
| **Apple Macintosh Display Card 8•24 (mdc824)** | 80 | Powers up in 1 bpp via its 68008 coprocessor; supports up to 24 bpp |

The stride is **not derivable at runtime** from low-mem — we have to
match what the card's declaration ROM picked. Mismatched stride is
the easiest-to-misdiagnose bug in this tree: text fragments across
the top of the screen with characters spread horizontally because
each row of an 8-row glyph lands on a different physical scanline.

**Select the target card at build time via `VIDEO_VARIANT`:**

```bash
make                              # mdc824 (default — matches current FPGA core)
make VIDEO_VARIANT=m2hires
make VIDEO_VARIANT=toby
```

The default changed from `m2hires` to `mdc824` on 2026-05-25 when the
FPGA core was updated to ship mdc824 as its standard NuBus card. The
m2hires path still builds and runs (use `VIDEO_VARIANT=m2hires`) — it
just isn't the default anymore.

`common/make/common.mk` translates the variant into `-DROW_BYTES=N`
(for C) and `--defsym ROW_BYTES=N` (for gas). Each `.s` file gates
its fallback default behind `.ifndef ROW_BYTES / ... / .endif` so
direct AS invocations without the Makefile still assemble. Adding a
new card means appending a case to the `ifeq` cascade in `common.mk`.

Higher color depths (2/4/8 bpp) require writing the card's control
registers first (m2hires: TFB MISC; mdc824: 68008 mailbox command).
The 8 bpp paint kernel + matching boot stub are parked under
`common/display/old/` until that init code is written; they assemble
fine but produce garbage on hardware until paired with depth-switch.

The **diagnostic boot stubs** under `common/display/diagnostics/`
exist to characterize an unfamiliar card or to confirm a card change
didn't break things. Workflow:

1. `make probe` from supervisor_bench/ — boot the resulting disk.
   Stripes should render dark-to-light L→R (`$00`=black, `$FF`=white)
   in standard polarity, or inverted on Mac-default ScrnBase polarity.
2. `make calibrate` — boot the resulting disk. A clean 200×200 square
   means stride is right; a parallelogram with N pixels of drift per
   row means real stride = assumed (640) + N.
3. `make strides` — paints 4 small squares at strides 640/832/1024/1280.
   The clean one tells you the actual stride in one shot.

## Patching offsets into built artifacts

The boot stub and payload both contain offsets that aren't known
until the image is assembled (`/Payload` byte offset in the boot
stub, `/Results.jsonl` byte offset and per-size read/write offsets
in the payload). Build scripts patch them post-link using
`common/tools/patch_offsets.py`:

```bash
common/tools/patch_offsets.py IMAGE \
    --payload-offset 0xXXXX \
    --results-offset 0xXXXX \
    --reads  1B=0x..,512B=0x.. \
    --writes 1B=0x..,512B=0x.. \
    --labels-order 1B,512B,...
```

iotest's build scripts handle this automatically via `rb-cli locate
IMG[@N] /Path | jq`. The supervisor_bench scripts still use the
older `patch_results_offset.py` (single-offset only) — they'll move
to the unified script when they migrate to flat rb-cli verbs.

## Reading results back

Both benches write JSONL records to `/Results.jsonl` on the booted
disk. After running, extract it host-side with:

```bash
rb-cli get /tmp/iotest.hda@1 /Results.jsonl /tmp/iotest_results.jsonl
```

(or `rb-cli get /tmp/iotest.dsk /Results.jsonl ...` for the floppy
variant — no @N selector for raw HFS).

iotest output format, one line per read or write:

```json
{"size":"1KB","len":1024,"op":"read","us":NNN,"err":0}
{"size":"1KB","len":1024,"op":"write","us":NNN,"err":0,"verified":1,"readback_us":NNN,"readback_err":0}
{"size":"4MB","len":4194304,"op":"skip","reason":"insufficient_ram","mem_top":0xN,"iobuf_base":0x200000}
```

supervisor_bench output: see `bench_main.c`'s emitter and
`SingleStepTests/results/` for the field schema.

## MAME integration

MAME's `macii` machine emulates the exact NuBus video cards our FPGA
core targets, and can run headlessly to take screenshots of the
emulated Mac display — so you can diagnose display issues, dump VRAM,
and trace device-register writes without needing access to physical
hardware. This is the workflow that found the m2hires `ROW_BYTES=128`
stride bug above.

### Prerequisites

- **MAME built locally** at `~/repos/mame/mame` (sibling checkout of
  this repo). Any recent MAME version with the macii driver works;
  `mame0287` is what was used for the m2hires diagnosis.
- **Mac II ROMs** at `~/repos/mame/roms/macii.zip`. The `-listroms maciihmu`
  command lists what's expected.

  **Use the Rev B ROM**, not Rev A — the user's physical Mac II is
  Rev B, and the SCSI / boot paths differ enough between revisions
  that an iotest run on Rev A under MAME doesn't model what the
  hardware actually does. Confirm the romset in `macii.zip` includes
  the Rev B image before trusting results.
- **m2hires declaration ROM** at `~/repos/mame/roms/nb_m2hr/341-0660.bin`.
  A copy is in this repo:
  ```bash
  mkdir -p ~/repos/mame/roms/nb_m2hr
  cp ~/repos/lbmactwo_MiSTer/releases/341-0660.bin ~/repos/mame/roms/nb_m2hr/
  ```
  Only needed if you pass `-nb9 m2hires` (the m2hires variant). Default
  builds target mdc824, and MAME's `macii*` machines already default to
  mdc824 in slot 9, so the m2hires declaration ROM is optional.

### Headless invocation

MAME normally needs an X display. With SDL2 we can use the **offscreen
video driver** to run without any host display, while still rendering
the emulated Mac screen and saving snapshots to PNG:

```bash
cd ~/repos/mame
SDL_VIDEODRIVER=offscreen ./mame maciihmu \
    -skip_gameinfo \
    -ramsize 8M \
    -hard1 /tmp/iotest.hda \
    -snapname iotest_%i \
    -snapsize 640x480 \
    -snapshot_directory /tmp/mame_snap \
    -nothrottle \
    -seconds_to_run 30 \
    -window
```

No `-nb9` flag: MAME's `macii*` machines already default to mdc824 in
slot 9, which matches the FPGA core and the iotest build default. Add
`-nb9 m2hires` only when testing the m2hires variant (and build the
image with `VIDEO_VARIANT=m2hires` so its `ROW_BYTES` matches the card).

Flags worth knowing:

| Flag | What it does |
|---|---|
| `SDL_VIDEODRIVER=offscreen` | renders to an in-memory framebuffer; no X needed |
| `-skip_gameinfo` | skip MAME's "press OK" warning screen; otherwise the autosnapshot captures it instead of the emulated display |
| `-nb9 <card>` | install card in NuBus slot 9 (`m2hires` or `mdc824`; default is `mdc824`). |
| `-ramsize 8M` | `maciihmu` defaults to 2 MB, which makes iotest skip every size (`IOBUF_BASE=0x200000` equals MemTop at 2 MB). 8 MB is the largest the Mac II ROM accepts. |
| `-hard1 path/to.hda` | SCSI HDD on the first channel |
| `-flop1 path/to.dsk` | Floppy disk in the internal drive (use for `iotest.dsk` etc.) |
| `-snapsize 640x480` | match the visible area exactly so the output PNG isn't padded |
| `-snapshot_directory dir` | where to write the PNG. Default `snap/` is relative to CWD. |
| `-nothrottle` | run as fast as host CPU allows (~4× real-time on a modern laptop) |
| `-seconds_to_run N` | exit after N **emulated** seconds; the auto-snapshot fires at exit |
| `-window` | required even with offscreen driver |
| `-autoboot_script foo.lua` | inject a Lua script that runs once emulation starts |

### Which machine and card

Use **`maciivi`** — the machine this core implements (68030 + on-chip
PMMU + VASP) — once its ROM set is on hand. Until then **`maciici`**
(ROMs present) is the stand-in 68030: the CPU/PMMU oracle is identical,
only the chipset differs. **`maclc2`** (driver present, ROMs dumpable
from the physical LC II) is the V8-chipset twin of the hardware test
machine.

The IIvi has **built-in VASP video**, so no NuBus card is required to
get a display. To exercise the NuBus path, plug the mdc824 into a slot
(`-nbc mdc824` for slot $C on `maciivi`) — the same card
`rtl/nubus/nubus_video_mdc824.sv` implements.

Pass `-nb9 m2hires` only when you've also built the image with
`VIDEO_VARIANT=m2hires` — running an mdc824-built image against an
m2hires card (or vice versa) is the classic ROW_BYTES mismatch (80 vs
128) and produces garbled text rather than a crash, so it's easy to
miss.

`./mame maciihmu -listslots` shows the full list of cards installable
in any slot if you need to experiment with others.

### Probing device internals via Lua

MAME's Lua API can:
- Read CPU memory at any address (`prog:read_u8/u16/u32`).
- Install **write taps** to log every CPU write to a memory range —
  including writes to memory-mapped device registers like the m2hires
  TFB at `$F9080000-$F908FFFF`.
- Schedule actions at specific emulated times (`emu.register_periodic`
  with an `emu.time()` check).

Example: trace what the m2hires declaration ROM programs into the
TFB registers during boot. Save as `/tmp/snoop_m2hires.lua`:

```lua
local prog = manager.machine.devices[":maincpu"].spaces["program"]

prog:install_write_tap(0xF9080000, 0xF9080FFF, "m2hires_reg_w",
    function(offset, data, mask)
        local reg_idx = (offset & 0xFF) >> 2
        print(string.format("[t=%.2f] m2hires reg %d <= 0x%08X (mask 0x%08X)",
                            emu.time(), reg_idx, data, mask))
    end)
print("m2hires register-write tap installed")
```

Run with `-autoboot_script /tmp/snoop_m2hires.lua` and grep stdout
for `reg write`. The captured values are the **CPU-side** writes;
MAME's `m2hires::registers_w` applies `data ^= 0xFFFFFFFF; data =
swapendian_int32(data)` before storing, so e.g. CPU `0xDFFFFFFF` →
`m_registers[LENGTH] = 32` → stride = 32 × 4 = **128 bytes**.

Example: dump VRAM at the current `ScrnBase` to verify your paint
code wrote the bytes you expected. Save as `/tmp/dump_vram.lua`:

```lua
local prog = manager.machine.devices[":maincpu"].spaces["program"]
local fired = false
emu.register_periodic(function()
    if fired or emu.time() < 25 then return end
    fired = true
    local sb = prog:read_u32(0x0824)
    print(string.format("ScrnBase=0x%08X", sb))
    for r = 0, 7 do
        local row = {}
        for i = 0, 31 do
            row[i+1] = string.format("%02X", prog:read_u8(sb + r * 80 + i))
        end
        print(string.format("row %d:", r), table.concat(row, " "))
    end
end)
```

Reading via the CPU side gets the XOR'd-back view of VRAM, so the
bytes you see are the bytes your paint code wrote.

### Worked example: the m2hires ROW_BYTES discovery

The whole story is preserved in commit `4a3a75c`. Summary:

1. User reported garbled iotest display on FPGA m2hires hardware.
2. Reproduced the same garbled output in MAME with `-nb9 m2hires`.
3. Same `/tmp/iotest.hda` rendered correctly with default MAME (mdc824) —
   so the payload bytes are fine, the bug is per-card.
4. VRAM dump at `ScrnBase` showed our paint bytes were exactly where
   we wrote them (correct content at offsets `row * 80`), so the paint
   code wasn't writing wrong bytes — the scanout was reading at a
   different stride.
5. Tested several plausible strides (80, 128, 144, 160) against the
   VRAM dump by re-indexing the same memory at different strides;
   stride 128 produced consistent 8-row glyph patterns.
6. Confirmed by snooping TFB register writes — declaration ROM
   wrote `LENGTH=32`, MAME's formula gives 32 × 4 = 128 bytes.
7. Patched ROW_BYTES → 128 → reran in MAME → text renders cleanly.

The `SDL_VIDEODRIVER=offscreen` headless trick made this iteration
cycle ~10 seconds per attempt instead of "boot on physical hardware,
photograph screen, repeat."

## File reorg history

This directory was reorganized on 2026-05-24 from two top-level
directories (`SingleStepTests/supervisor_bench/` and
`SingleStepTests/IOTest/`) into the current `preboot/` tree. The
shared bits (paint kernels, runtime, linker scripts, boot stubs,
diagnostic tools) moved into `common/`. Each moved file's header
comment includes its previous name so a grep against the old layout
still finds the right file.

If you came in looking for any of these old names, here's where to
find them:

| Old path | New path |
|---|---|
| supervisor_bench/font_ascii.c               | common/display/display_1bpp.c |
| supervisor_bench/font_ascii_m2hires.c       | common/display/old/font_ascii_m2hires.c |
| supervisor_bench/boot_stub.s                | common/boot/boot_stub_floppy.s |
| supervisor_bench/boot_stub_scsi.s           | common/boot/boot_stub_scsi_fixed_offset.s |
| supervisor_bench/boot_stub_scsi_m2hires.s   | common/display/old/boot_stub_scsi_m2hires.s |
| supervisor_bench/boot_stub_m2hires_probe.s  | common/display/diagnostics/boot_stub_probe.s |
| supervisor_bench/boot_stub_m2hires_calibrate.s | common/display/diagnostics/boot_stub_calibrate.s |
| supervisor_bench/boot_stub_m2hires_v3.s     | common/display/diagnostics/boot_stub_strides.s |
| supervisor_bench/boot_stub_minimal.s        | common/display/diagnostics/boot_stub_minimal.s |
| supervisor_bench/payload_entry_cpu_m2hires.s | common/display/old/payload_entry_cpu_m2hires.s |
| supervisor_bench/build_cpu_scsi_m2hires.sh  | common/display/old/build_cpu_scsi_m2hires.sh |
| supervisor_bench/build_m2hires_probe.sh     | common/display/diagnostics/build_probe.sh |
| supervisor_bench/{bench_types,freestanding,jsonl_writer}.{c,h} | common/runtime/ |
| supervisor_bench/{recovery,exception_handlers}.s | common/runtime/ |
| supervisor_bench/{payload,boot_stub}.ld     | common/runtime/ |
| supervisor_bench/patch_results_offset.py    | common/tools/old/patch_results_offset.py |
| supervisor_bench/raw_to_dc42.py             | common/tools/raw_to_dc42.py |
| IOTest/boot_stub.s                          | common/boot/boot_stub_scsi.s |
| IOTest/patch_offsets.py                     | common/tools/patch_offsets.py |
| IOTest/{diskio_main,sizes,timing}.{c,h}     | iotest/ |
| IOTest/{build_hda,build_dsk}.sh             | iotest/ |
