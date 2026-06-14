//============================================================================
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;  

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v" 
localparam CONF_STR = {
	"MacIIvi;UART57600:115200;",
	"-;",
	"F1,DSKIMG,Mount Pri Floppy;",
	"F2,DSKIMG,Mount Sec Floppy;",
	"-;",
	"SC0,IMGVHDHDA,Mount SCSI-6;",
	"SC1,IMGVHDHDA,Mount SCSI-5;",
	"SC2,NVR,Mount PRAM;",
	"-;",
	// Built-in VASP video locked to 640x480 (no Monitor selector, unlike MacLC's
	// 640x480 / 512x384 choice). 512 KB VRAM; aspect ratio still frames HDMI.
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[8],CPU Speed,16 MHz,32 MHz;",
	// RAM = 4 MB on-board + SIMMs (20=+16, 36=+32, 68=+64 MB). 36/68 not yet
	// validated -> keep the 2-choice line active; swap in the 4-choice line later.
	//"O[11:10],Memory,4MB,20MB,36MB,68MB;",
	"O[11:10],Memory,4MB,20MB;",
	"-;",
	"R[5],Interrupt (NMI / MacsBug);",
	"R[6],Reset PRAM & Core;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"v,0;", // [optional] config version 0-99. 
	        // If CONF_STR options are changed in incompatible way, then change version number too,
			  // so all options will get default values on first start.
	"V,v",`BUILD_DATE 
};

wire forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask(0),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys)
);

// ---------------------------------------------------------------------------
// CPU speed select (single-PLL clock-enable approach)
//   status[8] = 0 -> 15.6672 MHz (stock Mac IIvi)
//   status[8] = 1 -> 31.3344 MHz (2x "turbo")
// The 68030 advances one bus cycle per cpu_ce pulse. clk_sys must be the base
// clock = 4x the stock rate = 62.6688 MHz, giving clean integer enables:
//   stock : cpu_ce every 4th clk_sys cycle  (62.6688 / 4 = 15.6672 MHz)
//   turbo : cpu_ce every 2nd clk_sys cycle  (62.6688 / 2 = 31.3344 MHz)
// TODO(pll): regenerate rtl/pll in Quartus to output 62.6688 MHz on outclk_0
//            (currently the demo template value of 20 MHz), then feed cpu_ce to
//            the 68030 core when the CPU RTL lands.
// ---------------------------------------------------------------------------
wire cpu_turbo = status[8];

reg [1:0] ce_cnt;
reg       cpu_ce;
always @(posedge clk_sys) begin
	ce_cnt <= ce_cnt + 1'd1;
	cpu_ce <= cpu_turbo ? ~ce_cnt[0]         // /2 -> 31.3344 MHz
	                    : (ce_cnt == 2'd0);  // /4 -> 15.6672 MHz
end

wire reset = RESET | status[0] | buttons[1];

wire [1:0] col = status[4:3];

wire HBlank;
wire HSync;
wire VBlank;
wire VSync;
wire ce_pix;
wire [7:0] video;

mycore mycore
(
	.clk(clk_sys),
	.reset(reset),
	
	.pal(status[2]),
	.scandouble(forced_scandoubler),

	.ce_pix(ce_pix),

	.HBlank(HBlank),
	.HSync(HSync),
	.VBlank(VBlank),
	.VSync(VSync),

	.video(video)
);

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL = ce_pix;

assign VGA_DE = ~(HBlank | VBlank);
assign VGA_HS = HSync;
assign VGA_VS = VSync;
assign VGA_G  = (!col || col == 2) ? video : 8'd0;
assign VGA_R  = (!col || col == 1) ? video : 8'd0;
assign VGA_B  = (!col || col == 3) ? video : 8'd0;

reg  [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1; 
assign LED_USER    = act_cnt[26]  ? act_cnt[25:18]  > act_cnt[7:0]  : act_cnt[25:18]  <= act_cnt[7:0];

endmodule
