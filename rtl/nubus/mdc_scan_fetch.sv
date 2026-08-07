//
// mdc_scan_fetch.sv — scanline fetch client for the mdc824 SDRAM-backed VRAM
// (docs/VRAM_1MB_OPTIONS.md Option A).
//
// Sits between the card's line-buffer fill port (clk_sys) and the burst video
// read port on the memory backend (sdram.v on hardware, sim_ram.v in the
// sim — both implement the same client contract):
//
//   * The client holds vid_rd with vid_addr = next unserved word; the backend
//     streams words IN ORDER on vid_data qualified by vid_tog flipping once
//     per word (data may legitimately repeat, the toggle is the strobe). Words
//     arrive at most one per clk_sys sample.
//   * The backend may overshoot: it serves whole chained groups (up to 4
//     words to the next 4-word boundary), so words can keep arriving after
//     remaining hits 0 — they are dropped here (harmless SDRAM reads).
//   * vid_seq flips on every accepted `start`, so the backend can tell a
//     mid-flight line restart (abort) from normal consumption and never
//     replays a half-consumed group into the new line (the duplicate-group
//     race this handshake exists for — see sdram.v port comment).
//   * Every served word carries vid_dseq = the vid_seq of the group it was
//     fetched under. After a restart, still-draining words of the aborted
//     group carry the OLD seq and are dropped by tag — no timing windows.
//
// vid_tog crosses 65MHz->32.5MHz (same-PLL, 2:1): one registered sample per
// clk_sys cannot miss a flip because the backend holds each word 2 clk_64.
//
module mdc_scan_fetch #(
	parameter [25:0] SDRAM_BASE = 26'h0100000   // reserved mdc824 VRAM window
)(
	input             clk,          // clk_sys
	input             reset,

	// card side (nubus_video_mdc824 line prefetch)
	input             start,        // 1-clk pulse: begin fetching a line
	input      [19:0] base_word,    // card word address of the line's first word
	input      [9:0]  words,        // word count (0 = no fetch)
	output reg        wvalid,       // 1-clk: wdata is the line's next word
	output reg [15:0] wdata,

	// memory backend video port
	output            vid_rd,
	output     [25:0] vid_addr,
	output reg        vid_seq,
	input      [15:0] vid_data,
	input             vid_dseq,
	input             vid_tog
);

	reg [19:0] cur;
	reg [9:0]  remaining;
	reg        tog_d;

	assign vid_rd   = (remaining != 10'd0);
	assign vid_addr = SDRAM_BASE + {6'd0, cur};

	always @(posedge clk) begin
		wvalid <= 1'b0;
		tog_d  <= vid_tog;

		if (reset) begin
			remaining <= 10'd0;
			cur       <= 20'd0;
			vid_seq   <= 1'b0;
		end else begin
			if (vid_tog != tog_d && vid_dseq == vid_seq && remaining != 10'd0) begin
				wdata     <= vid_data;
				wvalid    <= 1'b1;
				cur       <= cur + 20'd1;
				remaining <= remaining - 10'd1;
			end

			if (start) begin
				cur       <= base_word;
				remaining <= words;
				vid_seq   <= ~vid_seq;
				wvalid    <= 1'b0;   // suppress a same-cycle consume of stale data
			end
		end
	end

endmodule
