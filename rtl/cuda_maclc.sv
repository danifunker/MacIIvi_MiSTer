/*
 * Apple CUDA for Mac LC/LC II Integration
 * Fixed packet format: [packet_type][command][data...] - NO length byte!
 *
 * Packet types:
 *   0x00 = ADB_PACKET
 *   0x01 = CUDA_PACKET (pseudo commands)
 *   0x02 = ERROR_PACKET (responses)
 *   0x03 = TIMER_PACKET
 *
 * Based on MAME's cuda.cpp and Linux via-cuda.c
 */

module cuda_maclc (
    input         clk,
    input         clk8_en,
    input         reset,

    // RTC timestamp initialization (Unix time)
    input  [32:0] timestamp,

    // Direct VIA Port B connections
    input         via_tip,          // VIA Port B bit 5 - Transaction In Progress
    input         via_byteack_in,   // VIA Port B bit 4 - from VIA
    output        cuda_treq,        // Port B bit 3 - Transfer Request (active LOW)
    output        cuda_byteack,     // Port B bit 4 - Byte Acknowledge

    // VIA Shift Register interface (CB1/CB2)
    output        cuda_cb1,         // CB1 - Shift clock (CUDA drives in external mode)
    input         via_cb2_in,       // CB2 - Data from VIA (when VIA sending)
    output        cuda_cb2,         // CB2 - Data to VIA (when CUDA sending)
    output        cuda_cb2_oe,      // CB2 output enable

    // VIA SR control signals
    input         via_sr_read,      // VIA is reading SR (shift in mode)
    input         via_sr_write,     // VIA has written SR (shift out mode)
    input         via_sr_ext_clk,   // VIA is in external clock mode (ACR bits 4:2 = 11x)
    input         via_sr_dir,       // VIA shift direction: 0=in, 1=out
    output reg    cuda_sr_irq,      // Request SR interrupt

    // Full port B for completeness
    output [7:0]  cuda_portb,       // Complete Port B output
    output [7:0]  cuda_portb_oe,    // Port B output enables

    // ADB signals (simplified)
    input         adb_data_in,
    output reg    adb_data_out,

    // System control
    output reg    reset_680x0,
    output reg    nmi_680x0
);

    //==========================================================================
    // Packet Type Definitions (from Linux uapi/linux/adb.h)
    //==========================================================================
    localparam [7:0] PKT_ADB        = 8'h00;
    localparam [7:0] PKT_CUDA       = 8'h01;
    localparam [7:0] PKT_ERROR      = 8'h02;
    localparam [7:0] PKT_TIMER      = 8'h03;

    //==========================================================================
    // CUDA Command Codes (from Linux uapi/linux/cuda.h)
    //==========================================================================
    localparam [7:0] CUDA_WARM_START    = 8'h00;
    localparam [7:0] CUDA_AUTOPOLL      = 8'h01;
    localparam [7:0] CUDA_GET_6805_ADDR = 8'h02;
    localparam [7:0] CUDA_GET_TIME      = 8'h03;
    localparam [7:0] CUDA_GET_PRAM      = 8'h07;
    localparam [7:0] CUDA_SET_6805_ADDR = 8'h08;
    localparam [7:0] CUDA_SET_TIME      = 8'h09;
    localparam [7:0] CUDA_POWERDOWN     = 8'h0A;
    localparam [7:0] CUDA_POWERUP_TIME  = 8'h0B;
    localparam [7:0] CUDA_SET_PRAM      = 8'h0C;
    localparam [7:0] CUDA_MS_RESET      = 8'h0D;
    localparam [7:0] CUDA_SEND_DFAC     = 8'h0E;
    localparam [7:0] CUDA_RESET_SYSTEM  = 8'h11;
    localparam [7:0] CUDA_SET_IPL       = 8'h12;
    localparam [7:0] CUDA_SET_AUTO_RATE = 8'h14;
    localparam [7:0] CUDA_GET_AUTO_RATE = 8'h16;
    localparam [7:0] CUDA_SET_DEV_LIST  = 8'h19;
    localparam [7:0] CUDA_GET_DEV_LIST  = 8'h1A;
    localparam [7:0] CUDA_SET_ONE_SEC   = 8'h1B;  // Set one-second interrupt mode
    localparam [7:0] CUDA_SET_PWR_MSG   = 8'h21;  // Set power messages
    localparam [7:0] CUDA_GET_SET_IIC   = 8'h22;
    localparam [7:0] CUDA_WAKEUP        = 8'h23;  // Enable/disable wakeup
    localparam [7:0] CUDA_TIMER_TICKLE  = 8'h24;  // Timer tickle
    localparam [7:0] CUDA_COMBINED_IIC  = 8'h25;  // Combined format IIC

    //==========================================================================
    // Port B Bit Definitions (Mac LC V8 protocol)
    //==========================================================================
    localparam PB_TREQ      = 3;  // CUDA output - Transfer Request
    localparam PB_BYTEACK   = 4;  // VIA output to CUDA
    localparam PB_TIP       = 5;  // VIA output to CUDA - Transaction In Progress

    //==========================================================================
    // CUDA State Machine
    //==========================================================================
    localparam [3:0] ST_IDLE            = 4'd0;
    localparam [3:0] ST_ATTENTION       = 4'd1;   // Startup: assert TREQ
    localparam [3:0] ST_RECV_BYTE       = 4'd2;   // Receiving a byte
    localparam [3:0] ST_RECV_WAIT       = 4'd3;   // Wait for next byte or end
    localparam [3:0] ST_PROCESS         = 4'd4;   // Process received packet
    localparam [3:0] ST_SEND_WAIT       = 4'd5;   // Wait for SR read before sending
    localparam [3:0] ST_SEND_BYTE       = 4'd6;   // Sending a byte
    localparam [3:0] ST_SEND_DONE       = 4'd7;   // Byte sent, wait for next
    localparam [3:0] ST_FINISH          = 4'd8;   // Transaction complete

    reg [3:0] state, next_state;

    //==========================================================================
    // Internal Registers
    //==========================================================================
    reg [7:0]  recv_buf[0:15];    // Receive buffer
    reg [3:0]  recv_count;        // Bytes received
    reg [7:0]  send_buf[0:15];    // Send buffer
    reg [3:0]  send_count;        // Bytes sent
    reg [3:0]  send_length;       // Total bytes to send

    // Shift register state
    reg [7:0]  shift_reg;
    reg [3:0]  bit_counter;
    reg [7:0]  shift_clk_div;
    reg        cb1_out;
    reg        cb2_out_reg;
    reg        cb2_oe_reg;

    // Control signals
    reg        treq_reg;
    reg        byteack_reg;

    // Edge detection
    reg        via_tip_prev;
    reg        via_sr_write_prev;
    reg        via_sr_read_prev;

    // Timing
    reg [15:0] wait_counter;

    // SR write tracking - only clock after ROM writes SR
    reg        sr_write_seen;

    // PRAM storage (256 bytes)
    reg [7:0]  pram[0:255];

    // RTC
    localparam [31:0] MAC_UNIX_DELTA = 32'd2082844800;
    reg [31:0] rtc_seconds;
    reg [23:0] rtc_tick_counter;
    reg        rtc_initialized;

    // Autopoll state
    reg        autopoll_enabled;

    //==========================================================================
    // Output Assignments
    //==========================================================================
    assign cuda_treq = treq_reg;  // treq_reg=1 means asserted, dataController inverts for pin
    assign cuda_byteack = byteack_reg;
    assign cuda_cb1 = cb1_out;
    assign cuda_cb2 = cb2_out_reg;
    assign cuda_cb2_oe = cb2_oe_reg;

    assign cuda_portb[2:0] = 3'b111;
    assign cuda_portb[PB_TREQ] = treq_reg;
    assign cuda_portb[PB_BYTEACK] = 1'b0;  // Input
    assign cuda_portb[PB_TIP] = 1'b0;      // Input
    assign cuda_portb[7:6] = 2'b11;
    assign cuda_portb_oe = 8'b11000111;

    //==========================================================================
    // PRAM Default Initialization
    //==========================================================================
    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1)
            pram[i] = 8'h00;
        pram[8'h08] = 8'h00;
        pram[8'h09] = 8'h08;
        pram[8'h0C] = 8'h4E;  // Extended PRAM validity 'N'
        pram[8'h0D] = 8'h75;  // Extended PRAM validity 'u'
        pram[8'h0E] = 8'h4D;  // Extended PRAM validity 'M'
        pram[8'h0F] = 8'h63;  // Extended PRAM validity 'c'
        pram[8'h10] = 8'hA8;  // SPValid
        pram[8'h13] = 8'h22;  // SPConfig: both ports useAsync (AppleTalk inactive)
        pram[8'h78] = 8'h07;  // Volume
        pram[8'h7C] = 8'hA8;  // PRAM signature
        pram[8'h7D] = 8'h00;
        pram[8'h7E] = 8'h00;
        pram[8'h7F] = 8'h01;
    end

    //==========================================================================
    // Main State Machine
    //==========================================================================
    reg [3:0] prev_state;

    always @(posedge clk) begin
        if (reset) begin
            state <= ST_ATTENTION;
            via_tip_prev <= 1'b1;
            via_sr_write_prev <= 1'b0;
            via_sr_read_prev <= 1'b0;
            prev_state <= ST_ATTENTION;
        end else if (clk8_en) begin
            prev_state <= state;
            state <= next_state;
            via_tip_prev <= via_tip;
            via_sr_write_prev <= via_sr_write;
            via_sr_read_prev <= via_sr_read;

            `ifdef VERBOSE_TRACE
            if (state != prev_state) begin
                $display("CUDA: state %d -> %d, TIP=%b, TREQ=%b, recv_cnt=%d, send_cnt=%d",
                         prev_state, state, via_tip, treq_reg, recv_count, send_count);
            end
            `endif
        end
    end

    // Next state logic
    always @(*) begin
        next_state = state;

        case (state)
            ST_ATTENTION: begin
                // At startup, wait for ROM to send probe (don't assert TREQ)
                // When ROM asserts TIP, go to receive mode to get probe byte
                if (!via_tip && via_tip_prev) begin
                    next_state = ST_RECV_WAIT;  // ROM starting transaction, receive probe
                    `ifdef VERBOSE_TRACE
                    $display("CUDA: ST_ATTENTION->ST_RECV_WAIT: ROM asserting TIP, ready to receive");
                    `endif
                end
                else if (wait_counter >= 16'd100000)
                    next_state = ST_IDLE;  // Timeout - go to idle anyway
            end

            ST_IDLE: begin
                // Wait for TIP to start a transaction
                // Check both falling edge and level - ROM may have already asserted TIP
                if ((!via_tip && via_tip_prev) || (!via_tip && sr_write_seen)) begin
                    next_state = ST_RECV_WAIT;
                    `ifdef VERBOSE_TRACE
                    $display("CUDA: IDLE->RECV_WAIT: TIP=%b, prev=%b, sr_write_seen=%b", via_tip, via_tip_prev, sr_write_seen);
                    `endif
                end
            end

            ST_RECV_WAIT: begin
                // Wait for SR write (ROM sending byte)
                // IMPORTANT: ROM releases TIP between bytes to check TREQ
                // We must wait for TIP to be re-asserted before clocking each byte
                //
                // Protocol: ROM asserts TIP -> writes SR -> we clock ->
                //           ROM toggles BYTEACK -> ROM releases TIP to check TREQ ->
                //           ROM writes SR for next byte -> ROM re-asserts TIP -> repeat
                //
                // Key insight: ROM may write SR BEFORE re-asserting TIP, so we track
                // sr_write_seen and wait for TIP assertion to start clocking

                // When TIP asserted AND we have pending SR write, start receiving
                if (!via_tip && sr_write_seen) begin
                    next_state = ST_RECV_BYTE;
                    `ifdef VERBOSE_TRACE
                    $display("CUDA: RECV_WAIT->RECV_BYTE: TIP asserted with pending SR write");
                    `endif
                end
                // Also handle case where TIP and SR write happen together
                else if (!via_tip && via_sr_write && !via_sr_write_prev) begin
                    next_state = ST_RECV_BYTE;
                    `ifdef VERBOSE_TRACE
                    $display("CUDA: RECV_WAIT->RECV_BYTE: TIP and sr_write edge together");
                    `endif
                end
                // Timeout: have data, no pending SR write, and waited long enough
                // wait_counter increments when: recv_count > 0 && !sr_write_seen && bit_counter >= 8
                // This works regardless of TIP state
                else if (recv_count > 0 && wait_counter >= 16'd5000) begin
                    next_state = ST_PROCESS;
                    `ifdef VERBOSE_TRACE
                    $display("CUDA: RECV_WAIT->PROCESS: packet complete, recv_count=%d, TIP=%b", recv_count, via_tip);
                    `endif
                end
            end

            ST_RECV_BYTE: begin
                // Shift in 8 bits
                if (bit_counter >= 4'd8)
                    next_state = ST_RECV_WAIT;
            end

            ST_PROCESS: begin
                // Process packet and prepare response
                next_state = ST_SEND_WAIT;
            end

            ST_SEND_WAIT: begin
                // CUDA sends to ROM:
                // - CUDA asserts TREQ to indicate it has data
                // - ROM asserts TIP to acknowledge
                // - ROM changes VIA to shift IN mode (writes ACR for external clock INPUT)
                // - CUDA clocks data on CB1/CB2 immediately once VIA is ready
                // - After 8 clocks, VIA sets SR_INT, ROM reads SR to get the byte
                //
                // IMPORTANT: We start clocking as soon as VIA is in external clock INPUT mode.
                // The ROM reads SR AFTER the shift completes, not before!
                // We wait for:
                //   - TIP asserted (!via_tip)
                //   - via_sr_ext_clk (VIA is in external clock mode)
                //   - !via_sr_dir (VIA is in INPUT mode, not output)
                //   - Small delay for VIA to be ready (wait_counter > 100)
                if (send_count < send_length && !via_tip) begin
                    // TIP asserted by ROM - wait for VIA to enter external clock INPUT mode
                    if (via_sr_ext_clk && !via_sr_dir && wait_counter > 16'd100) begin
                        next_state = ST_SEND_BYTE;
                        `ifdef VERBOSE_TRACE
                        $display("CUDA: SEND_WAIT->SEND_BYTE: sr_ext_clk=%b, sr_dir=%b, wait=%d", via_sr_ext_clk, via_sr_dir, wait_counter);
                        `endif
                    end
                end else if (send_count >= send_length) begin
                    next_state = ST_FINISH;
                end
                // Otherwise wait for TIP assertion and VIA external clock INPUT mode
            end

            ST_SEND_BYTE: begin
                // Shift out 8 bits - done after 8th falling edge
                // bit_counter increments on falling edges, VIA samples on rising edges
                // VIA needs exactly 8 rising edges per byte. Sequence:
                //   cb1=0 (start) -> toggle 0: cb1=1 (rising 1) -> toggle 1: cb1=0 (falling, bit_cnt=1)
                //   -> ... -> toggle 14: cb1=1 (rising 8) -> toggle 15: cb1=0 (falling, bit_cnt=8)
                // At bit_counter=8 && cb1=0, we've provided exactly 8 rising edges. Stop here.
                if (bit_counter >= 4'd8 && !cb1_out) begin
                    next_state = ST_SEND_DONE;
                    `ifdef VERBOSE_TRACE
                    $display("CUDA: ST_SEND_BYTE done - bit_counter=%d, cb1_out=%b", bit_counter, cb1_out);
                    `endif
                end
            end

            ST_SEND_DONE: begin
                // Byte sent, wait for next SR read or end of transaction
                // IMPORTANT: ROM releases TIP between bytes to check TREQ
                // If TREQ is still asserted (we have more data), ROM will re-assert TIP
                // Only go to FINISH when we're done sending AND TIP is released
                if (via_tip && send_count >= send_length) begin
                    // TIP released AND we're done - transaction complete
                    next_state = ST_FINISH;
                end
                else if (!via_tip && via_sr_read && !via_sr_read_prev) begin
                    // TIP asserted and ROM read SR - send next byte if available
                    if (send_count < send_length)
                        next_state = ST_SEND_BYTE;
                    else
                        next_state = ST_FINISH;
                end
                else if (wait_counter >= 16'd50000) begin
                    // Timeout - ROM not responding, finish transaction
                    next_state = ST_FINISH;
                    `ifdef VERBOSE_TRACE
                    $display("CUDA: SEND_DONE timeout, finishing. send_cnt=%d/%d TIP=%b", send_count, send_length, via_tip);
                    `endif
                end
                // Otherwise wait for TIP re-assertion or transaction end
            end

            ST_FINISH: begin
                // Wait for TIP to fully release
                if (via_tip && wait_counter >= 16'd10)
                    next_state = ST_IDLE;
            end

            default: next_state = ST_IDLE;
        endcase
    end

    //==========================================================================
    // State Machine Outputs and Data Processing
    //==========================================================================
    always @(posedge clk) begin
        if (reset) begin
            treq_reg <= 1'b1;           // Assert TREQ at startup to signal CUDA presence
            byteack_reg <= 1'b0;
            cb1_out <= 1'b1;
            cb2_out_reg <= 1'b1;
            cb2_oe_reg <= 1'b0;
            cuda_sr_irq <= 1'b0;
            recv_count <= 4'h0;
            send_count <= 4'h0;
            send_length <= 4'h0;
            bit_counter <= 4'h0;
            shift_clk_div <= 8'h0;
            shift_reg <= 8'h00;
            wait_counter <= 16'h0;
            reset_680x0 <= 1'b0;
            nmi_680x0 <= 1'b0;
            adb_data_out <= 1'b1;
            autopoll_enabled <= 1'b0;
            sr_write_seen <= 1'b0;
            rtc_seconds <= 32'h0;
            rtc_tick_counter <= 24'h0;
            rtc_initialized <= 1'b0;

        end else if (clk8_en) begin
            cuda_sr_irq <= 1'b0;

            // RTC tick counter
            if (!rtc_initialized && timestamp != 0) begin
                rtc_seconds <= timestamp[31:0] + MAC_UNIX_DELTA;
                rtc_initialized <= 1'b1;
            end else begin
                if (rtc_tick_counter >= 24'd7_999_999) begin
                    rtc_tick_counter <= 24'h0;
                    rtc_seconds <= rtc_seconds + 1'd1;
                end else begin
                    rtc_tick_counter <= rtc_tick_counter + 1'd1;
                end
            end

            // Track SR write events for clocking control
            if (via_sr_write && !via_sr_write_prev)
                sr_write_seen <= 1'b1;

            case (state)
                ST_ATTENTION: begin
                    // At startup, don't assert TREQ - wait for ROM to send probe first
                    // ROM will assert TIP and send a probe byte, we respond with PKT_ERROR
                    byteack_reg <= 1'b0;
                    recv_count <= 4'h0;
                    treq_reg <= 1'b0;  // Don't assert TREQ - wait for ROM probe
                    cb2_oe_reg <= 1'b0;  // Don't drive CB2 yet
                    cb1_out <= 1'b0;  // Start low
                    wait_counter <= wait_counter + 1'd1;
`ifdef VERBOSE_TRACE
                    if (wait_counter == 16'd0)
                        $display("CUDA: ST_ATTENTION starting, waiting for ROM probe, TIP=%b", via_tip);
`endif
                end

                ST_IDLE: begin
                    treq_reg <= 1'b0;       // De-assert TREQ when idle
                    byteack_reg <= 1'b0;
                    cb2_oe_reg <= 1'b0;
                    recv_count <= 4'h0;
                    send_count <= 4'h0;
                    wait_counter <= wait_counter + 1'd1;
                    // Only reset sr_write_seen when TIP is released
                    // Don't reset if TIP is about to be asserted (ROM writes SR before TIP)
                    if (via_tip)
                        sr_write_seen <= 1'b0;

                    // Continue providing CB1 clocks if VIA is in external clock mode
                    // This clears any pending shift that was auto-triggered when ROM read SR
                    // VIA trigger_serial (from SR read) sets bit_cnt=7, shift_active=1.
                    // Then 8 CB1 edges complete the shift (7 decrements + 1 completion).
                    // We must provide exactly 8 edges - more will trigger another shift!
                    if (via_sr_ext_clk && via_tip && bit_counter < 4'd8) begin
                        shift_clk_div <= shift_clk_div + 1'd1;
                        if (shift_clk_div >= 8'd16) begin
                            shift_clk_div <= 8'h0;
                            cb1_out <= ~cb1_out;
                            if (!cb1_out)  // Rising edge
                                bit_counter <= bit_counter + 1'd1;
                        end
                    end else if (via_tip && bit_counter >= 4'd8) begin
                        // Finished leftover clocking (bit_counter >= 8) - hold CB1 low
                        // DON'T reset bit_counter to 0 here, or we'll start clocking again!
                        // It will be reset when we enter a new transaction (RECV_BYTE or SEND_BYTE)
                        cb1_out <= 1'b0;
                        shift_clk_div <= 8'h0;
                    end else if (!via_tip) begin
                        // TIP asserted - new transaction starting
                        // Don't reset bit_counter, let RECV_WAIT handle it
                        cb1_out <= 1'b0;
                    end else begin
                        // TIP de-asserted, not in cleanup mode - reset for next transaction
                        cb1_out <= 1'b0;
                        bit_counter <= 4'h0;
                        shift_clk_div <= 8'h0;
                    end
`ifdef VERBOSE_TRACE
                    if (wait_counter[11:0] == 12'd0)
                        $display("CUDA: IDLE wait=%d TIP=%b sr_write_seen=%b sr_ext=%b bit_cnt=%d",
                                 wait_counter, via_tip, sr_write_seen, via_sr_ext_clk, bit_counter);
`endif
                end

                ST_RECV_WAIT: begin
                    // CUDA must clock CB1 for VIA shift register (external clock mode)
                    // In mode 7 (external clock), CUDA provides CB1 clocks and VIA shifts data
                    //
                    // IMPORTANT: ROM may release TIP between bytes or even during the first byte!
                    // ROM sequence: Assert TIP -> Release TIP -> Write SR -> clock completes
                    // We must clock whenever there's data to shift, regardless of TIP state.
                    treq_reg <= 1'b0;
                    cb2_oe_reg <= 1'b0;
`ifdef VERBOSE_TRACE
                    // Debug: trace when sr_write edge is detected
                    if (via_sr_write && !via_sr_write_prev) begin
                        $display("CUDA: RECV_WAIT sr_write EDGE! TIP=%b, sr_ext_clk=%b, bit_cnt=%d, cb1=%b",
                                 via_tip, via_sr_ext_clk, bit_counter, cb1_out);
                    end
`endif
                    // Reset bit_counter on any SR write edge, regardless of current sr_write_seen value
                    // This handles the case where ROM writes a new byte before sr_write_seen was set
                    if (via_sr_write && !via_sr_write_prev) begin
                        bit_counter <= 4'h0;
                        shift_clk_div <= 8'h0;
                        cb1_out <= 1'b0;  // Start low for first rising edge
`ifdef VERBOSE_TRACE
                        $display("CUDA: RECV_WAIT resetting bit_counter for new byte");
`endif
                    end
                    // Clock when VIA is in external clock mode AND we have pending data
                    // Don't require TIP to be asserted - ROM may release it during transfer
                    else if (via_sr_ext_clk && sr_write_seen) begin
`ifdef VERBOSE_TRACE
                        if (bit_counter >= 4'd8)
                            $display("CUDA: CLOCKING - bit_cnt=%d, cb1=%b, div=%d", bit_counter, cb1_out, shift_clk_div);
`endif
                        // VIA needs 9 rising edges total:
                        //   Edge 0: VIA auto-triggers, bit_cnt=7
                        //   Edge 1-7: VIA decrements bit_cnt (7→0)
                        //   Edge 8: VIA sees bit_cnt=0, sets shift_active=0
                        // CUDA samples on edges 0-7 (8 data bits), but must provide edge 8
                        // for VIA to complete. So we clock until bit_counter=9.
                        if (bit_counter < 4'd9 || (bit_counter == 4'd9 && cb1_out)) begin
                            // Still have edges to provide
                            shift_clk_div <= shift_clk_div + 1'd1;
                            // Clock slow enough for VIA to sample on E clock edges
                            if (shift_clk_div >= 8'd16) begin
                                shift_clk_div <= 8'h0;
                                cb1_out <= ~cb1_out;

                                // VIA external clock mode timing:
                                // - VIA shifts OUT on CB1 FALLING edge (shift_tick_f)
                                // - CB2 output is always shift_reg[7]
                                // - We must sample BEFORE VIA rotates, so sample on RISING edge
                                //
                                // Edge sequence:
                                // Rising 0: Auto-trigger, sample bit7, VIA bit_cnt=7
                                // Rising 1: Sample bit6, VIA bit_cnt 7→6
                                // ...
                                // Rising 7: Sample bit0, VIA bit_cnt 1→0
                                // Rising 8: VIA sees bit_cnt=0, shift_active→0
                                //
                                // Sample on rising edge (when cb1_out was low and going high)
                                if (!cb1_out) begin  // Rising edge
                                    bit_counter <= bit_counter + 1'd1;
                                    if (bit_counter < 4'd8) begin
                                        // Sample CB2 for data bits 0-7
                                        shift_reg <= {shift_reg[6:0], via_cb2_in};
`ifdef VERBOSE_TRACE
                                        $display("CUDA: RECV_WAIT sample bit %d = %b (CB2), SR now 0x%02x",
                                                 bit_counter, via_cb2_in, {shift_reg[6:0], via_cb2_in});
`endif
                                        if (bit_counter == 4'd7) begin
                                            // Byte complete - store it
                                            recv_buf[recv_count[3:0]] <= {shift_reg[6:0], via_cb2_in};
                                            recv_count <= recv_count + 1'd1;
                                            `ifdef VERBOSE_TRACE
                                            $display("CUDA: RECV_WAIT byte[%d] = 0x%02x", recv_count, {shift_reg[6:0], via_cb2_in});
                                            `endif
                                            // DON'T clear sr_write_seen yet - need 1 more edge for VIA
                                            // Toggle BYTEACK to signal byte received
                                            byteack_reg <= ~byteack_reg;
                                        end
                                    end else if (bit_counter == 4'd8) begin
                                        // Edge 8 (bit_counter=8→9): VIA completes its shift
                                        // NOW clear sr_write_seen since we're done clocking
                                        sr_write_seen <= 1'b0;
                                    end
                                end
                            end
                        end else begin
                            // 9 edges done (8 data + 1 completion)
                            // Hold CB1 low to avoid spurious edges when next byte starts
                            cb1_out <= 1'b0;
                        end
                    end
                    // NOTE: Leftover clocking (for spurious shifts) is handled in ST_IDLE,
                    // NOT here. RECV_WAIT should only clock when sr_write_seen is true,
                    // meaning ROM has actually written a byte to send. Otherwise, we just
                    // wait for the ROM to configure VIA properly for the new transaction.
                    else begin
                        // No pending data and no leftover shift - hold CB1 low
                        cb1_out <= 1'b0;
`ifdef VERBOSE_TRACE
                        if (wait_counter[10:0] == 11'd0)
                            $display("CUDA: RECV_WAIT no-clock: ext=%b dir=%b recv=%d bit=%d sr_ws=%b",
                                     via_sr_ext_clk, via_sr_dir, recv_count, bit_counter, sr_write_seen);
`endif
                    end

                    // Wait counter for detecting end of transaction
                    // Reset only on SR write activity (not on TIP changes)
                    // This allows detecting "no more bytes coming" even with TIP asserted
                    if (via_sr_write && !via_sr_write_prev) begin
                        wait_counter <= 16'h0;
`ifdef VERBOSE_TRACE
                        if (wait_counter > 0)
                            $display("CUDA: wait_counter reset from %d (sr_write edge)", wait_counter);
`endif
                    end
                    else if (recv_count > 0 && !sr_write_seen && bit_counter >= 4'd9 && !cb1_out) begin
                        // Count when: have data, no pending write, all edges done (9 + falling)
                        wait_counter <= wait_counter + 1'd1;
`ifdef VERBOSE_TRACE
                        if (wait_counter == 16'd0 || wait_counter == 16'd1000 || wait_counter == 16'd5000)
                            $display("CUDA: wait_counter=%d, recv_cnt=%d, sr_write_seen=%b, bit_cnt=%d, cb1=%b",
                                     wait_counter, recv_count, sr_write_seen, bit_counter, cb1_out);
`endif
                    end
`ifdef VERBOSE_TRACE
                    // Debug: trace why wait_counter isn't incrementing
                    else if (recv_count > 0 && wait_counter < 16'd10) begin
                        $display("CUDA: wait_counter BLOCKED - sr_write_seen=%b, bit_cnt=%d, cb1=%b, ext_clk=%b",
                                 sr_write_seen, bit_counter, cb1_out, via_sr_ext_clk);
                    end
`endif
                end

                ST_RECV_BYTE: begin
                    // Reset bit_counter on entry (from RECV_WAIT)
                    if (prev_state == ST_RECV_WAIT) begin
                        bit_counter <= 4'h0;
                        shift_clk_div <= 8'h0;
                        cb1_out <= 1'b0;  // Start low for first rising edge
                    end else begin
                        // Clock in byte from VIA
                        shift_clk_div <= shift_clk_div + 1'd1;
                    end

                    // Clock slow enough for VIA to sample on E clock edges
                    if (prev_state != ST_RECV_WAIT && shift_clk_div >= 8'd16) begin
                        shift_clk_div <= 8'h0;
                        cb1_out <= ~cb1_out;

                        if (cb1_out) begin  // Falling edge - sample
                            shift_reg <= {shift_reg[6:0], via_cb2_in};
                            bit_counter <= bit_counter + 1'd1;

                            if (bit_counter == 4'd7) begin
                                // Byte complete - store it
                                recv_buf[recv_count[3:0]] <= {shift_reg[6:0], via_cb2_in};
                                recv_count <= recv_count + 1'd1;
                                `ifdef VERBOSE_TRACE
                                $display("CUDA: RECV byte[%d] = 0x%02x", recv_count, {shift_reg[6:0], via_cb2_in});
                                `endif
                            end
                        end
                    end
                end

                ST_PROCESS: begin
                    // Process received packet
                    // Format: [packet_type][command][data...]
                    `ifdef VERBOSE_TRACE
                    $display("CUDA: PROCESS packet - type=0x%02x cmd=0x%02x data[0]=0x%02x cnt=%d",
                             recv_buf[0], recv_buf[1], recv_buf[2], recv_count);
                    `endif

                    case (recv_buf[0])  // Packet type
                        PKT_CUDA: begin
                            // CUDA pseudo command
                            case (recv_buf[1])  // Command code
                                CUDA_AUTOPOLL: begin
                                    autopoll_enabled <= recv_buf[2][0];
                                    // Response: [ERROR_PKT][OK status]
                                    // Simplified response - ROM may expect just 2 bytes
                                    send_buf[0] <= PKT_ERROR;
                                    send_buf[1] <= 8'h00;  // OK status
                                    send_length <= 4'd2;
                                    `ifdef VERBOSE_TRACE
                                    $display("CUDA: AUTOPOLL %s", recv_buf[2][0] ? "enabled" : "disabled");
                                    `endif
                                end

                                CUDA_GET_TIME: begin
                                    // Response: [ERROR_PKT][GET_TIME][time bytes...] per MAME
                                    send_buf[0] <= PKT_ERROR;
                                    send_buf[1] <= CUDA_GET_TIME;  // Echo command
                                    send_buf[2] <= rtc_seconds[31:24];
                                    send_buf[3] <= rtc_seconds[23:16];
                                    send_buf[4] <= rtc_seconds[15:8];
                                    send_buf[5] <= rtc_seconds[7:0];
                                    send_length <= 4'd6;
`ifdef VERBOSE_TRACE
                                    $display("CUDA: GET_TIME returning 0x%08x", rtc_seconds);
`endif
                                end

                                CUDA_SET_TIME: begin
                                    rtc_seconds <= {recv_buf[2], recv_buf[3], recv_buf[4], recv_buf[5]};
                                    send_buf[0] <= PKT_ERROR;
                                    send_length <= 4'd1;
                                end

                                CUDA_GET_PRAM: begin
                                    send_buf[0] <= PKT_ERROR;
                                    send_buf[1] <= pram[recv_buf[2]];
                                    send_length <= 4'd2;
                                end

                                CUDA_SET_PRAM: begin
                                    pram[recv_buf[2]] <= recv_buf[3];
                                    send_buf[0] <= PKT_ERROR;
                                    send_length <= 4'd1;
                                end

                                CUDA_RESET_SYSTEM: begin
                                    reset_680x0 <= 1'b1;
                                    send_buf[0] <= PKT_ERROR;
                                    send_length <= 4'd1;
                                end

                                CUDA_SEND_DFAC: begin
                                    // Send data to Digital Filter Audio Chip (I2C)
                                    // Just acknowledge - we don't have actual DFAC hardware
                                    send_buf[0] <= PKT_ERROR;
                                    send_buf[1] <= 8'h00;  // OK status
                                    send_length <= 4'd2;
`ifdef VERBOSE_TRACE
                                    $display("CUDA: SEND_DFAC (I2C audio) - acknowledged");
`endif
                                end

                                CUDA_GET_DEV_LIST: begin
                                    // Return ADB device list (empty - no devices)
                                    send_buf[0] <= PKT_ERROR;
                                    send_buf[1] <= CUDA_GET_DEV_LIST;  // Echo command
                                    send_buf[2] <= 8'h00;  // No devices (bitmap)
                                    send_buf[3] <= 8'h00;
                                    send_length <= 4'd4;
`ifdef VERBOSE_TRACE
                                    $display("CUDA: GET_DEV_LIST - returning empty device list");
`endif
                                end

                                CUDA_SET_DEV_LIST: begin
                                    // Set ADB device list - acknowledge
                                    send_buf[0] <= PKT_ERROR;
                                    send_buf[1] <= 8'h00;
                                    send_length <= 4'd2;
`ifdef VERBOSE_TRACE
                                    $display("CUDA: SET_DEV_LIST - acknowledged");
`endif
                                end

                                CUDA_SET_ONE_SEC: begin
                                    // Set one-second interrupt mode
                                    // Just acknowledge - we handle RTC internally
                                    send_buf[0] <= PKT_ERROR;
                                    send_buf[1] <= 8'h00;
                                    send_length <= 4'd2;
`ifdef VERBOSE_TRACE
                                    $display("CUDA: SET_ONE_SECOND_MODE = %d", recv_buf[2]);
`endif
                                end

                                CUDA_SET_AUTO_RATE: begin
                                    // Set autopoll rate
                                    send_buf[0] <= PKT_ERROR;
                                    send_buf[1] <= 8'h00;
                                    send_length <= 4'd2;
`ifdef VERBOSE_TRACE
                                    $display("CUDA: SET_AUTO_RATE = %d", recv_buf[2]);
`endif
                                end

                                CUDA_GET_AUTO_RATE: begin
                                    // Get autopoll rate
                                    send_buf[0] <= PKT_ERROR;
                                    send_buf[1] <= CUDA_GET_AUTO_RATE;
                                    send_buf[2] <= 8'h0B;  // Default rate
                                    send_length <= 4'd3;
`ifdef VERBOSE_TRACE
                                    $display("CUDA: GET_AUTO_RATE - returning 0x0B");
`endif
                                end

                                CUDA_SET_IPL: begin
                                    // Set interrupt priority level
                                    send_buf[0] <= PKT_ERROR;
                                    send_buf[1] <= 8'h00;
                                    send_length <= 4'd2;
`ifdef VERBOSE_TRACE
                                    $display("CUDA: SET_IPL = %d", recv_buf[2]);
`endif
                                end

                                CUDA_GET_SET_IIC: begin
                                    // I2C read/write
                                    send_buf[0] <= PKT_ERROR;
                                    send_buf[1] <= 8'h00;
                                    send_length <= 4'd2;
`ifdef VERBOSE_TRACE
                                    $display("CUDA: GET_SET_IIC - acknowledged");
`endif
                                end

                                default: begin
                                    // Unknown command - just acknowledge with OK
                                    send_buf[0] <= PKT_ERROR;
                                    send_buf[1] <= 8'h00;  // Return OK to not block boot
                                    send_length <= 4'd2;
                                    `ifdef VERBOSE_TRACE
                                    $display("CUDA: Unknown CUDA cmd 0x%02x - returning OK", recv_buf[1]);
                                    `endif
                                end
                            endcase
                        end

                        PKT_ADB: begin
                            // ADB command - for now just acknowledge
                            // Real implementation would talk to ADB devices
                            send_buf[0] <= PKT_ADB;
                            send_buf[1] <= 8'h00;  // No device response
                            send_length <= 4'd2;
                            `ifdef VERBOSE_TRACE
                            $display("CUDA: ADB command 0x%02x", recv_buf[1]);
                            `endif
                        end

                        default: begin
                            // Unknown packet type
                            send_buf[0] <= PKT_ERROR;
                            send_length <= 4'd1;
                        end
                    endcase

                    send_count <= 4'h0;
                    treq_reg <= 1'b1;  // Assert TREQ to indicate we have a response
                end

                ST_SEND_WAIT: begin
                    // Keep TREQ asserted while we have data to send
                    treq_reg <= 1'b1;
                    bit_counter <= 4'h0;
                    shift_clk_div <= 8'h0;
                    // Start cb1 low so first toggle creates auto-trigger rising edge for VIA
                    cb1_out <= 1'b0;

                    // Wait counter for ROM to configure VIA before we start clocking
                    // Reset on state entry, increment each cycle
                    if (prev_state != ST_SEND_WAIT)
                        wait_counter <= 16'h0;
                    else if (!via_tip)  // Only count when TIP is asserted
                        wait_counter <= wait_counter + 1'd1;

`ifdef VERBOSE_TRACE
                    if (wait_counter[9:0] == 10'd0 && wait_counter > 0)
                        $display("CUDA: SEND_WAIT wait=%d TIP=%b sr_ext=%b sr_dir=%b sr_read=%b",
                                 wait_counter, via_tip, via_sr_ext_clk, via_sr_dir, via_sr_read);
`endif

                    // Prepare byte to send
                    if (send_count < send_length) begin
                        shift_reg <= send_buf[send_count[3:0]];
                        cb2_out_reg <= send_buf[send_count[3:0]][7];  // MSB first
                        cb2_oe_reg <= 1'b1;
                    end else begin
                        cb2_oe_reg <= 1'b0;
                    end
                end

                ST_SEND_BYTE: begin
                    cb2_oe_reg <= 1'b1;

                    // Continue clocking until bit_counter=8 AND cb1 is low (8th falling edge done)
                    if (!(bit_counter >= 4'd8 && !cb1_out)) begin
                        shift_clk_div <= shift_clk_div + 1'd1;

                        // Clock slow enough for VIA to sample on E clock edges
                        // E clock is ~clk32/40, so we need each CB1 level to last at least 40+ clk8 cycles
                        // div 16 = 16 clk8_en per toggle = 64 clk32 per toggle, ~1.5 E periods
                        if (shift_clk_div >= 8'd16) begin
                            shift_clk_div <= 8'h0;
                            cb1_out <= ~cb1_out;

                            if (cb1_out) begin  // Falling edge - inc counter, prepare next bit
                                if (bit_counter < 4'd8) begin
                                    bit_counter <= bit_counter + 1'd1;
`ifdef VERBOSE_TRACE
                                    $display("CUDA: ST_SEND_BYTE falling edge - bit_counter %d, shift_reg=0x%02x, cb2=%b",
                                             bit_counter, shift_reg, cb2_out_reg);
`endif
                                end
                                // Update CB2 for the NEXT rising edge (VIA samples on rising)
                                // At falling N, we prepare cb2 for VIA sample N+1
                                // VIA sample 0 uses initial cb2 (from SEND_DONE)
                                // VIA sample 1 uses cb2 from falling 0 = shift_reg[6] after 0 shifts
                                // ...but we haven't shifted yet at falling 0!
                                // The key: cb2 for sample N+1 = original_byte[7-N-1]
                                // So at falling N, cb2 = shift_reg[6] (which is original[6-N] after N shifts)
                                // This gives: sample 0=bit7, sample 1=bit6, ... sample 7=bit0
                                // But with current shift_reg update timing, shift_reg has been
                                // shifted N times at falling N, so shift_reg[6] = original[6-N+1] = original[7-N]
                                // which is one off. The fix: use shift_reg[7] instead of [6]
                                if (bit_counter < 4'd8) begin
                                    // Shift and update CB2 for next sample
                                    shift_reg <= {shift_reg[6:0], 1'b0};
                                    cb2_out_reg <= shift_reg[6];  // Next bit to send
                                end
                            end
                        end
                    end
                end

                ST_SEND_DONE: begin
                    cb2_oe_reg <= 1'b1;
                    cuda_sr_irq <= 1'b1;
                    bit_counter <= 4'h0;

                    // Increment send_count only on state entry (not every cycle)
                    // Use prev_state to detect first cycle in this state
                    if (prev_state == ST_SEND_BYTE) begin
                        send_count <= send_count + 1'd1;
                        wait_counter <= 16'h0;  // Reset wait counter on entry
                        // Prepare next byte if needed, or de-assert TREQ if done
                        if (send_count + 1 < send_length) begin
                            shift_reg <= send_buf[send_count[3:0] + 1];
                            cb2_out_reg <= send_buf[send_count[3:0] + 1][7];
`ifdef VERBOSE_TRACE
                            $display("CUDA: SEND_DONE byte %d sent, preparing byte %d", send_count, send_count + 1);
`endif
                        end else begin
                            // All bytes sent - de-assert TREQ immediately
                            // ROM checks TREQ between bytes to know if more data is coming
                            treq_reg <= 1'b0;
`ifdef VERBOSE_TRACE
                            $display("CUDA: SEND_DONE - all %d bytes sent, de-asserting TREQ", send_count + 1);
`endif
                        end
                    end else begin
                        // Wait for TIP re-assertion (ROM releases TIP to check TREQ)
                        wait_counter <= wait_counter + 1'd1;
`ifdef VERBOSE_TRACE
                        if (wait_counter[10:0] == 11'd0)
                            $display("CUDA: SEND_DONE wait=%d TIP=%b TREQ=%b send_cnt=%d/%d sr_read=%b",
                                     wait_counter, via_tip, treq_reg, send_count, send_length, via_sr_read);
`endif
                    end
                end

                ST_FINISH: begin
                    cb2_oe_reg <= 1'b1;  // Keep driving until fully done
                    treq_reg <= 1'b0;    // Ensure TREQ is de-asserted
                    wait_counter <= wait_counter + 1'd1;
                end
            endcase
        end
    end

endmodule
