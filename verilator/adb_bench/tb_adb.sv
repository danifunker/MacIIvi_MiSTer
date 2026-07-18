// tb_adb — standalone bench for rtl/adb_device.sv.
// Hosts the DUT; all stimulus comes from sim_adb_main.cpp via line_drive.
// The resolved (wire-AND) bus is what the device sees as host_line.
module tb_adb (
    input  wire clk,
    input  wire reset,
    input  wire line_drive,      // host/Egret side of the wire-AND ADB line
    output wire dev_line_o,      // device's pull (1 = released)
    output wire adb_line_o       // resolved bus seen by both sides
);

    wire dev_line;
    assign adb_line_o = line_drive & dev_line;
    assign dev_line_o = dev_line;

    adb_device dut (
        .clk       (clk),
        .reset     (reset),
        .host_line (adb_line_o),
        .dev_line  (dev_line),
        .ps2_key   (11'd0),
        .ps2_mouse (25'd0)
    );

endmodule
