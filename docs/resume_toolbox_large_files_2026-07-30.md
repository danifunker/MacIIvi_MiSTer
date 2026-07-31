# Resume: BlueSCSI Toolbox large-file copies — MacIIvi, 2026-07-30

Branch `cd-audio` @ `7787ed1` (4 commits ahead of the 07-22 state, **unmerged,
unpushed**). Everything in the 2026-07-30 family sync is validated EXCEPT
Toolbox file copies. This doc is the handoff for that one bug.

---

## 1. Where we are (all green unless stated)

Owner verdict at end of session: *"CD Audio is working fine now. audio is
working, and I was able to set a CD. I think this is all working except for
toolbox copies."*

| Area | State |
|---|---|
| CD audio playback | ✅ owner-confirmed working (by ear) |
| General audio / chime | ✅ owner-confirmed working |
| CD changer SET NEXT CD | ✅ owner set a CD successfully |
| CD data mount (CHD) | ✅ HW-verified — "The Incredible Machine" on desktop |
| Boot / Finder / disk reads | ✅ HW-verified, stable soak, clock 1:1 |
| Toolbox LIST (0xD0) | ✅ works — MacAtrium lists all 9 files with correct sizes |
| Toolbox SEND, Mac→Shared (0xD3/D4/D5) | ✅ **appears to work** (see §3 evidence) |
| **Toolbox GET, Shared→Mac (0xD1)** | ❌ **"The SD card refused the transfer"** |

Deployed rbf: `output_files/MacIIvi.rbf`, md5 `636275835b99f4755dd79c0adb440999`,
SEED 2, netlist `ae54950`, all timing met (+0.205 worst), 522/553 M10K, ALM 97%.

Evidence screenshots committed in `releases/`:
`hw_143_familysync_finder_cd_20260730.png` (the PASS),
`hw_143_userdisk_extoff_boots_20260730.png`,
`hw_143_userdisk_finder_err10_20260730.png`.

The failing dialog was captured live this session (MacAtrium → Toolbox Shared
Files, error line *"The SD card refused the transfer."*). It is NOT in
`releases/`; re-capture with `bash scripts/grab.sh <out.png>` if needed.

---

## 2. THE BUG — prime suspect, with the arithmetic

**Hypothesis (high confidence): the disk Toolbox target's tb buffer is 512
bytes, but 0xD1 GET FILE transfers in 4096-byte blocks. Everything larger than
one 512-byte sector is unserviceable.**

HPS side — `../Main_MiSTer/toolbox.cpp:170-197` (`tb_get`):

```
// CDB[1]=index, CDB[2..5]=offset BE (units of 4096), CDB[6]=#4K blocks (0 => 1)
const uint32_t BLOCK = 4096;
uint32_t blocks = cdb[6] ? cdb[6] : 1;
uint32_t want   = blocks * BLOCK;        // >= 4096 ALWAYS
...
tb_ch.resp.resize(got);                  // tb_len returned to the core
tb_ch.status = STATUS_GOOD;
```

Core side — `rtl/scsi.v`:

- `parameter TB_ADDRW = 8;` (line 112) — default, and the **disk** target takes
  the default: `rtl/ncr5380.sv` instantiates `scsi #(.ID(i[2:0]),
  .TOOLBOX_ENABLE(i == 0)) target` with **no `TB_ADDRW` override**.
- `TB_ADDRW=8` ⇒ two `scsi_dpram`s of 256 words ⇒ **512-byte tb buffer**.
- `localparam [3:0] TB_MAXSEC = 1 << (TB_ADDRW - 8);` (line 1225) ⇒ **1** for
  the disk target.
- `tb_nsec` (lines 1226-1229) computes `ceil(tb_len/512)` then **clamps to
  TB_MAXSEC**. For a 4096-byte GET: `tb_nsec_raw = 8`, clamped to **1**.
- But the served length is the FULL `tb_len`:
  `(cmd_tb_fs_in || cmd_cdc_in) ? {16'd0, tb_len}` (line 1585).

So the target promises 4096 bytes, fetches only the first 512, and serves 3584
bytes of stale buffer (address wraps mod 256 words). Depending on where the
HPS/core round-trip desyncs, the next command's status block can miss its
`0xB5` signature, which makes the core return `tb_status <= 8'h02` = CHECK
CONDITION — exactly what a client renders as *"the SD card refused the
transfer."*

