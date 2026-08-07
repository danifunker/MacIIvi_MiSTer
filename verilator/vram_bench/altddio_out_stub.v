// minimal altddio_out stub for bench use: sd_clk = inverted outclock
// (datain_h=0 at rising, datain_l=1 at falling -> output rises at the
// falling edge of outclock, matching the real half-cycle shift)
module altddio_out #(
    parameter extend_oe_disable = "OFF",
    parameter intended_device_family = "Cyclone V",
    parameter invert_output = "OFF",
    parameter lpm_hint = "UNUSED",
    parameter lpm_type = "altddio_out",
    parameter oe_reg = "UNREGISTERED",
    parameter power_up_high = "OFF",
    parameter width = 1
)(
    input  [width-1:0] datain_h,
    input  [width-1:0] datain_l,
    input              outclock,
    output [width-1:0] dataout,
    input              aclr,
    input              aset,
    input              oe,
    input              outclocken,
    input              sclr,
    input              sset
);
    reg [width-1:0] q_h, q_l;
    always @(posedge outclock) q_h <= datain_h;
    always @(negedge outclock) q_l <= datain_l;
    assign dataout = outclock ? q_h : q_l;
endmodule
