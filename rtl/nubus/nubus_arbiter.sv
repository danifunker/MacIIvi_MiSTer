// NuBus Arbiter / Empty-Slot Handler
//
// Sits between the address decoder (selectNuBus) and the CPU data path.
// Handles the response for NuBus addresses where no card responds.
//
// On real Mac II hardware, a NuBus timeout (~25us) generates a bus error.
// The Slot Manager installs a bus error handler before probing, so empty
// slots are detected via the exception.
//
// This module generates BERR for empty NuBus slots after a configurable
// timeout, matching real hardware behavior. The timeout is set to match
// the system BERR counter (~251 system clocks ≈ 8 µs at 31.3344 MHz).

module nubus_arbiter (
    input         clk,
    input         _cpuAS,         // active-low address strobe
    input  [31:0] cpuAddr,        // full 32-bit CPU address
    input         selectNuBus,    // address decoder says this is NuBus space

    // Card interface — directly from the NuBus card(s)
    input  [15:0] card_data_out,  // data from card
    input         card_ack_n,     // active-low ACK from card (1 = not responding)

    // Outputs to CPU data path
    output [15:0] data_out,       // card data (no fake data for empty slots)
    output        ack_n,          // card ACK (no fake ACK for empty slots)
    output        acked,          // true when a real NuBus card has responded
    output        berr            // bus error for empty slot timeout
);

    // Detect when NuBus is selected but no card responds
    wire no_card = selectNuBus & card_ack_n;

    // Timeout counter for empty-slot bus error.
    // Real NuBus timeout is ~25us. We fire BERR faster (~8us / 260 clocks)
    // to match the system BERR counter timing, but we keep this self-contained.
    reg [8:0] timeout;
    always @(posedge clk) begin
        if (_cpuAS)
            timeout <= 0;
        else if (no_card && !timeout[8])
            timeout <= timeout + 1'd1;
    end

    // Fire BERR after ~260 system clocks with no card response
    wire timeout_berr = no_card && (timeout >= 9'd260);

    // Pass through card signals directly — no fake data for empty slots
    assign data_out = card_data_out;
    assign ack_n    = card_ack_n;

    // Only real card responses count as acked (prevents BERR counter reset)
    assign acked = selectNuBus & ~card_ack_n;

    // BERR output: asserted when empty slot times out
    assign berr = timeout_berr;

    // synthesis translate_off
    // Debug: log empty-slot bus errors (first 200)
    reg [7:0] dbg_cnt;
    initial dbg_cnt = 0;
    always @(posedge clk) begin
        if (timeout_berr && timeout == 9'd260 && dbg_cnt < 200) begin
            $display("NUBUS_BERR: addr=%h slot=%h",
                cpuAddr, cpuAddr[27:24]);
            dbg_cnt <= dbg_cnt + 1;
        end
    end
    // synthesis translate_on

endmodule