**Why the CD changer already works:** `rtl/ncr5380.sv` gives the CD target
`.CDCHANGER_ENABLE(1), .TB_ADDRW(11)` — a 4 KB buffer, `TB_MAXSEC=8` — because
LIST CDS with 100 entries needed multi-sector. **The file Toolbox never got the
same treatment.** This is the asymmetry to fix.

**Why LIST works but GET doesn't:** LIST returns 40 bytes/entry × 9 entries =
360 bytes < 512 ⇒ fits one sector. Consistent with the live listing being
perfect while copies fail.

**Why SEND (upload) works:** `toolbox.cpp:202-203` caps a SEND chunk at
`TB_PAYLOAD_MAX = 512 - 16 = 496` bytes, which fits the 512-byte buffer. The
core's collect path writes at word offset 8 (`11'd8 + data_cnt[8:1]`), i.e.
byte 16 — the two agree exactly.

### The fix to try first

Give the Toolbox-enabled disk target the same buffer the CD changer has:

```verilog
// rtl/ncr5380.sv, disk generate loop
scsi #(.ID(i[2:0]), .TOOLBOX_ENABLE(i == 0),
       .TB_ADDRW((i == 0) ? 11 : 8)) target
```

Cost ≈ +2 M10K on target 0 only (`scsi_dpram` is single-array post-prefetch).
Budget is fine: current fit is 522/553 with 31 free.

**Caveats to handle in the same change:**

1. `TB_MAXSEC = 1 << (11-8) = 8` ⇒ exactly 4096 bytes. If the Mac client ever
   sets `CDB[6] > 1`, `want` ≥ 8192 and the clamp truncates again — silently.
   Either clamp `data_len` to `TB_MAXSEC*512` when `tb_len` exceeds it (so the
   target serves only what it actually holds), or cap `want` in `tb_get`.
   **Serving fewer bytes than promised is the old alloc-overserve wedge class —
   do not leave the mismatch in place.**
2. `tb_nsec`, `tb_fetch_sec`, `TB_MAXSEC` are all `[3:0]`; 8 fits, but check
   `(tb_fetch_sec + 4'd1) >= tb_nsec` (line 1291) at the boundary.
3. This limitation is **identical upstream in MacLC** (their disk targets also
   default `TB_ADDRW=8`). If the fix works here, port it back — the two cores
   are kept byte-identical in `scsi.v`/`ncr5380.sv` modulo the documented
   MacIIvi fixups (see CLAUDE.md "SCSI/CD family sync").

---

## 3. Evidence from the live box (why SEND looks OK and GET looks broken)

Real shared folder = **`/media/fat/games/MacLC/shared`** (global `MiSTer.ini`
`shared_folder=`, shared by BOTH cores — note it is the *MacLC* path;
`/media/fat/games/MacIIvi/shared` exists but is EMPTY and is not what Main
serves). Resolution logic: `toolbox.cpp:100-108`.

Contents at 23:24 (sizes in bytes), against the owner's 23:27 screenshot:

| File | Size | mtime | > 512 B? |
|---|---|---|---|
| Open Tpt AppleTalk Library.bin | 508400 | Jul 30 16:15 | yes |
| Machine Data.bin | 102896 | **Jul 30 23:23** | yes |
| TIM Audio.bin | 45552 | **Jul 30 23:24** | yes |
| Machine Info.bin | 12784 | **Jul 30 23:24** | yes |
| System Picker.pdf | 11196 | Jul 26 22:23 | yes |
| ENGLISH.DAT.bin | 1408 | **Jul 30 23:23** | yes |
| hello.txt | 51 | Jul 16 10:09 | **no** |
| README.TXT | 14 | Jun 16 13:09 | **no** |
| new_file_from_host | 0 | Jun 15 22:02 | **no** |

The four bolded mtimes are from the owner's session minutes before the error —
i.e. **Mac→Shared uploads of 1 KB…100 KB completed and landed at plausible
sizes**. That is the 496-byte chunked SEND path working. The only files at or
under the 512-byte GET ceiling are exactly the three that predate the session.

**⚠ Not yet confirmed — ask the owner or test:** which button produced the
error, `Shared to Mac` (GET) or `From Mac to Shared…` (SEND)? The analysis
above predicts GET. If the owner says the failure was on **SEND** of a large
file, the prime suspect changes to chunk-loop/watchdog behaviour over ~1000
sequential 496-byte round trips, not the buffer size. **Also verify the
uploaded files are byte-identical to their Mac-side originals** — a plausible
size is not proof of a correct copy.

---

## 4. Other suspects (ranked, cheap first)

1. **STALE `/media/fat/config/MacIIvi.s3`** — contains
   `games/MacIIvi/TIM_3-mac.chd`, dated **Jul 16 11:55**, i.e. from BEFORE the
   4786494 slot convergence when CD-ROM was slot 3. Slot 3 is now
   `VD_TOOLBOX`. If Main applies `.s3` at boot it mounts a CHD onto the Toolbox
   block device, and the tb round-trip talks to a disc image instead of the
   handler. Main's own Toolbox auto-mount may or may not override it afterwards
   (LIST working suggests it does, at least eventually). **Test: rename `.s3`
   aside, reboot, retry a copy.** Zero risk, 4 minutes. Do this before touching
   RTL.
2. **Main binary provenance.** `/media/fat/MiSTer` md5 `fb020d08128d451008b28a326fee9332`
   == `../MacLC_MiSTer/releases/MiSTer` (owner's packed 20260730 build). It is
   **unverified** whether that binary was built from the current
   `../Main_MiSTer` HEAD `f49c7d0`, which includes **`c3fd47f "toolbox: 64-bit
   file offsets for GET/SEND seeks"`** — a commit that is directly about large
   files. If the deployed binary predates `c3fd47f`, rebuild and redeploy Main
   before blaming RTL. (Build: arm-none-linux-gnueabihf 10.2 at `/opt`; deploy
   = staged `.new` → md5 verify → atomic swap with `MiSTer.prev` rollback, from
   Git-Bash not WSL.)
3. **tb watchdog interaction.** `tb_to` (18-bit, ~8 ms at 32.5 MHz) force-latches
   the status block because the tb READ ack edge is not observed on HW. On a
   multi-sector fetch the watchdog now has to fire correctly *per sector*
   (`tb_to <= 18'd0` on each advance, line ~1291). If §2's fix half-works,
   instrument here first.
4. **File-handle statefulness.** `tb_get` keeps `tb_file` open across calls and
   only reopens when `offset == 0` (`toolbox.cpp:180-186`). Any lost/duplicated
   command in the middle of a multi-block download desynchronises the seek
   position for the remainder of that file.

---

## 5. Reproduction + gating protocol

**The owner's machine state is precious — respect these.**

- **ALWAYS clean-shutdown the guest before reloading a core:**
  `bash scripts/mac_clean_shutdown.sh` (evdev mouse into Special ▸ Shut Down;
  verify the "It is now safe to switch off your Macintosh." screen with
  `scripts/grab.sh`). Every `deploy_screenshot.sh` hard-reboots the MiSTer, and
  doing that under a live Mac leaves HFS dirty. This session burned ~9 boot
  cycles partly on self-inflicted dirty-volume noise.
- **CD-detach gating law** (from MacLC): a CUE/CHD attached at boot can hang
  intermittently on ANY build. To gate a build, move `config/MacIIvi.s4` aside,
  boot, judge, then remount. **One boot is never a verdict.**
- **Colour-icon integrity** is the marginality gate — check Finder icons render
  clean, not just that the desktop appeared.
- **Per-fit seed law:** every netlist change is a fresh roll. Re-sweep seeds;
  do not assume SEED 2 carries. Sweep script pattern is in this session's
  scratchpad; archives land in `output_files/seed_sweep_sync/`.

**Fast RTL regression (no hardware, seconds):**

```bash
wsl -e bash -lc "cd /mnt/c/Temp/mistercore/MacIIvi_MiSTer/verilator/scsi_bench && make -j\$(nproc) && ./obj_dir/Vscsi_bench_top && ./obj_dir/Vscsi_bench_top --mode gapcmds && ./obj_dir/Vscsi_bench_top --mode cdvol && ./obj_dir/Vscsi_bench_top --mode wbyte && ./obj_dir/Vscsi_bench_top --mode wword"
```

All were green on `ae54950` (full sweep 0 failing cells; gapcmds PASS; cdvol
PASS; wbyte/wword 0 mismatches). **The bench has no Toolbox GET test — adding
one is probably the highest-value next move**, because it would turn this
hardware bug into a seconds-long desk test. Model it on `run_cdvol()`
(`scsi_bench.cpp:645`), which already drives a full CDB + DataIn round trip;
the bench's HPS model would need to answer a tb round-trip with a >512-byte
payload and the `0xB5` status signature.

---

## 6. Machine + repo state (as left)

`.143` (`MISTER_HOST` in `scripts/local.env`, key `~/.ssh/mister_only`):

- `config/MacIIvi.s0` → `games/MacIIvi/Mac68KColorGames_v1.hda` ← **the owner's
  currently-working image; keep using this one.**
- `config/MacIIvi.s2` → `games/MacIIvi/MacIIvi.nvr` (PRAM, md5 `ebd27e12`)
- `config/MacIIvi.s3` → `games/MacIIvi/TIM_3-mac.chd` ← **stale, see §4.1**
- `config/MacIIvi.s4` → `games/MacIIvi/TIM_3-mac.chd`
- `games/MacIIvi/CD3/` → populated (TIM_3 BIN/CUE/CHD) — the CD-changer folder
- `games/MacIIvi/boot755_master.hda` → pristine 7.5.5, md5 `13cbbaad`, left as a
  known-good A/B gating volume. Delete if unwanted.
- Leftover backups I made: `MacIIvi.s0.gatebak`, `.s4.gatebak`, `.s4.detached`,
  `MacIIvi.nvr.pre_gate`. Safe to delete.
- Owner said they would clean-shutdown the guest at end of session.

**Known-not-a-core-bug:** `games/MacIIvi/boot755.hda` bombs *"Finder error type
10"* at Finder launch. Proven this session to be **an extension on that
volume** — it boots fine with Shift held (extensions off), and it fails
identically on the pre-sync 07-22 rbf. Not a regression, not the sync. Shift
boot recipe: `python tools/misterdeploy/ws_send.py --host $MISTER_HOST --port
$MISTER_HTTP_PORT kbdRawDown:42 "sleep:100" kbdRawUp:42`, started ~15 s after
the core launches.

Repo — branch `cd-audio`, unpushed:

- `ae54950` family sync from MacLC master `b247353`
- `31d426b` SEED 2 all-met
- `7787ed1` HW validation record + evidence PNGs
- (earlier) `1bebe75` CD changer port, `e6098ce` its seed

Push mechanism: SSH to GitHub is broken in this env — use `gh auth setup-git`
then an explicit HTTPS URL, and resync the tracking ref with
`git fetch <httpsurl> main:refs/remotes/origin/main`.

---

## 7. Suggested order of attack

1. Ask the owner **which direction failed** (GET vs SEND) and whether the
   uploaded files are byte-identical to their originals. This single answer
   splits the hypothesis space in half.
2. Rename `config/MacIIvi.s3` aside; retry a copy. (§4.1 — free.)
3. Verify the deployed Main is built from `f49c7d0` (includes `c3fd47f`
   64-bit offsets); rebuild + redeploy if not. (§4.2)
4. Add a Toolbox GET round trip to `scsi_bench` with a >512-byte payload;
   confirm it reproduces on the desk. (§5)
5. Apply the `TB_ADDRW(11)` fix + the over-serve clamp (§2), re-run the bench,
   Quartus + fresh seed sweep, clean-shutdown, deploy, retest on HW.
6. Port the fix back to MacLC (`rtl/ncr5380.sv`), since the same 512-byte
   ceiling is present there.
7. Then: merge `cd-audio` → `main`, push, and cut a release RBF.

## 8. Still unverified overall

- Whether the `rtl/asc.sv` byte-lane fix cured the long-standing **"game audio
  ~2× fast"** bug. The owner has `Mac68KColorGames_v1.hda` mounted and says
  audio is working — but a direct A/B on a known-2×-fast title has not been
  reported. Worth an explicit ask; if cured, close that thread and retire the
  `$807` clock-select hypothesis in chip `task_ab3818cc` (already believed dead).
- CD-changer **LIST CDS** with a multi-entry `CD3/` folder (only the TIM_3 set
  is there now, so the 100-entry multi-sector path is untested on HW).
