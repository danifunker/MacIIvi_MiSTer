# Handoff prompt — Main-side BlueSCSI Toolbox SEND speedup

Paste the block below into the session that owns `../Main_MiSTer`.

---

## Task

Speed up BlueSCSI Toolbox **SEND** (Mac → SD card) in the Main_MiSTer fork by
cutting the number of synchronous SD writes. This is a **performance and
robustness** change, not a correctness fix — do not change the wire protocol.

**Repo:** `../Main_MiSTer`, branch `add-bluescsi-toolbox-for-MacLC`, currently at
`d288d4f`.
**File:** `support/mac/mac_toolbox.cpp` (was `toolbox.cpp` before the `56ed556`
restructure).

## Why

`/media/fat` is exFAT mounted `sync,dirsync` — check with `mount | grep fat` on
the device. Every `write()` is committed synchronously to the card.

`tb_send_data()` (around line 252) currently does, once per 512-byte chunk:

```c
if (fseeko(tb_file, (off_t)off * 512, SEEK_SET) != 0) { ... }
size_t wrote = fwrite(chunk, 1, bytes, tb_file);
```

The `fseeko` before every `fwrite` forces glibc to flush its stdio buffer, so
this is **one `write()` syscall per 512 bytes** — about 5500 synchronous card
transactions for a 2.7 MiB file. Two costs:

1. It is slow.
2. Card erase cycles produce latency spikes of tens of milliseconds. Every one
   of those stalls the Toolbox handler, and with thousands of chances per file
   the tail latency is hit reliably.

The client writes sequentially, so essentially every one of those seeks is a
no-op that only exists to defeat buffering.

## Approach (recommended — small and low risk)

1. In `tb_send_prep()`, after `tb_file = fopen(path, "wb")`, give the stream a
   large buffer:
   ```c
   static char tb_wbuf[64 * 1024];
   setvbuf(tb_file, tb_wbuf, _IOFBF, sizeof(tb_wbuf));
   ```
2. In `tb_send_data()`, only seek when the position actually differs:
   ```c
   off_t want = (off_t)off * 512;
   if (ftello(tb_file) != want && fseeko(tb_file, want, SEEK_SET) != 0) {
       tb_ch.status = STATUS_CHECK; return;
   }
   ```
   `ftello()` reports the logical position including buffered bytes and does not
   flush, so a sequential copy never seeks after the first chunk.

That turns ~5500 syscalls into ~44 for a 2.7 MiB file while leaving
out-of-order writes correct (they still seek, which flushes — same as today).

If that is not enough, fall back to an explicit write-behind buffer that
accumulates contiguous chunks and flushes in 64 KB runs, flushing early on any
non-contiguous offset.

## Correctness requirements — do not skip these

- **Deferred error reporting.** With buffering, `fwrite` returns `bytes` even if
  the eventual `write()` fails, so the existing `wrote == bytes` test no longer
  detects I/O errors. Add `ferror(tb_file)` checks, and make `tb_send_end()`
  return `STATUS_CHECK` if `fflush` fails **or** `ferror` is set. A silent
  truncation is worse than the bug being fixed.
- **Flush before every close.** `tb_send_end()` already does `fflush` then
  `fclose`. Also check the implicit closes: `tb_send_prep()` closes any open file
  before creating the new one, and `tb_get()` closes/reopens when `offset == 0`.
  `fclose` flushes, but the *return value* must be checked on the SEND path.
- **Do not disturb the LBA-1 tail reassembly** added in `96caa9d`. A 512-byte
  chunk arrives as two request blocks: LBA 0 carries the CDB plus the first 496
  payload bytes, LBA 1 carries the 16-byte tail into `tb_tail`. `tb_send_data()`
  reassembles them before writing. Leave that intact.
- **Do not change the wire protocol.** The core side is already deployed and a
  matching core fix is in flight; core and Main must stay on the same contract.

No RTL or `scsi_bench` change is needed — the bench mirrors the handler's
behaviour, not its I/O strategy.

## Validation

- Time a large (>2 MiB) Mac → SD copy before and after.
- Verify the result is **byte-identical** to the Mac-side original, not merely a
  plausible size. Size alone previously hid a 16-bytes-per-block corruption.
- Confirm a partial/aborted copy still reports an error rather than silently
  leaving a short file.

## ⚠ Deploy caution

The device currently runs Main `md5 0e2b1026`, built from `96caa9d`.
Branch HEAD is `d288d4f`, which is **two commits ahead** of what is deployed:

- `56ed556` restructure: move all mac support into support/mac
- `d288d4f` mac: set the virtual CD size at mount, drop the SET_SDINFO hook

Building from HEAD therefore ships those two changes as well — the CD-size one
is a behaviour change that needs its own validation. Either validate them as
part of this deploy or build the speedup onto `96caa9d`.

Deploy hygiene: stage as `.new`, verify md5, atomic swap, keep the previous
binary as `MiSTer.prev` for rollback. Run from Git-Bash, not WSL.

## Context

The Mac → SD copy failure ("the SD card refused the transfer", aborting mid-file
on a clean 512-byte boundary) was root-caused on the **core** side and fixed in
`MacIIvi_MiSTer` commit `7ec4e2b`: the core's ~8 ms round-trip watchdog treated
a slow HPS answer as "no handler" and returned CHECK CONDITION. The core now
survives a stalled handler. This Main-side change reduces how often the handler
stalls at all, and makes copies much faster.
