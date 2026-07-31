# Toolbox file transfers — root cause + fix, 2026-07-31

Supersedes `resume_toolbox_large_files_2026-07-30.md` (its §2 hypothesis was
half right: the buffer IS too small, but that is only one of three defects, and
the one the owner saw first was a different bug entirely).

Branch `cd-audio`, commits `205800b` + `7efe80e` (core/bench) and Main_MiSTer
`96caa9d` (HPS). **Desk-validated, not yet on hardware.**

---

## 1. The owner's report

> "I was getting a lot of errors copying from the Mac (it was a loaded CD) to
> SDCard."

So the failing direction is **SEND** (Mac → shared folder), not GET. That single
answer redirected the hunt; the 07-30 doc had predicted GET.

## 2. Root cause — three defects on the SEND path

The Mac client (BlueSCSI `SEND_FILE_10`) transfers **a full 512-byte DataOut
block for every 0xD4**, and puts the number of *valid* bytes in that block in
CDB[6] (512-blocks) or CDB[1..2] (legacy count). The last chunk of a file is a
full block with a short valid count.

### (a) The visible errors — DataOut phase ended early

`data_len` for 0xD4 was derived from the CDB's *valid-byte count*, so on the
short final chunk the target stopped REQ-ing partway through the block and moved
to the status phase. The initiator still had bytes to push → phase mismatch →
the client reports a failed copy. Files whose size is an exact multiple of 512
have no short chunk and copied "fine".

**This predicts exactly what is on the SD card.** The four files uploaded in the
owner's session:

| file | size on SD | = k·512+496? | true size (+16) | multiple of 512? |
|---|---|---|---|---|
| Machine Data.bin | 102896 | 200·512+496 ✓ | 102912 | 201·512 ✓ |
| TIM Audio.bin | 45552 | 88·512+496 ✓ | 45568 | 89·512 ✓ |
| Machine Info.bin | 12784 | 24·512+496 ✓ | 12800 | 25·512 ✓ |
| ENGLISH.DAT.bin | 1408 | ✗ (2·512+384) | — | ✗ |

The three that landed are the three whose true size is an exact multiple of 512
— i.e. the only ones with no short final chunk. All three are also 16 bytes
below a valid MacBinary length (MacBinary is always a multiple of 128; these are
all ≡112 mod 128). That 16 is defect (b).

### (b) The silent corruption — 512-byte payload in a 512-byte buffer

The request block is `CDB at [0..9], payload at [16..]`, so a 512-byte payload
runs to buffer byte **527**. The Toolbox target's tb buffer was 512 bytes
(`TB_ADDRW=8`), so the payload wrapped back onto the CDB words and its last 16
bytes were lost. Because the write offset is in 512-byte units, every uploaded
file got a **16-byte zero hole every 512 bytes** and finished 16 bytes short.

The CD changer already had `TB_ADDRW=11` (4 KB) for multi-sector LIST CDS; the
file Toolbox never got the same treatment.

### (c) A latent transport race — Toolbox DataIn serve

Found by the new bench, not by the box. Toolbox responses are served straight
out of the tb dpram, whose port-B read register `q_b` is time-shared with the
look-ahead prefetch controller: for ~3 cycles after every word-address change
`q_b` holds `ram[addr+2]`, not `ram[addr]`. The pseudo-DMA read path covers this
with ncr5380's `dma_settle`; the PIO Toolbox path had no equivalent. The word
address only changes on even→odd byte boundaries, so **every EVEN byte** of a
LIST/GET is exposed. Real Mac PIO is slow enough to have hidden it; the bench
hits it every time.

### Also fixed: 0xD1 GET

`tb_get` serves 4096-byte blocks. With a 512-byte buffer the core promised 4096
bytes and served one sector eight times. `TB_ADDRW=11` gives the real 8 sectors,
and `tb_srv_len` now clamps the served length to what the buffer holds so an
over-long HPS response can never be served from wrapped words again.

---

## 3. What changed

**`rtl/scsi.v`**
- `data_len` for 0xD4 = fixed `32'd512`, plus a ~2 ms inter-byte watchdog
  (`tb_out_stalled`) that closes the phase gracefully if a client ever sends
  only the valid count instead of a full block — otherwise the target would hold
  REQ until the Mac reset the bus.
