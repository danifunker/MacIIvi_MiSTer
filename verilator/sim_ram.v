//
// sim_ram.v
//
// Simple RAM module for Verilator simulation of MacIIvi
// Replaces the SDRAM controller with synchronous RAM
//

module sim_ram
(
	// cpu/chipset interface - same as sdram.v
	input               clk,        // system clock
	input               reset,      // reset signal

	input [15:0]        din,        // data input from chipset/cpu
	output reg [15:0]   dout,       // data output to chipset/cpu
	input [25:0]        addr,       // 26 bit word address (128MB module space)
	input [1:0]         ds,         // upper/lower data strobe
	input               oe,         // cpu/chipset requests read
	input               we,         // cpu/chipset requests write

	// Emulated SDRAM module size (--sdram-module): 1=32MB, 2=64MB, 3=128MB.
	// Reproduces the PHYSICAL failure modes of an undersized module:
	//  - 32MB (MT48LC16M16): column A9 doesn't exist, so word bit 24 is
	//    ignored by the chip -> addresses >=32MB ALIAS onto 0..32MB (this is
	//    the pre-.143 "36MB random Finder error": RAM above 25MB wraps onto
	//    the ROM/VRAM/floppy staging words).
	//  - 32/64MB: word bit 25 drives nCS high (the 128MB module's inverted
	//    chip-1 select) -> single-chip modules are simply DESELECTED: writes
	//    vanish, reads float (modeled as $FFFF).
	input [1:0]         module_sz,

	input [31:0]        frame_count, // frame counter for debug logging

	// Video burst port twin (sdram.v Option A client contract): serves
	// in-order words from the live vid_addr; each word carries the vid_seq
	// it was sampled with (the client drops stale-tagged words after a line
	// restart) and vid_tog flips once per word. Bandwidth realism: at most
	// one word per 2 clk and only while the cpu/chipset port is idle — the
	// same 16.25M word/s ceiling as the real controller's alternate-window
	// 4-word groups, with CPU contention modeled crudely.
	input               vid_rd,
	input [25:0]        vid_addr,
	input               vid_seq,
	output reg [15:0]   vid_data,
	output reg          vid_dseq,
	output reg          vid_tog
);

// 128MB of RAM (64M words of 16 bits) — mirrors the 128MB-module SDRAM space.
// VASP layout (docs/VASP_RETARGET.md): ROM $000000, onboard VRAM $080000,
// mdc824 reserve $100000, floppies $180000/$280000, RAM $380000+ (up to 68MB)
reg [15:0] mem [0:67108863];  // 64M words = 128MB

// Physical-module address folding (see module_sz above)
wire [25:0] eff_addr = (module_sz == 2'd1) ? {2'b00, addr[23:0]} :  // 32MB: A9/col absent
                       (module_sz == 2'd2) ? {1'b0,  addr[24:0]} :  // 64MB: one chip
                                             addr;                  // 128MB: full
wire        deselected = (module_sz != 2'd3) && addr[25];           // chip 1 absent

// Debug counters
integer wr_count = 0;
integer rom_rd_count = 0;

always @(posedge clk) begin
	// Writes are allowed even during reset (needed for ROM loading)
	if (we && |ds && !deselected) begin
		if (ds[1]) mem[eff_addr][15:8] <= din[15:8];
		if (ds[0]) mem[eff_addr][7:0]  <= din[7:0];
		wr_count <= wr_count + 1;
		`ifdef VERBOSE_TRACE
		// Log first 10 writes and every 50000th after that
		if (wr_count < 10 || wr_count % 50000 == 0)
			$display("[F%0d] sim_ram WR[%0d]: addr=%h din=%h ds=%b",
				frame_count, wr_count, addr, din, ds);
		`endif
	end

	if (reset) begin
		rom_rd_count <= 0;
	end else begin
		if (oe) begin
			dout <= deselected ? 16'hFFFF : mem[eff_addr];
			// Log first 20 ROM reads only (ROM = SDRAM words $000000-$07FFFF)
			if (addr < 26'h0080000 && rom_rd_count < 20) begin
				$display("[F%0d] sim_ram RD_ROM[%0d]: addr=%h dout=%h",
					frame_count, rom_rd_count, addr, mem[eff_addr]);
				rom_rd_count <= rom_rd_count + 1;
			end
		end
	end
end

// Video burst port model. Rate: one word per 2 clk = the real controller's
// alternate-window 4-word-group average. No oe/we gate since the v2
// redundant-window release (sdram.v): a held cpu op only costs video its
// FIRST window, which this average already absorbs — tb_sdram_vid's chip-
// model bench carries the honest per-window contention.
wire [25:0] vid_eff = (module_sz == 2'd1) ? {2'b00, vid_addr[23:0]} :
                      (module_sz == 2'd2) ? {1'b0,  vid_addr[24:0]} :
                                            vid_addr;
reg vid_ph = 1'b0;
initial begin vid_tog = 1'b0; vid_dseq = 1'b0; vid_data = 16'h0000; end
always @(posedge clk) begin
	vid_ph <= ~vid_ph;
	if (vid_rd && vid_ph) begin
		vid_data <= mem[vid_eff];
		vid_dseq <= vid_seq;
		vid_tog  <= ~vid_tog;
	end
end

// Allow ROM/RAM initialization from simulation
// verilator tracing_off
/* verilator lint_off UNUSED */
initial begin
	// Memory will be initialized by the simulation testbench
	// via ioctl_download mechanism
end
/* verilator lint_on UNUSED */
// verilator tracing_on

endmodule
