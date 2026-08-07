//
// mdc_vram_ddr.sv — DDR3-backed mdc824 card VRAM (docs/VRAM_1MB_OPTIONS.md
// Option B).
//
// The card's full 1MB lives in HPS DDR3 through the MiSTer DDRAM channel
// (Avalon burst master, sys_top ram1 port). SDRAM is completely untouched by
// card VRAM traffic in this shape. One module owns the channel and serves:
//
//   * the scanline prefetch stream — SAME client contract as sdram.v's video
//     port (vid_rd/vid_addr/vid_seq in, vid_data/vid_dseq/vid_tog out), so
//     nubus_video_mdc824 + mdc_scan_fetch are byte-identical across Options
//     A and B. Fetches run as 4-quadword bursts (16 words), tagged with the
//     group's vid_seq; the next burst waits for the client to consume the
//     previous one (vid_addr catch-up), which also bounds the stream FIFO.
//   * the card FSM's ext_* CPU ops (always full 16-bit words — the FSM does
//     RMW merging itself). Writes complete on Avalon acceptance (posted by
//     the bridge); reads extract the addressed word from the 64-bit beat.
//     CPU ops preempt the NEXT scan burst, never an in-flight one, so a CPU
//     read waits at most one burst drain (~15-25 clk).
//
// Address map: card word w (16-bit units, 0..0x7FFFF) lives at DDR3 byte
// DDR_BASE + w*2, i.e. quadword DDR_BASE_QW + w[19:2], byte lanes 2*w[1:0].
// Default base 0x30000000 — the customary MiSTer core scratch region, well
// clear of the framework's 0x20000000 ascal buffers.
//
module mdc_vram_ddr #(
	parameter [28:0] DDR_BASE_QW = 29'h06000000   // byte 0x30000000 >> 3
)(
	input             clk,            // DDRAM_CLK domain (= clk_sys)
	input             reset,

	// MiSTer DDRAM channel
	input             ddr_busy,
	output reg  [7:0] ddr_burstcnt,
	output reg [28:0] ddr_addr,
	input      [63:0] ddr_dout,
	input             ddr_dout_ready,
	output reg        ddr_rd,
	output reg [63:0] ddr_din,
	output reg  [7:0] ddr_be,
	output reg        ddr_we,

	// scanline stream client (contract of sdram.v's video port)
	input             vid_rd,
	input      [25:0] vid_addr,       // SDRAM-window-style: base + card word
	input             vid_seq,
	output reg [15:0] vid_data,
	output reg        vid_dseq,
	output reg        vid_tog,

	// card FSM ext ops (full-word). Contract (matches vram_ram/the SDRAM ext
	// path): the FSM raises rd/wr and HOLDS it until ready, then drops it —
	// the line can stay high a cycle past ready. Requests are accepted on the
	// RISING edge only and ready is a LEVEL held while the request line is
	// held, so the trailing overlap can neither start a phantom op nor alias
	// a stale completion into the next op's wait.
	input             ext_rd,
	input             ext_wr,
	input      [19:0] ext_word,
	input      [15:0] ext_wdata,
	output reg [15:0] ext_dout,
	output            ext_ready
);

	localparam [3:0] SCAN_QW = 4'd4;   // quadwords per scan burst (16 words)

	// vid_addr arrives as SDRAM-layout address (window base + word); only the
	// card word offset matters here.
	wire [19:0] vid_word = vid_addr[19:0];

	// ---- scan stream FIFO (one burst deep: 16 words + margin) --------------
	reg [15:0] sfifo [0:31];
	reg [4:0]  sf_wr, sf_rd;
	reg [5:0]  sf_cnt;
	reg        sf_seq;          // seq tag of the words in the FIFO
	reg [1:0]  sf_skip;         // leading words of beat 0 to drop (alignment)
	reg [4:0]  sf_expect;       // words the burst will deliver after skip

	// group handshake (same rule as sdram.v): a new burst starts only when
	// the client consumed the previous group (vid_addr caught up) or
	// restarted (vid_seq changed)
	reg        expect_valid;
	reg [19:0] expect_word;
	reg        expect_seq;

	// ---- channel FSM --------------------------------------------------------
	localparam S_IDLE      = 3'd0;
	localparam S_EXT_WR    = 3'd1;
	localparam S_EXT_RD    = 3'd2;
	localparam S_EXT_RDW   = 3'd3;
	localparam S_SCAN_RD   = 3'd4;
	localparam S_SCAN_RDW  = 3'd5;

	reg [2:0]  st;
	reg [1:0]  ext_lane;
	reg [3:0]  beats_left;
	reg        ext_pend_rd, ext_pend_wr;   // accepted (edge-qualified) requests
	reg [19:0] ext_word_l;
	reg [15:0] ext_wdata_l;
	reg        ext_rd_d, ext_wr_d;
	reg        ext_done;                   // completion level for the held request
	assign ext_ready = ext_done;

	// serve the stream out of the FIFO at one word per clock
	always @(posedge clk) begin
		if (reset) begin
			sf_rd   <= 5'd0;
			vid_tog <= 1'b0;
			vid_dseq<= 1'b0;
		end else if (sf_cnt != 6'd0) begin
			vid_data <= sfifo[sf_rd];
			vid_dseq <= sf_seq;
			vid_tog  <= ~vid_tog;
			sf_rd    <= sf_rd + 5'd1;
		end
	end

	wire sf_pop = (sf_cnt != 6'd0);
	reg  sf_push;
	reg [2:0] sf_push_n;   // words pushed this cycle (a 64-bit beat = up to 4)

	always @(posedge clk) begin
		sf_push   <= 1'b0;
		sf_push_n <= 3'd0;
		ext_rd_d  <= ext_rd;
		ext_wr_d  <= ext_wr;

		if (reset) begin
			st <= S_IDLE;
			ddr_rd <= 1'b0; ddr_we <= 1'b0;
			ddr_burstcnt <= 8'd1; ddr_be <= 8'hFF;
			sf_wr <= 5'd0; sf_cnt <= 6'd0;
			expect_valid <= 1'b0;
			ext_pend_rd <= 1'b0; ext_pend_wr <= 1'b0;
			ext_done <= 1'b0;
		end else begin
			// request acceptance: RISING edge only; ready (ext_done) is a
			// level cleared when the card drops the request line
			if (!ext_rd && !ext_wr) ext_done <= 1'b0;
			if (ext_rd && !ext_rd_d) begin
				ext_pend_rd <= 1'b1; ext_word_l <= ext_word; ext_done <= 1'b0;
			end
			if (ext_wr && !ext_wr_d) begin
				ext_pend_wr <= 1'b1; ext_word_l <= ext_word; ext_wdata_l <= ext_wdata;
				ext_done <= 1'b0;
			end
			if (!vid_rd) expect_valid <= 1'b0;

			// FIFO count bookkeeping (push side updates below via sf_push*)
			sf_cnt <= sf_cnt + (sf_push ? {3'd0, sf_push_n} : 6'd0) - (sf_pop ? 6'd1 : 6'd0);

			case (st)
				S_IDLE: begin
					if (ext_pend_wr) begin
						ddr_addr     <= DDR_BASE_QW + {11'd0, ext_word_l[19:2]};
						ddr_burstcnt <= 8'd1;
						ddr_din      <= {4{ext_wdata_l}};
						ddr_be       <= 8'h03 << {ext_word_l[1:0], 1'b0};
						ddr_we       <= 1'b1;
						st           <= S_EXT_WR;
					end else if (ext_pend_rd) begin
						ddr_addr     <= DDR_BASE_QW + {11'd0, ext_word_l[19:2]};
						ddr_burstcnt <= 8'd1;
						ddr_be       <= 8'hFF;
						ddr_rd       <= 1'b1;
						ext_lane     <= ext_word_l[1:0];
						st           <= S_EXT_RD;
					end else if (vid_rd && sf_cnt == 6'd0 &&
					             (!expect_valid || (vid_seq != expect_seq) ||
					              (vid_word == expect_word))) begin
						// scan burst: SCAN_QW quadwords from the aligned base;
						// leading words below vid_word are dropped on receive
						ddr_addr     <= DDR_BASE_QW + {11'd0, vid_word[19:2]};
						ddr_burstcnt <= {4'd0, SCAN_QW};
						ddr_be       <= 8'hFF;
						ddr_rd       <= 1'b1;
						sf_skip      <= vid_word[1:0];
						sf_seq       <= vid_seq;
						sf_expect    <= ({SCAN_QW, 2'b00} - {3'd0, vid_word[1:0]});
						expect_word  <= vid_word + ({SCAN_QW, 2'b00} - {3'd0, vid_word[1:0]});
						expect_seq   <= vid_seq;
						expect_valid <= 1'b1;
						beats_left   <= SCAN_QW;
						st           <= S_SCAN_RD;
					end
				end

				S_EXT_WR: if (!ddr_busy) begin
					ddr_we      <= 1'b0;
					ext_pend_wr <= 1'b0;
					ext_done    <= 1'b1;   // accepted = done (bridge posts it)
					st          <= S_IDLE;
				end

				S_EXT_RD: if (!ddr_busy) begin
					ddr_rd <= 1'b0;
					st     <= S_EXT_RDW;
				end

				S_EXT_RDW: if (ddr_dout_ready) begin
					case (ext_lane)
						2'd0: ext_dout <= ddr_dout[15:0];
						2'd1: ext_dout <= ddr_dout[31:16];
						2'd2: ext_dout <= ddr_dout[47:32];
						2'd3: ext_dout <= ddr_dout[63:48];
					endcase
					ext_pend_rd <= 1'b0;
					ext_done    <= 1'b1;
					st          <= S_IDLE;
				end

				S_SCAN_RD: if (!ddr_busy) begin
					ddr_rd <= 1'b0;
					st     <= S_SCAN_RDW;
				end

				S_SCAN_RDW: if (ddr_dout_ready) begin
					// unpack the beat, dropping sf_skip leading words on beat 0
					// (writes into the FIFO happen in the same clock; the
					// count moves via sf_push/sf_push_n)
					if (sf_skip == 2'd0) begin
						sfifo[sf_wr]        <= ddr_dout[15:0];
						sfifo[sf_wr + 5'd1] <= ddr_dout[31:16];
						sfifo[sf_wr + 5'd2] <= ddr_dout[47:32];
						sfifo[sf_wr + 5'd3] <= ddr_dout[63:48];
						sf_wr <= sf_wr + 5'd4;
						sf_push <= 1'b1; sf_push_n <= 3'd4;
					end else if (sf_skip == 2'd1) begin
						sfifo[sf_wr]        <= ddr_dout[31:16];
						sfifo[sf_wr + 5'd1] <= ddr_dout[47:32];
						sfifo[sf_wr + 5'd2] <= ddr_dout[63:48];
						sf_wr <= sf_wr + 5'd3;
						sf_push <= 1'b1; sf_push_n <= 3'd3;
					end else if (sf_skip == 2'd2) begin
						sfifo[sf_wr]        <= ddr_dout[47:32];
						sfifo[sf_wr + 5'd1] <= ddr_dout[63:48];
						sf_wr <= sf_wr + 5'd2;
						sf_push <= 1'b1; sf_push_n <= 3'd2;
					end else begin
						sfifo[sf_wr]        <= ddr_dout[63:48];
						sf_wr <= sf_wr + 5'd1;
						sf_push <= 1'b1; sf_push_n <= 3'd1;
					end
					sf_skip <= 2'd0;
					beats_left <= beats_left - 4'd1;
					if (beats_left == 4'd1) st <= S_IDLE;
				end

				default: st <= S_IDLE;
			endcase
		end
	end

endmodule
