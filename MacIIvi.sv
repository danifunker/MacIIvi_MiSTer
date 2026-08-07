//============================================================================
//  Macintosh IIvi
//
//  VASP chipset core derived from the MacLCII core (imported @ a254a02);
//  lineage: MacPlus core by Sorgelig / Plus Too.
//  Copyright (C) 2025-2026 Dani Sarfati
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);
	assign ADC_BUS  = 'Z;
	assign USER_OUT = '1;

`ifndef MDC_VRAM_DDR
	assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = 0;
`else
	// Option B (docs/VRAM_1MB_OPTIONS.md): the DDRAM channel carries the
	// mdc824 card VRAM — driven by the mdc_vram_ddr adapter below.
	assign DDRAM_CLK = clk_sys;
`endif
	assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

	assign LED_USER  = dio_download || (disk_act ^ |diskMotor);
	assign LED_DISK  = 0;
	assign LED_POWER = 0;
	assign BUTTONS   = 0;
	assign VGA_SCALER= 0;
	assign VGA_DISABLE = 0;
	assign HDMI_FREEZE = 0;
	assign HDMI_BLACKOUT = 0;
	assign HDMI_BOB_DEINT = 0;

	wire [1:0] ar = status[8:7];
	video_freak video_freak
	(
		.*,
		.VGA_DE_IN(VGA_DE),
		.VGA_DE(),

		.ARX((!ar) ? 12'd256 : (ar - 1'd1)),
		.ARY((!ar) ? 12'd171 : 12'd0),
		.CROP_SIZE(0),
		.CROP_OFF(0),
		.SCALE(status[13:12])
	);
	
	`include "build_id.v"
	localparam CONF_STR = {
		"MacIIvi;UART57600:115200;",
		"-;",
		// One floppy only: the real Mac IIvi has a single internal SuperDrive
		// and no external floppy port. The old "Sec Floppy" (F2, ioctl index 2)
		// was dropped 2026-08-06 (owner call, fit headroom): the second drive
		// still exists inside the family-shared swim.v but its insertDisk is
		// tied off below, so it permanently reports "no disk" — exactly a real
		// IIvi's empty second bay. Keep the F**1** index: the mount latches key
		// on dio_menu==1 and Main packs the extension into the upper bits.
		"F1,DSKIMG,Mount Floppy;",
		"-;",
		"SC0,IMGVHDHDA,Mount SCSI-0;",
		"SC1,IMGVHDHDA,Mount SCSI-1;",
		"SC2,NVR,Mount PRAM;",
		// CD-ROM (SCSI ID 3). ISO/TOAST (TO* matches .toast) are raw 2048-byte
		// images and work today; CUE/BIN/CHD are listed for the Main_MiSTer
		// translation layer — a 2048-byte-sector .bin also works mounted directly.
		"SC4,ISOTO*CUEBINCHD,Mount CD-ROM;",
		"OI,CD-ROM Drive,Enabled,Disabled;",
		"-;",
		"O78,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
		"OCD,Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
		"OA,Monitor,640x480 VGA,512x384 12in RGB;",
		"-;",
		// Memory: one line per SDRAM-module tier (O234 = status[4:2]), so only
		// sizes the fitted module can back are offered. menumask bit 0 = module
		// >=64MB (from hps_io sdram_sz; H hides when the bit is SET, h when CLEAR).
		// 36MB tops out SDRAM word $157FFFF and 48MB word $1B7FFFF — both inside a
		// 64MB module's (and a 128MB module's chip-0) $1FFFFFF limit, so both need
		// only a >=64MB module. 48MB doubles as the chip-0-only probe that isolates
		// the 68MB chip-1/nCS fault. 68MB (word $257FFFF, needs a 128MB module's
		// SECOND chip) is HIDDEN pending a hardware fix of that path — the RTL
		// still supports the size, it's just not OSD-reachable (and the clamp below
		// caps any stale selection). With an unknown/32MB module only 8/20MB show.
		"H0O234,Memory,8MB,20MB;",
		"h0O234,Memory,8MB,20MB,36MB,48MB;",
		"-;",
		"R5,Interrupt (NMI / MacsBug);",
		"R6,Reset PRAM & Core;",
		"R0,Reset & Apply CPU+Memory;",
		"V,v",`BUILD_DATE
	};

	////////////////////   CLOCKS   ///////////////////

	wire clk_sys, clk_mem;
	wire pll_locked;

	pll pll
	(
		.refclk(CLK_50M),
		.outclk_0(clk_mem),
		.outclk_1(clk_sys),
		.locked(pll_locked)
	);

	// pll_locked is asynchronous to clk_sys — synchronize it before the reset
	// logic / PRAM FSM consume it. (The sdram controller keeps the raw signal:
	// a glitchy init reload there is harmless, it just re-runs the ladder.)
	reg [1:0] pll_locked_sync = 2'b00;
	always @(posedge clk_sys) pll_locked_sync <= {pll_locked_sync[0], pll_locked};
	wire pll_locked_s = pll_locked_sync[1];

	// Hold the machine in reset from FPGA config until the framework has
	// streamed boot0.rom (dio_index 0) into SDRAM. Without this latch the 68k
	// runs through the 100+ ms gap between PLL lock and the start of the ROM
	// download, executing whatever the PREVIOUS core left in SDRAM at the ROM
	// window — per-load garbage that can poke any peripheral (and HPS-side
	// block-device state) before the real boot. Symptom: cold loads sometimes
	// misbehave (weird boot chime) unless a different core is loaded first.
	// Cleared only by reconfig; the ROM stays in SDRAM across warm resets.
	reg rom_loaded = 1'b0;
	always @(posedge clk_sys) if (dio_download && dio_index == 0) rom_loaded <= 1'b1;

	reg [2:0] status_mem = 3'b000;       // latched memory selection (status[4:2])
	// Machine is hardwired to Mac IIvi ($A55A2016); the Performa 600 OSD option
	// was removed for the release (P600's 32MHz CPU mode was never enabled — it
	// ran at 16MHz like the IIvi anyway). status[4] freed by that removal and now
	// reused as the Memory field's 3rd bit (O234, five sizes 8/20/36/48/68).
	localparam [1:0] status_cpu = 2'b10; // 68020
	reg       n_reset = 0;
	reg       pram_force_reset = 1'b0;  // "Reset PRAM & Core" -> system reset pulse
	wire      egret_reset_680x0_w;      // Egret HC05 holding 68k in reset (#3 probe)
	// Mac LC always runs at C15M (~15.67 MHz) - use 16 MHz clock enables
	always @(posedge clk_sys) begin
		reg [15:0] rst_cnt;

		if (clk8_en_p) begin
			// various sources can reset the mac
			// NOTE: Do NOT include ~_cpuReset_o here — the CPU executes the RESET
			// instruction during boot to reset peripherals, which would cause an
			// infinite reset loop if fed back to the system reset.
			// Only the ROM download (index 0) holds the machine in reset: it loads
			// boot0.rom into SDRAM before the CPU may run. Floppy mounts (index 1/2)
			// stream into SDRAM on the separate `dioBusControl` slot while the CPU
			// keeps running, so they must NOT reboot the core (hot-insert, like real
			// hardware / lbmactwo). Gating on dio_index==0 fixes the insert-disk reboot.
			// `!rom_loaded` extends the hold from config until that first ROM
			// download begins (see the rom_loaded latch above).
			if(~pll_locked_s || !rom_loaded || status[0] || buttons[1] || RESET || pram_force_reset || (dio_download && dio_index == 0)) begin
				rst_cnt <= '1;
				n_reset <= 0;
			end
			else if(rst_cnt) begin
				rst_cnt     <= rst_cnt - 1'd1;
				status_mem  <= status[4:2];
			end
			else begin
				n_reset <= 1;
			end
		end
	end

	///////////////////////////////////////////////////

	localparam SCSI_DEVS = 2;          // SCSI block devices -> hps_io slots 0,1
	localparam VD_PRAM   = 2;          // PRAM NVRAM save image -> hps_io slot 2
	localparam VD_TOOLBOX = 3;         // BlueSCSI Toolbox shared folder -> hps_io slot 3
	localparam VD_CDROM  = 4;          // CD-ROM image (SCSI ID 3) -> hps_io slot 4
	localparam VD_CD_TOOLBOX = 5;      // BlueSCSI Toolbox CD Changer control -> hps_io slot 5
	localparam VDNUM     = 6;          // total hps_io block devices

	// the status register is controlled by the on screen display (OSD)
	wire [31:0] status;
	wire  [1:0] buttons;

	// Fitted SDRAM module, reported by Main (menu core probes it once and Main
	// replays it to every core): [15] = valid, [1:0] 1=32MB 2=64MB 3=128MB.
	// Gates which Memory OSD line shows and clamps ram_size_bytes so a stale
	// selection can never address past the module (the 36MB-on-32MB failure
	// mode: RAM above 25MB wraps onto the ROM/VRAM/floppy staging words and
	// corrupts the machine mid-session).
	wire [15:0] sdram_sz;
	wire        sdram_64p = sdram_sz[15] && (sdram_sz[1:0] >= 2'd2);  // 64 or 128MB
	// menumask bit 0 = "module >=64MB" gates the 8/20/36/48 vs 8/20 Memory lines.
	// (128MB detection retired with the 68MB OSD entry — the offered sizes now top
	// out at 48MB = chip-0-only; re-add sdram_128 when the chip-1/nCS path is fixed.)
	wire [15:0] status_menumask = {15'd0, sdram_64p};

	// hps_io block-device buses (all VDNUM devices)
	wire [31:0] sd_lba[VDNUM];
	wire  [VDNUM-1:0] sd_rd;
	wire  [VDNUM-1:0] sd_wr;
	wire  [VDNUM-1:0] sd_ack;
	// hps_io drives [12:0] (AW=12 in WIDE mode); [7:0] serves every 512-byte
	// consumer, [12:8] reach the CD whole-frame burst path (2352 B/txn).
	wire           [12:0] sd_buff_addr;
	wire           [15:0] sd_buff_dout;
	wire           [15:0] sd_buff_din[VDNUM];
	wire                  sd_buff_wr;
	wire  [VDNUM-1:0] img_mounted;
	wire           [63:0] img_size;

	// SCSI side (slots 0,1): separate buses driven by dataController, stitched into
	// the shared hps_io buses so the PRAM save image (slot 2) can coexist.
	wire [31:0] scsi_lba[SCSI_DEVS];
	wire  [SCSI_DEVS-1:0] scsi_rd, scsi_wr;
	wire  [SCSI_DEVS-1:0] scsi_ack = sd_ack[SCSI_DEVS-1:0];
	wire           [15:0] scsi_buff_din[SCSI_DEVS];
	assign sd_lba[0]      = scsi_lba[0];
	assign sd_lba[1]      = scsi_lba[1];
	assign sd_rd[1:0]     = scsi_rd;
	assign sd_wr[1:0]     = scsi_wr;
	assign sd_buff_din[0] = scsi_buff_din[0];
	assign sd_buff_din[1] = scsi_buff_din[1];

	// CD-ROM (SCSI ID 3) dedicated slot (4): read-only block device driven by
	// the cdrom target through dataController. cd_wr is tied off — the target
	// never issues writes (read-only device, WRITE commands CHECK).
	wire [31:0] cd_lba;
	wire        cd_rd;
	wire [15:0] cd_buff_din;
	assign sd_lba[VD_CDROM]      = cd_lba;
	assign sd_rd [VD_CDROM]      = cd_rd;
	assign sd_wr [VD_CDROM]      = 1'b0;
	assign sd_buff_din[VD_CDROM] = cd_buff_din;
	wire        cd_ack     = sd_ack[VD_CDROM];
	wire        cd_mounted = img_mounted[VD_CDROM];
	// OSD "CD-ROM Drive" option (OI / status[18], 0 = Enabled). Disabling makes
	// ID 3 vanish from the bus entirely — the pre-CD baseline, kept as a
	// hardware A/B lever given the SCSI wedge history.
	wire        cd_enable  = ~status[18];

	// BlueSCSI Toolbox dedicated slot (3): isolated block device driven by the
	// primary SCSI target (ID 0) through dataController. There is deliberately
	// NO OSD "SC3" file-picker entry — the Toolbox shared folder is exposed by
	// the HPS (Main_MiSTer) handler, not user-mounted, matching MacLC. Inert
	// (graceful degradation) until the HPS mounts a shared folder here
	// (tb_mounted) and answers the round-trips; see the BlueSCSI core/HPS
	// contract. Slot layout matches MacLC exactly (Toolbox 3, CD-ROM 4), so the
	// HPS needs NO per-core slot override — maclc_toolbox_slot() = TOOLBOX_SLOT.
	wire [31:0] tb_lba;
	wire        tb_rd, tb_wr;
	wire [15:0] tb_buff_din;
	assign sd_lba[VD_TOOLBOX]      = tb_lba;
	assign sd_rd [VD_TOOLBOX]      = tb_rd;
	assign sd_wr [VD_TOOLBOX]      = tb_wr;
	assign sd_buff_din[VD_TOOLBOX] = tb_buff_din;
	wire        tb_ack     = sd_ack[VD_TOOLBOX];
	wire        tb_mounted = img_mounted[VD_TOOLBOX];

	// BlueSCSI Toolbox CD Changer control slot (5): control-only round-trip for
	// the CD target's 0xD7/D8/DA. No CONF_STR mount entry — the Main fork mounts
	// it when the CD-folder handler is active. docs/BLUESCSI_CD_CHANGER_CONTRACT.md
	wire [31:0] cdtb_lba;
	wire        cdtb_rd, cdtb_wr;
	wire [15:0] cdtb_buff_din;
	assign sd_lba[VD_CD_TOOLBOX]      = cdtb_lba;
	assign sd_rd [VD_CD_TOOLBOX]      = cdtb_rd;
	assign sd_wr [VD_CD_TOOLBOX]      = cdtb_wr;
	assign sd_buff_din[VD_CD_TOOLBOX] = cdtb_buff_din;
	wire        cdtb_ack     = sd_ack[VD_CD_TOOLBOX];
	wire        cdtb_mounted = img_mounted[VD_CD_TOOLBOX];
	wire        ioctl_write;
	reg         ioctl_wait = 0;
	wire [10:0] ps2_key;
	wire [24:0] ps2_mouse;
	wire        capslock;

	wire [24:0] ioctl_addr;
	wire [15:0] ioctl_data;

	wire [32:0] TIMESTAMP;

	// =====================================================================
	// PRAM persistence (NVRAM) — autosave to a mounted save image (slot 2).
	//   load  : when the PRAM image mounts (img_mounted[VD_PRAM], size>0)
	//   flush : when the OSD opens and PRAM changed since the last save
	//   R6    : "Reset PRAM & Core" — zero PRAM, flush zeros, reboot the machine
	// One 512-byte sector at LBA 0 holds the 256 PRAM bytes (rest padded). The
	// Egret owns the canonical pram[]; we shuttle it through pram_buf via the
	// pram_load_*/pram_save_* ports (see egret_wrapper.sv). SD handshake mirrors
	// scsi.v: drop rd/wr on io_ack rising, sector done on io_ack falling.
	// =====================================================================
	reg        pram_load_wr;
	reg  [7:0] pram_load_addr, pram_load_data, pram_save_addr;
	wire [7:0] pram_save_data;
	wire       pram_wr_stb;

	reg        pram_rd, pram_wr_req;
	wire       pram_ack = sd_ack[VD_PRAM];
	assign sd_lba[VD_PRAM] = 32'd0;             // single 512B sector at LBA 0
	assign sd_rd [VD_PRAM] = pram_rd;
	assign sd_wr [VD_PRAM] = pram_wr_req;

	reg  [7:0] pram_buf[0:255];                 // staging buffer <-> SD sector
	// FPGA->HPS readback during save: 16-bit word = {odd byte, even byte}; pad.
	assign sd_buff_din[VD_PRAM] = (sd_buff_addr < 8'd128)
	        ? {pram_buf[{sd_buff_addr[6:0],1'b1}], pram_buf[{sd_buff_addr[6:0],1'b0}]}
	        : 16'h0000;

	reg        pram_ena;                        // a save image is mounted (size>0)
	reg        pram_dirty;                      // PRAM changed since last save
	reg        pram_rst_after;                  // pulse reset after the current save
	reg        pram_load_pending, pram_flush_pending, pram_clr_pending;
	reg        old_pack, old_osd, old_mnt2, old_rstpram;
	reg        pram_ready;        // -> Egret: pram[] loaded (or no image / timed out)
	reg [31:0] pram_rdy_cnt;      // ready backstop so a missing image never hangs boot
	reg        pram_restart_after_load; // load landed after CPU release -> clean restart
	reg [26:0] pram_ld_wd;        // load watchdog: re-kick a stalled SD read
	reg  [1:0] pram_ld_try;       // retries before giving up (boot with defaults)

	localparam [3:0] P_IDLE=0, P_LD_RD=1, P_LD_DAT=2, P_LD_CPY=3,
	                 P_FILL=4, P_SV_WR=5, P_SV_DAT=6, P_CLR=7, P_RST=8, P_LD_KICK=9;
	// ~2 s at the IIvi's 32.5 MHz clk_sys (rtl/pll/pll_0002.v; 2026-07-15 clock
	// audit): long enough for a busy HPS. If the ready backstop fires while
	// retries are still running, the CPU boots on defaults and a subsequently-
	// successful load auto-restarts the machine with the real PRAM
	// (pram_restart_after_load) — both orders safe. (Ported from MacLC
	// fix-pram-boot-hold 5cef15d, HW-validated there 2026-07-16.)
	localparam [26:0] PRAM_LD_WD_MAX = 27'd65_000_000;
	reg  [3:0] pst;
	reg  [8:0] pcnt;
	reg  [6:0] rst_hold;

	always @(posedge clk_sys) begin
		if (~pll_locked_s) begin
			pst <= P_IDLE; pram_rd <= 0; pram_wr_req <= 0; pram_load_wr <= 0;
			pram_ena <= 0; pram_dirty <= 0; pram_force_reset <= 0; pram_rst_after <= 0;
			pram_load_pending <= 0; pram_flush_pending <= 0; pram_clr_pending <= 0;
			old_pack <= 0; old_osd <= 0; old_mnt2 <= 0; old_rstpram <= 0; rst_hold <= 0;
			pram_ready <= 0; pram_rdy_cnt <= 0;
			pram_restart_after_load <= 0; pram_ld_wd <= 0; pram_ld_try <= 0;
		end else begin
			old_pack    <= pram_ack;
			old_osd     <= OSD_STATUS;
			old_mnt2    <= img_mounted[VD_PRAM];
			old_rstpram <= status[6];
			pram_load_wr <= 1'b0;                  // default low; pulsed in copy/clear

			// PRAM SD-read capture (only while HPS services our slot)
			if (pram_ack && sd_buff_wr && sd_buff_addr < 8'd128) begin
				pram_buf[{sd_buff_addr[6:0],1'b0}] <= sd_buff_dout[7:0];
				pram_buf[{sd_buff_addr[6:0],1'b1}] <= sd_buff_dout[15:8];
			end

			// firmware PRAM writes mark the image dirty
			if (pram_wr_stb) pram_dirty <= 1'b1;

			// event latches
			if (img_mounted[VD_PRAM] && !old_mnt2) begin
				pram_ena <= (img_size != 0);
				if (img_size != 0) pram_load_pending <= 1'b1;  // load runs -> P_LD_CPY sets pram_ready
				else               pram_ready        <= 1'b1;  // no image: release the boot-copy now
			end
			if (OSD_STATUS && !old_osd && pram_dirty && pram_ena) pram_flush_pending <= 1'b1;
			if (status[6] && !old_rstpram) pram_clr_pending <= 1'b1;

			// PRAM-ready gate. The Egret's boot-copy seeds the 68k's working PRAM from
			// pram[] the instant this asserts (and the 68k is held in reset until then):
			// a real image releases it via the load FSM (P_LD_CPY); a no-image (size==0)
			// report releases it in the mount handler above. The backstop below bounds
			// the hold when neither happens (no mount status, or a load stalled past its
			// retries) so a fresh core load can never sit on a black screen for minutes —
			// the MacLC 2026-07-16 field symptom (only cured by a manual .nvr re-mount).
			// The OLD 3.9e9-cycle backstop (~120 s at clk_sys = 32.5 MHz — per
			// rtl/pll/pll_0002.v and the 2026-07-15 clock audit; NOT ~65 MHz as an
			// earlier comment claimed) existed because a short blind timeout used to
			// cause zero-PRAM boots when the auto-mount was slow: it fired before the
			// mount and seeded the all-zero default -> ROM InitUtil wiped PRAM every
			// boot. That hazard is gone now that a LATE load auto-restarts the machine
			// with the loaded PRAM (pram_restart_after_load below), so short is safe
			// again. 200e6 cycles ~= 6.2 s at 32.5 MHz. Paused during P_LD_CPY so it
			// can't release the Egret boot-copy against a half-written pram[] (the
			// copy sets pram_ready itself on completion).
			if (!pram_ready && pst != P_LD_CPY) begin
				if (pram_rdy_cnt >= 32'd200_000_000) pram_ready <= 1'b1;
				else pram_rdy_cnt <= pram_rdy_cnt + 1'b1;
			end

			// hold the reset pulse long enough for the clk8_en_p reset block to latch
			if (pram_force_reset) begin
				if (rst_hold == 0) pram_force_reset <= 1'b0;
				else rst_hold <= rst_hold - 1'b1;
			end

			case (pst)
			P_IDLE: begin
				if (pram_clr_pending) begin
					pram_clr_pending <= 0; pcnt <= 0; pst <= P_CLR;
				end else if (pram_load_pending) begin
					pram_load_pending <= 0; pram_rd <= 1'b1;
					pram_ld_wd <= 0; pram_ld_try <= 0; pst <= P_LD_RD;
				end else if (pram_flush_pending) begin
					pram_flush_pending <= 0; pram_rst_after <= 0; pcnt <= 0; pst <= P_FILL;
				end
			end

			// ---- LOAD: SD sector -> pram_buf -> Egret pram[] ----
			// Watchdogged: a request the HPS never services (busiest exactly at
			// core start: ROM download + every disk slot mounting) is re-kicked
			// up to 3 times, then abandoned so the machine boots with defaults
			// instead of hanging — the MacLC black/white-screen class.
			P_LD_RD:
				if (pram_ack) begin pram_rd <= 1'b0; pram_ld_wd <= 0; pst <= P_LD_DAT; end
				else if (pram_ld_wd == PRAM_LD_WD_MAX) begin
					pram_ld_wd <= 0;
					if (pram_ld_try == 2'd3) begin  // give up: release the boot
						pram_rd <= 1'b0; pram_ready <= 1'b1; pst <= P_IDLE;
					end else begin                  // drop + re-arm the request
						pram_ld_try <= pram_ld_try + 1'b1;
						pram_rd <= 1'b0; pst <= P_LD_KICK;
					end
				end
				else pram_ld_wd <= pram_ld_wd + 1'b1;
			P_LD_KICK: begin pram_rd <= 1'b1; pst <= P_LD_RD; end
			P_LD_DAT:
				if (old_pack && !pram_ack) begin
					pcnt <= 0;
					// Copy landing after the CPU was released (slow/stalled mount,
					// or a manual re-mount) can't seed the Egret's working PRAM —
					// the boot-copy window is gone. Restart cleanly after the copy
					// so the machine comes up ON the loaded PRAM (automates the
					// old manual mount-then-reset ritual).
					pram_restart_after_load <= pram_ready;
					pst <= P_LD_CPY;
				end
				else if (pram_ld_wd == PRAM_LD_WD_MAX) begin
					pram_ld_wd <= 0; pram_ready <= 1'b1; pst <= P_IDLE;  // wedged ack: boot as-is
				end
				else pram_ld_wd <= pram_ld_wd + 1'b1;
			P_LD_CPY: begin
				pram_load_wr   <= 1'b1;
				pram_load_addr <= pcnt[7:0];
				pram_load_data <= pram_buf[pcnt[7:0]];
				if (pcnt == 9'd255) begin
					pram_dirty <= 0; pram_ena <= 1; pram_ready <= 1'b1;
					if (pram_restart_after_load) begin pram_restart_after_load <= 0; pst <= P_RST; end
					else pst <= P_IDLE;
				end
				else pcnt <= pcnt + 1'b1;
			end

			// ---- SAVE: Egret pram[] -> pram_buf -> SD sector ----
			P_FILL: begin
				pram_save_addr <= pcnt[7:0];               // addr for capture next cycle
				if (pcnt != 0) pram_buf[pcnt[7:0] - 8'd1] <= pram_save_data;
				if (pcnt == 9'd256) pst <= P_SV_WR;
				else pcnt <= pcnt + 1'b1;
			end
			P_SV_WR: begin
				pram_wr_req <= 1'b1;
				if (pram_ack) begin pram_wr_req <= 1'b0; pst <= P_SV_DAT; end
			end
			P_SV_DAT: if (old_pack && !pram_ack) begin
				pram_dirty <= 0;
				if (pram_rst_after) begin pram_rst_after <= 0; pst <= P_RST; end
				else pst <= P_IDLE;
			end

			// ---- Reset PRAM & Core ----
			P_CLR: begin                                   // zero Egret pram[] + pram_buf
				pram_load_wr   <= 1'b1;
				pram_load_addr <= pcnt[7:0];
				pram_load_data <= 8'h00;
				pram_buf[pcnt[7:0]] <= 8'h00;
				if (pcnt == 9'd255) begin
					if (pram_ena) begin pram_rst_after <= 1; pst <= P_SV_WR; end
					else pst <= P_RST;
				end else pcnt <= pcnt + 1'b1;
			end
			P_RST: begin
				pram_force_reset <= 1'b1; rst_hold <= 7'd127; pst <= P_IDLE;
			end
			default: pst <= P_IDLE;
			endcase
		end
	end

	hps_io #(.CONF_STR(CONF_STR), .VDNUM(VDNUM), .WIDE(1)) hps_io
	(
		.clk_sys(clk_sys),
		.HPS_BUS(HPS_BUS),

		.buttons(buttons),
		.status(status),
		.status_menumask(status_menumask),
		.sdram_sz(sdram_sz),

		.sd_lba(sd_lba),
		.sd_rd(sd_rd),
		.sd_wr(sd_wr),
		.sd_ack(sd_ack),

		.sd_buff_addr(sd_buff_addr),
		.sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din),
		.sd_buff_wr(sd_buff_wr),
		
		.img_mounted(img_mounted),
		.img_size(img_size),

		.ioctl_download(dio_download),
		.ioctl_index(dio_index),
		.ioctl_wr(ioctl_write),
		.ioctl_addr(ioctl_addr),
		.ioctl_dout(ioctl_data),
		.ioctl_wait(ioctl_wait),

		.TIMESTAMP(TIMESTAMP),

		.ps2_key(ps2_key),
		.ps2_kbd_led_use(3'b001),
		.ps2_kbd_led_status({2'b00, capslock}),

		.ps2_mouse(ps2_mouse)
	);

	// ------------------------------------------------------------------------
	// Display source. DEFAULT = the mdc824 NuBus card is THE display, exactly
	// like the Mac II core (lbmactwo): CLK_VIDEO is clk_sys and the card's
	// fractional-accumulator ce_pixel paces the scanout — no second video PLL,
	// no muxed-clock Fitter Err 15836. The built-in video keeps its register
	// surfaces (VRAM window / VDAC / montype) for the ROM's POST, but reports
	// monitor sense 7 ("no display attached"), the real no-monitor-on-DB15 +
	// NuBus-card configuration, so the ROM adopts the 8*24 as boot display.
	//
	// ONBOARD_DISPLAY (MacIIvi.qsf macro) rebuilds the LC-heritage shape:
	// built-in video on the dedicated pixel clock as the MiSTer output and
	// the card shrunk to its 128KB boot config — the guaranteed-first-light
	// fallback while the card-adoption path is being proven on hardware.
	// ------------------------------------------------------------------------
`ifdef ONBOARD_DISPLAY
	assign CLK_VIDEO = clk_vid;
	assign CE_PIXEL  = v8_ce_pix;   // constant 1 now (pix_ce tied high below)

	// Video Output — straight V8 video, no overlays.
	assign VGA_R  = v8_vga_r;
	assign VGA_G  = v8_vga_g;
	assign VGA_B  = v8_vga_b;
	assign VGA_DE = v8_de;
	assign VGA_VS = v8_vsync;
	assign VGA_HS = v8_hsync;
	assign VGA_F1 = 0;
	assign VGA_SL = 0;
`else
	assign CLK_VIDEO = clk_sys;
	assign CE_PIXEL  = mdc_ce_pixel;

	// Video Output — the 8*24 card's scanout (vga_blank is a display enable).
	assign VGA_R  = mdc_r;
	assign VGA_G  = mdc_g;
	assign VGA_B  = mdc_b;
	assign VGA_DE = mdc_blank;
	assign VGA_VS = mdc_vs;
	assign VGA_HS = mdc_hs;
	assign VGA_F1 = 0;
	assign VGA_SL = 0;
`endif

	// ------------------------------------------------------------------------
	// Dedicated pixel clock (pll_video) — true per-monitor scanout rates.
	// (Ported from MacLC 536a0a3+56b9888+78e484c, end state.) The V8 used to
	// scan out at clk_sys/2 = 16.25 MHz in every mode, so VGA 640x480 (800x525
	// total) refreshed at 38.7 Hz. clk_vid now carries 25.175 MHz (VGA,
	// 59.94 Hz) / 15.664 MHz (12" RGB, 60.14 Hz) / 58.742 MHz (Portrait tap,
	// OSD-unreachable today). CPU/SDRAM/System-Tick stay on clk_sys (CPU speed
	// and the a937c4c tick are pixel-clock independent by construction — do
	// NOT re-tie ticks/onesec to vblank).
	//
	// The rate switch is a runtime PLL RECONFIG of the single output counter
	// (ao486 pattern, sys/pll_cfg): CLK_VIDEO must be a raw PLL output —
	// sys_top's clock-select blocks reject a muxed clock (Fitter Err 15836),
	// which killed the earlier cyclonev_clkselect approach. Only C0 changes;
	// the VCO (704.9 MHz) stays put, so one register write + start suffices.
	// The static config is C0=28 (25.175 MHz VGA — see rtl/pll_video.v:21): a
	// VGA boot performs NO reconfig at all (the earlier /12-static +
	// boot-time-retarget variant glitched CLK_VIDEO during the HPS SD mount →
	// BERR storms). An OSD switch to 12" RGB (C0=45, SLOWER than the 25.175
	// constraint = STA-safe) retargets mid-session; Portrait (C0=12) stays
	// OSD-unreachable until the static constraint moves back to /12.
	// (Video is reset-held until first lock via vidrst below.)
	wire clk_vid, pll_video_locked;
	wire [63:0] reconfig_to_pll, reconfig_from_pll;
	pll_video pllv
	(
		.refclk(CLK_50M),
		.rst(1'b0),
		.outclk_0(clk_vid),
		.locked(pll_video_locked),
		.reconfig_to_pll(reconfig_to_pll),
		.reconfig_from_pll(reconfig_from_pll)
	);

	wire        pixcfg_waitrequest;
	reg         pixcfg_write;
	reg   [5:0] pixcfg_address;
	reg  [31:0] pixcfg_data;
	pll_cfg pll_video_cfg
	(
		.mgmt_clk(CLK_50M),
		.mgmt_reset(0),
		.mgmt_waitrequest(pixcfg_waitrequest),
		.mgmt_read(0),
		.mgmt_readdata(),
		.mgmt_write(pixcfg_write),
		.mgmt_address(pixcfg_address),
		.mgmt_writedata(pixcfg_data),
		.reconfig_to_pll(reconfig_to_pll),
		.reconfig_from_pll(reconfig_from_pll)
	);

	// C0 counter value per monitor: {[22:18] counter#=0, [17] odd-div,
	// [16] bypass, [15:8] high count, [7:0] low count} — layout per
	// sys/pll_cfg/altera_pll_reconfig_core.v:557-569.
	wire [31:0] pix_c0 = (v8_monitor_id == 4'h2) ? 32'h00021716 :  // /45 = 15.664 MHz
	                     (v8_monitor_id == 4'h1) ? 32'h00000606 :  // /12 = 58.742 MHz
	                                               32'h00000E0E;   // /28 = 25.175 MHz
	always @(posedge CLK_50M) begin : pix_reconfig
		reg [31:0] c0_cur = 32'h00000E0E;  // = the static /28 VGA config: a VGA
		                                   // boot performs NO reconfig (the boot-
		                                   // time PLL glitch BERR-stormed the HPS
		                                   // SCSI path); only an OSD switch to
		                                   // 12" retargets, mid-session
		reg [31:0] c0_s1, c0_s2;
		reg [2:0]  state = 0;
		c0_s1 <= pix_c0;                   // settle across clk_sys -> CLK_50M
		c0_s2 <= c0_s1;
		if (!pixcfg_waitrequest) begin
			pixcfg_write <= 0;
			if (pll_video_locked) begin
				if (state) state <= state + 1'd1;
				case (state)
					0: if (c0_s2 == c0_s1 && c0_s2 != c0_cur) begin
							c0_cur <= c0_s2;
							state  <= 1;
						end
					1: begin pixcfg_address <= 0; pixcfg_data <= 0;      pixcfg_write <= 1; end // polled mode
					3: begin pixcfg_address <= 5; pixcfg_data <= c0_cur; pixcfg_write <= 1; end // C0 counter
					5: begin pixcfg_address <= 2; pixcfg_data <= 0;      pixcfg_write <= 1; end // start
				endcase
			end
		end
	end

	// Video-domain reset: hold scanout in reset until its PLL locks, released
	// synchronously in clk_vid. (*_meta = 2FF first stage, false-pathed in
	// MacIIvi.sdc.)
	reg vidrst_meta = 1'b1, vidrst_s = 1'b1;
	always @(posedge clk_vid) begin
		vidrst_meta <= ~n_reset || ~pll_video_locked;
		vidrst_s    <= vidrst_meta;
	end

	// clk_vid -> clk_sys: VBL/HBL levels for the guest-facing consumers
	// (pseudovia VBL IRQ, VIA PB7 debug input, dbg_probes).
	reg vbl_meta, v8_vblank_s, hbl_meta, v8_hblank_s;
	always @(posedge clk_sys) begin
		vbl_meta    <= v8_vblank;
		v8_vblank_s <= vbl_meta;
		hbl_meta    <= v8_hblank;
		v8_hblank_s <= hbl_meta;
	end

	// ASC samples drive AUDIO_L/R directly (Commit C). Legacy DMA gone.
	// ASC samples drive AUDIO_L/R, with CD audio (SCSI CD-ROM playback engine)
	// mixed in at half gain, saturating. cd_snd_* are exact zeros whenever the
	// drive isn't playing, so this is transparent to the existing ASC path.
	// CD audio mixed at FULL gain, saturating — the real machine sums the
	// drive's line out with the DAC at unity; the previous half-gain mix was
	// the "CD sounds half as loud" report (MacLC 07-28). cd_snd_* are silent
	// (exact zeros) whenever the drive isn't playing, and are linearly
	// interpolated inside cd_audio.sv so the sys/audio_out 48 kHz pickup
	// doesn't add stair-step imaging.
	wire signed [15:0] cd_snd_l, cd_snd_r;
	wire signed [16:0] audio_mix_l = {asc_sample_l[15], asc_sample_l}
	                               + {cd_snd_l[15], cd_snd_l};
	wire signed [16:0] audio_mix_r = {asc_sample_r[15], asc_sample_r}
	                               + {cd_snd_r[15], cd_snd_r};
	assign AUDIO_L = (audio_mix_l > 17'sd32767)  ? 16'sd32767 :
	                 (audio_mix_l < -17'sd32768) ? -16'sd32768 : audio_mix_l[15:0];
	assign AUDIO_R = (audio_mix_r > 17'sd32767)  ? 16'sd32767 :
	                 (audio_mix_r < -17'sd32768) ? -16'sd32768 : audio_mix_r[15:0];
	assign AUDIO_S = 1;
	assign AUDIO_MIX = 0;

	// Macintosh IIvi memory configuration — VASP model (docs/VASP_RETARGET.md):
	// one CONTIGUOUS block at $0 (4MB motherboard + one SIMM bank), no V8-style
	// config-register banking. The ROM sizes memory by probing; open-bus $FFFF
	// above ram_size ends the probe. Menu configs (status[4:2], latched at
	// reset into status_mem):
	//   8MB  = 4 + 4x1MB SIMMs   (000, default)
	//   20MB = 4 + 4x4MB SIMMs   (001)
	//   36MB = 4 + 4x8MB SIMMs   (010) — RAM top = SDRAM word $157FFFF (chip 0)
	//   48MB (011)                     — RAM top = SDRAM word $1B7FFFF (chip 0);
	//                                    MAME-listed size; also the chip-0 probe
	//   68MB = 4 + 4x16MB SIMMs  (100) — RAM top = SDRAM word $257FFFF (chip 1):
	//                                    HIDDEN pending the chip-1/nCS fix, but the
	//                                    RTL supports it and the clamp caps to it.
	// The selection is clamped to what the fitted module can back (sdram_sz above;
	// unknown module = treat as 32MB). Cap = 48MB on a >=64MB module (chip-0 max
	// we currently trust), 20MB otherwise. Without the clamp an oversized config
	// wraps its upper RAM onto the ROM/VRAM/floppy staging words (or the dead
	// second chip) — boots, then corrupts once the OS grows into high memory (the
	// pre-.143 "36MB random Finder error"; the same shape froze 68MB at Happy Mac).
	wire [2:0]  mem_cap = sdram_64p ? 3'd3 :   // 48MB allowed (chip 0)
	                                  3'd1;    // 20MB max (32MB/unknown module)
	wire [2:0]  mem_eff = (status_mem > mem_cap) ? mem_cap : status_mem;
	wire [26:0] ram_size_bytes = (mem_eff == 3'd4) ? 27'h4400000 :  // 68MB (RTL-only)
	                             (mem_eff == 3'd3) ? 27'h3000000 :  // 48MB
	                             (mem_eff == 3'd2) ? 27'h2400000 :  // 36MB
	                             (mem_eff == 3'd1) ? 27'h1400000 :  // 20MB
	                                                 27'h0800000;   // 8MB (default)
				  
	// Serial Ports
	wire serialOut;
	wire serialIn;
	wire serialCTS = 1'b1; // Idle/deasserted when no serial device connected
	wire serialRTS;

	// V8 Video system wires
	wire v8_hsync, v8_vsync, v8_hblank, v8_vblank, v8_de;
	wire v8_ce_pix;
	wire [7:0] v8_vga_r, v8_vga_g, v8_vga_b;
	wire [7:0] ariel_pixel_addr;
	wire [23:0] ariel_palette_data;
	wire [7:0] ariel_reg_dout;
	wire selectVDAC;       // From address decoder (VASP-internal CLUT/DAC)
	wire selectPseudoVIA;  // From address decoder
	wire selectVRAM;       // From address decoder
	wire selectBoxID;      // $5FFFFFFC machine-ID longword
	wire selectSuperSlot;  // NuBus $C/$D/$E super-slot space
	wire selectSlot;       // NuBus $FC/$FD/$FE slot space
	wire [1:0] slotNum;    // 0=$C 1=$D 2=$E
	// NuBus slot $E: Apple Display Card 8*24 (mdc824) — bus-side integration.
	// The card self-decodes $E/$FE; slots $C/$D fall to the open-bus path.
	wire [15:0] nubusDataOut;   // slot-space read data (card or open-bus $FFFF)
	wire        nubusAck_n;     // slot-space DTACK (card ack or open-bus ack)
	wire        nubus_nmrq_n;   // card VBL IRQ (active low) -> pseudoVIA slot $E
	wire [7:0] pseudovia_dout;
	wire pseudovia_irq;

	// SCC Channel A RX is wired to the physical MiSTer UART pin so the serial
	// port is usable for PPP / dial-up (and as the basis for AppleTalk work).
	// (Previously forced to 1'b1 to dodge a suspected ROM "Break detection loop";
	// that was a symptom of earlier boot issues, since resolved, not the RX path.)
	// The line idles high; rxuart double-syncs UART_RXD internally.
	assign serialIn = UART_RXD;
	assign UART_TXD = serialOut;
	assign UART_RTS = serialRTS ;
	assign UART_DTR = UART_DSR;


	// interconnects
	// CPU
	wire clk8, _cpuReset, _cpuReset_o, _cpuUDS, _cpuLDS, _cpuRW, _cpuAS;
	wire clk8_en_p, clk8_en_n;
	wire clk16_en_p, clk16_en_n;
	// V8 SCSI_PCLK / SCC RTxC source — see rtl/v8_clocks.sv and plan_040526.md Step 5.
	wire scsi_pclk_en;
	v8_clocks v8_clocks_inst (
		.clk_sys     (clk_sys),
		.reset       (~n_reset),
		.scsi_pclk_en(scsi_pclk_en)
	);
	wire _cpuVMA, _cpuVPA, _cpuDTACK;
	wire E_rising, E_falling;
	wire [2:0] _cpuIPL;       // final IPL to CPU (programmer's-switch NMI applied below)
	wire [2:0] _cpuIPL_dc;    // raw IPL from dataController (VIA1 / PseudoVIA / SCC)
	wire [2:0] cpuFC;
	wire [7:0] cpuAddrHi;
	wire [31:0] cpuAddr;
	assign cpuAddr[0] = 1'b0;
	wire [7:0]  cpuAddrFullHi = cpuAddr[31:24];
	wire [15:0] cpuDataOut;

	// RAM/ROM
	wire _romOE;
	wire _ramOE, _ramWE;
	wire _memoryUDS, _memoryLDS;
	wire dioBusControl;
	wire cpuBusControl;
	wire [25:0] memoryAddr;  // 26-bit SDRAM word address from address controller
	wire [15:0] memoryDataOut;
	wire memoryLatch;
	// peripherals
	wire vid_alt;
	wire memoryOverlayOn, selectSCSI, selectSCC, selectIWM, selectVIA, selectRAM, selectROM, selectASC, selectUnmapped;
	wire selectSCSIDMA;   // SCSI pseudo-DMA window (DACK) from address decoder
	wire scsiDREQ;        // SCSI pseudo-DMA request → gates CPU DTACK on DMA cycles
	wire scsiIRQ;         // NCR5380 latched IRQ (level) → pseudo-VIA IFR bit 3
	// JTAG probe feeds from the SCSI engine (consumed by dbg_probes below)
	wire [15:0] dbg_scsi_w, dbg_scsi2_w, dbg_scsi4_w, dbg_scsi5_w;
	wire [31:0] dbg_ncr_w, dbg_ncr2_w, dbg_wr_w;
	wire [31:0] overlay_trigger_addr;
	wire [15:0] dataControllerDataOut;

	// floppy disk image interface
	wire dskReadAckInt;
	wire [21:0] dskReadAddrInt;
	wire dskReadAckExt;
	wire [21:0] dskReadAddrExt;

	// dtack generation for 16 MHz mode
	reg  dtack_en, mem_latch_d;
	wire sdram_ram_ready;       // SDRAM read-data-valid (from sdram.v)
	wire cpu_walk_cycle;        // PMMU walker borrowing the bus (from tg68k dbg_walk_cycle_o)
	// SURGICAL gate: ONLY the borrowed PMMU-walk descriptor read waits for real
	// SDRAM data-valid. Every normal access keeps the fast slot-start ack, so the
	// known-good cpu-cycle timing (that booted reliably) is left unperturbed.
	wire walk_read = cpu_walk_cycle & (selectRAM | selectVRAM) & _cpuRW;
	always @(posedge clk_sys) begin
		if (!_cpuReset) begin
			dtack_en <= 0;
		end
		else begin
			// mem_latch_d = registered memoryLatch: high at busPhase 0, i.e. the
			// START of each busCycle. (cpuBusControl & mem_latch_d) therefore
			// strobes once at the start of EVERY cpu slot.
			mem_latch_d <= memoryLatch;
			if (_cpuAS) dtack_en <= 0;
			// VRAM is SDRAM-backed and reads via the same cpu-slot as RAM,
			// so it must take the slot-aligned DTACK path (a cpu-slot start),
			// NOT the immediate !ROM&!RAM peripheral path. Excluding selectVRAM
			// here stops DTACK asserting before the SDRAM cpu-slot commits the
			// read/write (was truncating longword writes / sampling stale data).
			// H1: this was `!cpuBusControl_d & cpuBusControl` (rising edge), which
			// gave each ISOLATED cpu slot one DTACK opportunity. With slot 00 now
			// also a cpu slot the three slots are contiguous (one rising edge per
			// round), so we strobe at each cpu-slot start instead — same busPhase-0
			// timing as the old edge, but for all 3 slots (3 acks/round = +50%).
			// Only the borrowed PMMU-WALK read waits for real SDRAM data-valid
			// (sdram_ram_ready): it is the one cycle phase-misaligned with the SDRAM
			// command slot, so it otherwise latches `dout` before the read completes
			// and captures stale data (the 10MB-boot Sad Mac). EVERY other access
			// (normal RAM/VRAM reads, ROM reads, all writes) keeps the fast
			// slot-start ack — the timing the core already booted reliably with — so
			// this cannot perturb normal cpu-cycle timing. Peripherals keep the
			// immediate ack.
			if (!_cpuAS & ( (cpuBusControl & mem_latch_d & ~walk_read)
			              | (cpuBusControl & walk_read & sdram_ram_ready)
			              | (!selectROM & !selectRAM & !selectVRAM) )) dtack_en <= 1;
		end
	end

	// FC=7 is the 68k CPU space. cpuAddr[19:16] is the CPU-space cycle-type field:
	//   $F = interrupt acknowledge  -> autovector via VPA (Mac autovectored IRQs)
	//   else ($0 breakpoint, $2 coprocessor, ...) = no responder -> bus error.
	// The boot ROM probes for hardware with `moves` accesses (SFC=7) that MUST
	// bus-error; asserting VPA there wrongly completes the probe and corrupts
	// the machine-config word. (LC lineage: memory stm-root-cause-moves-berr.)
	wire        fc7_iack = (cpuFC == 3'b111) && (cpuAddr[19:16] == 4'hF);
	// FC=7 non-IACK = CPU space with no responder (breakpoint/coprocessor/probe).
	// It MUST bus-error: suppress BOTH VPA and DTACK so no responder completes
	// the cycle, regardless of the (possibly garbage) address the EA computed.
	wire        fc7_berr = (cpuFC == 3'b111) && !fc7_iack;
	// VASP 32-bit regions (decoder-driven — see rtl/addrDecoder.v):
	//   io_space  = the $50xxxxxx VASP I/O block -> 6800-style VPA/E-clock
	//               cycles (except SCSI pseudo-DMA, which is DREQ-gated DTACK)
	//   slot_space = NuBus slot + super-slot space ($C/$D/$E). Until the NuBus
	//               arbiter is wired: ACK with open-bus $FFFF (the lbmactwo
	//               empty-slot convention; TG68 BERR frames are not
	//               handler-recoverable for normal cycles, hardware-validated
	//               on the Mac II core). The mdc824 integration replaces this.
	wire        io_space   = (cpuAddrFullHi == 8'h50);
	wire        slot_space = selectSuperSlot || selectSlot;
	// SCSI pseudo-DMA ($F06000/$F12000) must use ASYNC DTACK gated by the NCR5380's
	// DREQ — NOT the 6800-style VPA path the rest of the $F0xxxx I/O region uses.
	// A VPA cycle completes on the E-clock regardless of whether the SCSI chip has
	// data, so it would corrupt every block transfer. Carve selectSCSIDMA out of
	// VPA and hold the CPU (DTACK deasserted) until scsiDREQ rises.
	// TIMEOUT (2026-06-12): a stalled DACK access must eventually BUS-ERROR —
	// the real LC glue does this, and the ROM's blind-transfer primitive
	// ($A08CFA: saves the $8 vector, installs a temp handler from $1ac(a4),
	// jsr's into the transfer, restores) is DESIGNED around catching it. The
	// old "no glue-level timeout, same as hardware" claim was wrong, and the
	// 7.x boot dies deterministically (dack=14592) inside exactly that
	// primitive. Threshold 250 ms: far above legitimate stalls that bridge
	// HPS sector fetches (ms-scale, SD hiccups worse) so the proven 6.0.8
	// read path can't false-trigger; PSDT records the max stall + fire count.
	localparam SDMA_TIMEOUT = 23'd8125000;  // ~250 ms @ 32.5 MHz
	reg [22:0] sdma_stall_ctr = 23'd0;
	reg        sdma_berr      = 1'b0;
	reg [22:0] sdma_stall_max = 23'd0;   // PSDT: longest stall observed
	reg [7:0]  sdma_berr_cnt  = 8'd0;    // PSDT: timeouts fired
	always @(posedge clk_sys) begin
		if (!_cpuReset) begin
			sdma_stall_ctr <= 0;
			sdma_berr      <= 0;
		end else if (_cpuAS) begin
			sdma_stall_ctr <= 0;
			sdma_berr      <= 0;
		end else if (selectSCSIDMA && !scsiDREQ && !sdma_berr) begin
			sdma_stall_ctr <= sdma_stall_ctr + 23'd1;
			if (sdma_stall_ctr > sdma_stall_max) sdma_stall_max <= sdma_stall_ctr;
			if (sdma_stall_ctr == SDMA_TIMEOUT) begin
				sdma_berr <= 1'b1;   // held until AS deasserts
				if (sdma_berr_cnt != 8'hFF) sdma_berr_cnt <= sdma_berr_cnt + 8'd1;
			end
		end else if (selectSCSIDMA)
			sdma_stall_ctr <= 0;     // DREQ arrived
	end

	// --- Active pseudo-DMA stall snapshot (PSDS/PSD2/PSD3) --------------------
	// Latch the live SCSI engine state the FIRST time a pseudo-DMA DACK access is
	// DREQ-starved past SDMA_SNAP_THRESH (well above a normal HPS sector-fetch
	// bridge, far below the 250 ms sdma_berr). With the deeper read prefetch
	// (rtl/scsi.v RING_LOG) this should rarely fire; when it does it captures
	// whether a residual stall is H1 (phase=DATA_OUT, io_rd=1, io_ack=0,
	// io_busy=1), H2 (pmatch=0 / phase!=DATA_OUT) or H3 (dma_en=0) — see
	// docs/findings_scsi_dma_stall_offline_2026-06-14.md. Sticky until reset;
	// reuses sdma_stall_ctr. Read via scripts/read_probes.sh (PSDS block).
	localparam SDMA_SNAP_THRESH = 23'd520000;   // ~16 ms @ 32.5 MHz (tunable)
	reg        sdma_snapped    = 1'b0;
	reg [15:0] sdma_snap_scsi2 = 16'd0;
	reg [31:0] sdma_snap_ncr   = 32'd0;
	reg [31:0] sdma_snap_wr    = 32'd0;
	always @(posedge clk_sys) begin
		if (!_cpuReset)
			sdma_snapped <= 1'b0;
		else if (!sdma_snapped && sdma_stall_ctr == SDMA_SNAP_THRESH) begin
			sdma_snap_scsi2 <= dbg_scsi2_w;   // phase0/1, io_rd, io_wr, io_ack
			sdma_snap_ncr   <= dbg_ncr_w;     // dreq/dma_en/dma_ack/holdoff/mr_dma/pmatch/tcr
			sdma_snap_wr    <= dbg_wr_w;      // data_cnt/phase/io_busy/sd_buff_sel/data_complete
			sdma_snapped    <= 1'b1;
		end
	end

	// ── Always-on marginality anchor (ported from MacLC 4dfb463, 2026-07-30) ──
	// On MacLC, probes-OFF fits of the cd-audio-era netlist deterministically
	// corrupted the SCSI read path on hardware (Finder colour-icon noise →
	// error-11 / F-Line bombs) while every probe-bearing fit passed; STA met
	// either way and did not predict it (MacLC docs/resume_probes_off_hunt_
	// 2026-07-29.md §5). Their two-way bisect isolated the protective effect to
	// the fanout of the top-level ISSP probes — these sink registers keep the
	// SAME nets loaded in every build, with no JTAG hub, so the fitter treats
	// the SCSI capture/status cones as live logic. MacIIvi ships probe-less
	// (no CDA/PSDT ISSP deck at all), i.e. it is permanently in MacLC's failing
	// build class — carry the anchor. preserve+noprune = no merging, no
	// retiming, no sweeping. Do NOT remove, ifdef, or XOR-fold (a reduction
	// lets synthesis restructure the cones); ~352 FFs is the entire cost.
	wire [31:0] dbg_cda0_w, dbg_cda1_w, dbg_cda2_w, dbg_cda3_w, dbg_cda4_w;
	wire [31:0] dbg_cdur_w, dbg_wrfb_w;
	wire [31:0] dbg_ring0_w, dbg_ring1_w;  // read-ring bookkeeping (anchor-only)
	wire [31:0] dbg_ism_flpe_w;            // swim ISM error/overrun counters
	// Floppy forensics (PFLP deck; anchor consumes a subset, the rest are
	// unconnected-but-declared so a future probe/HUD deck is a hookup away —
	// see MacLC.sv USE_DBG_HUD for the on-screen renderer if a hunt needs it).
	wire [15:0] dbg_flp_byte_cnt, dbg_flp_miss_cnt, dbg_flp_step_cnt;
	wire [7:0]  dbg_flp_disk_data, dbg_iwm_latch, dbg_flp_raw, dbg_flp_status;
	wire [6:0]  dbg_flp_track;
	wire        dbg_flp_side, dbg_flp_byte_stb;
	wire [21:0] dbg_flp_gcr_addr;
	wire [31:0] dbg_ism_state, dbg_ism_verdict_w, dbg_ism_unrlatch_w, dbg_ism_scan_w;
	wire [31:0] dbg_flp_media;
	wire [15:0] dbg_flp_strb_cnt, dbg_flp_strb_en_cnt;
	wire [23:0] dbg_flp_strb_last, dbg_mfm_stall_w;
	wire [8:0]  dbg_flp_rej_step;
	(* preserve, noprune *) reg [31:0] anchor_cda0, anchor_cda1, anchor_cda2,
	                                   anchor_cda3, anchor_cda4, anchor_cdur;
	(* preserve, noprune *) reg [31:0] anchor_psdt, anchor_psds, anchor_psd2,
	                                   anchor_psd3, anchor_wrfb;
	// (2026-08-03, MacLC) Extension: the 11-word anchor above proved
	// INSUFFICIENT on the post-floppy netlist — a probes-off fit corrupted the
	// Finder colour-icon read path with the anchor present, while the ISSP
	// deck on the same RTL/seed lineage passed the gate + 3-boot soak. The
	// recurring failure fingerprint of this class is RING-STALE serving: a
	// ring slot served at/past the rd_hps_blk fill boundary. These two words
	// pin that exact cone — the stall comparators, fill counter, and
	// look-ahead adder of each disk target (scsi.v dbg_ring; comparator nets
	// shared with io_busy by construction). Same law: never remove, ifdef,
	// or fold.
	(* preserve, noprune *) reg [31:0] anchor_ring0, anchor_ring1;
	// (2026-08-04, MacLC) Floppy-cone extension. An LC build passed the SCSI
	// icon gate + soak yet failed a sustained floppy file copy mid-file
	// ("disk error") — while the copy-pattern TB (tb_ism_copytest) proves the
	// RTL serves the identical region byte-exact. Same per-fit marginality
	// class, different cone: the icon gate only exercises the SCSI path, and
	// the floppy fetch cone (SDRAM slot -> dskReadDataLatch -> MFM engine)
	// had never been pinned. These words load the fetch latch,
	// delivery/starve counters, head position, and the live fetch address.
	// Same law: never remove, ifdef, or fold.
	(* preserve, noprune *) reg [31:0] anchor_flp0, anchor_flp1, anchor_flp2;
	always @(posedge clk_sys) begin
		anchor_cda0 <= dbg_cda0_w;
		anchor_cda1 <= dbg_cda1_w;
		anchor_cda2 <= dbg_cda2_w;
		anchor_cda3 <= dbg_cda3_w;
		anchor_cda4 <= dbg_cda4_w;
		anchor_cdur <= dbg_cdur_w;
		anchor_psdt <= {sdma_berr_cnt, 1'b0, sdma_stall_max};
		anchor_psds <= {15'd0, sdma_snapped, sdma_snap_scsi2};
		anchor_psd2 <= sdma_snap_ncr;
		anchor_psd3 <= sdma_snap_wr;
		anchor_wrfb <= dbg_wrfb_w;
		anchor_ring0 <= dbg_ring0_w;
		anchor_ring1 <= dbg_ring1_w;
		anchor_flp0  <= {dbg_flp_byte_cnt, dbg_flp_miss_cnt};
		anchor_flp1  <= {dbg_flp_step_cnt, dbg_iwm_latch, dbg_flp_raw};
		anchor_flp2  <= {dbg_flp_byte_stb, dbg_flp_side, dbg_flp_track[6:0],
		                 1'b0, dskReadAddrInt[21:0]};
	end

	assign      _cpuVPA = fc7_iack ? 1'b0 : ((fc7_berr || slot_space) ? 1'b1 : ~(!_cpuAS && io_space && !selectSCSIDMA));
	assign      _cpuDTACK = fc7_berr ? 1'b1 :
	                        (slot_space && !_cpuAS) ? nubusAck_n :
	                        selectSCSIDMA ? ~scsiDREQ :
	                        (~(!_cpuAS && !io_space) | !dtack_en);

	// ─────────────────────────────────────────────────────────────────────────
	// SCSI / peripheral read-path fit-stabilization (structural fix; ported from
	// MacLC 0c8844b, HW-proven there since 2026-06-24).
	//
	// Peripheral reads ($Exxxxx/$Fxxxxx, cpuAddr[23:21]==111) complete via the
	// 6800-style VPA cycle — NOT the async-DTACK path RAM/ROM/VRAM use. The VPA
	// cycle is E-paced (E ≈ 812 kHz ⇒ ~40 clk_sys per E period) and the wrapper
	// latches read data LATE: at s_state 6, after stalling at s_state 4 for xVma
	// (= eCntr==8, one tick before E-fall — rtl/tg68k/tg68k.v:277,288,308). So
	// from address/select settle (AS at s_state 1) to the data sample is ALWAYS
	// ≥5 clk_sys.
	//
	// The bit that makes this read fit-sensitive is CSR bit6 / scsi_bsy — the
	// deepest cone in the whole read mux: scsi.v phase reg → bsy=(phase!=IDLE) →
	// |target_bsy (cross-module) → wide OR → CSR (ncr5380.sv) → far inter-module
	// route → 7-way cpuDataOut mux (dataController_top.sv) → CPU din. CSR bit1 /
	// scsi_sel is a local ICR register bit (shallow) — which is exactly why HW
	// read bit1 right but bit6 wrong, depending on placement → dice-roll boots.
	//
	// Fix: register the peripheral read data one clk_sys stage (periph_din_reg)
	// and feed the CPU the REGISTERED value on VPA cycles only. The ≥5-cycle VPA
	// window absorbs the +1 latency completely (sampled at s_state 6, settled by
	// ~s_state 3), so no DTACK/VMA change is needed and the memory (DTACK) read
	// path — including SCSI pseudo-DMA (selectSCSIDMA) and the PMMU walker's RAM
	// reads — is byte-for-byte unchanged. MacIIvi.sdc adds a conservative 2×
	// multicycle on `-to periph_din_reg` (supersedes the old constraint-only
	// `-from {*ncr5380*} -to {*tg68_din_r*}` relaxation). periph_din_reg is only
	// CONSUMED during VPA reads, when its combinational input is held stable by
	// the CPU. Mirrored in verilator/sim.v.
	wire vpa_periph_read = !fc7_iack && !fc7_berr && !slot_space && !_cpuAS &&
	                       io_space && !selectSCSIDMA;
	reg [15:0] periph_din_reg;
	always @(posedge clk_sys) periph_din_reg <= dataControllerDataOut;
	wire [15:0] cpu_din_muxed = slot_space      ? nubusDataOut :
	                            vpa_periph_read ? periph_din_reg :
	                                              dataControllerDataOut;

	// ── Programmer's switch / Level-7 NMI (debug aid) ───────────────────────────
	// An OSD button (status[5], the "R5" momentary trigger) fires a non-maskable
	// Level-7 interrupt so MacsBug can break into a HUNG system — the core has no
	// other way in (it otherwise generates only IPL 1/2/4). The 68k takes the
	// level-7 autovector through the same IACK/VPA path that already serves the
	// normal interrupts. The latch clears on the level-7 IACK so it fires exactly
	// ONCE and never masks levels 1/2/4; a ~2 ms timeout backstop releases it if
	// the CPU can't ack (e.g. it is already running at mask 7).
	reg        nmi_req   = 1'b0;
	reg        nmi_btn_d = 1'b0;
	reg [15:0] nmi_to    = 16'd0;
	always @(posedge clk_sys) begin
		nmi_btn_d <= status[5];
		if (status[5] && !nmi_btn_d) begin
			nmi_req <= 1'b1;
			nmi_to  <= 16'hFFFF;
		end else if (nmi_req) begin
			if ((fc7_iack && cpuAddr[3:1] == 3'b111) || nmi_to == 16'd0)
				nmi_req <= 1'b0;
			else
				nmi_to <= nmi_to - 1'b1;
		end
	end
	assign _cpuIPL = nmi_req ? 3'b000 : _cpuIPL_dc;
	wire        cpu_en_p      = clk16_en_p;
	wire        cpu_en_n      = clk16_en_n;
	assign      _cpuReset_o   = tg68_reset_n;
	// The 68k RESET instruction resets chip-level peripherals (NCR5380+SCSI
	// targets, SCC — see dataController._resetInstr_n) and the pseudo-VIA,
	// but NOT the CPU/system (reset-source NOTE above: feeding it into
	// n_reset would loop), NOT the Egret, NOT RAM/SDRAM mapping.
	assign      _cpuRW        = tg68_rw;
	assign      _cpuAS        = tg68_as_n;
	assign      _cpuUDS       = tg68_uds_n;
	assign      _cpuLDS       = tg68_lds_n;
	assign      E_falling     = tg68_E_falling;
	assign      E_rising      = tg68_E_rising;
	assign      _cpuVMA       = tg68_vma_n;
	assign      cpuFC[0]      = tg68_fc0;
	assign      cpuFC[1]      = tg68_fc1;
	assign      cpuFC[2]      = tg68_fc2;
	assign      cpuAddr[31:1] = tg68_a[31:1];
	assign      cpuDataOut    = tg68_dout;

	wire        tg68_rw;
	wire        tg68_as_n;
	wire        tg68_uds_n;
	wire        tg68_lds_n;
	wire        tg68_E_rising;
	wire        tg68_E_falling;
	wire        tg68_vma_n;
	wire        tg68_fc0;
	wire        tg68_fc1;
	wire        tg68_fc2;
	wire [15:0] tg68_dout;
	wire [31:0] tg68_a;
	wire        tg68_reset_n;
	wire        tg68_longword;   // 32-bit access flag — drives SCSI pseudo-DMA byte packing

	// BERR: autovector path only for now. Unmapped-BERR disabled — see
	// docs/plan_040526.md: enabling it regresses boot because the CPU
	// emits high-bit addresses ($50xxxxxx etc.) early in ROM execution.
	// Diagnostic $display below stays enabled so we can study the pattern.
	// Bus-error CPU-space (FC=7) accesses that are NOT interrupt acknowledges:
	// these are the boot ROM's hardware-presence probes (`moves` to CPU space),
	// which a real 68030 faults because nothing decodes the cycle. Without this
	// the probe completes via VPA and the boot mis-detects hardware -> STM.
	// Slot-space handling, take 3 (the one that matches LBMacTwo's
	// hardware-validated empty-NuBus-slot path): do NOT bus-error — TG68's
	// berr exception frames are not handler-recoverable for normal cycles
	// (both an immediate and a delayed+held BERR died in the ROM probe loop
	// at $A05E78, 13 faults then Sad-Mac handler). Instead ACK the cycle and
	// return $FFFF (NuBus open-bus convention — LBMacTwo.sv nubus_no_card):
	// value-checking probes ($A4BEB0 reads $FE000010/$1C) see a dead slot
	// instead of phantom-card garbage, and nothing depends on TG68 berr.
	wire cpu_berr = (fc7_berr && !_cpuAS) || sdma_berr;
`ifdef SIMULATION
	reg _cpuAS_d;
	always @(posedge clk_sys) _cpuAS_d <= _cpuAS;
	always @(posedge clk_sys) begin
`ifdef VERBOSE_TRACE
		if (_cpuAS_d && !_cpuAS && cpuBusControl && selectUnmapped)
			$display("BERR_UNMAPPED: addr=%h fc=%b rw=%b @%0t", cpuAddr, cpuFC, _cpuRW, $time);
		if (_cpuAS_d && !_cpuAS && |cpuAddrFullHi)
			$display("HIGH_ADDR: hi=%h addr=%h fc=%b rw=%b @%0t", cpuAddrFullHi, cpuAddr, cpuFC, _cpuRW, $time);
`endif
	end
`endif

	wire        cpu_make_berr;
	wire [31:0] cpu_berr_frame_pc, cpu_exe_pc, cpu_tg68_pc;
	wire [31:0] cpu_pmmu_log, cpu_pmmu_phys;   // PMMU logical/physical (mode-switch capture)
	wire [31:0] cpu_pmmu_tc, cpu_pmmu_crp, cpu_pmmu_wda, cpu_pmmu_wdd, cpu_pmmu_st;  // MMU-input forensics
	// cpu_walk_cycle is declared up near the dtack glue (it gates the walk-read DTACK)
	wire [15:0] cpu_exe_opcode, cpu_berr_opcode;
	// F-line trap capture (PFLx probes below)
	wire [31:0] cpu_fline_first_pc, cpu_fline_first_op, cpu_fline_last_pc,
	            cpu_fline_last_op, cpu_fline_meta;
	tg68k tg68k (
		.clk        ( clk_sys      ),
		.reset      ( !_cpuReset ),
		.phi1       ( cpu_en_p  ),
		.phi2       ( cpu_en_n  ),
		.cpu        ( 2'b10 ),  // 68030 (Mac LC II); old selectable form: {status_cpu[1], |status_cpu}

		.dtack_n    ( _cpuDTACK  ),
		.rw_n       ( tg68_rw    ),
		.as_n       ( tg68_as_n  ),
		.uds_n      ( tg68_uds_n ),
		.lds_n      ( tg68_lds_n ),
		.fc         ( { tg68_fc2, tg68_fc1, tg68_fc0 } ),
		.reset_n    ( tg68_reset_n ),

		.E          (  ),
		.E_div      ( 1'b1 ),
		.E_PosClkEn ( tg68_E_falling ),
		.E_NegClkEn ( tg68_E_rising  ),
		.vma_n      ( tg68_vma_n ),
		.vpa_n      ( _cpuVPA ),

		.br_n       ( 1'b1    ),
		.bg_n       (  ),
				.bgack_n    ( 1'b1 ),
				.ipl        ( _cpuIPL ),
				.berr       ( cpu_berr ),
				.din        ( cpu_din_muxed ),
				.dout       ( tg68_dout ),
				.longword   ( tg68_longword ),
				.addr       ( tg68_a ),
				.dbg_make_berr      ( cpu_make_berr ),
				.dbg_berr_frame_pc  ( cpu_berr_frame_pc ),
				.dbg_exe_pc         ( cpu_exe_pc ),
				.dbg_exe_opcode     ( cpu_exe_opcode ),
				.dbg_berr_opcode    ( cpu_berr_opcode ),
				.dbg_tg68_pc        ( cpu_tg68_pc ),
				.dbg_pmmu_log       ( cpu_pmmu_log ),
				.dbg_pmmu_phys      ( cpu_pmmu_phys ),
				.dbg_pmmu_tc_o      ( cpu_pmmu_tc ),
				.dbg_pmmu_crp_o     ( cpu_pmmu_crp ),
				.dbg_pmmu_wda_o     ( cpu_pmmu_wda ),
				.dbg_pmmu_wdd_o     ( cpu_pmmu_wdd ),
				.dbg_pmmu_st_o      ( cpu_pmmu_st ),
				.dbg_walk_cycle_o   ( cpu_walk_cycle ),
				.dbg_fline_first_pc ( cpu_fline_first_pc ),
				.dbg_fline_first_op ( cpu_fline_first_op ),
				.dbg_fline_last_pc  ( cpu_fline_last_pc  ),
				.dbg_fline_last_op  ( cpu_fline_last_op  ),
				.dbg_fline_meta     ( cpu_fline_meta     )
			);
	
	// On-chip framebuffer (BRAM): packed CPU VRAM write mirror (port A) +
	// video scanline read (port B).
	wire [10:0] v8_words_per_line;
	wire [17:0] vram_bram_waddr;
	wire        vram_bram_we;
	wire [17:0] v8_vram_raddr;
	wire [15:0] v8_vram_rdata;

	addrController_top ac0
	(
		.clk(clk_sys),
		.clk8(clk8),
		.clk8_en_p(clk8_en_p),
		.clk8_en_n(clk8_en_n),
		.clk16_en_p(clk16_en_p),
		.clk16_en_n(clk16_en_n),
		._cpuReset(_cpuReset),
		.cpuAddr(cpuAddr),
		._cpuUDS(_cpuUDS),
		._cpuLDS(_cpuLDS),
		._cpuRW(_cpuRW),
		._cpuAS(_cpuAS),
		.ram_size_bytes(ram_size_bytes),
		.memoryAddr(memoryAddr),
		.memoryLatch(memoryLatch),
		._memoryUDS(_memoryUDS),
		._memoryLDS(_memoryLDS),
		._romOE(_romOE),
		._ramOE(_ramOE),
		._ramWE(_ramWE),
		.dioBusControl(dioBusControl),
		.cpuBusControl(cpuBusControl),
		.selectSCSI(selectSCSI),
		.selectSCSIDMA(selectSCSIDMA),
		.selectSCC(selectSCC),
		.selectIWM(selectIWM),
		.selectVIA(selectVIA),
		// selectASC was NEVER connected here (sim.v had it; FPGA didn't) —
		// the wire floated to GND, so ASC register access was DEAD on
		// hardware while sim audio worked. Found 2026-06-11 when the probe
		// deck made the dangling net visible (Quartus 12110). Prime suspect
		// for the broken FPGA sound.
		.selectASC(selectASC),
		.selectRAM(selectRAM),
		.selectROM(selectROM),
		.selectVDAC(selectVDAC),
		.selectPseudoVIA(selectPseudoVIA),
		.selectVRAM(selectVRAM),
		.selectBoxID(selectBoxID),
		.selectSuperSlot(selectSuperSlot),
		.selectSlot(selectSlot),
		.slotNum(slotNum),
		.selectUnmapped(selectUnmapped),
		.words_per_line(v8_words_per_line),
		.vram_waddr(vram_bram_waddr),
		.vram_we(vram_bram_we),
		.memoryOverlayOn(memoryOverlayOn),
		.overlay_trigger_addr(overlay_trigger_addr),

		.dskReadAddrInt(dskReadAddrInt),
		.dskReadAckInt(dskReadAckInt),
		.dskReadAddrExt(dskReadAddrExt),
		.dskReadAckExt(dskReadAckExt)
	);


	wire [1:0] diskEject;
	wire [1:0] diskMotor, diskAct;
	
	// Video Mode Selection Logic
	// 0=1bpp, 1=2bpp, 2=4bpp, 3=8bpp, 4=16bpp
	// Mapped from OSD (status[16:15]) for now:
	// DEBUG: Allow CPU to set video mode (via PseudoVIA)
	wire [2:0] v8_video_mode = pvia_video_config[2:0];
	/*
	wire [2:0] v8_video_mode = status[16:15] == 2'b00 ? 3'd2 : // 4bpp
							   status[16:15] == 2'b01 ? 3'd1 : // 2bpp
							   status[16:15] == 2'b10 ? 3'd0 : // 1bpp
							   status[16:15] == 2'b11 ? 3'd3 : // 8bpp
							   status[17] ? 3'd4 : 3'd2;       // 16bpp override
	*/

	// Monitor ID Selection — the sense ID the ROM reads for the onboard VASP
	// video.  HARDWIRED to 7 = "no monitor on the onboard port", so the IIvi ROM
	// routes the WHOLE boot display (happy Mac / Welcome / Finder) to the NuBus
	// mdc824 card — which is what HDMI actually shows.  CONFIRMED on hardware
	// 2026-07-13 (.143): System 7.5.5 boots to the Finder on the card
	// (releases/hw_143_montype7_FINDER_20260713.png).  The earlier "sense 7
	// WEDGES the ROM" note was WRONG (MAME's incomplete static-sense model + a
	// sim card-scanout frame-counting artifact); see docs/resume_2026-07-12_
	// display_routing.md.  The OSD "Onboard monitor" toggle was removed for the
	// release — the card is the only display, so sense 7 is fixed.  (status[10]
	// "Monitor" 640/512 still sets the — now unscanned — onboard video size.)
	wire [3:0] v8_monitor_id = 4'h7;   // no onboard monitor -> ROM boots on card

	// VASP-internal CLUT/DAC — same register interface as the LC's discrete
	// Ariel RAMDAC (MAME vasp.cpp dac_r/dac_w), so the module carries over.
	ariel_ramdac ariel(
		.clk_sys(clk_sys),
		.clk_pix(clk_vid),   // video lookup port in the scanout clock domain
		.reset(~n_reset),
		.reg_addr(cpuAddr[10:0]),
		.uds_n(_cpuUDS),
		.lds_n(_cpuLDS),
		.data_in(cpuDataOut[7:0]),
		.data_out(ariel_reg_dout),
		.we(selectVDAC && !_cpuRW && cpuBusControl),
		.req(selectVDAC && cpuBusControl),
		.mem_latch(memoryLatch),
		.cpu_as_n(_cpuAS),

		// The RAMDAC takes the pixel index from v8_video and returns RGB data
		.pixel_index(ariel_pixel_addr),
		.rgb_out(ariel_palette_data),
		.ariel_written(ariel_written)
	);
	wire ariel_written;

	wire [7:0] pvia_video_config;
	wire [7:0] asc_data_out;
	wire asc_irq;

	pseudovia pvia(
		.clk_sys(clk_sys),
		.reset(~n_reset),
		.addr({cpuAddr[12:1], tg68_a[0]}),
		.data_in(cpuDataOut[7:0]),
		.data_out(pseudovia_dout),
		.we(selectPseudoVIA && !_cpuRW && cpuBusControl),
		.req(selectPseudoVIA && cpuBusControl),
		.vblank_irq(v8_vblank_s),   // 2FF-synced from the clk_vid scanout domain
		// NuBus slot IRQs: only slot $E is populated (mdc824 VBL, active low)
		.slot_irq_c(1'b0),
		.slot_irq_d(1'b0),
		.slot_irq_e(~nubus_nmrq_n),
		.asc_irq(asc_irq),
		// SCSI flags tied off — LC II lineage decision (System 7 crash-restart
		// tracked to this wiring there; MAME maclc boots with the 5380
		// irq_handler unconnected). Revisit for the IIvi against MAME maciivx
		// (which DOES route 5380 DRQ/IRQ into the pseudoVIA via the scsihelp)
		// during disk bring-up — see docs/VASP_RETARGET.md.
		.scsi_irq(1'b0),
		.scsi_drq(1'b0),
		.irq_out(pseudovia_irq),
		.monitor_id(v8_monitor_id),
		.video_config(pvia_video_config)
	);

	// ------------------------------------------------------------------------
	// NuBus slot $E — Apple Display Card 8*24 (mdc824), bus-side integration
	// (lbmactwo pattern; see docs/VASP_RETARGET.md §NuBus). The card runs on
	// clk_sys, self-decodes $E000_0000/$FE00_0000, ACKs per 16-bit half, and
	// carries its own 384KB dual-port BRAM VRAM + baked declaration ROM.
	// Its VGA outputs are not yet routed to the MiSTer output (onboard video
	// stays the display until the mdc824 display phase); the Slot Manager can
	// already probe and configure the card.
	// ------------------------------------------------------------------------
	wire [15:0] nubusDataOut_card;
	wire        nubusAck_card;   // active low; 1 = card not responding
	wire [7:0]  mdc_r, mdc_g, mdc_b;
	wire        mdc_hs, mdc_vs, mdc_blank, mdc_ce_pixel;
	wire [24:0] mdc_vram_addr, mdc_vram_scan_addr;
	wire [15:0] mdc_vram_dout, mdc_vram_din, mdc_vram_scan_data;
	wire        mdc_vram_rd, mdc_vram_wr, mdc_vram_ready, mdc_vram_scan_rd;
	wire        card_ext_rd, card_ext_wr;
	wire [15:0] card_ext_din;
	wire        card_ext_ready;
	wire        mdc_scan_start, mdc_scan_wr;
	wire [19:0] mdc_scan_base;
	wire [9:0]  mdc_scan_words;
	wire [15:0] mdc_scan_wdata;

	// Card VRAM backing (docs/VRAM_1MB_OPTIONS.md Option A, 2026-08-07):
	// DEFAULT shape = the FULL 1MB lives in the reserved SDRAM window at word
	// $100000. MDC_VRAM_WORDS=0 steers every CPU access through the (HW-
	// proven) ext_* path, and the card scans out of an internal 2x512-word
	// line buffer fed by mdc_scan_fetch through sdram.v's burst video port
	// (4 chained reads per otherwise-idle command window, lowest priority).
	// This frees the 384KB BRAM framebuffer (~384 M10K) and makes all of the
	// 1MB the Slot Manager sizes actually scannable (24bpp stays deferred in
	// the card's mode mux, but its framebuffer is no longer unreachable).
	//
	// The IIvi ROM's Slot Manager hard-fails the card if PrimaryInit's VRAM
	// sizing probe (write $AAAAAAAA @ byte $F4B00 ~979KB, read back) misses
	// (sad Mac $0F/$33, 2026-07-11) — TOTAL_WORDS stays 1MB as before; the
	// probe now lands in SDRAM like every other VRAM word.
	//
	// Under ONBOARD_DISPLAY the card keeps its legacy 128KB BRAM boot config
	// (vram_ram below) with port-B scanout — the guaranteed-first-light
	// fallback shape, unchanged. Keep in sync with verilator/sim.v.
`ifdef ONBOARD_DISPLAY
	localparam MDC_VRAM_WORDS = 65536;    // 128KB boot config, BRAM scanout
`else
	localparam MDC_VRAM_WORDS = 0;        // 1MB, all SDRAM-backed (Option A)
`endif
	nubus_video_mdc824 #(.SLOT_ID(4'hE), .VRAM_WORDS(MDC_VRAM_WORDS),
	                     .TOTAL_WORDS(524288)) nubus_card (
		.clk(clk_sys),
		.reset(!_cpuReset),
		// Real A0 required: the declaration ROM lives on byte lane 3
		// (local_addr[1:0]==2'b11) and cpuAddr[0] is forced 0 on this
		// 16-bit bus — without tg68_a[0] every decl-ROM read returned
		// $FFFF and the Slot Manager saw an empty slot (2026-07-11 bench
		// finding; lbmactwo feeds the card its full HMMU address).
		.addr({cpuAddr[31:1], tg68_a[0]}),
		.data_in(cpuDataOut),
		.uds_lds({~_cpuUDS, ~_cpuLDS}),
		.cpu_longword(tg68_longword),
		.rw_n(_cpuRW),
		.cpu_as_n(_cpuAS),
		.select(selectSlot || selectSuperSlot),
		.data_out(nubusDataOut_card),
		.ack_n(nubusAck_card),
		.nmrq_n(nubus_nmrq_n),
		.vga_r(mdc_r), .vga_g(mdc_g), .vga_b(mdc_b),
		.vga_hs(mdc_hs), .vga_vs(mdc_vs), .vga_blank(mdc_blank),
		.vga_clk(),
		.vram_addr(mdc_vram_addr),
		.vram_dout(mdc_vram_dout),
		.vram_din(mdc_vram_din),
		.vram_rd(mdc_vram_rd),
		.vram_wr(mdc_vram_wr),
		.vram_ready(mdc_vram_ready),
		.ext_rd(card_ext_rd),
		.ext_wr(card_ext_wr),
		.ext_din(card_ext_din),
		.ext_ready(card_ext_ready),
		.vram_scan_addr(mdc_vram_scan_addr),
		.vram_scan_rd(mdc_vram_scan_rd),
		.vram_scan_data(mdc_vram_scan_data),
		.scan_start(mdc_scan_start),
		.scan_base(mdc_scan_base),
		.scan_words(mdc_scan_words),
		.scan_wr(mdc_scan_wr),
		.scan_wdata(mdc_scan_wdata),
		.dbg_scan_underrun(),
		// declaration ROM is $readmemh-baked; no download path
		.ioctl_wr(1'b0), .ioctl_addr(25'd0), .ioctl_data(16'd0),
		.ioctl_download(1'b0), .ioctl_index(8'd0),
		.overlay_en(1'b0),
		.monochrome(1'b0),
		.monitor_512(status[10]),   // shares the OSD Monitor option
		.ce_pixel(mdc_ce_pixel),
		.dbg_video_en(), .dbg_vram_wr_cnt(), .dbg_vram_fetch_cnt(),
		.dbg_irq_cnt(), .dbg_ack_cnt(), .dbg_vblank_enable()
	);

	// BRAM card VRAM exists only in the ONBOARD_DISPLAY fallback shape; the
	// default 1MB-SDRAM shape steers every access ext and scans from the
	// card's internal line buffer.
	generate if (MDC_VRAM_WORDS != 0) begin : g_mdc_vram
		vram_ram #(.WORDS(MDC_VRAM_WORDS)) mdc_vram (
			.clk(clk_sys),
			.addr(mdc_vram_addr),
			.din(mdc_vram_dout),
			.dout(mdc_vram_din),
			.rd(mdc_vram_rd),
			.wr(mdc_vram_wr),
			.ready(mdc_vram_ready),
			.addr_b(mdc_vram_scan_addr),
			.rd_b(mdc_vram_scan_rd),
			.dout_b(mdc_vram_scan_data)
		);
	end else begin : g_mdc_vram
		assign mdc_vram_din      = 16'h0000;
		assign mdc_vram_ready    = 1'b1;
		assign mdc_vram_scan_data = 16'h0000;
	end endgenerate

	// Scanline fetch client: card line requests -> the VRAM backend's burst
	// video port. Backend select (docs/VRAM_1MB_OPTIONS.md):
	//   default      = Option A: sdram.v idle-window chained reads into the
	//                  reserved window at word $100000.
	//   MDC_VRAM_DDR = Option B: the mdc_vram_ddr adapter on the HPS DDR3
	//                  channel (same client contract; SDRAM untouched by
	//                  card VRAM traffic, ext ops rerouted below too).
	wire        vidp_rd, vidp_seq, vidp_dseq, vidp_tog;
	wire [25:0] vidp_addr;
	wire [15:0] vidp_data;

	mdc_scan_fetch #(.SDRAM_BASE(26'h0100000)) mdc_fetch (
		.clk(clk_sys),
		.reset(!_cpuReset),
		.start(mdc_scan_start),
		.base_word(mdc_scan_base),
		.words(mdc_scan_words),
		.wvalid(mdc_scan_wr),
		.wdata(mdc_scan_wdata),
		.vid_rd(vidp_rd),
		.vid_addr(vidp_addr),
		.vid_seq(vidp_seq),
		.vid_data(vidp_data),
		.vid_dseq(vidp_dseq),
		.vid_tog(vidp_tog)
	);

	wire        sdram_vid_dseq, sdram_vid_tog;
	wire [15:0] sdram_vid_data;
`ifdef MDC_VRAM_DDR
	// Option B: SDRAM video port idles; the DDR adapter serves the stream
	// and the card's ext ops (instance below, next to the ext glue).
	wire        sdram_vid_rd   = 1'b0;
	wire        sdram_vid_seq  = 1'b0;
	wire [25:0] sdram_vid_addr = 26'd0;
`else
	wire        sdram_vid_rd   = vidp_rd;
	wire        sdram_vid_seq  = vidp_seq;
	wire [25:0] sdram_vid_addr = vidp_addr;
	assign vidp_data = sdram_vid_data;
	assign vidp_dseq = sdram_vid_dseq;
	assign vidp_tog  = sdram_vid_tog;
`endif

	// Empty-slot open bus: slots $C/$D (and any slot cycle the card doesn't
	// claim) — after 32 clk_sys with no card ack, answer $FFFF with DTACK. The
	// Slot Manager reads the $FF "format byte" as slot-empty and moves on
	// (lbmactwo-validated; TG68 BERR frames are not handler-recoverable, so
	// no arbiter-timeout BERR here). Was 4 clk: the card's cold-tail ext
	// accesses ride the SDRAM cpu-slot and ack in ~10-20 clk, which the old
	// horizon would have eaten. Real NuBus allows 25.6us; 32 clk ~= 1us.
	reg [5:0] nubus_timeout;
	always @(posedge clk_sys) begin
		if (_cpuAS) nubus_timeout <= 6'd0;
		else if (slot_space && nubusAck_card && !nubus_timeout[5])
			nubus_timeout <= nubus_timeout + 6'd1;
	end
	wire nubus_no_card = slot_space && nubusAck_card && nubus_timeout[5];
	assign nubusDataOut = nubus_no_card ? 16'hFFFF : nubusDataOut_card;
	assign nubusAck_n   = nubus_no_card ? 1'b0    : nubusAck_card;

	// JTAG In-System probes (SCSI / CPU loop sampler / ASC / video) + the
	// fetch-history/reset-source forensic recorders. FPGA-only — never in
	// verilator/sim.v (altsource_probe is an Altera primitive). Read with:
	// bash scripts/read_probes.sh
	//
	// MACRO-GATED (USE_DEBUG_PROBES in MacIIvi.qsf) since the IIvi retarget:
	// the deck + rings + sld-hub cost ~2.5-3.5K ALMs and the first IIvi fit
	// came in at 118% ALM. The Verilator sim is the primary debug surface;
	// re-enable the deck only for targeted hardware forensics.
`ifdef USE_DEBUG_PROBES
	// PSDT: pseudo-DMA stall timeout visibility — {fires[7:0], max_stall[22:0]}
	altsource_probe #(
		.instance_id ("PSDT"), .probe_width (32), .source_width(1),
		.sld_auto_instance_index ("YES")
	) cp_psdt (.probe({sdma_berr_cnt, 1'b0, sdma_stall_max}), .source(), .source_clk(clk_sys), .source_ena(1'b1));

	// PSDS/PSD2/PSD3: active pseudo-DMA stall snapshot (latched at SDMA_SNAP_THRESH).
	// PSDS[16]=snapped flag, PSDS[15:0]=dbg_scsi2 layout; PSD2=dbg_ncr (PSNC layout);
	// PSD3=dbg_wr (PSCW layout). Decoded by scripts/cpu_state.tcl.
	altsource_probe #(
		.instance_id ("PSDS"), .probe_width (32), .source_width(1),
		.sld_auto_instance_index ("YES")
	) cp_psds (.probe({15'd0, sdma_snapped, sdma_snap_scsi2}), .source(), .source_clk(clk_sys), .source_ena(1'b1));
	altsource_probe #(
		.instance_id ("PSD2"), .probe_width (32), .source_width(1),
		.sld_auto_instance_index ("YES")
	) cp_psd2 (.probe(sdma_snap_ncr), .source(), .source_clk(clk_sys), .source_ena(1'b1));
	altsource_probe #(
		.instance_id ("PSD3"), .probe_width (32), .source_width(1),
		.sld_auto_instance_index ("YES")
	) cp_psd3 (.probe(sdma_snap_wr), .source(), .source_clk(clk_sys), .source_ena(1'b1));

	// --- PRST: reset-source recorder (#3 spontaneous-reboot-after-Happy-Mac) ----
	// The reboot is a NON-bus-error CPU reset (PBER berr->reset=0 proved it). The
	// CPU reset (_cpuReset, dataController_top.sv:189) is forced by exactly two
	// things: _systemReset (n_reset) low, OR the Egret HC05 asserting
	// egret_reset_680x0. This latches WHICH source pulled the line on the FIRST
	// reset AFTER the CPU started running (armed once n_reset releases), so the
	// cold-boot reset itself is skipped. reset_src bit = that source demanding
	// reset at the _cpuReset falling edge:
	//   [7]=egret_reset_680x0 (Egret firmware — prime suspect)
	//   [6]=~pll_locked_s [5]=~rom_loaded [4]=status[0](OSD) [3]=buttons[1]
	//   [2]=pram_force_reset [1]=RESET [0]=ROM-download(index0)
	// first_src==0x80 ⟹ the Egret rebooted it; any [6:0] bit ⟹ a system reset.
	wire [7:0] reset_src = { egret_reset_680x0_w, ~pll_locked_s, ~rom_loaded,
	                         status[0], buttons[1], pram_force_reset, RESET,
	                         (dio_download && dio_index == 0) };
	reg        prst_armed     = 1'b0;
	reg        cpuReset_d_p   = 1'b1;
	reg [7:0]  reboot_cnt     = 8'd0;
	reg [7:0]  first_src      = 8'd0;
	reg        first_rst_seen = 1'b0;
	reg        first_nreset   = 1'b1;
	always @(posedge clk_sys) begin
		cpuReset_d_p <= _cpuReset;
		if (n_reset) prst_armed <= 1'b1;                    // CPU out of cold-boot reset
		if (prst_armed && cpuReset_d_p && !_cpuReset) begin // _cpuReset fell while armed
			if (reboot_cnt != 8'hFF) reboot_cnt <= reboot_cnt + 8'd1;
			if (!first_rst_seen) begin
				first_rst_seen <= 1'b1;
				first_src      <= reset_src;
				first_nreset   <= n_reset;    // 1 ⟹ Egret reset (n_reset still high)
			end
		end
	end
	altsource_probe #(
		.instance_id ("PRST"), .probe_width (32), .source_width(1),
		.sld_auto_instance_index ("YES")
	) cp_prst (.probe({reboot_cnt, first_src, reset_src,
	                   prst_armed, first_rst_seen, first_nreset, n_reset, 4'd0}),
	           .source(), .source_clk(clk_sys), .source_ena(1'b1));

	// --- PFHx/PFOx/PFJx: instruction-fetch history v2 — WILD-JUMP catcher ---
	// 16-deep ring of {full addr[31:0], fetched word[15:0]} for FC=2'b10 code
	// fetches (address at AS fall; the word is re-sampled every clk while the
	// cycle is live, so the slot holds the settled bus data when AS rises).
	// FREEZE (primary): the FIRST code fetch into the exception vector table
	// (full 32-bit addr < $400) after fh_armed — armed by the first code fetch
	// from ROM home $Axxxxx, because the reset-overlay path legitimately
	// executes at $2A-$B4 before jumping to ROM home (MAME trace lines 1-12).
	// FREEZE (fallback): first F-line trap, as before, for non-low-jump bombs.
	// After freeze: ring holds the killing fetch + the 15 before it; fh_wp =
	// slot of the OLDEST entry. PFJS/PFJT = last non-sequential fetch pair
	// (full 32-bit); PFJO = {word fetched at PFJS, word fetched at PFJT}.
	// Readout: PFA0/PFA1 = ring addrs (wide), PFW0 = fetched words, PFJX =
	// {meta, jump words, tgt, src} — see the consolidated instances below.
	reg [31:0] fh_ring_a [0:15];
	reg [15:0] fh_ring_o [0:15];
	reg [3:0]  fh_wp = 4'd0;
	reg        fh_frozen = 1'b0;
	reg        fh_armed = 1'b0;
	reg        fh_cause_low = 1'b0, fh_cause_fline = 1'b0;
	reg        fh_as_d = 1'b1;
	reg        fh_pend = 1'b0;           // code-fetch cycle live: keep sampling its data
	reg [3:0]  fh_pend_slot = 4'd0;
	reg        fh_pend_tgt = 1'b0;       // live cycle is a jump target: mirror word into PFJO
	reg [31:0] fh_prev_pc = 32'd0, fh_jump_src = 32'd0, fh_jump_tgt = 32'd0;
	reg [15:0] fh_jump_src_op = 16'd0, fh_jump_tgt_op = 16'd0;
	reg [7:0]  fh_jumps = 8'd0;
	wire        fh_ifetch = (cpuFC[1:0] == 2'b10) && fh_as_d && !_cpuAS; // AS fell, code fetch
	wire [15:0] fh_din = cpu_din_muxed;  // mirrors tg68k .din
	always @(posedge clk_sys) begin
		fh_as_d <= _cpuAS;
		if (!_cpuReset) begin
			fh_wp <= 4'd0; fh_frozen <= 1'b0; fh_armed <= 1'b0;
			fh_cause_low <= 1'b0; fh_cause_fline <= 1'b0;
			fh_pend <= 1'b0; fh_pend_tgt <= 1'b0;
			fh_prev_pc <= 32'd0; fh_jumps <= 8'd0;
		end else begin
			// Live-cycle data sampling — runs even after freeze so the KILLING
			// fetch's word (the vector-table entry executed as code) lands too.
			if (fh_pend) begin
				if (!_cpuAS) begin
					fh_ring_o[fh_pend_slot] <= fh_din;
					if (fh_pend_tgt) fh_jump_tgt_op <= fh_din;
				end else begin
					fh_pend <= 1'b0; fh_pend_tgt <= 1'b0;
				end
			end
			if (!fh_frozen) begin
				if (fh_ifetch) begin
					if (cpuAddr[23:20] == 4'hA) fh_armed <= 1'b1;
					fh_ring_a[fh_wp] <= cpuAddr;
					fh_pend <= 1'b1; fh_pend_slot <= fh_wp; fh_pend_tgt <= 1'b0;
					fh_wp <= fh_wp + 4'd1;
					if (cpuAddr != fh_prev_pc + 32'd2 && cpuAddr != fh_prev_pc) begin
						fh_jump_src    <= fh_prev_pc;
						fh_jump_tgt    <= cpuAddr;
						fh_jump_src_op <= fh_ring_o[fh_wp - 4'd1]; // prev fetch, cycle done
						fh_pend_tgt    <= 1'b1;
						fh_jumps       <= fh_jumps + 8'd1;
					end
					fh_prev_pc <= cpuAddr;
					if (fh_armed && cpuAddr < 32'h00000400) begin
						fh_frozen <= 1'b1; fh_cause_low <= 1'b1;
					end
				end
				if (cpu_fline_meta[31:16] != 16'd0) begin
					fh_frozen <= 1'b1; fh_cause_fline <= 1'b1;
				end
			end
		end
	end
	// Consolidated WIDE ISSP instances (2026-07-02): the 64-instance deck
	// corrupted the sld-hub enumeration (6 phantom nodes with garbage widths,
	// every read returning all-ones) — quartus_stp 17.0 handled the previous
	// ~41-instance deck fine. ISSP probes go up to 511 bits, so the ring packs
	// into 4 instances. scripts/cpu_state.tcl slices the wide hex strings.
	// PFA0 = ring addrs 7..0 (LSB 32 bits = entry 0), PFA1 = addrs 15..8,
	// PFW0 = the 16 fetched words (LSB 16 bits = entry 0),
	// PFJX = {meta[31:0], jump words[31:0], tgt[31:0], src[31:0]} (LSB = src);
	//        meta = {8'd0, cause_fline, cause_low, armed, frozen, wp[3:0], 8'd0, jumps[7:0]},
	//        jump words = {src_word[15:0], tgt_word[15:0]}.
	altsource_probe #(
		.instance_id ("PFA0"), .probe_width (256), .source_width(1), .sld_auto_instance_index ("YES")
	) cp_pfa0 (.probe({fh_ring_a[7], fh_ring_a[6], fh_ring_a[5], fh_ring_a[4],
	                   fh_ring_a[3], fh_ring_a[2], fh_ring_a[1], fh_ring_a[0]}),
	           .source(), .source_clk(clk_sys), .source_ena(1'b1));
	altsource_probe #(
		.instance_id ("PFA1"), .probe_width (256), .source_width(1), .sld_auto_instance_index ("YES")
	) cp_pfa1 (.probe({fh_ring_a[15], fh_ring_a[14], fh_ring_a[13], fh_ring_a[12],
	                   fh_ring_a[11], fh_ring_a[10], fh_ring_a[9],  fh_ring_a[8]}),
	           .source(), .source_clk(clk_sys), .source_ena(1'b1));
	altsource_probe #(
		.instance_id ("PFW0"), .probe_width (256), .source_width(1), .sld_auto_instance_index ("YES")
	) cp_pfw0 (.probe({fh_ring_o[15], fh_ring_o[14], fh_ring_o[13], fh_ring_o[12],
	                   fh_ring_o[11], fh_ring_o[10], fh_ring_o[9],  fh_ring_o[8],
	                   fh_ring_o[7],  fh_ring_o[6],  fh_ring_o[5],  fh_ring_o[4],
	                   fh_ring_o[3],  fh_ring_o[2],  fh_ring_o[1],  fh_ring_o[0]}),
	           .source(), .source_clk(clk_sys), .source_ena(1'b1));
	altsource_probe #(
		.instance_id ("PFJX"), .probe_width (128), .source_width(1), .sld_auto_instance_index ("YES")
	) cp_pfjx (.probe({8'd0, fh_cause_fline, fh_cause_low, fh_armed, fh_frozen, fh_wp, 8'd0, fh_jumps,
	                   fh_jump_src_op, fh_jump_tgt_op, fh_jump_tgt, fh_jump_src}),
	           .source(), .source_clk(clk_sys), .source_ena(1'b1));

	// --- PFLx: F-line (vector 11) trap capture — System 7.x bad-F-line hunt ---
	// PFLX (160b) = {meta, last_op, last_pc, first_op, first_pc}; ops are
	// {op[15:0], ext[15:0]} pairs;
	// meta = {count[15:0], 7'b0, first_ctx, 7'b0, last_ctx}; ctx=1 means the trap
	// came from the PMMU ext-word sub-decode (op/ext are the latched F-line pair).
	// Consolidated into one wide instance (deck-size fix, see PFA0 comment):
	// PFLX = {meta, last_op, last_pc, first_op, first_pc} (LSB 32 = first_pc).
	altsource_probe #(
		.instance_id ("PFLX"), .probe_width (160), .source_width(1), .sld_auto_instance_index ("YES")
	) cp_pflx (.probe({cpu_fline_meta, cpu_fline_last_op, cpu_fline_last_pc,
	                   cpu_fline_first_op, cpu_fline_first_pc}),
	           .source(), .source_clk(clk_sys), .source_ena(1'b1));

	dbg_probes probes(
		.clk(clk_sys),
		.cpuAddr(cpuAddr[23:0]),
		.cpuAddrHi(cpuAddrFullHi),
		.cpuReset_n(_cpuReset),
		.resetInstr_n(tg68_reset_n),
		.cpuFC(cpuFC),
		.cpuAS_n(_cpuAS),
		.cpuRW(_cpuRW),
		.cpuDTACK_n(_cpuDTACK),
		.cpuVPA_n(_cpuVPA),
		.cpuUDS_n(_cpuUDS),
		.cpuLDS_n(_cpuLDS),
		.cpuIPL_n(_cpuIPL),
		.cpu_din(dataControllerDataOut),
		.selectSCSI(selectSCSI),
		.selectSCSIDMA(selectSCSIDMA),
		.selectRAM(selectRAM),
		.selectROM(selectROM),
		.selectVRAM(selectVRAM),
		.selectVIA(selectVIA),
		.selectPseudoVIA(selectPseudoVIA),
		.selectASC(selectASC),
		.selectAriel(selectVDAC),   // probe port keeps the LC-era name
		.selectIWM(selectIWM),
		.selectSCC(selectSCC),
		.scsiDREQ(scsiDREQ),
		.scsiIRQ(scsiIRQ),
		.scsi_dbg(dbg_scsi_w),
		.scsi_dbg2(dbg_scsi2_w),
		.scsi_dbg4(dbg_scsi4_w),
		.scsi_dbg5(dbg_scsi5_w),
		.scsi_dbg_ncr(dbg_ncr_w),
		.scsi_dbg_ncr2(dbg_ncr2_w),
		.scsi_dbg_wr(dbg_wr_w),
		.img_mounted(img_mounted[1:0]),
		.sd_rd(sd_rd[1:0]),
		.sd_wr(sd_wr[1:0]),
		.sd_ack(sd_ack[1:0]),
		.asc_irq(asc_irq),
		.asc_sample_l(asc_sample_l),
		.pvia_video_config(pvia_video_config),
		.v8_vblank(v8_vblank_s),
		// BERR investigation (#3 cold-boot reboot loop): the ACTUAL bus-error
		// signals, not the vector-read inference PEXC/PFR use.
		.cpu_berr(cpu_berr),
		.fc7_berr(fc7_berr && !_cpuAS),
		.sdma_berr(sdma_berr),
		.memoryOverlayOn(memoryOverlayOn),
		.cpu_make_berr(cpu_make_berr),
		.cpu_berr_frame_pc(cpu_berr_frame_pc),
		.cpu_exe_pc(cpu_exe_pc),
		.cpu_exe_opcode(cpu_exe_opcode),
		.cpu_berr_opcode(cpu_berr_opcode),
		.cpu_tg68_pc(cpu_tg68_pc),
		.cpu_pmmu_log(cpu_pmmu_log),
		.cpu_pmmu_phys(cpu_pmmu_phys),
		.cpu_pmmu_tc(cpu_pmmu_tc),
		.cpu_pmmu_crp(cpu_pmmu_crp),
		.cpu_pmmu_wda(cpu_pmmu_wda),
		.cpu_pmmu_wdd(cpu_pmmu_wdd),
		.cpu_pmmu_st(cpu_pmmu_st),
		.cpu_dout(tg68_dout),
		.cpu_memaddr(memoryAddr[22:0]),  // probe deck is 23-bit (LC-era forensics)
		.cpu_ramwe_n(_ramWE),
		.mb_hi_i(memoryAddr[23]),        // mb_hi retired; bit23 of the linear address
		.walk_cycle(cpu_walk_cycle),
		.ramOE_n(_ramOE),
		.selectUnmapped(selectUnmapped),
		.cpuBusControl(cpuBusControl)
	);
`endif  // USE_DEBUG_PROBES

	maclc_v8_video v8_video(
		.clk_sys(clk_vid),      // scanout runs on the dedicated pixel clock
		.clk8_en_p(clk8_en_p),
		.pix_ce(1'b1),          // every clk_vid edge = one pixel
		.reset(vidrst_s),

		// Configuration
		.video_mode(v8_video_mode),
		.monitor_id(v8_monitor_id),

		// Test / diagnostic controls — disabled (OSD test options removed).
		.test_bypass_vram(1'b0),
		.test_pattern_sel(2'b00),

		// Video Signals
		.hsync(v8_hsync),
		.vsync(v8_vsync),
		.hblank(v8_hblank),
		.vblank(v8_vblank),
		.vga_r(v8_vga_r),
		.vga_g(v8_vga_g),
		.vga_b(v8_vga_b),
		.de(v8_de),
		.ce_pix(v8_ce_pix),

		// Palette Interface (Connected to Ariel RAMDAC)
		.palette_addr(ariel_pixel_addr),
		.palette_data(ariel_palette_data),

		.words_per_line(v8_words_per_line),
		.vram_raddr(v8_vram_raddr),
		.vram_rdata(v8_vram_rdata)
	);

	// On-chip framebuffer (BRAM). CPU VRAM writes land on port A (clk_sys);
	// video reads port B in the pixel-clock domain — the CDC lives inside the
	// dual-clock M10K primitive.
	//
	// mdc824-only default: this 384KB bank is REMOVED — the $60000000 VRAM
	// window stays fully SDRAM-backed for the ROM's POST (reads/writes work),
	// there is just no onboard scanout to feed. v8_video keeps running as a
	// headless timing generator (pseudoVIA VBL source) over black pixels.
`ifdef ONBOARD_DISPLAY
	vram_bram vram_fb(
		.a_clk(clk_sys),
		.b_clk(clk_vid),
		.a_addr(vram_bram_waddr),
		.a_din(memoryDataOut),
		.a_be({~_cpuUDS, ~_cpuLDS}),
		.a_we(vram_bram_we),
		.a_dout(),                 // CPU reads still come from SDRAM (dropped later)
		.b_addr(v8_vram_raddr),    // video scanline prefetch
		.b_dout(v8_vram_rdata)
	);
`else
	assign v8_vram_rdata = 16'h0000;
`endif

	// ASC sample outputs (Commit C will route to AUDIO_L/R)
	wire signed [15:0] asc_sample_l;
	wire signed [15:0] asc_sample_r;
	wire               asc_sample_tick;

	// V8 schematic SND[0:2]/DFAC_CLK/CULTDAC0: see rtl/asc.sv / rtl/ariel_ramdac.sv
	asc asc_inst(
		.clk(clk_sys),
		.reset(~n_reset),
		.cs(selectASC),
		// cpuAddr[0] is forced 0 in this core, so the ASC register A0 (which
		// selects MODE/FIFOMODE/CLOCK — the odd-numbered regs) gets dropped and
		// odd regs alias onto the even reg below them. Reconstruct the real A0
		// from tg68_a[0], exactly like the SWIM/IWM instance does.
		.addr({cpuAddr[11:1], tg68_a[0]}),
		// Full 16-bit write bus: the FIFO must see BOTH byte lanes so MOVE.W/
		// MOVE.L fills land every sample (see the fifo_pend note in rtl/asc.sv;
		// [7:0]-only here was the "game audio at 2x speed" bug class).
		.data_in(cpuDataOut),
		.data_out(asc_data_out),
		.we(!_cpuRW && cpuBusControl),
		.cpu_as_n(_cpuAS),
		.uds_n(_cpuUDS),
		.lds_n(_cpuLDS),
		.sample_l(asc_sample_l),
		.sample_r(asc_sample_r),
		.sample_tick(asc_sample_tick),
		.irq(asc_irq)
	);

`ifdef USE_AUDIO_ISSP
	// JTAG audio-confirmation probe (read-only) — no SignalTap. Instance "AUD".
	// Read live: Tools > In-System Sources and Probes Editor.
	//   probe[15:0]  = current ASC sample (signed) driving AUDIO_L/R
	//   probe[31:16] = sample-tick counter — advances iff the ASC is producing
	//                  samples. If it counts on hardware but you hear nothing,
	//                  the ASC works and the issue is downstream (sys_top/output/
	//                  build). If it's frozen, the ASC isn't being clocked/selected.
	// Enabled via the USE_AUDIO_ISSP macro in MacIIvi.qsf; absent from release/sim.
	//   probe[15:0]  = current ASC sample (signed)
	//   probe[31:16] = ASC write count — edge-detected CPU writes to the ASC. If this
	//                  advances, the CPU IS feeding the ASC (issue is the ASC/output);
	//                  if it stays ~0, the audio data never reaches the ASC (decode/bus).
	// probe[15:0]=ASC writes, probe[31:16]=ASC reads (both edge-detected, sticky).
	//   reads>0 & writes=0 → CPU probes the ASC but never feeds it (ROM/OS audio path)
	//   reads=0 & writes=0 → CPU never touches the ASC (selectASC decode / not mapped)
	//   writes>0           → CPU feeds it (then issue is ASC sample-gen / output)
	reg [15:0] asc_wr_cnt = 16'd0, asc_rd_cnt = 16'd0;
	reg        asc_wr_d   = 1'b0,  asc_rd_d   = 1'b0;
	wire       asc_wr_now = selectASC && !_cpuRW && cpuBusControl;
	wire       asc_rd_now = selectASC &&  _cpuRW && cpuBusControl;
	always @(posedge clk_sys) begin
		asc_wr_d <= asc_wr_now;
		asc_rd_d <= asc_rd_now;
		if (asc_wr_now && !asc_wr_d) asc_wr_cnt <= asc_wr_cnt + 16'd1;
		if (asc_rd_now && !asc_rd_d) asc_rd_cnt <= asc_rd_cnt + 16'd1;
	end
	wire [31:0] aud_probe_bus = { asc_rd_cnt, asc_wr_cnt };
	altsource_probe #(
		.sld_auto_instance_index ("YES"),
		.sld_instance_index      (0),
		.instance_id             ("AUD"),
		.probe_width             (32),
		.source_width            (0),
		.source_initial_value    ("0"),
		.enable_metastability    ("NO")
	) u_aud_issp (
		.probe  (aud_probe_bus),
		.source ()
	);
`endif

	/*
	always @(posedge clk_sys) begin
		if (!_cpuAS && clk8_en_p) begin
			$display("DC: AS_active addr=%h fc=%d rw=%b @%0t", cpuAddr, cpuFC, _cpuRW, $time);
		end
	end
	*/

	// v8_vblank debug removed - fires every frame, too noisy

	reg memoryOverlayOn_prev;
	always @(posedge clk_sys) begin
		if (memoryOverlayOn != memoryOverlayOn_prev) begin
			$display("DC: memoryOverlayOn changed: %b @%0t", memoryOverlayOn, $time);
		end
		memoryOverlayOn_prev <= memoryOverlayOn;
	end

	dataController_top dataController (
		.clk32(clk_sys),
		.clk8_en_p(clk8_en_p),
		.clk8_en_n(clk8_en_n),
		.scsi_pclk_en(scsi_pclk_en),
		.E_rising(E_rising),
		.E_falling(E_falling),
		._systemReset(n_reset),
		.pseudovia_irq(pseudovia_irq),
		._cpuReset(_cpuReset),
		._cpuIPL(_cpuIPL_dc),
		._cpuUDS(_cpuUDS),
		._cpuLDS(_cpuLDS), 
		._cpuRW(_cpuRW), 
		._cpuVMA(_cpuVMA),
		.cpuDataIn(cpuDataOut),
		.cpuDataOut(dataControllerDataOut), 	
		.cpuAddrRegHi(cpuAddr[12:9]),
		.cpuAddrRegMid(cpuAddr[6:4]),  // for SCSI register select (A6-A4)
		.cpuAddrRegLo(cpuAddr[2:1]),
		.cpuLongword(tg68_longword),
		.selectSCSI(selectSCSI),
		.selectSCSIDMA(selectSCSIDMA),
		.scsiDREQ(scsiDREQ),
		.scsiIRQ(scsiIRQ),
		.dbg_scsi(dbg_scsi_w),
		.dbg_scsi2(dbg_scsi2_w),
		.dbg_scsi4(dbg_scsi4_w),
		.dbg_scsi5(dbg_scsi5_w),
		.dbg_ncr(dbg_ncr_w),
		.dbg_ncr2(dbg_ncr2_w),
		.dbg_wr(dbg_wr_w),
		.selectSCC(selectSCC),
		.selectIWM(selectIWM),
		.selectVIA(selectVIA),
		.selectASC(selectASC),
		.asc_data_in(asc_data_out),
		.cpuBusControl(cpuBusControl),
		.memoryDataOut(memoryDataOut),
		.memoryDataIn(sdram_do),
		.memoryLatch(memoryLatch),
		.selectVDAC(selectVDAC),
		.vdac_data_in(ariel_reg_dout),
		.selectPseudoVIA(selectPseudoVIA),
		.pseudovia_data_in(pseudovia_dout),
		.selectBoxID(selectBoxID),
		.machine_p600(1'b0),   // hardwired Mac IIvi (Performa OSD option removed)
		.selectUnmapped(selectUnmapped),
		
		// peripherals
		.ps2_key(ps2_key), 
		.capslock(capslock),
		.ps2_mouse(ps2_mouse),
		// serial uart
		.serialIn(serialIn),
		.serialOut(serialOut),
		.serialCTS(serialCTS),
		.serialRTS(serialRTS),

		// rtc unix ticks
		.timestamp(TIMESTAMP),

		// video
		._hblank(~v8_hblank_s),
		._vblank(~v8_vblank_s),
		.vid_alt(vid_alt),


		// floppy disk interface
		// Drive 2 tied off — single-SuperDrive machine (see CONF_STR note).
		// Constant zeros let synthesis fold the ext-drive cones in swim.v
		// without touching the family-shared file.
		.insertDisk({1'b0, dsk_int_ins}),
		.diskSides({1'b0, dsk_int_ds}),
		.diskMFM({1'b0, dsk_int_mfm}),
		.diskHD({1'b0, dsk_int_hd}),
		.diskEject(diskEject),
		.dskReadAddrInt(dskReadAddrInt),
		.dskReadAckInt(dskReadAckInt),
		.dskReadAddrExt(dskReadAddrExt),
		.dskReadAckExt(dskReadAckExt),
		.diskMotor(diskMotor),
		.diskAct(diskAct),

		// block device interface for scsi disk (slots 0,1)
		.img_mounted(img_mounted[SCSI_DEVS-1:0]),
		.img_size(img_size[40:9]),
		.io_lba(scsi_lba),
		.io_rd(scsi_rd),
		.io_wr(scsi_wr),
		.io_ack(scsi_ack),

		.sd_buff_addr(sd_buff_addr[7:0]),
		.sd_buff_addr_hi(sd_buff_addr[12:8]),
		.sd_buff_dout(sd_buff_dout),
		.sd_buff_din(scsi_buff_din),
		.sd_buff_wr(sd_buff_wr),

		// CD-ROM target (SCSI ID 3) block interface (slot VD_CDROM).
		.cd_enable(cd_enable),
		.cd_img_mounted(cd_mounted),
		.cd_io_lba(cd_lba),
		.cd_io_rd(cd_rd),
		.cd_io_wr(),           // read-only target: never writes
		.cd_io_ack(cd_ack),
		.cd_sd_buff_din(cd_buff_din),

		// BlueSCSI Toolbox dedicated slot (3) — Main-managed shared folder.
		.tb_mounted(tb_mounted),
		.tb_lba(tb_lba),
		.tb_rd(tb_rd),
		.tb_wr(tb_wr),
		.tb_ack(tb_ack),
		.tb_buff_din(tb_buff_din),

		// BlueSCSI Toolbox CD Changer transport (slot VD_CD_TOOLBOX).
		.cdtb_mounted(cdtb_mounted),
		.cdtb_lba(cdtb_lba),
		.cdtb_rd(cdtb_rd),
		.cdtb_wr(cdtb_wr),
		.cdtb_ack(cdtb_ack),
		.cdtb_buff_din(cdtb_buff_din),

		// CD audio PCM -> AUDIO_L/R mixer (declared near the audio assigns above)
		.cd_snd_l(cd_snd_l),
		.cd_snd_r(cd_snd_r),

		// CD-audio engine JTAG visibility (CDA0..CDA4/CDUR) + write forensics
		// (WRFB). No ISSP deck on MacIIvi (JTAG hub near its node ceiling) —
		// these feed the always-on marginality anchor above instead, which
		// keeps the same cones loaded that MacLC's probe deck accidentally
		// protected. For HW bring-up probes, see cp_cda0..4/cp_cdur/cp_wrfb
		// in MacLC MacLC.sv (hub budget permitting).
		.dbg_cda0(dbg_cda0_w),
		.dbg_cda1(dbg_cda1_w),
		.dbg_cda2(dbg_cda2_w),
		.dbg_cda3(dbg_cda3_w),
		.dbg_cda4(dbg_cda4_w),
		.dbg_cdur(dbg_cdur_w),
		.dbg_wrfb(dbg_wrfb_w),
		.dbg_ism_flpe(dbg_ism_flpe_w),
		.dbg_ring0(dbg_ring0_w),
		.dbg_ring1(dbg_ring1_w),
		.dbg_flp_byte_cnt(dbg_flp_byte_cnt),
		.dbg_flp_miss_cnt(dbg_flp_miss_cnt),
		.dbg_flp_disk_data(dbg_flp_disk_data),
		.dbg_flp_track(dbg_flp_track),
		.dbg_flp_side(dbg_flp_side),
		.dbg_flp_step_cnt(dbg_flp_step_cnt),
		.dbg_iwm_latch(dbg_iwm_latch),
		.dbg_flp_byte_stb(dbg_flp_byte_stb),
		.dbg_flp_raw(dbg_flp_raw),
		.dbg_flp_gcr_addr(dbg_flp_gcr_addr),
		.dbg_ism_verdict(dbg_ism_verdict_w),
		.dbg_ism_unrlatch(dbg_ism_unrlatch_w),
		.dbg_ism_scan(dbg_ism_scan_w),
		.dbg_mfm_stall(dbg_mfm_stall_w),
		.dbg_ism_state(dbg_ism_state),
		.dbg_flp_strb_cnt(dbg_flp_strb_cnt),
		.dbg_flp_strb_en_cnt(dbg_flp_strb_en_cnt),
		.dbg_flp_strb_last(dbg_flp_strb_last),
		.dbg_flp_rej_step(dbg_flp_rej_step),
		.dbg_flp_status(dbg_flp_status),
		.dbg_flp_media(dbg_flp_media),

		// PRAM persistence (NVRAM) — driven by the FSM above
		.pram_load_wr(pram_load_wr),
		.pram_load_addr(pram_load_addr),
		.pram_load_data(pram_load_data),
		.pram_save_addr(pram_save_addr),
		.pram_save_data(pram_save_data),
		.pram_wr_stb(pram_wr_stb),
		.pram_ready(pram_ready),
		// #3 reset-source probe: expose the Egret's 68k-reset line (Port C bit 3)
		.egret_dbg_reset_680x0(egret_reset_680x0_w)
	);

	reg disk_act;
	always @(posedge clk_sys) begin
		integer timeout = 0;

		if(timeout) begin
			timeout <= timeout - 1;
			disk_act <= 1;
		end else begin
			disk_act <= 0;
		end

		if(|diskAct) timeout <= 500000;
	end

	//////////////////////// DOWNLOADING ///////////////////////////

	// Download handler: ROM (boot0.rom, 512KB) and floppy disk images
	// MiSTer loads boot0.rom with ioctl_index=0, F1/F2 mounts use index 1/2
	wire dio_download;
	wire [23:0] dio_addr = ioctl_addr[24:1];  // word address from byte address
	wire  [7:0] dio_index;
	// MiSTer Main encodes the MATCHED EXTENSION of a multi-extension F entry
	// in the upper bits of ioctl_index (menu index in the low bits): an F1
	// pick of a .dsk arrives as 8'h01 but a .img as 8'h41. The mount-flag
	// latches below compared the FULL byte, so a .img mount downloaded into
	// SDRAM (the write path already masks [1:0]) yet never presented a disk —
	// a silent no-op mount, latent since the beginning. Found 2026-08-06 on
	// MacLC driving the swap gates. Compare the MENU index.
	wire  [5:0] dio_menu = dio_index[5:0];

	// good floppy image sizes are 819200 bytes and 409600 bytes
	// (single drive — the dsk_ext_* twin machinery was removed with the
	// second floppy, 2026-08-06)
	reg dsk_int_ds;
	reg dsk_int_ss;   // single sided image inserted
	reg dsk_int_mfm;  // MFM-format image (ISM/SWIM path): 720K or 1.44MB
	reg dsk_int_hd;   // 1.44MB HD (vs 720K DD)

	// DiskCopy 4.2 (.dsk/.image) support: an 84-byte (42-word) header precedes
	// the raw logical-order sector data (tags trail the data; they land past
	// the disk region and are ignored). Detect = Pascal name length 1-63 at
	// byte 0 AND private magic $0100 at bytes 82-83 (word 41 = 16'h0001 after
	// the ioctl byte order). Once detected, subsequent words write 42 words
	// lower, overwriting the header bytes — SDRAM ends up holding pure sector
	// data exactly like a raw image. Raw images can't false-trigger: byte 0
	// of a bootable HFS floppy is 'L' (76 > 63) or $00 for blank media.
	reg dc42_name_ok;
	reg dc42_skip;
	reg [7:0] dc42_disk_format;  // DC42 byte 0x50: 0=400K GCR,1=800K GCR,2=720K MFM,3=1440K MFM

	// ── Disk CHANGE must be presented as a TRANSITION (MacLC 2026-08-05/06) ──
	// The guest learns about media only by polling the drive's CSTIN sense
	// line, so "a disk is present" is not enough — it must see no-disk and
	// THEN disk to run its unmount/mount machinery. dsk_*_ins used to be a
	// pure LEVEL from the size latched at end-of-download, so mounting image
	// B over image A never moved CSTIN: the guest kept A's VCB and cached
	// catalog over B's SDRAM contents — the ghost volume ("…cannot be found"
	// with zero disk I/O). Hold the drive EMPTY from download start until
	// DSK_EMPTY_CY (2.06 s at clk_sys) after it ends: the guest sees the disk
	// leave, unmounts, then sees a fresh insert. The hold must outlast the
	// Sony driver's media poll — MAME 0.264 runtime (MacLC tap_swapB
	// 2026-08-06) shows the NoDiskInPl+DiskChg pair polled every ~0.8 s.
	// ★ Landed together with floppy.v's disk_switched (SWITCHED sense reg) —
	// this same hold WITHOUT that flag was the reverted ebbdac6 regression:
	// the transition told the driver the disk left and came back while the
	// disk-switched flag insisted nothing changed, a state no real machine
	// produces (MAME asserts m_dskchg on every unload).
	localparam [25:0] DSK_EMPTY_CY = 26'h3FFFFFF;
	reg [25:0] dsk_int_empty_cy;
	wire dsk_int_empty = (dsk_int_empty_cy != DSK_EMPTY_CY);
	// any known type of disk image inserted?
	wire dsk_int_ins = !dsk_int_empty && (dsk_int_ds || dsk_int_ss || dsk_int_mfm);
	// at the end of a download latch file size
	// diskEject is set by macos on eject
	always @(posedge clk_sys) begin
		reg old_down;
		old_down <= dio_download;
		// Download START = the change event: drop the media immediately and
		// hold the timer at 0 for the whole upload (SDRAM is being
		// overwritten, so the old geometry is meaningless the moment the
		// transfer begins; clearing the regs also means a wrong-sized file
		// leaves the drive EMPTY instead of re-inserting stale geometry).
		if(~old_down && dio_download && dio_menu == 6'd1) begin
			dsk_int_ds  <= 0;
			dsk_int_ss  <= 0;
			dsk_int_mfm <= 0;
			dsk_int_hd  <= 0;
			dsk_int_empty_cy <= 26'd0;
		end
		else if(dio_download && dio_menu == 6'd1)
			dsk_int_empty_cy <= 26'd0;
		else if(dsk_int_empty_cy != DSK_EMPTY_CY)
			dsk_int_empty_cy <= dsk_int_empty_cy + 26'd1;
		if(old_down && ~dio_download && dio_menu == 6'd1) begin
			// GCR (IWM path) — raw word count, or DC42 disk_format byte (rusty-backup
			// dc42.rs: 0x50 = 0/1/2/3 = 400G/800G/720M/1440M, authoritative + tag-agnostic).
			dsk_int_ds  <= (dio_addr == 409600) || (dc42_skip && dc42_disk_format == 8'd1);
			dsk_int_ss  <= (dio_addr == 204800) || (dc42_skip && dc42_disk_format == 8'd0);
			// MFM (ISM path): 720K DD (368640 words) / 1.44MB HD (737280 words)
			dsk_int_mfm <= (dio_addr == 368640) || (dio_addr == 737280) ||
			               (dc42_skip && (dc42_disk_format == 8'd2 || dc42_disk_format == 8'd3));
			dsk_int_hd  <= (dio_addr == 737280) || (dc42_skip && dc42_disk_format == 8'd3);
		end

		if(diskEject[0]) begin
			dsk_int_ds <= 0;
			dsk_int_ss <= 0;
			dsk_int_mfm <= 0;
			dsk_int_hd <= 0;
		end
	end	

	// (the dsk_ext_* mount block was removed with the second floppy;
	// diskEject[1] from the SWIM now intentionally lands nowhere)

	// Download addresses (SDRAM word addresses, VASP layout):
	//   ROM (1MB): $000000 + offset
	//   Floppy:    $180000 + offset
	//   ($280000, the old Floppy-2 staging region, is unused since the
	//    second drive was dropped — index 2 can no longer arrive.)
	reg [25:0] dio_a;
	reg [15:0] dio_data;
	reg        dio_write;

	// DC42 write offset: active from the word after the magic (word 41)
	wire [19:0] dio_flp_a = dc42_skip ? (dio_addr[19:0] - 20'd42) : dio_addr[19:0];

	always @(posedge clk_sys) begin
		reg old_cyc = 0;
		if(ioctl_write) begin
			if (dio_index[1:0] != 2'b00) begin
				// DC42 header detection (floppy downloads only)
				if (dio_addr[19:0] == 20'd0) begin
					dc42_skip    <= 1'b0;
					dc42_name_ok <= (ioctl_data[7:0] >= 8'd1) && (ioctl_data[7:0] <= 8'd63);
				end else if (dio_addr[19:0] == 20'd40)
					dc42_disk_format <= ioctl_data[7:0];  // byte 0x50 (low byte of word 40)
				else if (dio_addr[19:0] == 20'd41 && dc42_name_ok && ioctl_data == 16'h0001)
					dc42_skip <= 1'b1;
			end
			dio_data <= {ioctl_data[7:0], ioctl_data[15:8]};
			case (dio_index[1:0])
				2'b01:   dio_a <= 26'h0180000 + {6'b0, dio_flp_a};  // Floppy
				default: dio_a <= {7'b0, dio_addr[18:0]};           // ROM (1MB) at $000000 (must match addrController rom_sdram_word)
			endcase
			ioctl_wait <= 1;
		end

		old_cyc <= dioBusControl;
		if(~dioBusControl) dio_write <= ioctl_wait;
		if(old_cyc & ~dioBusControl & dio_write) ioctl_wait <= 0;
	end


	// sdram used for ram/rom maps directly into 68k address space
	wire download_cycle = dio_download && dioBusControl;

	// ============================================================
	// VRAM is left uninitialized — the Mac's video driver clears and
	// fills the framebuffer itself (matches real hardware). The old
	// rainbow test-pattern seeder was removed.
	// ============================================================

	////////////////////////// SDRAM /////////////////////////////////

	// SDRAM Address mapping (VASP layout — docs/VASP_RETARGET.md):
	// memoryAddr[25:0] is already the SDRAM word address from addrController
	// (ROM $000000, VRAM $080000, floppies $180000/$280000, RAM $380000+).
	// 36MB RAM reaches above the 32MB module boundary (sdram.v drives column
	// A9 from addr[24]); 68MB reaches into a 128MB module's second chip
	// (addr[25] -> nCS level). Both are OSD-gated by sdram_sz above.

`ifdef MDC_VRAM_DDR
	// Option B: card ext ops go to DDR3 through the adapter — the SDRAM mux
	// never sees them (card_ext_slot is constant 0, its mux arms fold away).
	wire        card_ext_slot = 1'b0;
	wire [25:0] card_ext_addr = 26'd0;
	mdc_vram_ddr #(.DDR_BASE_QW(29'h06000000)) mdc_ddr (   // byte 0x30000000
		.clk(clk_sys),
		.reset(!_cpuReset),
		.ddr_busy(DDRAM_BUSY),
		.ddr_burstcnt(DDRAM_BURSTCNT),
		.ddr_addr(DDRAM_ADDR),
		.ddr_dout(DDRAM_DOUT),
		.ddr_dout_ready(DDRAM_DOUT_READY),
		.ddr_rd(DDRAM_RD),
		.ddr_din(DDRAM_DIN),
		.ddr_be(DDRAM_BE),
		.ddr_we(DDRAM_WE),
		.vid_rd(vidp_rd),
		.vid_addr(vidp_addr),
		.vid_seq(vidp_seq),
		.vid_data(vidp_data),
		.vid_dseq(vidp_dseq),
		.vid_tog(vidp_tog),
		.ext_rd(card_ext_rd),
		.ext_wr(card_ext_wr),
		.ext_word(mdc_vram_addr[19:0]),
		.ext_wdata(mdc_vram_dout),
		.ext_dout(card_ext_din),
		.ext_ready(card_ext_ready)
	);
`else
	// Card ext SDRAM access — twin of verilator/sim.v (long note there). With
	// the SDRAM-backed card VRAM (Option A) this is the path for EVERY card
	// VRAM word: SDRAM word $100000 + card word. An ext access coincides with
	// a CPU bus cycle TO the card, so the RAM/ROM arms are idle by
	// construction; only floppy staging can collide, and then the ext op
	// waits (its progress gates on card_ext_slot). READS complete on the
	// controller's read-data-valid handshake for the ext address. WRITES are
	// declared done after THREE clk8_en_p edges with the write presented:
	// edge 1 is a throwaway (may race the assertion), and of the two full
	// command windows between edges 1..3 the floppy's extra slot can claim at
	// most one (one extra slot per 4-window round; downloads never coincide
	// with ext ops), so >=1 window has certainly CAS'd the write — an
	// idempotent rewrite either way. ~9-12 clk_sys vs the old fixed 14.
	// Priority: download > floppy staging > card ext > cpu.
	wire [25:0] card_ext_addr = 26'h0100000 + {6'd0, mdc_vram_addr[19:0]};
	wire        card_ext_req  = card_ext_rd || card_ext_wr;
	wire        card_ext_slot = card_ext_req && !download_cycle
	                            && !dskReadAckInt && !dskReadAckExt;
	reg  [1:0]  card_ext_wedge = 2'd0;
	always @(posedge clk_sys) begin
		if (!card_ext_req)
			card_ext_wedge <= 2'd0;
		else if (clk8_en_p && card_ext_wr && card_ext_wedge != 2'd3)
			card_ext_wedge <= card_ext_wedge + 2'd1;
	end
	assign card_ext_ready = card_ext_rd
	                      ? (sdram_ram_ready && sdram_addr == card_ext_addr)
	                      : (card_ext_wedge == 2'd3);
	assign card_ext_din   = sdram_out;
`endif

	wire [25:0] sdram_addr = download_cycle ? dio_a :
	                         card_ext_slot  ? card_ext_addr : memoryAddr;
	wire [15:0] sdram_din  = download_cycle ? dio_data :
	                         card_ext_slot  ? mdc_vram_dout : memoryDataOut;
	wire  [1:0] sdram_ds   = download_cycle ? 2'b11 :
	                         card_ext_slot  ? 2'b11 : { !_memoryUDS, !_memoryLDS };
	wire        sdram_we   = download_cycle ? dio_write :
	                         card_ext_slot  ? card_ext_wr : !_ramWE;
	wire        sdram_oe   = download_cycle ? 1'b0 :
	                         card_ext_slot  ? card_ext_rd :
	                         (!_ramOE || !_romOE || dskReadAckInt || dskReadAckExt);
	wire [15:0] sdram_do   = download_cycle ? 16'hffff :
	                         (dskReadAckInt || dskReadAckExt) ? extra_rom_data_demux :
	                                                            sdram_out;
	// during rom/disk download ffff is returned so the screen is black during download
	// "extra rom" is used to hold the disk image. It's expected to be byte wide and
	// we thus need to properly demultiplex the word returned from sdram in that case
	// Disk image is packed 2 bytes per SDRAM word (download byte-swaps so the
	// EVEN file byte is the high lane, the ODD byte the low lane). The byte to
	// return is picked by the disk byte-address parity bit, dskReadAddr[0] —
	// but the word-address conversion in addrController (`+ dskReadAddr[21:1]`)
	// DROPS bit 0, so `memoryAddr[0]` here is really dskReadAddr[1] and selected
	// the wrong byte on every odd address: reads came back 0,0,3,3,4,4,7,7,…
	// (each odd byte duplicated, its even partner skipped), shredding the GCR
	// data field so every sector failed checksum ("drive responds, data
	// unreadable"). Select on the live parity bit of whichever drive is being
	// serviced; the track encoder holds dskReadAddr stable across the whole
	// fetch window, so the live bit is coherent with the returning word. Keep in
	// sync with verilator/sim.v.
	wire dsk_byte_odd = dskReadAckExt ? dskReadAddrExt[0] : dskReadAddrInt[0];
	wire [15:0] extra_rom_data_demux = dsk_byte_odd?
							 {sdram_out[7:0],sdram_out[7:0]}:{sdram_out[15:8],sdram_out[15:8]};
	wire [15:0] sdram_out;

	// (The LC II core patched its ROM's warm-vs-cold `bne.w` here — an LC-II-ROM
	// workaround, retired for the IIvi ROM; re-derive if a warm-reset hang shows
	// up during bring-up. See docs/VASP_RETARGET.md "LC-II-isms".)

	assign SDRAM_CKE = 1;

	// Dedicated SDRAM re-init pulse on the explicit user resets (R0 / R6 /
	// core button). The reverted d88c098/50d0c32 attempts tied .init to
	// signals that are ALSO asserted through the cold-load ROM download, so
	// init swallowed the download writes and broke cold boot (HW-confirmed
	// 2026-06-08). This pulse is structurally different — exactly the shape
	// the handoff §5 follow-up prescribed:
	//   * edge-triggered, never level-held through a download;
	//   * fires only once the ROM is already in SDRAM (rom_loaded);
	//   * suppressed while ANY download is active (!dio_download);
	//   * the init ladder is content-preserving (NOPs + refreshes + mode-
	//     register rewrite, ~126 us — see rtl/sdram.v), and n_reset's ~4 ms
	//     stretch keeps the CPU in reset until long after it completes.
	reg  [3:0] sdram_reinit_cnt = 4'd0;
	reg        user_reset_d = 1'b0;
	wire       user_reset_now = status[0] | buttons[1] | pram_force_reset;
	always @(posedge clk_sys) begin
		user_reset_d <= user_reset_now;
		if (user_reset_now && !user_reset_d && rom_loaded && !dio_download)
			sdram_reinit_cnt <= 4'd15;
		else if (sdram_reinit_cnt != 0)
			sdram_reinit_cnt <= sdram_reinit_cnt - 4'd1;
	end
	wire sdram_reinit = (sdram_reinit_cnt != 0);

	sdram sdram
	(
		// system interface
		// Full init at config (`!pll_locked`), plus the gated user-reset
		// re-init pulse above. Do NOT add any signal here that is held
		// during the ROM download (see comment above for the history).
		.init           ( !pll_locked || sdram_reinit ),
		.clk_64         ( clk_mem                  ),
		.clk_8          ( clk8                     ),

		.sd_clk         ( SDRAM_CLK                ),
		.sd_data        ( SDRAM_DQ                 ),
		.sd_addr        ( SDRAM_A                  ),
		.sd_dqm         ( {SDRAM_DQMH, SDRAM_DQML} ),
		.sd_cs          ( SDRAM_nCS                ),
		.sd_ba          ( SDRAM_BA                 ),
		.sd_we          ( SDRAM_nWE                ),
		.sd_ras         ( SDRAM_nRAS               ),
		.sd_cas         ( SDRAM_nCAS               ),


		// cpu/chipset interface
		// map rom to sdram word address $200000 - $20ffff
		.din            ( sdram_din                ),
		.addr           ( sdram_addr               ),
		.ds             ( sdram_ds                 ),
		.we             ( sdram_we                 ),
		.oe             ( sdram_oe                 ),
		.dout           ( sdram_out                ),
		.ram_ready      ( sdram_ram_ready          ),

		// mdc824 scanline burst port (idle windows only)
		.vid_rd         ( sdram_vid_rd             ),
		.vid_addr       ( sdram_vid_addr           ),
		.vid_seq        ( sdram_vid_seq            ),
		.vid_data       ( sdram_vid_data           ),
		.vid_dseq       ( sdram_vid_dseq           ),
		.vid_tog        ( sdram_vid_tog            )
	);

endmodule
