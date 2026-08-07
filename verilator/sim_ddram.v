//
// sim_ddram.v — behavioral MiSTer DDRAM-channel model for the Verilator sim
// (docs/VRAM_1MB_OPTIONS.md Option B twin of the HPS f2sdram bridge).
//
// Models the emu-side Avalon burst contract with a fixed pipeline latency:
//   * write: accepted when busy=0 (posted; byte enables applied immediately)
//   * read:  accepted when busy=0; BURSTCNT beats stream out on
//            dout/dout_ready starting LATENCY clocks later, one per clock
//   * busy pulses for a cycle after each acceptance (crude rate limit)
//
// Backing store: only the 1MB card-VRAM window (the low 17 quadword-address
// bits) — matches mdc_vram_ddr's DDR_BASE_QW-relative use; any base aliases
// into the same 1MB, which is exactly what the adapter addresses.
//
module sim_ddram (
	input             clk,
	input             reset,

	input      [28:0] addr,        // quadword (8-byte) address
	input       [7:0] burstcnt,
	input      [63:0] din,
	input       [7:0] be,
	input             rd,
	input             we,
	output reg        busy,
	output reg [63:0] dout,
	output reg        dout_ready
);

	localparam LATENCY = 12;       // clk_sys cycles from accept to first beat

	reg [63:0] mem [0:131071];     // 1MB = 128K quadwords

	wire [16:0] idx = addr[16:0];

	// pending read burst
	reg  [16:0] rd_idx;
	reg   [7:0] rd_left;
	reg   [3:0] rd_wait;

	integer bi;
	always @(posedge clk) begin
		dout_ready <= 1'b0;
		busy       <= 1'b0;

		if (reset) begin
			rd_left <= 8'd0;
			rd_wait <= 4'd0;
		end else begin
			if (we && !busy) begin
				for (bi = 0; bi < 8; bi = bi + 1)
					if (be[bi]) mem[idx][bi*8 +: 8] <= din[bi*8 +: 8];
				busy <= 1'b1;
			end else if (rd && !busy && rd_left == 8'd0) begin
				rd_idx  <= idx;
				rd_left <= (burstcnt == 8'd0) ? 8'd1 : burstcnt;
				rd_wait <= LATENCY[3:0];
				busy    <= 1'b1;
			end else if (rd_left != 8'd0) begin
				if (rd_wait != 4'd0)
					rd_wait <= rd_wait - 4'd1;
				else begin
					dout       <= mem[rd_idx];
					dout_ready <= 1'b1;
					rd_idx     <= rd_idx + 17'd1;
					rd_left    <= rd_left - 8'd1;
				end
			end
		end
	end

endmodule
