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
	input [24:0]        addr,       // 25 bit word address
	input [1:0]         ds,         // upper/lower data strobe
	input               oe,         // cpu/chipset requests read
	input               we,         // cpu/chipset requests write

	input [31:0]        frame_count // frame counter for debug logging
);

// 64MB of RAM (32M words of 16 bits) — mirrors the 64MB-module SDRAM space.
// VASP layout (docs/VASP_RETARGET.md): ROM $000000, onboard VRAM $080000,
// mdc824 reserve $100000, floppies $180000/$280000, RAM $380000+ (up to 36MB)
reg [15:0] mem [0:33554431];  // 32M words = 64MB

// Debug counters
integer wr_count = 0;
integer rom_rd_count = 0;

always @(posedge clk) begin
	// Writes are allowed even during reset (needed for ROM loading)
	if (we && |ds) begin
		if (ds[1]) mem[addr][15:8] <= din[15:8];
		if (ds[0]) mem[addr][7:0]  <= din[7:0];
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
			dout <= mem[addr];
			// Log first 20 ROM reads only (ROM = SDRAM words $000000-$07FFFF)
			if (addr < 25'h0080000 && rom_rd_count < 20) begin
				$display("[F%0d] sim_ram RD_ROM[%0d]: addr=%h dout=%h",
					frame_count, rom_rd_count, addr, mem[addr]);
				rom_rd_count <= rom_rd_count + 1;
			end
		end
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
