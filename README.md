# Macintosh IIvi for the [MiSTer Board](https://github.com/MiSTer-devel/Main_MiSTer/wiki)

An emulation core for the **Apple Macintosh IIvi** running on MiSTer FPGA.

Shares its chipset and peripheral lineage with the
[Macintosh LC core](https://github.com/danifunker/MacLC_MiSTer), which descends from the
[MacPlus MiSTer core](https://github.com/MiSTer-devel/MacPlus_MiSTer) by Sorgelig and the
[Plus Too project](http://www.bigmessowires.com/plus-too/). The Mac IIvi emulates a
Motorola 68030 CPU with its on-chip PMMU (via a modified TG68K core), the VASP gate array
(video/glue), the Egret (HC05) system controller, a NuBus video card, and the machine's
other peripherals. The stock IIvi has **no FPU** (the 68882 socket is empty), and neither
does this core.

> **Work in progress.** This is an actively-developed core.

## Status

### Working

- Boots **Mac OS 7.1 and 7.5.5** from SCSI to the Finder desktop
- **68030 CPU with PMMU** via TG68K (with core-specific tweaks), running at the IIvi's
  native ~15.67 MHz
- **SCSI hard disks** on IDs 0 and 1 (read/write, boot) — two drives plus the CD-ROM
  run together
- **File transfer** to/from the SD card via the BlueSCSI Toolbox — see
  [File transfer](#file-transfer-bluescsi-toolbox)
- **CD-ROM drive** on SCSI ID 3 — data, mixed-mode and audio discs, including the
  AppleCD Audio Player. Needs a CD driver in the guest System — see
  [CD-ROM support](#cd-rom-support-scsi).
- **Color display** on a NuBus video card — 640×480 or 512×384
- **Sound**, including CD audio
- **Memory:** 8 / 20 / 36 / 48 MB configurations
- **PRAM/NVRAM:** save (on entering the OSD), automatic load at core start (or forced load),
  and clear
- **SCC serial** is wired in and "usable" but not yet doing anything useful
- **Floppy disks (read-only):** 800 KB GCR and 1.44 MB MFM disks in raw or
  DiskCopy 4.2 format. See [Floppy disk support](#floppy-disk-support)

### Not working yet

- **Floppy writes** (disks mount locked/write-protected)

## Usage

1. Copy the `*.rbf` to the root of your MiSTer SD card.
2. Place the 1 MB Mac IIvi ROM as `boot0.rom` in the `MacIIvi` folder.
3. Place a bootable SCSI hard-disk image (`.vhd` / `.img` / `.hda`) in the `MacIIvi` folder.
4. Optional: put files to share with the Mac in `games/MacIIvi/shared` — see
   [File transfer](#file-transfer-bluescsi-toolbox).

Open the on-screen display with **F12** to mount images and change options.

## ROM

The core requires the 1 MB Macintosh IIvx/IIvi/Performa 600 ROM (checksum `$4957EB49`,
CRC32 `61BE06E5`), placed as `boot0.rom`. The ROM is loaded into SDRAM at core start;
changing it requires a reset/reload.

## SCSI bus layout

Three real targets sit on the emulated SCSI bus. The remaining OSD slots are
**not SCSI devices** — they are private channels the core uses to talk to MiSTer's
Main (file transfer, PRAM, CD swapping), and the guest never sees them:

| OSD slot | SCSI ID | Purpose |
|---|---|---|
| `Mount SCSI-0` | **0** | Primary hard disk (boot device) |
| `Mount SCSI-1` | **1** | Secondary hard disk |
| `Mount CD-ROM` | **3** | CD-ROM drive |
| `Mount PRAM` | — | PRAM/NVRAM save image (host channel) |
| *(no OSD entry)* | — | BlueSCSI Toolbox shared folder (host channel) |
| *(no OSD entry)* | — | BlueSCSI Toolbox CD changer control (host channel) |

The two host channels without an OSD entry are mounted automatically by an updated
Main_MiSTer (see [Updating Main_MiSTer](#using-custom-mister-binary-for-this-core)); on an
older Main they stay unmounted and the features that use them degrade gracefully.

The Toolbox file-transfer commands are answered by the **SCSI ID 0** target and the
CD changer commands by the **ID 3** target — clients find them by INQUIRY, not by ID.

## Hard disk support (SCSI)

The on-screen display exposes two SCSI slots:

- **Mount SCSI-0** — primary drive (SCSI ID 0), the usual boot device
- **Mount SCSI-1** — secondary drive (SCSI ID 1)

> **The disk IDs are 0 and 1.** The boot SCSI ID is stored in PRAM, so an existing install
> blessed for a different ID will not boot until you run **Reset PRAM & Core** — or
> re-bless the volume for its new ID.

Images use a raw SCSI format (same as the SCSI2SD project, documented
[here](http://www.codesrc.com/mediawiki/index.php?title=HFSFromScratch)) with a `.vhd`,
`.img`, or `.hda` extension. The SCSI disk is writable; data written from within the OS is
persisted to the image file.

Cold boots of System 7.1 and 7.5.5 to the Finder desktop have been verified, and SCSI
writes were validated. A tool to create hard-disk images (with driver and partition table)
is available [here](https://diskjockey.onegeekarmy.eu/).

Both drives can be mounted at once, with the CD-ROM alongside them — all three targets
active on the bus is the normal, tested configuration.

## CD-ROM support (SCSI)

The core emulates an Apple-compatible CD-ROM drive on **SCSI ID 3**:

- **Mount CD-ROM** — mounts a disc image (the disc auto-remounts at core start)
- **CD-ROM Drive** (Enabled/Disabled) — removes the drive from the SCSI bus entirely
  when disabled

**The guest System must have a CD driver installed** — the stock Apple *CD-ROM* extension
works: the drive presents an AppleCD-family identity (`CD-ROM CDU-8004`, the AppleCD 300
mechanism).

Image format support:

| Format | Status |
|---|---|
| `.iso` / `.toast` / `.bin` (2048-byte sectors) | stock MiSTer Main |
| `.cue`+`.bin` (2352-byte raw), `.chd` | needs an updated Main_MiSTer, see [Updating Main_MiSTer](#using-custom-mister-binary-for-this-core) |

**CD audio is supported:** audio and mixed-mode discs mount correctly (pure-audio discs
reject data reads like a real drive — the Audio CD Access extension depends on that), and
the **AppleCD Audio Player** works end to end: full track listing with durations, play,
pause/resume, next/previous track, stop, and fast-forward/rewind scan with audio, and the
player's **volume slider** scales the audio. CD audio requires `.cue`+`.bin` or `.chd`
images (and therefore the forked Main, below) — flat 2048-byte images carry no audio tracks.

The drive also implements the **BlueSCSI CD changer** commands, so a guest-side changer
utility can list the discs in `games/MacIIvi/CD3` and swap between them without going
through the OSD.

Ejecting from the Finder (drag to Trash) is honored; use the OSD to insert a
different disc.

## File transfer (BlueSCSI Toolbox)

Files move between the SD card and the running Mac using the **BlueSCSI Toolbox**
protocol — no floppies or network needed. The core answers the Toolbox vendor SCSI
commands and MiSTer's Main serves a folder on the SD card as shared storage.

1. Put files in `games/MacIIvi/shared` on the SD card (or set `SHARED_FOLDER=` in
   `MiSTer.ini` to point elsewhere — note that this setting is global, so it will
   redirect every core that uses a shared folder).
2. Install the client, once: put
   [`releases/BlueSCSI Toolkit for MiSTer.dsk`](releases/) in your `MacIIvi` folder and
   mount it with **Mount Floppy**. Copy its contents to your boot volume, then eject;
   you won't need it again.
3. Run **BlueSCSI SD Transfer** from that folder. It lists the shared folder:
   **Download** copies a file to the Mac, and **File → Upload File** copies one
   back to the SD card.

This requires the updated Main_MiSTer — see
[Updating Main_MiSTer](#using-custom-mister-binary-for-this-core). Stock Main has no
Toolbox handler; the core degrades gracefully without it, and Toolbox commands simply
report that no shared folder is available.

*BlueSCSI Toolbox files distributed with permission from Eric Helgeson (c) 2026*

## CD Swapping (BlueSCSI Toolbox)

To use CD Swapping via BlueSCSI toolbox, create a folder in `/media/fat/games/MacIIvi`
called `CD3` and place CD images into that folder.

The updated Main_MiSTer must be running.

Note- this has not been fully tested yet.

## Using custom MiSTer Binary for this core

Two features — **file transfer** and **CUE/BIN + CHD CD images** — need support in
MiSTer's main executable. The changes are **merged upstream**
([PR #1255](https://github.com/MiSTer-devel/Main_MiSTer/pull/1255)) but have not
appeared in a released MiSTer binary yet, so `update_all` / the standard updater will
not give you them. Until a release includes them, perform this task:

1. Back up the existing one: `cp /media/fat/MiSTer /media/fat/MiSTer.orig`
2. cp `/media/fat/games/MacIIvi/MiSTer /media/fat/MiSTer` and make it executable (`chmod +x /media/fat/MiSTer`).
3. Reboot the MiSTer.

Note that the normal MiSTer updater may overwrite this file with the current official
build, which silently removes both features — re-copy it after running an update, until
a release ships with the merged support. Once one does, the updater is all you need and
this step goes away.

## Floppy disk support

**Floppy reading works** — 800 KB GCR and 1.44 MB MFM.
Mount images through the OSD's **"Mount Floppy"** slot. Disks are **read-only** for now:
they mount write-protected, exactly like a locked physical floppy.

The IIvi has a single internal SuperDrive and no external floppy port, so the core
exposes one floppy slot.

Both common image formats are auto-detected — no conversion needed:

- **Raw** (`.dsk` / `.img`): 819,200 bytes for 800K, 1,474,560 for 1.44 MB,
  409,600 for 400K, 737,280 for 720K
- **DiskCopy 4.2** (`.dsk` / `.image` / `.dc42`): the 84-byte DC42 header is parsed and
  skipped automatically; the disk geometry comes from the header's format byte

720K images are for PC/FAT disks and need PC Exchange installed in the guest.

### Swapping floppies — works like a real Mac

**Media changes are reported to the Mac:** the drive presents both the "disk in place"
transition and the SuperDrive's "disk switched" flag the way a real drive does, so a
running Mac notices ejects, inserts, and swaps on its own — no reset needed.

The natural flow is the real-Mac one:

- **In the Finder, eject first** — drag the floppy to the Trash (the Mac ejects it and
  the drive really empties), then mount the next image in the OSD. The new disk is
  picked up within a couple of seconds and mounts as itself.
- Mounting a *different* image over a still-mounted one (no eject) is the equivalent
  of yanking a disk out of a real drive mid-use: the Mac sees its volume vanish. It
  copes, but may complain, so prefer the eject-first flow.

Booting from a floppy works: mount a bootable image at the flashing-`?` screen and the
ROM picks it up within a few seconds.

## PRAM / NVRAM

The Mac IIvi's parameter RAM (PRAM) — which stores settings such as the monitor color depth
and the real-time clock — is backed by a persistent NVRAM image:

- **Save:** PRAM is written back when you open the OSD.
- **Load:** the PRAM image is loaded automatically when the core starts; you can also force a
  reload via the "Mount PRAM" slot in the OSD.
- **Clear:** "Reset PRAM & Core" clears PRAM and resets the machine (a fresh, default PRAM).

A default PRAM image is included as `releases/MacIIvi.nvr`.

## Memory

Four configurations are selectable in the OSD: **8 MB**, **20 MB**, **36 MB** and
**48 MB**. The list adapts to the SDRAM module fitted to your MiSTer — 36 and 48 MB
require a 64 MB or larger module, so with a 32 MB module only 8 and 20 MB are offered.
(If the larger options don't appear on a board that has the RAM, enter the main MiSTer
menu once so Main probes the module.) Changing the memory setting applies on reset
("Reset & Apply CPU+Memory"). A cold boot with more RAM selected takes longer to complete
its RAM test before booting — be patient.

## Display

The IIvi has both onboard VASP video and NuBus slots. This core scans out an Apple
**8•24-class NuBus video card**, and reports no monitor on the onboard port, so the ROM
routes the entire display — boot screen included — to the card.

Two resolutions are selectable in the OSD:

- **640×480 VGA**
- **512×384 12" RGB**

Aspect ratio and scaling options are available in the OSD. The "Original"
aspect is true **4:3** for both monitor modes (fixed 2026-08-08 — it was
256:171, a Mac Plus 512×342 leftover from the LC-family import, which
overflowed integer scaling on 5:4 panels into a blank screen and squished
forced-1080p output; `scripts/aspect_check.py` is the offline regression
gate for the scaler math).

## Keyboard & mouse

Keyboard and mouse are delivered over a wire-level ADB device model. The **Alt** key maps to
the Mac's Command (⌘) key and the **Windows** key maps to Option (⌥). The numeric keypad is
emulated.

## Building from source

### FPGA (Quartus)

Built with **Intel Quartus 17.0.2 Lite**. Either open `MacIIvi.qpf` in the Quartus GUI and
compile, or use the scripted CLI flow (repeatable, headless-friendly):

```bash
bash scripts/build.sh        # full compile -> output_files/MacIIvi.rbf
```

Set `QUARTUS_BIN` in `scripts/local.env` first. Deploy the resulting `.rbf` from
`output_files/` to the SD card.

### Simulation (Verilator)

A Verilator testbench is provided for development:

```bash
cd verilator
make
./obj_dir/Vemu --help
```

See [CLAUDE.md](CLAUDE.md) and the `docs/` directory for architecture notes and the
development workflow.

## AI Disclaimer
Please be aware this core was developed with heavy use of AI tooling, including Claude (Fable, Opus, Sonnet Models) and GPT (Codex), and does borrow from MAME.

## Known Inaccuracies
- The NuBus video card presents **512KB of VRAM** (the 4•8-class
  configuration of the MDC ROM), so the Monitors panel offers up to 256
  colors at both resolutions and does not list the 24-bit "Millions" mode.
  300KB of it is scannable framebuffer — exactly 640×480 at 256 colors.
- TG68K CPU is not cycle accurate, however the CPU test suite included in this repository
  was used to verify CPU instruction accuracy against real 68030 silicon
- No FPU is emulated — correct for a stock Mac IIvi, but software that requires a 68882
  will not run

## MAME Sourced Components
- SCSI subsystem
- EGRET (this core does use the original EGRET firmware which is baked into core) this includes ADB connectivity
- Floppy (SWIM)
- CD-ROM & CD-ROM Audio
- VASP (video/glue subsystem)
- NuBus video card
- ASC (sound subsystem)

## Credits

- **MacPlus MiSTer** core by Sorgelig
- **Plus Too** by Steve Chamberlin (Big Mess o' Wires)
- **BlueSCSI Toolbox** protocol and client by [Eric Helgeson](https://github.com/erichelgeson)
- Mac IIvi port and ongoing development by [danifunker](https://github.com/danifunker) and [alanswx](https://github.com/alanswx)
