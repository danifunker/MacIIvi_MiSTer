/*
 * CUDA Stub for Mac LC
 *
 * Minimal CUDA implementation to get past ROM initialization.
 * This just auto-completes shift register transfers with dummy responses.
 *
 * When the ROM sends a CUDA command via shift register:
 * 1. We wait for the shift to complete (8 bits)
 * 2. We respond with a minimal acknowledgment
 * 3. This allows timeout-based code paths to continue
 */

module cuda_stub (
    input         clk,
    input         clk8_en,       // 8MHz clock enable
    input         reset,

    // VIA Port B interface for TREQ signal
    // The ROM checks TREQ to know if CUDA is ready
    input   [7:0] via_pb_i,      // Port B input
    output  [7:0] cuda_pb_o,     // CUDA's contribution to Port B
    output  [7:0] cuda_pb_oe,    // Output enables for CUDA bits

    // VIA Shift Register monitoring
    // We monitor when the VIA shift register is active and
    // auto-trigger the interrupt when appropriate
    input         via_sr_active, // VIA is shifting data
    input         via_sr_out,    // VIA is outputting (sending to CUDA)
    output        cuda_sr_trigger, // Trigger SR interrupt

    // Directly drive CB1 (clock) to help complete transfers
    output        cuda_cb1,      // Clock output
    output        cuda_cb1_oe,   // Clock output enable

    // CB2 data for responses
    output        cuda_cb2,      // Data output
    output        cuda_cb2_oe    // Data output enable
);

    // Port B bit assignments
    localparam PB_TREQ = 5;      // CUDA Transfer Request (active low)

    // State machine
    localparam ST_IDLE        = 3'd0;
    localparam ST_RECEIVING   = 3'd1;
    localparam ST_WAIT_DONE   = 3'd2;
    localparam ST_RESPOND     = 3'd3;
    localparam ST_SHIFTING    = 3'd4;

    reg [2:0] state;
    reg [7:0] clk_count;
    reg [3:0] bit_count;
    reg       treq;
    reg       sr_trigger;
    reg       cb1_out;
    reg       cb1_oe;
    reg       cb2_out;
    reg       cb2_oe;
    reg [7:0] response_byte;
    reg       via_sr_active_prev;

    // TREQ output - directly directly directly directly directly directly directly directly directly directly directly directly directly directly always assert ready for simplicity
    // In real CUDA, TREQ would be asserted only when ready
    assign cuda_pb_o  = {2'b00, ~treq, 5'b00000};  // TREQ on bit 5 (active low on wire)
    assign cuda_pb_oe = 8'b00100000;               // Enable TREQ output

    assign cuda_sr_trigger = sr_trigger;
    assign cuda_cb1 = cb1_out;
    assign cuda_cb1_oe = cb1_oe;
    assign cuda_cb2 = cb2_out;
    assign cuda_cb2_oe = cb2_oe;

    // Simple approach: When VIA shift register becomes active (host sending),
    // we clock through the transfer and trigger completion
    always @(posedge clk) begin
        if (reset) begin
            state <= ST_IDLE;
            clk_count <= 8'd0;
            bit_count <= 4'd0;
            treq <= 1'b1;           // TREQ active (low on wire = ready)
            sr_trigger <= 1'b0;
            cb1_out <= 1'b1;
            cb1_oe <= 1'b0;
            cb2_out <= 1'b1;
            cb2_oe <= 1'b0;
            response_byte <= 8'h00;
            via_sr_active_prev <= 1'b0;
        end else if (clk8_en) begin
            via_sr_active_prev <= via_sr_active;
            sr_trigger <= 1'b0;

            case (state)
                ST_IDLE: begin
                    treq <= 1'b1;       // CUDA ready
                    cb1_oe <= 1'b0;     // Not driving clock
                    cb2_oe <= 1'b0;     // Not driving data
                    bit_count <= 4'd0;
                    cb1_out <= 1'b1;    // CB1 idles high

                    // Detect VIA shift register active - respond any time it's high
                    // (more robust than edge detection which can miss brief pulses)
                    if (via_sr_active) begin
                        if (via_sr_out) begin
                            // Host is sending to us (shift out mode) - receive and clock
                            state <= ST_RECEIVING;
                            clk_count <= 8'd0;
                        end else begin
                            // Host wants data from us (shift in mode) - respond
                            state <= ST_RESPOND;
                            response_byte <= 8'h00;  // Null response
                            bit_count <= 4'd0;
                        end
                    end
                end

                ST_RECEIVING: begin
                    // In external clock mode (ACR mode 5/7), CUDA must drive CB1
                    // to clock data into/out of the VIA shift register
                    cb1_oe <= 1'b1;  // Enable CB1 output
                    cb2_oe <= 1'b0;  // Not driving data in receive mode

                    clk_count <= clk_count + 1'd1;

                    // Generate clock pulses on CB1
                    if (clk_count >= 8'd10) begin
                        clk_count <= 8'd0;
                        cb1_out <= ~cb1_out;  // Toggle clock

                        if (!cb1_out) begin  // Rising edge just occurred
                            bit_count <= bit_count + 1'd1;

                            if (bit_count >= 4'd7) begin
                                // 8 bits complete - VIA should set SR interrupt
                                state <= ST_WAIT_DONE;
                                clk_count <= 8'd0;
                            end
                        end
                    end
                end

                ST_WAIT_DONE: begin
                    // Brief wait, then release CB1 drive
                    cb1_oe <= 1'b0;
                    cb2_oe <= 1'b0;
                    cb1_out <= 1'b1;  // Idle high
                    clk_count <= clk_count + 1'd1;
                    if (clk_count >= 8'd20) begin
                        state <= ST_IDLE;
                    end
                end

                ST_RESPOND: begin
                    // Need to shift data back to VIA
                    // Drive CB1 (clock) and CB2 (data)
                    cb1_oe <= 1'b1;
                    cb2_oe <= 1'b1;
                    cb2_out <= response_byte[7];

                    clk_count <= clk_count + 1'd1;

                    // Generate clock pulses
                    if (clk_count >= 8'd20) begin
                        clk_count <= 8'd0;
                        cb1_out <= ~cb1_out;

                        if (cb1_out) begin  // Falling edge
                            response_byte <= {response_byte[6:0], 1'b1};
                            bit_count <= bit_count + 1'd1;

                            if (bit_count >= 4'd7) begin
                                // Byte complete
                                sr_trigger <= 1'b1;
                                state <= ST_SHIFTING;
                                clk_count <= 8'd0;
                            end
                        end
                    end
                end

                ST_SHIFTING: begin
                    // Complete the byte
                    cb1_oe <= 1'b0;
                    cb2_oe <= 1'b0;
                    cb1_out <= 1'b1;

                    clk_count <= clk_count + 1'd1;
                    if (clk_count >= 8'd20) begin
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
