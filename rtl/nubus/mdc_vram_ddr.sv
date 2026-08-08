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

	// scanline stream client (contract of sdram.v's video port, plus the
	// pair lane: when the FIFO holds two words they are served together on
	// one tog — mdc_scan_fetch consumes both. Sustains 24bpp (960 words in
	// a ~928-clk line); the sdram.v backend never pairs.)
	input             vid_rd,
	input      [25:0] vid_addr,       // SDRAM-window-style: base + card word
	input             vid_seq,
	output reg [15:0] vid_data,
	output reg        vid_dseq,
	output reg        vid_tog,
	output reg        vid_pair,
	output reg [15:0] vid_data2,

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
	input      [1:0]  ext_ds,      // write byte strobes ([1]=[15:8], [0]=[7:0])
	output reg [15:0] ext_dout,
	output            ext_ready
);

	localparam [4:0] SCAN_QW = 5'd16;  // quadwords per scan burst (64 words).
	                                   // The bridge model costs ~12 clk dead
	                                   // latency per burst with no overlap;
	                                   // 64-word bursts + the pair drain
	                                   // amortize it to ~0.72 clk/word —
	                                   // 24bpp needs 960 words in a ~928-clk
	                                   // line, sustained.

	// vid_addr arrives as SDRAM-layout address (window base + word); only the
	// card word offset matters here.
	wire [19:0] vid_word = vid_addr[19:0];

	// ---- scan stream FIFO: one 64-bit entry per BEAT (single write port so
	// it infers MLAB/M10K — the word-wide 4-write-port first cut became ~1K
	// registers + two 64:1 mux trees and overflowed the device) -------------
	reg [63:0] bfifo [0:15];
	reg [3:0]  bf_wr, bf_rd;
	reg [4:0]  bf_cnt;
	reg        sf_seq;          // seq tag of the burst in the FIFO
	reg [1:0]  burst_skip;      // words to drop from the burst's first beat
	                            // (line starts are word-even in every mode,
	                            // so this is 0 or 2 — never odd)

	// two-stage serve pipeline: bf_q shows the FIFO head a clock ahead,
	// cur_beat unpacks it at up to two words per clock
	reg [63:0] bf_q;
	reg        bf_q_valid;
	reg [63:0] cur_beat;
	reg [2:0]  cur_rem;         // words left in cur_beat
	reg [1:0]  cur_idx;
	reg        skip_used;       // burst_skip consumed (first beat served)
	wire [15:0] cw0 = (cur_idx == 2'd0) ? cur_beat[15:0]  :
	                  (cur_idx == 2'd1) ? cur_beat[31:16] :
	                  (cur_idx == 2'd2) ? cur_beat[47:32] : cur_beat[63:48];
	wire [15:0] cw1 = (cur_idx == 2'd0) ? cur_beat[31:16] :
	                  (cur_idx == 2'd1) ? cur_beat[47:32] : cur_beat[63:48];
	wire [1:0]  serve_n  = (cur_rem >= 3'd2) ? 2'd2 : {1'b0, cur_rem[0]};
	wire        scan_drained = (bf_cnt == 5'd0) && !bf_q_valid && (cur_rem == 3'd0);

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
	reg [4:0]  beats_left;
	reg        ext_pend_rd, ext_pend_wr;   // accepted (edge-qualified) requests
	reg [19:0] ext_word_l;
	reg [15:0] ext_wdata_l;
	reg [1:0]  ext_ds_l;
	reg        ext_rd_d, ext_wr_d;
	reg        ext_done;                   // completion level for the held request
	assign ext_ready = ext_done;

	// serve the stream — a pair per clock out of the staged beat. With the
	// even-skip invariant the first beat holds 2 or 4 words and every later
	// beat holds 4, so the single-word arm is defensive only.
	always @(posedge clk) begin
		if (reset) begin
			bf_rd      <= 4'd0;
			bf_q_valid <= 1'b0;
			cur_rem    <= 3'd0;
			cur_idx    <= 2'd0;
			skip_used  <= 1'b0;
			vid_tog    <= 1'b0;
			vid_dseq   <= 1'b0;
			vid_pair   <= 1'b0;
		end else begin
			// rearm the skip for the next burst once fully drained
			if (scan_drained) skip_used <= 1'b0;

			if (vid_seq != sf_seq) begin
				// stale-burst discard: the client restarted while this
				// burst was draining. A 1-bit seq aliases after TWO
				// restarts, and a 64-word tail lives long enough to span
				// them — so a stale tail must never reach vid_tog. Drop a
				// beat per clock, no toggles.
				cur_rem    <= 3'd0;
				bf_q_valid <= 1'b0;
				if (bf_cnt != 5'd0) bf_rd <= bf_rd + 4'd1;
			end else begin
				// serve from the current beat
				if (cur_rem != 3'd0) begin
					vid_data <= cw0;
					vid_pair <= (serve_n == 2'd2);
					if (serve_n == 2'd2) vid_data2 <= cw1;
					vid_dseq <= sf_seq;
					vid_tog  <= ~vid_tog;
					cur_idx  <= cur_idx + serve_n;
					cur_rem  <= cur_rem - {1'b0, serve_n};
				end

				// stage 2 load: take the shown beat when cur empties this
				// clock (may override the cur_rem decrement above —
				// intended). The burst's first beat starts at the skip
				// offset — any alignment, per the port contract (in-system
				// line starts are word-even, but the bench and the
				// contract cover odd bases too).
				if (bf_q_valid && (cur_rem == {1'b0, serve_n})) begin
					cur_beat   <= bf_q;
					cur_rem    <= skip_used ? 3'd4
					                        : (3'd4 - {1'b0, burst_skip});
					cur_idx    <= skip_used ? 2'd0 : burst_skip;
					skip_used  <= 1'b1;
					bf_q_valid <= 1'b0;
				end

				// stage 1 load: show the FIFO head (bf_cnt is the
				// write-side guard, registered, so a beat pushed this edge
				// is not read until the next — no read-during-write on the
				// MLAB)
				if (!bf_q_valid && bf_cnt != 5'd0) begin
					bf_q       <= bfifo[bf_rd];
					bf_rd      <= bf_rd + 4'd1;
					bf_q_valid <= 1'b1;
				end
			end
		end
	end

	wire bf_pop_w = (bf_cnt != 5'd0) &&
	                ((vid_seq != sf_seq) || !bf_q_valid);
	always @(posedge clk) begin
		ext_rd_d  <= ext_rd;
		ext_wr_d  <= ext_wr;

		if (reset) begin
			st <= S_IDLE;
			ddr_rd <= 1'b0; ddr_we <= 1'b0;
			ddr_burstcnt <= 8'd1; ddr_be <= 8'hFF;
			bf_wr <= 4'd0; bf_cnt <= 5'd0;
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
				ext_ds_l <= ext_ds;
				ext_done <= 1'b0;
			end
			if (!vid_rd) expect_valid <= 1'b0;

			// FIFO count: push = a beat landing (below), pop = stage-1 load
			bf_cnt <= bf_cnt + {4'd0, (st == S_SCAN_RDW) && ddr_dout_ready}
			                 - {4'd0, bf_pop_w};

			case (st)
				S_IDLE: begin
					if (ext_pend_wr) begin
						ddr_addr     <= DDR_BASE_QW + {11'd0, ext_word_l[19:2]};
						ddr_burstcnt <= 8'd1;
						ddr_din      <= {4{ext_wdata_l}};
						// per-byte enables: word lane k spans qword bytes
						// 2k (= wdata[7:0], ds[0]) and 2k+1 (= wdata[15:8],
						// ds[1]) — the pair is ext_ds_l as-is, shifted up
						ddr_be       <= {6'd0, ext_ds_l}
						                << {ext_word_l[1:0], 1'b0};
						ddr_we       <= 1'b1;
						st           <= S_EXT_WR;
					end else if (ext_pend_rd) begin
						ddr_addr     <= DDR_BASE_QW + {11'd0, ext_word_l[19:2]};
						ddr_burstcnt <= 8'd1;
						ddr_be       <= 8'hFF;
						ddr_rd       <= 1'b1;
						ext_lane     <= ext_word_l[1:0];
						st           <= S_EXT_RD;
					end else if (vid_rd && scan_drained &&
					             (!expect_valid || (vid_seq != expect_seq) ||
					              (vid_word == expect_word) ||
					              (vid_word == expect_word + 20'd1))) begin
						// (the +1 arm tolerates a client that stepped past
						// expect_word with a pair after a lone-word serve —
						// unreachable with even line starts, but a hang if
						// it ever happened)
						// scan burst: SCAN_QW quadwords from the aligned base;
						// leading words below vid_word are dropped on receive
						ddr_addr     <= DDR_BASE_QW + {11'd0, vid_word[19:2]};
						ddr_burstcnt <= {3'd0, SCAN_QW};
						ddr_be       <= 8'hFF;
						ddr_rd       <= 1'b1;
						burst_skip   <= vid_word[1:0];
						sf_seq       <= vid_seq;
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
					// whole beats go into the FIFO; the serve stage applies
					// burst_skip to the first one
					bfifo[bf_wr] <= ddr_dout;
					bf_wr        <= bf_wr + 4'd1;
					beats_left <= beats_left - 5'd1;
					if (beats_left == 5'd1) st <= S_IDLE;
				end

				default: st <= S_IDLE;
			endcase
		end
	end

endmodule
