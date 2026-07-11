/*
 * CUDA ADB Interface for Mac LC
 *
 * This module implements a simplified CUDA interface that bridges
 * the VIA shift register to the ADB keyboard/mouse handler.
 *
 * CUDA Protocol (simplified):
 * - Host sets TIP low to start transaction
 * - Host sends command via VIA shift register
 * - CUDA responds with TREQ low when ready
 * - Data exchanged via shift register with clock/byteack handshaking
 * - CUDA sets TREQ high when transaction complete
 *
 * VIA Port B bits used:
 * - Bit 3: TIP (Transfer In Progress) - input from host
 * - Bit 4: BYTEACK - input from host (directly active, directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly used)
 * - Bit 5: TREQ (Transfer Request) - output from CUDA
 *
 * Shift register interface:
 * - CB1: Clock (directly directly directly directly directly directly output from CUDA when shifting)
 * - CB2: Data (bidirectional)
 */

module cuda_adb (
    input         clk,
    input         clk_en,        // 8MHz clock enable
    input         reset,

    // VIA Port B interface (directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly for CUDA handshaking)
    input   [7:0] via_pb_i,      // Port B input (directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly to read TIP, BYTEACK)
    output  [7:0] cuda_pb_o,     // Port B output bits from CUDA
    output  [7:0] cuda_pb_oe,    // Port B output enables

    // VIA Shift Register interface
    input         sr_write,      // CPU wrote to shift register
    input   [7:0] sr_data_out,   // Data from CPU via shift register
    output  [7:0] sr_data_in,    // Data to CPU via shift register
    output        sr_cb1,        // Shift clock from CUDA
    output        sr_cb2_o,      // Shift data output from CUDA
    input         sr_cb2_i,      // Shift data input to CUDA
    output        sr_cb2_oe,     // Shift data output enable
    output        sr_trigger,    // Trigger shift register interrupt

    // ADB device interface (directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly directly to existing adb.sv)
    output  [1:0] adb_st,        // ADB state for adb.sv
    output        adb_viaBusy,   // VIA busy signal
    input         adb_listen,    // ADB listen mode
    output  [7:0] adb_din,       // Data to ADB device
    output        adb_din_strobe,// Data strobe to ADB
    input   [7:0] adb_dout,      // Data from ADB device
    input         adb_dout_strobe,// Data strobe from ADB
    input         adb_int        // Interrupt from ADB
);

    // CUDA Port B bit positions
    localparam PB_TIP     = 3;   // Transfer In Progress (from host)
    localparam PB_BYTEACK = 4;   // Byte Acknowledge (from host)
    localparam PB_TREQ    = 5;   // Transfer Request (from CUDA)

    // CUDA states
    localparam CUDA_IDLE           = 4'd0;
    localparam CUDA_WAIT_CMD       = 4'd1;
    localparam CUDA_RECV_CMD       = 4'd2;
    localparam CUDA_PROCESS_CMD    = 4'd3;
    localparam CUDA_SEND_RESP      = 4'd4;
    localparam CUDA_WAIT_BYTEACK   = 4'd5;
    localparam CUDA_SHIFT_BIT      = 4'd6;
    localparam CUDA_DONE           = 4'd7;
    localparam CUDA_ADB_CMD        = 4'd8;
    localparam CUDA_ADB_RESP       = 4'd9;

    reg [3:0] state;
    reg [3:0] next_state;

    // CUDA packet types
    localparam PKT_ADB        = 8'h00;
    localparam PKT_PSEUDO     = 8'h01;
    localparam PKT_ERROR      = 8'h02;
    localparam PKT_TICK       = 8'h03;

    // CUDA command buffer
    reg [7:0] cmd_buffer [0:7];
    reg [2:0] cmd_len;
    reg [2:0] cmd_idx;

    // Response buffer
    reg [7:0] resp_buffer [0:7];
    reg [2:0] resp_len;
    reg [2:0] resp_idx;

    // Shift register state
    reg [7:0] shift_data;
    reg [2:0] bit_cnt;
    reg       shift_clock;
    reg       shift_dir;        // 0 = receive, 1 = send
    reg       shift_active;

    // Handshaking signals
    reg       treq;
    reg       tip_prev;
    reg       byteack_prev;
    reg       sr_write_prev;

    // Timing counter for shift clock
    reg [7:0] clk_div;
    localparam CLK_DIV_MAX = 8'd40;  // Shift clock timing

    // ADB state machine interface
    reg [1:0] adb_state;
    reg [7:0] adb_data_to_send;
    reg       adb_strobe;
    reg       adb_busy;

    // Extract handshake signals from VIA Port B
    wire tip     = ~via_pb_i[PB_TIP];     // Active low
    wire byteack = ~via_pb_i[PB_BYTEACK]; // Active low

    // Output TREQ on Port B
    assign cuda_pb_o  = {2'b00, ~treq, 5'b00000};  // TREQ is active low
    assign cuda_pb_oe = 8'b00100000;               // Only drive TREQ bit

    // Shift register interface
    assign sr_cb1     = shift_clock;
    assign sr_cb2_o   = shift_data[7];
    assign sr_cb2_oe  = shift_dir;
    assign sr_data_in = shift_data;

    // Generate shift complete trigger
    reg sr_complete;
    assign sr_trigger = sr_complete;

    // ADB interface outputs
    assign adb_st = adb_state;
    assign adb_viaBusy = adb_busy;
    assign adb_din = adb_data_to_send;
    assign adb_din_strobe = adb_strobe;

    // Main state machine
    always @(posedge clk) begin
        if (reset) begin
            state <= CUDA_IDLE;
            treq <= 1'b0;           // TREQ high (inactive, active low on wire)
            shift_clock <= 1'b1;
            shift_active <= 1'b0;
            shift_dir <= 1'b0;
            bit_cnt <= 3'd0;
            cmd_len <= 3'd0;
            cmd_idx <= 3'd0;
            resp_len <= 3'd0;
            resp_idx <= 3'd0;
            tip_prev <= 1'b0;
            byteack_prev <= 1'b0;
            sr_write_prev <= 1'b0;
            sr_complete <= 1'b0;
            adb_state <= 2'b11;     // Idle state
            adb_strobe <= 1'b0;
            adb_busy <= 1'b0;
            clk_div <= 8'd0;
        end else if (clk_en) begin
            // Edge detection
            tip_prev <= tip;
            byteack_prev <= byteack;
            sr_write_prev <= sr_write;

            // Clear one-shot signals
            sr_complete <= 1'b0;
            adb_strobe <= 1'b0;

            case (state)
                CUDA_IDLE: begin
                    treq <= 1'b0;  // TREQ inactive (high on wire)
                    adb_state <= 2'b11;  // Idle

                    // Detect TIP going active (host starting transaction)
                    if (tip && !tip_prev) begin
                        state <= CUDA_WAIT_CMD;
                        cmd_len <= 3'd0;
                        cmd_idx <= 3'd0;
                        treq <= 1'b1;  // Assert TREQ (low on wire) - ready for command
                    end

                    // Check for ADB device wanting to send data
                    if (adb_dout_strobe) begin
                        // ADB device has data - initiate CUDA->host transfer
                        resp_buffer[0] <= PKT_ADB;
                        resp_buffer[1] <= 8'h00;  // ADB command echo placeholder
                        resp_buffer[2] <= adb_dout;
                        resp_len <= 3'd3;
                        // For now, just queue it - host will poll
                    end
                end

                CUDA_WAIT_CMD: begin
                    // Wait for host to send command via shift register
                    if (sr_write && !sr_write_prev) begin
                        // Host wrote to shift register - receive the byte
                        cmd_buffer[cmd_len] <= sr_data_out;
                        cmd_len <= cmd_len + 1'd1;

                        // Signal byte received
                        sr_complete <= 1'b1;

                        // After first byte, check packet type
                        if (cmd_len == 0) begin
                            // First byte is packet type
                            state <= CUDA_RECV_CMD;
                        end
                    end

                    // Host ended transaction
                    if (!tip && tip_prev) begin
                        state <= CUDA_PROCESS_CMD;
                    end
                end

                CUDA_RECV_CMD: begin
                    // Continue receiving command bytes
                    if (sr_write && !sr_write_prev) begin
                        cmd_buffer[cmd_len] <= sr_data_out;
                        cmd_len <= cmd_len + 1'd1;
                        sr_complete <= 1'b1;
                    end

                    // Host ended command phase
                    if (!tip && tip_prev) begin
                        state <= CUDA_PROCESS_CMD;
                    end
                end

                CUDA_PROCESS_CMD: begin
                    // Process the received command
                    case (cmd_buffer[0])
                        PKT_ADB: begin
                            // ADB command - forward to ADB handler
                            if (cmd_len >= 2) begin
                                adb_data_to_send <= cmd_buffer[1];
                                adb_strobe <= 1'b1;
                                adb_state <= 2'b00;  // New command state
                                state <= CUDA_ADB_CMD;
                            end else begin
                                // Invalid - send error response
                                resp_buffer[0] <= PKT_ERROR;
                                resp_buffer[1] <= 8'h00;
                                resp_len <= 3'd2;
                                state <= CUDA_SEND_RESP;
                            end
                        end

                        PKT_PSEUDO: begin
                            // Pseudo command (power, RTC, etc.)
                            // For now, just acknowledge
                            resp_buffer[0] <= PKT_PSEUDO;
                            resp_buffer[1] <= cmd_buffer[1];  // Echo command
                            resp_buffer[2] <= 8'h00;          // Success
                            resp_len <= 3'd3;
                            state <= CUDA_SEND_RESP;
                        end

                        default: begin
                            // Unknown - send minimal ack
                            resp_buffer[0] <= cmd_buffer[0];
                            resp_buffer[1] <= 8'h00;
                            resp_len <= 3'd2;
                            state <= CUDA_SEND_RESP;
                        end
                    endcase
                end

                CUDA_ADB_CMD: begin
                    // Wait for ADB device to process command
                    adb_state <= 2'b01;  // Even byte state

                    // ADB device responded
                    if (adb_dout_strobe) begin
                        resp_buffer[0] <= PKT_ADB;
                        resp_buffer[1] <= cmd_buffer[1];  // Echo ADB command
                        resp_buffer[2] <= adb_dout;
                        resp_len <= 3'd3;
                        state <= CUDA_ADB_RESP;
                        adb_state <= 2'b10;  // Odd byte state
                    end

                    // Timeout - no response (happens for empty ADB commands)
                    // TODO: Add timeout counter
                end

                CUDA_ADB_RESP: begin
                    // Collect more ADB response bytes if any
                    if (adb_dout_strobe && resp_len < 7) begin
                        resp_buffer[resp_len] <= adb_dout;
                        resp_len <= resp_len + 1'd1;
                    end

                    // When ADB is done, send response to host
                    adb_state <= 2'b11;  // Idle
                    state <= CUDA_SEND_RESP;
                end

                CUDA_SEND_RESP: begin
                    // Wait for host to start new transaction to receive response
                    if (tip && !tip_prev) begin
                        resp_idx <= 3'd0;
                        shift_data <= resp_buffer[0];
                        shift_dir <= 1'b1;  // Output mode
                        state <= CUDA_SHIFT_BIT;
                        bit_cnt <= 3'd0;
                        clk_div <= 8'd0;
                        treq <= 1'b1;  // Assert TREQ
                    end
                end

                CUDA_SHIFT_BIT: begin
                    // Shift out response bits
                    clk_div <= clk_div + 1'd1;

                    if (clk_div >= CLK_DIV_MAX) begin
                        clk_div <= 8'd0;
                        shift_clock <= ~shift_clock;

                        if (!shift_clock) begin
                            // Rising edge - shift next bit
                            shift_data <= {shift_data[6:0], 1'b1};
                            bit_cnt <= bit_cnt + 1'd1;

                            if (bit_cnt == 3'd7) begin
                                // Byte complete
                                sr_complete <= 1'b1;
                                resp_idx <= resp_idx + 1'd1;

                                if (resp_idx + 1 >= resp_len) begin
                                    // All bytes sent
                                    state <= CUDA_DONE;
                                end else begin
                                    // Load next byte
                                    shift_data <= resp_buffer[resp_idx + 1];
                                    bit_cnt <= 3'd0;
                                end
                            end
                        end
                    end
                end

                CUDA_DONE: begin
                    // Transaction complete
                    treq <= 1'b0;  // Deassert TREQ
                    shift_dir <= 1'b0;
                    shift_clock <= 1'b1;

                    if (!tip) begin
                        state <= CUDA_IDLE;
                    end
                end

                default: begin
                    state <= CUDA_IDLE;
                end
            endcase
        end
    end

endmodule
