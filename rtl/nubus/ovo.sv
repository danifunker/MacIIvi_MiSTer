// Text Overlay Module (SystemVerilog port of ovo.vhd)
// Overlays text on existing VGA signal

module ovo #(
    parameter COLS = 40,
    parameter LINES = 1,
    parameter [23:0] RGB = 24'hFFFF00  // Yellow
) (
    // VGA IN
    input [7:0] i_r,
    input [7:0] i_g,
    input [7:0] i_b,
    input i_hs,
    input i_vs,
    input i_de,
    input i_clk,

    // VGA OUT
    output reg [7:0] o_r,
    output reg [7:0] o_g,
    output reg [7:0] o_b,
    output reg o_hs,
    output reg o_vs,
    output reg o_de,

    // Control
    input ena,  // Overlay ON/OFF

    // Text input - array of character codes (A=0, B=1, etc.)
    input [7:0] text_in [0:COLS-1],
    input [5:0] text_len
);

    // 8x8 Font ROM (A-Z, space, punctuation)
    function [7:0] get_font_row;
        input [7:0] char_code;
        input [2:0] row;
        begin
            case (char_code)
                8'd0:  get_font_row = (row == 3'd1) ? 8'b01111110 : (row == 3'd2) ? 8'b11000011 : (row == 3'd3) ? 8'b11000011 : (row == 3'd4) ? 8'b11111111 : (row == 3'd5) ? 8'b11000011 : (row == 3'd6) ? 8'b11000011 : 8'b00000000; // A
                8'd1:  get_font_row = (row == 3'd1) ? 8'b11111110 : (row == 3'd2) ? 8'b11000011 : (row == 3'd3) ? 8'b11111110 : (row == 3'd4) ? 8'b11111110 : (row == 3'd5) ? 8'b11000011 : (row == 3'd6) ? 8'b11111110 : 8'b00000000; // B
                8'd2:  get_font_row = (row == 3'd1) ? 8'b01111110 : (row == 3'd2) ? 8'b11000000 : (row == 3'd3) ? 8'b11000000 : (row == 3'd4) ? 8'b11000000 : (row == 3'd5) ? 8'b11000000 : (row == 3'd6) ? 8'b01111110 : 8'b00000000; // C
                8'd3:  get_font_row = (row == 3'd1) ? 8'b11111100 : (row == 3'd2) ? 8'b11000110 : (row == 3'd3) ? 8'b11000011 : (row == 3'd4) ? 8'b11000011 : (row == 3'd5) ? 8'b11000110 : (row == 3'd6) ? 8'b11111100 : 8'b00000000; // D
                8'd4:  get_font_row = (row == 3'd1) ? 8'b11111111 : (row == 3'd2) ? 8'b11000000 : (row == 3'd3) ? 8'b11111100 : (row == 3'd4) ? 8'b11111100 : (row == 3'd5) ? 8'b11000000 : (row == 3'd6) ? 8'b11111111 : 8'b00000000; // E
                8'd5:  get_font_row = (row == 3'd1) ? 8'b11111111 : (row == 3'd2) ? 8'b11000000 : (row == 3'd3) ? 8'b11111100 : (row == 3'd4) ? 8'b11111100 : (row == 3'd5) ? 8'b11000000 : (row == 3'd6) ? 8'b11000000 : 8'b00000000; // F
                8'd6:  get_font_row = (row == 3'd1) ? 8'b01111110 : (row == 3'd2) ? 8'b11000000 : (row == 3'd3) ? 8'b11001111 : (row == 3'd4) ? 8'b11000011 : (row == 3'd5) ? 8'b11000011 : (row == 3'd6) ? 8'b01111110 : 8'b00000000; // G
                8'd7:  get_font_row = (row == 3'd1) ? 8'b11000011 : (row == 3'd2) ? 8'b11000011 : (row == 3'd3) ? 8'b11111111 : (row == 3'd4) ? 8'b11111111 : (row == 3'd5) ? 8'b11000011 : (row == 3'd6) ? 8'b11000011 : 8'b00000000; // H
                8'd8:  get_font_row = (row == 3'd1) ? 8'b01111110 : (row == 3'd2) ? 8'b00011000 : (row == 3'd3) ? 8'b00011000 : (row == 3'd4) ? 8'b00011000 : (row == 3'd5) ? 8'b00011000 : (row == 3'd6) ? 8'b01111110 : 8'b00000000; // I
                8'd9:  get_font_row = (row == 3'd1) ? 8'b00011111 : (row == 3'd2) ? 8'b00000110 : (row == 3'd3) ? 8'b00000110 : (row == 3'd4) ? 8'b11000110 : (row == 3'd5) ? 8'b11000110 : (row == 3'd6) ? 8'b01111100 : 8'b00000000; // J
                8'd10: get_font_row = (row == 3'd1) ? 8'b11000110 : (row == 3'd2) ? 8'b11001100 : (row == 3'd3) ? 8'b11111000 : (row == 3'd4) ? 8'b11111000 : (row == 3'd5) ? 8'b11001100 : (row == 3'd6) ? 8'b11000110 : 8'b00000000; // K
                8'd11: get_font_row = (row == 3'd1) ? 8'b11000000 : (row == 3'd2) ? 8'b11000000 : (row == 3'd3) ? 8'b11000000 : (row == 3'd4) ? 8'b11000000 : (row == 3'd5) ? 8'b11000000 : (row == 3'd6) ? 8'b11111111 : 8'b00000000; // L
                8'd12: get_font_row = (row == 3'd1) ? 8'b11000011 : (row == 3'd2) ? 8'b11100111 : (row == 3'd3) ? 8'b11111111 : (row == 3'd4) ? 8'b11011011 : (row == 3'd5) ? 8'b11000011 : (row == 3'd6) ? 8'b11000011 : 8'b00000000; // M
                8'd13: get_font_row = (row == 3'd1) ? 8'b11000011 : (row == 3'd2) ? 8'b11100011 : (row == 3'd3) ? 8'b11110011 : (row == 3'd4) ? 8'b11011011 : (row == 3'd5) ? 8'b11001111 : (row == 3'd6) ? 8'b11000111 : 8'b00000000; // N
                8'd14: get_font_row = (row == 3'd1) ? 8'b01111110 : (row == 3'd2) ? 8'b11000011 : (row == 3'd3) ? 8'b11000011 : (row == 3'd4) ? 8'b11000011 : (row == 3'd5) ? 8'b11000011 : (row == 3'd6) ? 8'b01111110 : 8'b00000000; // O
                8'd15: get_font_row = (row == 3'd1) ? 8'b11111110 : (row == 3'd2) ? 8'b11000011 : (row == 3'd3) ? 8'b11111110 : (row == 3'd4) ? 8'b11111110 : (row == 3'd5) ? 8'b11000000 : (row == 3'd6) ? 8'b11000000 : 8'b00000000; // P
                8'd16: get_font_row = (row == 3'd1) ? 8'b01111110 : (row == 3'd2) ? 8'b11000011 : (row == 3'd3) ? 8'b11000011 : (row == 3'd4) ? 8'b11011011 : (row == 3'd5) ? 8'b11001111 : (row == 3'd6) ? 8'b01111111 : 8'b00000000; // Q
                8'd17: get_font_row = (row == 3'd1) ? 8'b11111110 : (row == 3'd2) ? 8'b11000011 : (row == 3'd3) ? 8'b11111110 : (row == 3'd4) ? 8'b11111000 : (row == 3'd5) ? 8'b11001100 : (row == 3'd6) ? 8'b11000110 : 8'b00000000; // R
                8'd18: get_font_row = (row == 3'd1) ? 8'b01111110 : (row == 3'd2) ? 8'b11000000 : (row == 3'd3) ? 8'b01111110 : (row == 3'd4) ? 8'b01111110 : (row == 3'd5) ? 8'b00000011 : (row == 3'd6) ? 8'b01111110 : 8'b00000000; // S
                8'd19: get_font_row = (row == 3'd1) ? 8'b11111111 : (row == 3'd2) ? 8'b00011000 : (row == 3'd3) ? 8'b00011000 : (row == 3'd4) ? 8'b00011000 : (row == 3'd5) ? 8'b00011000 : (row == 3'd6) ? 8'b00011000 : 8'b00000000; // T
                8'd20: get_font_row = (row == 3'd1) ? 8'b11000011 : (row == 3'd2) ? 8'b11000011 : (row == 3'd3) ? 8'b11000011 : (row == 3'd4) ? 8'b11000011 : (row == 3'd5) ? 8'b11000011 : (row == 3'd6) ? 8'b01111110 : 8'b00000000; // U
                8'd21: get_font_row = (row == 3'd1) ? 8'b11000011 : (row == 3'd2) ? 8'b11000011 : (row == 3'd3) ? 8'b11000011 : (row == 3'd4) ? 8'b01100110 : (row == 3'd5) ? 8'b00111100 : (row == 3'd6) ? 8'b00011000 : 8'b00000000; // V
                8'd22: get_font_row = (row == 3'd1) ? 8'b11000011 : (row == 3'd2) ? 8'b11000011 : (row == 3'd3) ? 8'b11011011 : (row == 3'd4) ? 8'b11111111 : (row == 3'd5) ? 8'b11100111 : (row == 3'd6) ? 8'b11000011 : 8'b00000000; // W
                8'd23: get_font_row = (row == 3'd1) ? 8'b11000011 : (row == 3'd2) ? 8'b01100110 : (row == 3'd3) ? 8'b00111100 : (row == 3'd4) ? 8'b00111100 : (row == 3'd5) ? 8'b01100110 : (row == 3'd6) ? 8'b11000011 : 8'b00000000; // X
                8'd24: get_font_row = (row == 3'd1) ? 8'b11000011 : (row == 3'd2) ? 8'b01100110 : (row == 3'd3) ? 8'b00111100 : (row == 3'd4) ? 8'b00011000 : (row == 3'd5) ? 8'b00011000 : (row == 3'd6) ? 8'b00011000 : 8'b00000000; // Y
                8'd25: get_font_row = (row == 3'd1) ? 8'b11111111 : (row == 3'd2) ? 8'b00000110 : (row == 3'd3) ? 8'b00001100 : (row == 3'd4) ? 8'b00011000 : (row == 3'd5) ? 8'b00110000 : (row == 3'd6) ? 8'b11111111 : 8'b00000000; // Z
                8'd26: get_font_row = 8'b00000000; // Space
                8'd27: get_font_row = (row == 3'd6) ? 8'b00011000 : (row == 3'd5) ? 8'b00011000 : (row == 3'd3) ? 8'b00011000 : (row == 3'd2) ? 8'b00011000 : (row == 3'd1) ? 8'b00011000 : 8'b00000000; // !
                8'd28: get_font_row = (row == 3'd1) ? 8'b00011000 : (row == 3'd2) ? 8'b00011000 : (row == 3'd3) ? 8'b00011000 : (row == 3'd4) ? 8'b00011000 : (row == 3'd6) ? 8'b00011000 : 8'b00000000; // :
                default: get_font_row = 8'b00000000;
            endcase
        end
    endfunction

    // Pipeline registers (2-cycle delay like ovo.vhd)
    reg [7:0] t_r, t_g, t_b;
    reg t_hs, t_vs, t_de;

    // Counters
    reg [11:0] hcpt, vcpt;
    reg de_seen;

    // Latched text input
    reg [7:0] text_latched [0:COLS-1];
    reg [5:0] len_latched;

    // Font rendering
    wire [8:0] char_x_full = hcpt[11:3];  // Which character (full width)
    wire [5:0] char_x = char_x_full[5:0]; // Truncated to 6 bits (0-63)
    wire [2:0] char_px = hcpt[2:0];       // Which pixel within character
    wire [2:0] char_row = vcpt[2:0];      // Which row within character
    wire [7:0] current_char = (char_x < len_latched) ? text_latched[char_x] : 8'd26;
    wire [7:0] font_row = get_font_row(current_char, char_row);
    wire text_pixel = font_row[7 - char_px];

    // Text area detection (bottom of screen, adjustable via LINES parameter)
    // Position at scanlines 472-479 (last 8 lines of 480 visible)
    localparam V_RES = 480;  // Assume 480p video
    wire in_text_area = (hcpt < COLS * 8) && (vcpt >= (V_RES - LINES * 8)) && (vcpt < V_RES);
    wire [2:0] text_row_offset = vcpt[2:0];  // Row within text area

    always @(posedge i_clk) begin
        // Propagate VGA signals (2-cycle delay)
        t_r <= i_r;
        t_g <= i_g;
        t_b <= i_b;
        t_hs <= i_hs;
        t_vs <= i_vs;
        t_de <= i_de;

        o_r <= t_r;
        o_g <= t_g;
        o_b <= t_b;
        o_hs <= t_hs;
        o_vs <= t_vs;
        o_de <= t_de;

        // Latch text input during vsync
        if (i_vs) begin
            integer i;
            for (i = 0; i < COLS; i = i + 1) begin
                text_latched[i] <= text_in[i];
            end
            len_latched <= text_len;
        end

        // Vertical counter
        if (i_vs) begin
            vcpt <= 12'd0;
            de_seen <= 1'b0;
        end else if (i_hs && !t_hs && de_seen) begin
            vcpt <= vcpt + 12'd1;
        end

        // Horizontal counter
        if (i_hs) begin
            hcpt <= 12'd0;
        end else if (i_de) begin
            hcpt <= hcpt + 12'd1;
            de_seen <= 1'b1;
        end


        // Insert overlay
        if (ena && in_text_area && text_pixel) begin
            o_r <= RGB[23:16];
            o_g <= RGB[15:8];
            o_b <= RGB[7:0];
        end
    end

endmodule
