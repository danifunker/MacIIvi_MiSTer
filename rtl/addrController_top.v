module addrController_top(
	// clocks:
	input clk,
	output clk8,
	output clk8_en_p,
	output clk8_en_n,
	output clk16_en_p,
	output clk16_en_n,

	// system config:
	// Contiguous RAM size in bytes (VASP model: 4MB motherboard + one SIMM
	// bank presented as a single block at $0 — MAME vasp.cpp set_ram_info;
	// there is NO V8-style config-register banking on this machine).
	input [25:0] ram_size_bytes,

	// 68030 CPU memory interface:
	input _cpuReset,
	input [31:0] cpuAddr,
	input _cpuUDS,
	input _cpuLDS,
	input _cpuRW,
	input _cpuAS,

	// RAM/ROM:
	output [24:0] memoryAddr,  // 25-bit SDRAM word address (64MB module space)
	output _memoryUDS,
	output _memoryLDS,
	output _romOE,
	output _ramOE,
	output _ramWE,
	output dioBusControl,
	output cpuBusControl,
	output memoryLatch,

	// peripherals:
	output selectSCSI,
	output selectSCSIDMA,
	output selectSCC,
	output selectIWM,
	output selectASC,
	output selectVIA,
	output selectRAM,
	output selectROM,

	// VASP-internal blocks
	output selectVDAC,
	output selectPseudoVIA,
	output selectVRAM,
	output selectBoxID,

	// NuBus decode (consumed by the top / arbiter)
	output selectSuperSlot,
	output selectSlot,
	output [1:0] slotNum,

	output selectUnmapped,

	// On-chip framebuffer (BRAM) write mirror — VRAM scanout stays in BRAM.
	input  [10:0] words_per_line, // active words/line (from the video module)
	output [17:0] vram_waddr,     // packed BRAM word address for a CPU VRAM write
	output        vram_we,        // 1-cyc strobe: commit the CPU VRAM write to BRAM

	// misc
	output memoryOverlayOn,
	output [31:0] overlay_trigger_addr,  // debug: address that caused overlay disable

	// interface to read dsk image from ram
	input [21:0] dskReadAddrInt,
	output dskReadAckInt,
	input [21:0] dskReadAddrExt,
	output dskReadAckExt
);

	// ============================================================
	// Bus cycle / clock generation (unchanged from the LC II base)
	// ============================================================
	assign dioBusControl = extraBusControl;

	reg [1:0] busCycle;
	reg [1:0] busPhase;
	reg [1:0] extra_slot_count;

	always @(posedge clk) begin
		busPhase <= busPhase + 1'd1;
		if (busPhase == 2'b11)
			busCycle <= busCycle + 2'd1;
	end
	assign memoryLatch = busPhase == 2'd3;
	assign clk8 = !busPhase[1];
	assign clk8_en_p = busPhase == 2'b11;
	assign clk8_en_n = busPhase == 2'b01;
	assign clk16_en_p = !busPhase[0];
	assign clk16_en_n = busPhase[0];

	reg extra_slot_advance;
	always @(posedge clk)
		if (clk8_en_n) extra_slot_advance <= (busCycle == 2'b11);

	always @(posedge clk) begin
		if(clk8_en_p && extra_slot_advance) begin
			extra_slot_count <= extra_slot_count + 2'd1;
		end
	end

	// H1 (perf): video scanout reads the on-chip BRAM framebuffer (vram_bram),
	// not SDRAM, so the CPU owns slots 00/01/11 (3 of 4 slots). The remaining
	// "extra" slot (10) serves floppy disk reads. NOTE: the dtack glue in
	// MacIIvi.sv/sim.v must assert per-cpu-slot (the 3 slots 11,00,01 are
	// CONTIGUOUS, so a rising-edge detector would see only one edge per round
	// and HALVE throughput).
	assign cpuBusControl = (busCycle == 2'b00) || (busCycle == 2'b01) || (busCycle == 2'b11);
	wire extraBusControl = (busCycle == 2'b10);

	// ============================================================
	// Memory control signals
	// ============================================================
	assign _romOE = ~(cpuBusControl && selectROM && _cpuRW);

	assign _ramOE = ~(cpuBusControl && (selectRAM || selectVRAM) && _cpuRW);

	// RAM Write Enable: Active for RAM or VRAM writes
	assign _ramWE = ~(cpuBusControl && (selectRAM || selectVRAM) && !_cpuRW);

	assign _memoryUDS = cpuBusControl ? _cpuUDS : 1'b0;
	assign _memoryLDS = cpuBusControl ? _cpuLDS : 1'b0;

	// ============================================================
	// VASP RAM/ROM/VRAM → SDRAM translation
	// All outputs are 25-bit SDRAM word addresses (64MB module space).
	//
	// SDRAM Layout (word addresses) — fixed regions LOW so the 4/8/20MB RAM
	// configs stay within a 32MB module; only 36MB needs a 64MB module:
	//   $0000000-$007FFFF  ROM (1MB; boot0.rom download target)
	//   $0080000-$00FFFFF  onboard-video VRAM (1MB window backing)
	//   $0100000-$017FFFF  reserved: mdc824 NuBus VRAM (if SDRAM-backed)
	//   $0180000-$027FFFF  Floppy disk image 1 (2MB window)
	//   $0280000-$037FFFF  Floppy disk image 2 (2MB window)
	//   $0380000+          RAM, contiguous (4/8/20/36MB → top $157FFFF)
	// Must match the download mapping in MacIIvi.sv and verilator/sim.v.
	// ============================================================
	localparam [24:0] SDRAM_ROM_BASE  = 25'h0000000;
	localparam [24:0] SDRAM_VRAM_BASE = 25'h0080000;
	localparam [24:0] SDRAM_DSK1_BASE = 25'h0180000;
	localparam [24:0] SDRAM_DSK2_BASE = 25'h0280000;
	localparam [24:0] SDRAM_RAM_BASE  = 25'h0380000;

	// RAM: contiguous at CPU $0 (≤36MB ⇒ cpuAddr[25:1] covers it)
	wire [24:0] ram_sdram_word  = SDRAM_RAM_BASE + {1'b0, cpuAddr[25:1]};

	// ROM: 1MB image, mirrored every 1MB across $4xxxxxxx (and the overlay at $0)
	wire [24:0] rom_sdram_word  = {6'b000000, cpuAddr[19:1]};

	// VRAM: 1MB window at $60000000, mirrored; backed 1:1 in SDRAM
	wire [19:0] vram_cpu_offset = cpuAddr[19:0];
	wire [24:0] vram_sdram_word = SDRAM_VRAM_BASE + {6'b0, vram_cpu_offset[19:1]};

	// ---- On-chip framebuffer (BRAM) write mirror ----
	// The video engine scans 1-8bpp at a fixed 1024-byte (512-word) stride, but
	// only the first words_per_line words of each line are visible. Pack out the
	// stride gap (packed = line*words_per_line + col) so 640-wide modes fit the
	// 384KB BRAM; for 16bpp@512 (words_per_line=512) packing == natural offset.
	wire [9:0]  vram_line = vram_cpu_offset[19:10];   // scanline (stride 1024B)
	wire [8:0]  vram_colw = vram_cpu_offset[9:1];     // word within the line (0..511)
	wire [18:0] vram_packed = vram_line * words_per_line + {10'd0, vram_colw};
	wire        vram_col_visible = ({2'b0, vram_colw} < words_per_line);
	assign vram_waddr = vram_packed[17:0];
	// One write per CPU VRAM bus cycle (memoryLatch), only for visible columns
	// (off-screen stride padding is dropped so it can't corrupt the next line).
	assign vram_we = selectVRAM && !_cpuRW && cpuBusControl && memoryLatch && vram_col_visible;

	// Floppy disk addresses: byte offset → SDRAM word
	wire [24:0] dsk_int_sdram_word = SDRAM_DSK1_BASE + {4'b0, dskReadAddrInt[21:1]};
	wire [24:0] dsk_ext_sdram_word = SDRAM_DSK2_BASE + {4'b0, dskReadAddrExt[21:1]};

	// CPU address mux (selects based on address decode)
	wire [24:0] cpu_sdram_word = selectVRAM ? vram_sdram_word :
	                              selectROM ? rom_sdram_word :
	                              selectRAM ? ram_sdram_word :
	                              25'h0;

	// ============================================================
	// Extra bus slots (disk reads)
	// ============================================================
	assign dskReadAckInt = (extraBusControl == 1'b1) && (extra_slot_count == 0);
	assign dskReadAckExt = (extraBusControl == 1'b1) && (extra_slot_count == 1);

	// Final SDRAM word address output
	assign memoryAddr =
		dskReadAckInt ? dsk_int_sdram_word :
		dskReadAckExt ? dsk_ext_sdram_word :
		cpu_sdram_word;

	// ============================================================
	// Address decoder (full 32-bit VASP map)
	// ============================================================
	addrDecoder ad(
		.address({cpuAddr[31:1], 1'b0}),
		._cpuAS(_cpuAS),
		._cpuRW(_cpuRW),
		.memoryOverlayOn(memoryOverlayOn),
		.ram_size_bytes(ram_size_bytes),
		.selectRAM(selectRAM),
		.selectROM(selectROM),
		.selectSCSI(selectSCSI),
		.selectSCSIDMA(selectSCSIDMA),
		.selectSCC(selectSCC),
		.selectIWM(selectIWM),
		.selectASC(selectASC),
		.selectVIA(selectVIA),
		.selectVDAC(selectVDAC),
		.selectPseudoVIA(selectPseudoVIA),
		.selectVRAM(selectVRAM),
		.selectBoxID(selectBoxID),
		.selectSuperSlot(selectSuperSlot),
		.selectSlot(selectSlot),
		.slotNum(slotNum),
		.selectUnmapped(selectUnmapped)
	);

	// ============================================================
	// ROM Overlay Register
	// ============================================================
	// At reset, ROM is overlaid at $00000000 so the CPU reads the reset
	// vector from ROM. Per MAME vasp.cpp rom_switch_r, the overlay is
	// disabled by the first READ from the ROM region ($4xxxxxxx) — the
	// reset vector's JMP into ROM home performs exactly that. Writes to
	// the ROM region are ignored and do NOT clear the overlay.
	//
	// The disable is deferred until _cpuAS goes high (bus cycle ends),
	// so the read that triggered it completes with overlay still active.
	// ============================================================
	reg rom_overlay = 1;
	reg overlay_disable_pending = 0;
	reg [31:0] overlay_trigger_addr_r = 0;

	assign memoryOverlayOn = rom_overlay;
	assign overlay_trigger_addr = overlay_trigger_addr_r;

	wire overlay_trigger = !_cpuAS && _cpuRW && (cpuAddr[31:28] == 4'h4);

	always @(posedge clk) begin
		if (!_cpuReset) begin
			rom_overlay <= 1'b1;
			overlay_disable_pending <= 1'b0;
			overlay_trigger_addr_r <= 32'h0;
		end else begin
			if (overlay_trigger && rom_overlay) begin
				overlay_disable_pending <= 1'b1;
				overlay_trigger_addr_r <= cpuAddr;
			end

			if (overlay_disable_pending && _cpuAS) begin
				rom_overlay <= 1'b0;
				overlay_disable_pending <= 1'b0;
			end
		end
	end

endmodule