- New FSM state `TBS_REQ2`: for 0xD4, write the payload tail (buffer sector 1)
  to **LBA 1 first**, then the CDB block to LBA 0, so the handler has the whole
  512 bytes when it runs. Carries the same ~8 ms ack watchdog as TBS_STAT /
  TBS_DATA — it is the one new HPS transfer in the round-trip and a missed ack
  would wedge the bus.
- `tb_srv_len` clamps the served DataIn length to `TB_MAXSEC*512`.
- `tb_srv_hold` holds REQ (and req_bus) down a few cycles after each advance in
  a Toolbox DataIn serve. Scoped: it is 0 everywhere else.

**`rtl/ncr5380.sv`** — `.TB_ADDRW(i == 0 ? 11 : 8)` on the disk targets.

**`../Main_MiSTer/toolbox.cpp`** — accept the LBA-1 tail block, reassemble up to
512 bytes per 0xD4 (the 496 cap is gone), cap GET's staged response at 4096.

**`verilator/scsi_bench`** — new `--mode toolbox`: `tb_*` ports on the harness,
a `TbHps` mirror of Main's handler, and a test that drives COUNT → LIST (560 B,
crosses a sector) → SEND PREP/DATA×3/END (1408 B = 2 full blocks + a 384-byte
tail, byte-compared) → a short-DataOut SEND (watchdog path) → GET (4096 B).
It reproduced (a) and (c) on the unfixed RTL and is green on the fix.

---

## 4. Validation state

Desk (all green on `7efe80e`):

```bash
wsl -e bash -lc "cd /mnt/c/Temp/mistercore/MacIIvi_MiSTer/verilator/scsi_bench && make -j\$(nproc) && ./obj_dir/Vscsi_bench_top && for m in gapcmds cdvol wbyte wword toolbox; do ./obj_dir/Vscsi_bench_top --mode \$m; done"
```

- full sweep: **0 failing cells**
- gapcmds PASS · cdvol PASS · wbyte/wword 0 mismatches · **toolbox PASS**
- `verilator/` main sim builds clean.

Hardware: **not yet.** Quartus seed sweep for the new netlist was running when
this was written (`output_files/seed_sweep_tbfix/`, seeds 2,1,3,4,5, first
all-met wins). Expect ~+2 M10K from `TB_ADDRW` 8→11 (was 522/553).

## 5. Deploy plan (needs the owner's go, per repo law)

1. `bash scripts/mac_clean_shutdown.sh` — never reload a core under a live Mac.
2. Push the new Main binary (`../Main_MiSTer/bin/MiSTer`): staged `.new` → md5
   verify → atomic swap keeping `MiSTer.prev`. **Core and Main must move
   together** — the LBA-1 tail block is a wire-contract change.
   (Safe for MacLC too: its older core never writes LBA 1, so `tb_tail` stays
   zero and its uploads keep today's content, just with the right length.)
3. `bash scripts/deploy_screenshot.sh` (Git-Bash, never WSL).
4. Rename `config/MacIIvi.s3` aside — stale, points at `TIM_3-mac.chd` from
   before slot 3 became `VD_TOOLBOX`.
5. CD-detach gating law: move `config/MacIIvi.s4` aside for the first boot,
   judge Finder + **colour-icon integrity**, then remount. One boot is never a
   verdict.
6. Owner test: copy a file **off a mounted CD** to the shared folder, and a file
   from the shared folder to the Mac. Verify byte-identity, not just size.

## 6. Follow-ups

- **Port to MacLC** once HW-validated: `rtl/scsi.v` is byte-identical between the
  two cores (verified), so it copies wholesale; `rtl/ncr5380.sv` needs only the
  `.TB_ADDRW(i == 0 ? 11 : 8)` line added to its `scsi #(...) target`
  instantiation. Also update
  `MacLC_MiSTer/docs/BLUESCSI_CORE_HPS_CONTRACT.md`, which still documents
  "`[16..]`=SEND payload (≤512−16)" and a single request block.
- **Throughput.** Every tb round-trip pays the ~8 ms `tb_to` watchdog because the
  tb READ ack is not observed on hardware (the WRITE ack is — which is why the
  new tail-block write costs nothing). That caps Toolbox transfers at roughly
  64 KB/s in both directions. Pre-existing, unchanged by this fix, but it is the
  next thing worth chasing if copying off a CD feels slow.
- Delete the leftover `.gatebak` / `.detached` / `.pre_gate` files on the box.
