// sim_ddr3.v — behavioral stand-in for the DDRAM port that backs the NuBus
// Ethernet card (rtl/nubus/nubus_enetnbtp.sv) in simulation. 164 KB covering
// the card window at ARM 0x1FF00000 (Avalon word 0x03FE0000): 128K card RAM,
// 32K raw declROM, control block, CMD ring (v3 layout, "McNBETH3").
//
// The host (Main_MiSTer support/mac) side is played by whoever stages this
// memory:
//   +eth_magic            write the MAGIC gate word so the card decodes
//   +eth_rom=<file.hex>   $readmemh the RAW declROM image into the ROMRAW
//                         region (64-bit words, 4096 entries; generate with
//                         scripts/gen_enetnbtp_rom.py --hex)
// or a testbench poking the array hierarchically.

module sim_ddr3 (
	input             clk,
	input      [28:0] addr,
	input       [7:0] burst,     // always 1 from the card
	input             rd,
	input             we,
	input      [63:0] wdata,
	input       [7:0] be,
	output reg [63:0] rdata,
	output reg        rvalid,
	output            busy
);

	// TB hook: hold the model busy to stall the mailbox FSM (hierarchical
	// poke, so no port change and sim.v stays untouched).
	reg stall = 1'b0;
	assign busy = stall;

	// 0x5200 x 64-bit words = 164 KB (layout tops out at word 0x51FF)
	reg [63:0] mem [0:20991];

	wire [14:0] off = addr[14:0];   // window-relative (base low bits are zero)

	integer i;
	reg [1023:0] romfile;
	initial begin
		for (i = 0; i < 20992; i = i + 1) mem[i] = 64'h0;
		rvalid = 0;
		rdata  = 0;
		if ($test$plusargs("eth_magic"))
			mem[15'h5000] = 64'h4D634E42_45544833;
		if ($value$plusargs("eth_rom=%s", romfile))
			$readmemh(romfile, mem, 15'h4000, 15'h4FFF);
	end

	always @(posedge clk) begin
		rvalid <= 0;
		if (rd) begin
			rdata  <= mem[off];
			rvalid <= 1;
		end
		if (we) begin
			for (i = 0; i < 8; i = i + 1)
				if (be[i]) mem[off][i*8 +: 8] <= wdata[i*8 +: 8];
		end
	end

	// testbench "host" access (hierarchical task calls from tb_enetnbtp.v)
	task poke64(input [14:0] w, input [63:0] v); mem[w] = v; endtask
	function [63:0] peek64(input [14:0] w); peek64 = mem[w]; endfunction

endmodule
