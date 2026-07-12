#include <verilated.h>
#include <set>
#include "Vemu.h"
#include "Vemu__Syms.h"

#include "imgui.h"
#include "implot.h"
#ifndef _MSC_VER
#include <stdio.h>
#include <SDL.h>
#include <SDL_opengl.h>
#else
#define WIN32
#include <dinput.h>
#endif

#define VERILATOR_MAJOR_VERSION (VERILATOR_VERSION_INTEGER / 1000000)

#if VERILATOR_MAJOR_VERSION >= 5
#define VERTOPINTERN top->rootp
#else
#define VERTOPINTERN top
#endif

#include "sim_console.h"
#include "sim_bus.h"
#include "sim_blkdevice.h"
#include "sim_video.h"
#include "sim_audio.h"
#include "sim_input.h"
#include "sim_clock.h"
#include "sim_serial.h"
#include "m68k_dasm.h"

#include "../imgui/imgui_memory_editor.h"
#include "../imgui/ImGuiFileDialog.h"

#include <iostream>
#include <sstream>
#include <fstream>
#include <iterator>
#include <string>
#include <iomanip>
#include <vector>
#include <algorithm>
using namespace std;

// stb_image_write for PNG screenshots
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "sim/stb_image_write.h"

// Simulation control
// ------------------
int initialReset = 48;
bool run_enable = 1;
int batchSize = 150000;
bool single_step = 0;
bool multi_step = 0;
int multi_step_amount = 1024;

// Machine configuration
// ---------------------
// Mac LC only (no longer supports Mac Plus)
// For TG68K: cpu = {status_cpu[1], |status_cpu}
//   cfg_cpuType=0  -> cpu="00" (68000)
//   cfg_cpuType=1  -> cpu="01" (68010)
//   cfg_cpuType=2  -> cpu="11" (68020)
//   cfg_cpuType=3  -> cpu="11" (68020)
// Mac LC needs 68020 mode (cfg_cpuType=2 or 3)
int cfg_cpuType = 2;       // 68020 mode via TG68K
int cfg_memSize = 1;       // 0=1MB, 1=4MB

// Verbose bring-up diagnostics (overlay/FC/march/STM/RAMCFG/bus/CPU-trace
// console spam). Off by default for a quiet console; enable with --verbose/-v.
bool verbose_diag = false;
#define DLOG(...) do { if (verbose_diag) fprintf(stderr, __VA_ARGS__); } while (0)

// TG68K regfile is a packed [511:0] vector; Verilator exposes it as 16x32-bit
// words. The kernel's debug taps prove the mapping (d0=regfile[511:480]=word15,
// a0=regfile[255:224]=word7, a7=regfile[31:0]=word0): Dn = rf[15-n], An = rf[7-n].
// NOTE: the older [TBL]/[MARCH]/[ERR] detectors used ascending rf[0..13] and so
// MISLABELED every register — use these macros instead.
#define RF_D(rf,n) ((uint32_t)(rf)[15-(n)])
#define RF_A(rf,n) ((uint32_t)(rf)[7-(n)])

// CPU trace
// ---------
bool cpu_trace_enable = false;  // Enable after ROM download
bool cpu_trace_disabled = false; // --no-cpu-trace: skip per-instruction trace (long runs)
bool pc_heartbeat = false;      // --heartbeat: print the 68k PC once per frame (long runs)
bool cpu_trace_started = false;  // Wait for ROM load and reset
FILE* cpu_trace_file = nullptr;
const char* cpu_trace_filename = "cpu_trace.log";
int cpu_trace_count = 0;
const int cpu_trace_max = 0;  // 0 = unlimited
int post_download_delay = 0;  // Delay after ROM load before tracing
uint32_t cpu_trace_last_pc = 0xFFFFFFFF;  // For edge detection (new instruction)
int cpu_trace_last_frame = -1;  // Track frame transitions in trace log
// --trace-frames A,B: only WRITE trace lines for frames in [A,B] (skip the slow
// chime so a focused window like the bank-scan stays small). Default = all.
int trace_from_frame = 0;
int trace_to_frame = 0x7FFFFFFF;

// Fetch buffer: sliding window of recent code-space fetches (PC -> word).
// Used to (a) skip extension-word fetches so only opcodes are logged and
// (b) feed the disassembler real extension words for correct operand display.
// TG68 fetches opcode then extension words sequentially, so we buffer up to
// 5 consecutive fetches and emit the oldest when we have enough context.
struct FetchEntry { uint32_t pc; uint16_t word; int frame; uint32_t data_addr; };
const int FETCH_BUF_SIZE = 8;
FetchEntry fetch_buf[FETCH_BUF_SIZE];
int fetch_buf_len = 0;
uint32_t next_opcode_pc = 0xFFFFFFFF;  // Expected PC of next real opcode (after last emit)

// RAM debug
// ---------
bool ram_debug_enable = false;  // Disable for speed
FILE* ram_debug_file = nullptr;
const char* ram_debug_filename = "ram_debug.log";
int ram_debug_count = 0;
const int ram_debug_max = 10000000;  // Stop after this many RAM accesses

// Peripheral debug
// ----------------
bool periph_debug_enable = false;  // Enable for peripheral access logging
FILE* periph_debug_file = nullptr;
const char* periph_debug_filename = "periph_debug.log";
int periph_debug_count = 0;
const int periph_debug_max = 5000000;  // Stop after this many peripheral accesses
bool periph_debug_prev_bus_control = false;  // For edge detection

// Screenshot functionality
// ------------------------
std::vector<int> screenshot_frames;
bool screenshot_mode = false;

// Stop at frame functionality
// ---------------------------
int stop_at_frame = -1;
bool stop_at_frame_enabled = false;

// Synthetic ADB mouse stimulus (headless repro of the hardware ADB-init hang)
// ---------------------------------------------------------------------------
// --mouse-from N [--mouse-to M]: from frame N (through M), put a nonzero motion
// delta in every ps2_mouse packet, mimicking the MiSTer HPS forwarding a real
// USB mouse the user is moving. Without this, headless runs strobe ps2_mouse[24]
// with all-zero deltas, so adb_device never raises mouse_evt — the Talk-R0-data
// and SRQ paths (the ones live hardware exercises) go untested.
int mouse_inject_from = -1;
int mouse_inject_to   = 0x7FFFFFFF;

// Warm-reset test: pulse the top-level reset at a given frame WITHOUT reloading
// the ROM (it persists in the SDRAM model) — a faithful proxy for the FPGA's R0
// soft reset / OS restart, to test whether the machine warm-boots.
// -------------------------------------------------------------------
int  reset_at_frame = -1;
long long warm_reset_start = -1;   // main_time when the pulse began (<0 = not yet)
const long long WARM_RESET_LEN = 4000;  // hold reset asserted this many ticks

// Level-7 NMI test (--nmi-at-frame N): pulse the programmer's-switch NMI at frame
// N to verify the CPU+glue take the level-7 autovector (the MacsBug break path).
int  nmi_at_frame = -1;
long long nmi_start = -1;

// Headless mode (no GUI)
// ----------------------
bool headless = false;

// Debug GUI
// ---------
const char* windowTitle = "Verilator Sim: Macintosh LC";
const char* windowTitle_Control = "Simulation control";
const char* windowTitle_DebugLog = "Debug log";
const char* windowTitle_Video = "VGA output";
const char* windowTitle_Audio = "Audio output";
bool showDebugLog = true;
DebugConsole console;
MemoryEditor mem_edit;
SimSerialTerminal serialTerminal;

// HPS emulator
// ------------
SimBus bus(console);
SimBlockDevice blockdevice(console);

// Disk images (mirrors lbmactwo): SCSI -> block device (MountDisk),
// floppy -> ioctl download into SDRAM (QueueDownload). Set via --scsi0/1
// and --floppy0/1 on the command line.
std::string scsi_disk_files[2];
std::string floppy_disk_files[2];

// Boot ROM override (--rom <path>). Empty => default ../releases/boot0.rom.
// Lets us swap fastmem/nomemcheck ROMs without clobbering the shared boot0.rom.
std::string rom_file_override;

// Input handling
// --------------
SimInput input(13, console);
const int input_right = 0;
const int input_left = 1;
const int input_down = 2;
const int input_up = 3;
const int input_a = 4;
const int input_b = 5;
const int input_x = 6;
const int input_y = 7;
const int input_l = 8;
const int input_r = 9;
const int input_select = 10;
const int input_start = 11;
const int input_menu = 12;

// Video
// -----
// Mac LC VGA mode (monitor_id=6) is 640x480
#define VGA_WIDTH 640
#define VGA_HEIGHT 480
#define VGA_ROTATE 0
#define VGA_SCALE_X vga_scale
#define VGA_SCALE_Y vga_scale
SimVideo video(VGA_WIDTH, VGA_HEIGHT, VGA_ROTATE);
// Default 1:1 so the full 640x480 frame fits the video window on a typical
// display (at 1.5x the 960x720 image + panels overran many screens, clipping
// the bottom/right edges). Use the Zoom slider to scale up.
float vga_scale = 1.0;

// Verilog module
// --------------
Vemu* top = NULL;

vluint64_t main_time = 0;	// Current simulation time.
double sc_time_stamp() {	// Called by $time in Verilog.
	return main_time;
}

// 32 MHz system clock for Mac LC
int clk_sys_freq = 32000000;
SimClock clk_sys(1);

// Audio
// -----
#ifndef DISABLE_AUDIO
SimAudio audio(clk_sys_freq, false);
#endif

// Reset simulation variables and clocks
void resetSim() {
	main_time = 0;
	VERTOPINTERN->reset = 1;
	clk_sys.Reset();
}

int verilate() {

	if (!Verilated::gotFinish()) {

		// Assert reset during startup
		if (main_time < initialReset) { VERTOPINTERN->reset = 1; }
		// Deassert reset after startup
		if (main_time == initialReset) { VERTOPINTERN->reset = 0; }

		// Warm-reset test (--reset-at-frame N): once we reach frame N, hold the
		// top-level reset asserted for WARM_RESET_LEN ticks, then release. The ROM
		// already lives in the SDRAM model and is NOT reloaded, so this mirrors an
		// FPGA R0 / OS restart (warm boot against existing SDRAM).
		if (reset_at_frame >= 0) {
			if (warm_reset_start < 0 && (int)video.count_frame >= reset_at_frame) {
				warm_reset_start = main_time;
				printf("[F%d] WARM RESET: asserting reset (ROM kept in SDRAM)\n", (int)video.count_frame);
			}
			if (warm_reset_start >= 0 && main_time < warm_reset_start + WARM_RESET_LEN) {
				VERTOPINTERN->reset = 1;
			} else if (warm_reset_start >= 0 && main_time == warm_reset_start + WARM_RESET_LEN) {
				VERTOPINTERN->reset = 0;
				printf("[F%d] WARM RESET: released reset\n", (int)video.count_frame);
			}
		}

		// Level-7 NMI test (--nmi-at-frame N): pulse nmi_pulse at frame N. sim.v
		// edge-detects it and forces IPL=7; expect "NMI: cleared (level-7 IACK TAKEN)".
		if (nmi_at_frame >= 0) {
			if (nmi_start < 0 && (int)video.count_frame >= nmi_at_frame) {
				nmi_start = main_time;
				printf("[F%d] NMI TEST: pulsing Level-7 NMI\n", (int)video.count_frame);
			}
			VERTOPINTERN->nmi_pulse =
				(nmi_start >= 0 && main_time < nmi_start + WARM_RESET_LEN) ? 1 : 0;
		}

		// Clock dividers
		clk_sys.Tick();

		// Set system clock in core
		VERTOPINTERN->clk_sys = clk_sys.clk;

		// Set machine configuration (Mac LC only)
		VERTOPINTERN->cfg_cpuType = cfg_cpuType;
		VERTOPINTERN->cfg_memSize = cfg_memSize;

		// Simulate both edges of system clock
		if (clk_sys.clk != clk_sys.old) {
			if (clk_sys.IsRising() && *bus.ioctl_download != 1) {
				blockdevice.BeforeEval(main_time);
			}
			if (clk_sys.clk) {
				input.BeforeEval();
				bus.BeforeEval();
			}
			top->eval();
			if (clk_sys.clk) { bus.AfterEval(); blockdevice.AfterEval(); }

			// ROM overlay transition logger (one-shot edges)
			if (clk_sys.clk) {
				static int prev_ov = -1;
				int ov = (int)VERTOPINTERN->emu__DOT__ac0__DOT__rom_overlay;
				if (ov != prev_ov) {
					DLOG( "[OVERLAY] rom_overlay %d->%d at F%d cyc=%llu\n",
						prev_ov, ov, video.count_frame, (unsigned long long)main_time);
					prev_ov = ov;
				}
				static int prev_pend = -1, prev_rst = -1;
				int pend = (int)VERTOPINTERN->emu__DOT__ac0__DOT__overlay_disable_pending;
				int rst = (int)VERTOPINTERN->emu__DOT___cpuReset;
				if (pend != prev_pend) { DLOG( "[OVERLAY] pending %d->%d F%d cyc=%llu\n", prev_pend, pend, video.count_frame, (unsigned long long)main_time); prev_pend = pend; }
				if (rst != prev_rst) { DLOG( "[OVERLAY] _cpuReset %d->%d F%d cyc=%llu\n", prev_rst, rst, video.count_frame, (unsigned long long)main_time); prev_rst = rst; }
				// FC during $A0xxxx accesses (overlay-clear gate is cpuFC[1])
				static int fc_logs = 0;
				uint32_t ca = top->debug_cpuAddr;
				if ((ca & 0xF00000) == 0xA00000 && fc_logs < 24) {
					unsigned fc = VERTOPINTERN->emu__DOT__cpuFC;
					static uint32_t last_ca = 0xFFFFFFFF; static unsigned last_fc = 0xFF;
					if (ca != last_ca || fc != last_fc) {
						DLOG( "[FC] $A-access addr=%06X FC=%u (fc1=%u) F%d\n",
							ca & 0xFFFFFF, fc, (fc>>1)&1, video.count_frame);
						fc_logs++; last_ca = ca; last_fc = fc;
					}
				}
			}

			// [LOOPBACK] decisive test for the $A03124 hardware-presence loopback:
			// MAME reads $F21C00=$00 (separate) -> cmp not-equal -> bne taken; ours
			// bne falls through. Log the CPU's read VALUE (debug_cpuDataIn) at the
			// loopback addresses ($F_1C00) — if it reads $FF (unmapped, distinct) the
			// value is correct and the bug is flag-commit timing; if it reads the
			// aliased write value, it's a wrong-read-value bug.
			{
				static int lb_logs = 0;
				uint32_t pc = VERTOPINTERN->debug_pc & 0xFFFFFF;
				if (pc >= 0xA03124 && pc <= 0xA03150 && lb_logs < 400) {
					uint32_t ca  = top->debug_cpuAddr & 0xFFFFFF;
					uint32_t din = VERTOPINTERN->debug_cpuDataIn;
					auto &rf = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__regfile;
					uint32_t d1 = (uint32_t)rf[14];   // D1 (regfile is reversed: D0=rf15..D7=rf8)
					uint32_t op1 = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__op1out;
					uint32_t op2 = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__op2out;
					unsigned srin = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__srin;
					// REAL committed condition codes: flags = ...XNZVC, Z = bit 2.
					unsigned flags = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__flags;
					uint32_t eadata = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__ea_data;
					unsigned sit   = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__store_in_tmp;
					unsigned exopc = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__execopc;
					// Boot-sim bus FSM (tg68k.v wrapper, one level above the kernel).
					unsigned sstate = VERTOPINTERN->emu__DOT__tg68k__DOT__s_state;
					uint32_t dinr   = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68_din_r;
					unsigned ebs    = VERTOPINTERN->emu__DOT__tg68k__DOT__eff_busstate;
					static uint32_t lastkey = 0xFFFFFFFF;
					uint32_t key = pc ^ (din << 1) ^ (op1 << 5) ^ (op2 << 9) ^ (flags << 13)
					             ^ (d1 << 3) ^ (ca << 4) ^ (eadata << 7) ^ (sstate << 17)
					             ^ (exopc << 20) ^ (sit << 21) ^ (dinr << 11) ^ (ebs << 23);
					if (key != lastkey) {
						DLOG( "[LOOPBACK] pc=%06X addr=%06X din=%08X D1=%08X OP1=%08X OP2=%08X ea=%08X Zreal=%u CCR=%02X exOPC=%u sit=%u ss=%u dinr=%04X ebs=%u F%d\n",
							pc, ca, din, d1, op1, op2, eadata, (flags >> 2) & 1, flags & 0x1F,
							exopc, sit, sstate, dinr & 0xFFFF, ebs, video.count_frame);
						lb_logs++; lastkey = key;
					}
				}
			}

			// [BNEPROOF] Retire-accurate proof of the bne @ $A0313E direction.
			// exe_condition (= NOT Flags(2) for bne cc=$6) is what the kernel ACTUALLY
			// uses to take/fall-through; decodeOPC=1 marks an instruction entering
			// decode (= actually executed, NOT a discarded prefetch). Logged UN-DEDUPED
			// every eval in the loop body so a transient Z=1 cannot hide. Also pairs
			// each bne with the cmp's read stride and the live d0/d1.
			{
				static int bp_logs = 0;
				uint32_t pc = VERTOPINTERN->debug_pc & 0xFFFFFF;
				if (pc >= 0xA03124 && pc <= 0xA03150 && bp_logs < 1200) {
					unsigned exeop = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__exe_opcode;
					unsigned cond  = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__exe_condition;
					unsigned dec   = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__decodeopc;
					unsigned exopc = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__execopc;
					unsigned flags = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__flags;
					unsigned ss    = VERTOPINTERN->emu__DOT__tg68k__DOT__s_state;
					uint32_t ca    = top->debug_cpuAddr & 0xFFFFFF;
					auto &rf = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__regfile;
					uint32_t d0 = (uint32_t)rf[15], d1 = (uint32_t)rf[14], d2 = (uint32_t)rf[13];
					// Only emit at decode boundaries and at the bne's commit, plus any
					// cycle where Flags shows Z=1 (the thing we must catch or rule out).
					bool zset = ((flags >> 2) & 1);
					if (dec || (exeop == 0x6604 && exopc) || zset) {
						DLOG("[BNEPROOF] pc=%06X addr=%06X exeop=%04X cond=%u dec=%u exOPC=%u Z=%u CCR=%02X ss=%u D0=%08X D1=%08X D2=%08X F%d\n",
							pc, ca, exeop, cond, dec, exopc, (flags>>2)&1, flags&0x1F, ss, d0, d1, d2, video.count_frame);
						bp_logs++;
					}
				}
			}

			// [CKSUM] Settle the ROM-checksum POST stall question. The full-ROM sum
			// loop is at $A46AF0 (move.w (A0)+,D0; add.l D0,D1; subq.l #1,D3; bne),
			// $3FFFE words; then $A46AFC eor.l D4,D1; $A46AFE beq $a46b04. PASS (Z=1)
			// -> $A46B04 jmp(A6); FAIL (Z=0) -> $A46B00 move.w #$FFFF,D6 -> caller
			// $A464EC bne $a48cda (error handler). Retire-accurate via decodeopc.
			// Logs coarse D3 countdown milestones (is it PROGRESSING vs stuck?) plus
			// the decisive eor/beq result. D1=rf14 D3=rf12 D4=rf11 (regfile reversed).
			{
				static int ck_logs = 0;
				static uint32_t last_milestone = 0xFFFFFFFF;
				uint32_t pc = VERTOPINTERN->debug_pc & 0xFFFFFF;
				if (pc >= 0xA46ADA && pc <= 0xA46B08 && ck_logs < 120) {
					unsigned dec   = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__decodeopc;
					unsigned flags = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__flags;
					auto &rf = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__regfile;
					uint32_t d1 = (uint32_t)rf[14], d3 = (uint32_t)rf[12], d4 = (uint32_t)rf[11];
					uint32_t milestone = d3 >> 14;   // ~16 samples across $3FFFE
					if (pc == 0xA46AF2 && dec && milestone != last_milestone) {
						DLOG("[CKSUM] progress D3=%08X D1(sum)=%08X F%d cyc=%llu\n",
							d3, d1, video.count_frame, (unsigned long long)main_time);
						last_milestone = milestone; ck_logs++;
					}
					if ((pc==0xA46AFC || pc==0xA46AFE || pc==0xA46B00 || pc==0xA46B04) && dec) {
						DLOG("[CKSUM] RESULT pc=%06X Z=%u CCR=%02X D1(sum^exp)=%08X D4(exp)=%08X F%d\n",
							pc, (flags>>2)&1, flags&0x1F, d1, d4, video.count_frame);
						ck_logs++;
					}
				}
			}

			// March progress counters — independent of cpu_trace gating.
			// $A46910 = one full inner-march region pass completed (cmpi.w #21,d7)
			// $A4694C = march fully done; $A4A590 = bank-scan driver reached.
			if (VERTOPINTERN->debug_fetch_valid && !*bus.ioctl_download) {
				static uint32_t march_last_pc = 0xFFFFFFFF;
				static int hit_910 = 0, hit_694c = 0, hit_a590 = 0;
				uint32_t mpc = VERTOPINTERN->debug_pc & 0xFFFFFF;
				// --heartbeat: sample the PC once per frame so long runs show
				// whether the CPU is advancing or wedged in a loop (no --verbose flood).
				if (pc_heartbeat) {
					static int last_hb_frame = -1;
					if ((int)video.count_frame != last_hb_frame) {
						last_hb_frame = (int)video.count_frame;
						auto &hbrf = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__regfile;
						fprintf(stderr, "[HB] F%d pc=%06X fullpc=%08X a7=%08X a2=%08X\n",
						        (int)video.count_frame, mpc,
						        (unsigned)VERTOPINTERN->debug_pc, RF_A(hbrf,7), RF_A(hbrf,2));
					}
				}
				if (mpc != march_last_pc) {
					{   // STM-entry detector: first jump INTO the serial-monitor
						// region ($A49800-$A49FFF) from outside, with source PC.
						static int stm_logs = 0;
						bool in_stm   = (mpc >= 0xA49800 && mpc <= 0xA499FF);
						bool prev_stm = (march_last_pc >= 0xA49800 && march_last_pc <= 0xA499FF);
						if (in_stm && !prev_stm && stm_logs < 12) {
							DLOG( "[STM_ENTRY] -> %06X from %06X F%d\n", mpc, march_last_pc, video.count_frame);
							stm_logs++;
						}
					}
					{   // fatal-error / diagnostic handler entry ($A48CD0/$A48CDA sets
						// SP=$2600 + magic $87654321). Capture which error-check branch
						// fired (march_last_pc) and the registers, to find the failed test.
						static int en=0;
						if ((mpc==0xA48CD0 || mpc==0xA48CDA || mpc==0xA4638C || mpc==0xA46200) && en<12) {
							auto &rf = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__regfile;
							DLOG( "[ERR] ->%06X from %06X F%d D0=%08X D1=%08X D2=%08X D6=%08X D7=%08X\n",
								mpc, march_last_pc, video.count_frame,
								RF_D(rf,0),RF_D(rf,1),RF_D(rf,2),RF_D(rf,6),RF_D(rf,7)); DLOG("      D4(testmask)=%08X D3=%08X A0=%08X A1=%08X\n",RF_D(rf,4),RF_D(rf,3),RF_A(rf,0),RF_A(rf,1)); en++;
						}
					}
					{   // MOVES-BERR fix verification: machine-config word D2 (and D5
						// jump index) at the dispatch $A00AB0. MAME: D2=$CC000D07.
						static int n=0;
						if (mpc==0xA00AB0 && n<8) {
							auto &rf = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__regfile;
							DLOG( "[D2PROBE] $A00AB0 #%d F%d D2=%08X D5=%08X\n",
								n, video.count_frame, RF_D(rf,2), RF_D(rf,5)); n++;
						}
					}
					{   // boot state-machine: log entry into each of MAME's 11 handlers
						// (+ the STM-subsystem $A48Cxx) to find where our sequence diverges.
						static const uint32_t H[] = {0xA48468,0xA483FC,0xA47C30,0xA47942,
							0xA477D2,0xA473F4,0xA4730C,0xA4713E,0xA4703E,0xA46F5A,0xA46EC8};
						static uint32_t last_h=0; static int st=0;
						bool ish=false; for (unsigned i=0;i<11;i++) if (mpc==H[i]) ish=true;
						
						if (ish && mpc!=last_h && st<300) {
							DLOG( "[STATE] handler %06X F%d\n", mpc, video.count_frame); st++; last_h=mpc;
						}
					}
					march_last_pc = mpc;
					if (mpc == 0xA46910) { hit_910++;
						auto &rf = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__regfile;
						DLOG( "[MARCH] PASS#%d F%d D0=%08X D1=%08X D2=%08X D4=%08X D6=%08X D7=%08X A0=%08X A1=%08X A2=%08X A3=%08X A4=%08X A5=%08X\n",
							hit_910, video.count_frame,
							RF_D(rf,0),RF_D(rf,1),RF_D(rf,2),RF_D(rf,4),
							RF_D(rf,6),RF_D(rf,7),RF_A(rf,0),RF_A(rf,1),
							RF_A(rf,2),RF_A(rf,3),RF_A(rf,4),RF_A(rf,5)); }
					else if (mpc == 0xA4694C) { hit_694c++;
						DLOG( "[MARCH] *** DONE $A4694C hit#%d cyc=%llu F%d ***\n",
							hit_694c, (unsigned long long)main_time, video.count_frame); }
					else if (mpc == 0xA4A590) { hit_a590++;
						if (hit_a590 <= 3) DLOG( "[MARCH] bank-scan $A4A590 hit#%d cyc=%llu F%d\n",
							hit_a590, (unsigned long long)main_time, video.count_frame); }
					else if (mpc == 0xA467FE) { static int n=0; if(++n<=8) DLOG( "[PROBE] PASS $A467FE (bank present) #%d F%d\n", n, video.count_frame); }
					else if (mpc == 0xA467F6) { static int n=0; if(++n<=8) DLOG( "[PROBE] FAIL $A467F6 (bank absent) #%d F%d\n", n, video.count_frame); }
					else if (mpc == 0xA46584) { static int n=0; if(++n<=12) { // cmpaw #-1,a0 : A0=region start loaded, A5=table base
						auto &rf = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__regfile;
						DLOG( "[TBL] $A46584 #%d F%d D7=%08X A0(start)=%08X A4=%08X A5(tbl)=%08X SP=%08X\n",
							n, video.count_frame, RF_D(rf,7), RF_A(rf,0), RF_A(rf,4), RF_A(rf,5), RF_A(rf,7)); } }
					else if (mpc == 0xA4658A) { static int n=0; if(++n<=12) { // movel a4@+,d0 : D0=region length
						auto &rf = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__regfile;
						DLOG( "[TBL] $A4658A #%d F%d D0(len)=%08X A0=%08X A4=%08X\n",
							n, video.count_frame, RF_D(rf,0), RF_A(rf,0), RF_A(rf,4)); } }
					else if (mpc == 0xA4657E) { static int n=0; if(++n<=8) { // moveal sp@,a4 : about to read table ptr from SP
						auto &rf = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__regfile;
						DLOG( "[TBL] $A4657E #%d F%d (D7=3 RAM-region entry) SP=%08X A4=%08X A5=%08X overlay=%d\n",
							n, video.count_frame, RF_A(rf,7), RF_A(rf,4), RF_A(rf,5),
							(int)VERTOPINTERN->emu__DOT__ac0__DOT__rom_overlay);
						// READ-ONLY dump of built descriptor table memory before the march
						// writes it. CPU $9FFFE0..$9FFFFF -> SDRAM words $0FFFF0..$0FFFFF
						// (motherboard_high: word = {3'b000, cpuAddr[20:1]}). 68k longwords
						// are big-endian word pairs in the 16-bit mem[] array.
						auto &M = VERTOPINTERN->emu__DOT__ram__DOT__mem;
						DLOG( "[TBLMEM] #%d F%d CPU$9FFFE0:", n, video.count_frame);
						for (uint32_t w = 0xFFFF0; w <= 0xFFFFE; w += 2)
							DLOG( " %08X", ((unsigned)M[w] << 16) | (unsigned)M[w+1]);
						DLOG( "\n");
						// The REAL descriptor table is at the top of 4MB (CPU $3FFFEx ->
						// SDRAM word $1FFFFx). Dump CPU $3FFFE0..$3FFFFC and the table-ptr
						// slot CPU $7FF8..$7FFC (SDRAM $3FFC..$3FFE).
						DLOG( "[TBLMEM] #%d F%d CPU$3FFFE0:", n, video.count_frame);
						for (uint32_t w = 0x1FFFF0; w <= 0x1FFFFE; w += 2)
							DLOG( " %08X", ((unsigned)M[w] << 16) | (unsigned)M[w+1]);
						DLOG( "  | CPU$7FF8:");
						for (uint32_t w = 0x3FFC; w <= 0x3FFE; w += 2)
							DLOG( " %08X", ((unsigned)M[w] << 16) | (unsigned)M[w+1]);
						DLOG( "\n"); } }

						// [ENUM] correctly-mapped register snapshot at the RAM-enumeration
						// decision points, to diff control flow + values vs the MAME oracle.
						{
							static const struct { uint32_t pc; const char* tag; int cap; } EP[] = {
								{0xA4A5B2,"B2_btstD0", 4}, {0xA4A5C2,"C2_btstD1", 4},
								{0xA4A5E4,"E4_PanD",   4}, {0xA4A5EC,"EC_C4set",  4},
								{0xA4A60C,"0C_topRAM", 4}, {0xA4A626,"26_A5set",  4},
								{0xA4A65C,"5C_walk0",  4}, {0xA4A666,"66_rgnSt", 24},
								{0xA4A66C,"6C_rgnSz", 24}, {0xA4A698,"98_stkSet",24},
								{0xA4A6AE,"AE_final",  8}, {0xA4654A,"4A_rdTbl",  8},
							};
							static int ecap[12] = {0};
							for (int i = 0; i < 12; i++) {
								if (mpc == EP[i].pc && ecap[i] < EP[i].cap) {
									auto &rf = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__regfile;
									DLOG("[ENUM] %-9s pc=%06X F%d D0=%08X D1=%08X D2=%08X D4=%08X A0=%08X A1=%08X A2=%08X A5=%08X A7=%08X\n",
										EP[i].tag, mpc, video.count_frame,
										RF_D(rf,0),RF_D(rf,1),RF_D(rf,2),RF_D(rf,4),
										RF_A(rf,0),RF_A(rf,1),RF_A(rf,2),RF_A(rf,5),RF_A(rf,7));
									ecap[i]++;
								}
							}
						}

						// [JMP6] Post-state-machine $A4A2xx-$A4A4xx hardware-init flow that
						// ends in the crashing jmp(A6) at $A4A454. MAME (our patched ROM):
						// caller $A4A300 `lea ($a4a308,PC),A6` -> A6=$A4A308 -> jmp(A6) returns
						// cleanly (60x, no crash). Our core: A6=$FFFFFFAA garbage -> $7FF8 wedge.
						// Log every new PC in the window with A6/A2/A5 (skip the 256x delay loop
						// $A4A44E/$A4A450) to find where A6 first goes bad vs MAME.
						{
							static int j6 = 0; static int dcnt = 0;
							static uint32_t last454a6 = 0xDEADBEEF;
							auto &rf = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__regfile;
							// [DERAIL] the 68k PC jumping into $FFFFxxxx (the crash). Log the source pc
							// (the jmp(An) instr) + all regs so we see WHICH jmp went bad and to what.
							// Fire ONCE on the good->bad PC transition (mpc enters $FFxxxx from a
							// normal address) so march_last_pc = the offending jmp/rts and the regs
							// are pre-garbage. Also dump the FULL 32-bit debug_pc (unmasked) to see
							// the sign-extension, + all A/D regs + A7(SP).
							bool bad=(mpc & 0xFF0000u)==0xFF0000u, prevbad=(march_last_pc & 0xFF0000u)==0xFF0000u;
							if (bad && !prevbad && dcnt < 6) {
								DLOG("[DERAIL] full_pc=%08X mpc=%06X SRC=%06X F%d | A0=%08X A1=%08X A2=%08X A3=%08X A4=%08X A5=%08X A6=%08X A7=%08X | D0=%08X D1=%08X D2=%08X D5=%08X\n",
									(unsigned)VERTOPINTERN->debug_pc, mpc, march_last_pc, video.count_frame,
									RF_A(rf,0),RF_A(rf,1),RF_A(rf,2),RF_A(rf,3),RF_A(rf,4),RF_A(rf,5),RF_A(rf,6),RF_A(rf,7),
									RF_D(rf,0),RF_D(rf,1),RF_D(rf,2),RF_D(rf,5));
								dcnt++;
							}
							bool log6=false; const char* t6="";
							if      (mpc==0xA4A290) { t6="ENTRY";    log6=true; } // routine entry (A6=outer ret)
							else if (mpc==0xA4A2F8) { t6="pollDONE"; log6=true; } // after dbne: D0<0 => timeout
							else if (mpc==0xA4A31C) { t6="TIMEOUT!"; log6=true; } // bmi error path taken
							else if (mpc==0xA4A3CE) { t6="D0ne20";   log6=true; } // bne $a4a3ce (D0&$70 != $20)
							else if (mpc==0xA4A24C) { t6="EXIT(A3)"; log6=true; } // jmp(A3): state-machine exit
							else if (mpc==0xA4A454) {                             // jmp(A6); dedup by A6
								uint32_t a6=RF_A(rf,6);
								if (a6!=last454a6) { t6="jmp(A6)"; log6=true; last454a6=a6; }
							}
							if (log6 && j6 < 900) {
								DLOG("[JMP6] %-9s pc=%06X<-%06X F%d A6=%08X A5=%08X A3=%08X A2=%08X D1=%08X D2=%08X D5=%08X\n",
									t6, mpc, march_last_pc, video.count_frame,
									RF_A(rf,6),RF_A(rf,5),RF_A(rf,3),RF_A(rf,2),RF_D(rf,1),RF_D(rf,2),RF_D(rf,5));
								j6++;
							}
						}
						// [RING] 48-entry circular trace of the derail lead-up. Stores every instr
						// from F150; on the FIRST abnormal PC (not RAM<4MB / ROM $A0-A7 / VIA $F0xxxx)
						// it flushes the buffer in order -> the last good entry = the jmp/rts that
						// derailed, with its opcode + A3/A4/A6/A7/D2.
						{
							static uint32_t rpc[48],rop[48],ra2[48],ra5[48],ra6[48],ra7[48],rd2[48];
							static int ri=0; static bool flushed=false;
							auto &rf = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__regfile;
							bool abn = !((mpc<0x400000u) || (mpc>=0xA00000u && mpc<0xA80000u) || (mpc>=0xF00000u && mpc<0xF10000u));
							if (video.count_frame>=150 && !flushed) {
								if (abn) {
									DLOG("[RING] FLUSH at abnormal pc=%06X full=%08X F%d\n", mpc, (unsigned)VERTOPINTERN->debug_pc, video.count_frame);
									for (int k=0;k<48;k++){ int idx=(ri+k)%48;
										DLOG("[RING] %2d pc=%06X op=%04X A2=%08X A5=%08X A6=%08X A7=%08X D2=%08X\n",
											k, rpc[idx], rop[idx], ra2[idx], ra5[idx], ra6[idx], ra7[idx], rd2[idx]); }
									flushed=true;
								} else {
									rpc[ri%48]=mpc; rop[ri%48]=(unsigned)VERTOPINTERN->debug_opcode;
									ra2[ri%48]=RF_A(rf,2); ra5[ri%48]=RF_A(rf,5); ra6[ri%48]=RF_A(rf,6);
									ra7[ri%48]=RF_A(rf,7); rd2[ri%48]=RF_D(rf,2); ri++;
								}
							}
						}
				}
			}

			// (LC II "Candidate-B" V8 RAM-config trace removed: the IIvi/VASP
			// has no RAM-config register banking — RAM is one contiguous block
			// per MAME vasp.cpp; see docs/VASP_RETARGET.md.)

			// [BERRFRAME] 68030 bus-fault frame build + Format-$B RTE consume trace.
			// Ground-truths the OS "continue-past" probe bug. DISP line = the frame as
			// BUILT (stacked PC/SSW/opcode). RTE line = the STACKED (post-handler) SSW +
			// whether the rte_mmu_fix continue-past replay fires + where the RTE landed.
			// Kernel taps via tg68k_debug.vlt. fprintf(stderr) so it always shows; capped
			// to avoid flooding a BERR storm. Trigger on berr_frame_pc change (each = one
			// fault dispatch, value held until next fault) + make_berr edge counting.
			#define KB(n) (VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__##n)
			if (!*bus.ioctl_download) {
				static uint32_t bf_prev = 0xFFFFFFFFu;
				static int      rs_prev = -1;
				static int      mb_prev = 0;
				static int      mb_total = 0, bf_n = 0, rte_n = 0, land = 0;
				const int       CAP = 120;

				int mb = (int)KB(make_berr);
				if (mb && !mb_prev) mb_total++;
				mb_prev = mb;

				uint32_t bf = (uint32_t)KB(berr_frame_pc);
				if (bf != bf_prev) {
					bf_prev = bf;
					if (bf_n < CAP) {
						unsigned ssw = (unsigned)(uint16_t)KB(berr_ssw);
						fprintf(stderr,
						  "[BERRFRAME] DISP berr#%d F%d frame_pc=%08X live_pc=%08X ssw=%04X[b9=%u DF=%u RW=%u] long=%d faddr=%08X opc=%04X tberr=%d tmmu=%d\n",
						  mb_total, video.count_frame, bf, (uint32_t)KB(tg68_pc),
						  ssw, (ssw>>9)&1u, (ssw>>8)&1u, (ssw>>6)&1u,
						  (int)KB(berr_long_frame), (uint32_t)KB(berr_fault_addr),
						  (unsigned)(uint16_t)KB(exe_opcode),
						  (int)KB(trap_berr), (int)KB(trap_mmu_berr));
						bf_n++;
					}
				}

				int rs = (int)(uint16_t)KB(rte_mmu_fix_ssw);
				if (rs != rs_prev) {
					rs_prev = rs;
					if (rs != 0 && rte_n < CAP) {
						fprintf(stderr,
						  "[BERRFRAME] RTE  F%d stacked_ssw=%04X[b9=%u DF=%u] fmt=%04X fix_write=%d fix_commit=%d fix_opc=%04X\n",
						  video.count_frame, (unsigned)rs, ((unsigned)rs>>9)&1u, ((unsigned)rs>>8)&1u,
						  (unsigned)(uint16_t)KB(rte_format_word),
						  (int)KB(rte_mmu_fix_write), (int)KB(rte_mmu_fix_commit),
						  (unsigned)(uint16_t)KB(rte_mmu_fix_opcode));
						rte_n++;
						land = 1;
					}
				}
				if (land && VERTOPINTERN->debug_fetch_valid) {
					fprintf(stderr, "[BERRFRAME]      landed_pc=%06X opc=%04X\n",
						VERTOPINTERN->debug_pc & 0xFFFFFFu, VERTOPINTERN->debug_opcode & 0xFFFFu);
					land = 0;
				}
			}

			// [EXC] Exception-dispatch tracer — pins the fatal "bad F-Line" (sim) /
			// "type 7" (HW) at Finder launch. Edge-detect each trap_* request and log
			// the vector + faulting PC (opcode_pc) + full SR (flagssr, bit5=S) + the
			// live opcode. Frame-gated to skip the early-boot storm; capped. The trap
			// signals are held across the multi-cycle dispatch, so edge-detect on the
			// rising transition to log once per exception.
			// NOTE: A-line (trap_1010, vec10) DELIBERATELY EXCLUDED — it is the normal
			// Mac Toolbox trap-dispatch mechanism ($Axxx opcodes = every Toolbox/OS
			// call), which fires hundreds of times per frame and would flood the cap
			// before the fatal F-line at Finder launch. The bomb is a "bad F-Line"
			// (vec11); we only want the rare fault classes.
			if (!*bus.ioctl_download && video.count_frame >= 1600) {
				static int p1111=0, ppriv=0, pillg=0, paddr=0, pfmt=0;
				static int exc_n = 0; const int ECAP = 400;
				struct Trap { const char* name; int now; int* prev; };
				Trap tr[] = {
					{ "F-LINE  vec11", (int)KB(trap_1111),        &p1111 },
					{ "PRIVVIOL vec8", (int)KB(trap_priv),        &ppriv },
					{ "ILLEGAL  vec4", (int)KB(trap_illegal),     &pillg },
					{ "ADDR-ERR vec3", (int)KB(trap_addr_error),  &paddr },
					{ "FORMATERR v14", (int)KB(trap_format_error), &pfmt  },
				};
				for (auto& t : tr) {
					if (t.now && !*t.prev && exc_n < ECAP) {
						// flagssr = SR high byte (SR[15:8]); resets to $27. S=bit5, IPL=bits2:0.
						unsigned srhi = (unsigned)(uint8_t)KB(flagssr);
						fprintf(stderr,
						  "[EXC] F%d %s  vector=%03X opcode_pc=%08X exe_pc=%08X live_pc=%08X SRhi=%02X[S=%u IPL=%u] exe_opcode=%04X svmode=%d\n",
						  video.count_frame, t.name,
						  (unsigned)KB(trap_vector) & 0x3FF,
						  (uint32_t)KB(opcode_pc), (uint32_t)KB(exe_pc), (uint32_t)KB(tg68_pc),
						  srhi, (srhi>>5)&1u, srhi&7u,
						  (unsigned)(uint16_t)KB(exe_opcode),
						  (int)KB(svmode));
						exc_n++;
					}
					*t.prev = t.now;
				}
			}

			// [PCRING] torn-jsr-push forensics (2026-07-03). The F1768 F-line
			// executes at $378004 = a jsr return address pushed 2 LOW (missing
			// displacement +2), and the pmmu_busy gate on directPC/ea_to_pc was
			// behavior-inert => the tear is an edge-ORDERING flip between the
			// data_write_tmp<=TG68_PC sample (clkena_lw domain, writepc=1) and
			// the seq-arm TG68_PC<=TG68_PC_add commit (clkena_in domain) at a
			// walk exit. Ring-log every settled-cycle change of that cluster;
			// dump on (a) the first F-line >=F1600, (b) a state="11" write cycle
			// carrying the torn value $00378004, with healthy $00378006 pushes
			// logged one-line for contrast. All output on stderr as [PCRING].
			{
				struct RE { uint64_t t; int f; uint32_t pc, add, dwt, ma;
				            uint8_t wpc, lw, cin, busy, st, brw; };
				static const int RN = 16384;
				static RE ring[RN]; static int rw = 0; static bool wrapped = false;
				static uint32_t ppc=~0u, padd=~0u, pdwt=~0u, pma=~0u; static int pflags=-1;
				RE e;
				e.t   = main_time;
				e.f   = video.count_frame;
				e.pc  = (uint32_t)KB(tg68_pc);
				e.add = (uint32_t)KB(tg68_pc_add);
				e.dwt = (uint32_t)KB(data_write_tmp);
				e.ma  = (uint32_t)KB(memaddr);
				e.wpc = (uint8_t)(KB(writepc) & 1);
				e.lw  = (uint8_t)(KB(clkena_lw) & 1);
				e.cin = (uint8_t)(KB(clkena_in) & 1);
				e.busy= (uint8_t)(KB(pmmu_busy) & 1);
				e.st  = (uint8_t)(KB(state) & 3);
				e.brw = (uint8_t)(KB(tg68_pc_brw) & 1);
				int flags = e.wpc | (e.lw<<1) | (e.cin<<2) | (e.busy<<3) | (e.st<<4) | (e.brw<<6);
				if (e.pc!=ppc || e.add!=padd || e.dwt!=pdwt || e.ma!=pma || flags!=pflags) {
					ring[rw] = e; rw = (rw+1)%RN; if (rw==0) wrapped = true;
					ppc=e.pc; padd=e.add; pdwt=e.dwt; pma=e.ma; pflags=flags;
				}
				auto dump_ring = [&](const char* why, int last_n) {
					int n = wrapped ? RN : rw;
					int from = (last_n > 0 && last_n < n) ? n - last_n : 0;
					fprintf(stderr, "[PCRING] ==== DUMP (%s) t=%llu F%d entries=%d ====\n",
					        why, (unsigned long long)main_time, video.count_frame, n - from);
					for (int i = from; i < n; ++i) {
						const RE& r = ring[wrapped ? (rw + i) % RN : i];
						fprintf(stderr, "[PCRING] t=%llu F%d pc=%08X add=%08X dwt=%08X ma=%08X "
						        "wpc=%u lw=%u cin=%u busy=%u st=%u brw=%u\n",
						        (unsigned long long)r.t, r.f, r.pc, r.add, r.dwt, r.ma,
						        r.wpc, r.lw, r.cin, r.busy, r.st, r.brw);
					}
					fprintf(stderr, "[PCRING] ==== END DUMP (%s) ====\n", why);
				};
				if (video.count_frame >= 1600 && !*bus.ioctl_download) {
					// (a) full-ring dump on the first F-line dispatch (site-independent)
					static int pfl = 0; static bool excdumped = false;
					int fl = (int)KB(trap_1111);
					if (fl && !pfl && !excdumped) { dump_ring("FLINE", 0); excdumped = true; }
					pfl = fl;
					// (b) torn-value push write: state="11" carrying $00378004
					static int ptorn = 0, torn_n = 0;
					int torn = (e.st == 3 && e.dwt == 0x00378004u);
					if (torn && !ptorn && torn_n < 4) {
						fprintf(stderr, "[PCRING] TORN-PUSH t=%llu F%d ma=%08X\n",
						        (unsigned long long)main_time, video.count_frame, e.ma);
						dump_ring("TORNPUSH", 128); torn_n++;
					}
					ptorn = torn;
					// healthy-sibling push one-liners ($00378006) for contrast
					static int pok = 0, ok_n = 0;
					int okp = (e.st == 3 && e.dwt == 0x00378006u);
					if (okp && !pok && ok_n < 8) {
						fprintf(stderr, "[PCRING] OK-PUSH t=%llu F%d ma=%08X\n",
						        (unsigned long long)main_time, video.count_frame, e.ma);
						ok_n++;
					}
					pok = okp;
					// writepc falling edges at the jsr site: the final sample moments
					static int pwpc = 0, site_n = 0;
					if (!e.wpc && pwpc && e.pc >= 0x377FF0u && e.pc <= 0x378010u && site_n < 100) {
						fprintf(stderr, "[PCRING] SITE-SAMPLE-END t=%llu F%d pc=%08X dwt=%08X busy=%u lw=%u st=%u\n",
						        (unsigned long long)main_time, video.count_frame, e.pc, e.dwt, e.busy, e.lw, e.st);
						site_n++;
					}
					pwpc = e.wpc;
				}
			}
			#undef KB

			// [SR] VIA6522 shift-register + Egret handshake trace. The $A4A18C packet
			// loop never completes in our core (MAME: 14 iters & exits). Watch whether
			// the SR transfers bytes (bit_cnt 7->0, IFR[2] fires) and whether the Egret
			// ever DEASSERTS TREQ (port_b_i bit3). Gated to the post-chime window and
			// deduped by a composite key so we see edge transitions, not every clk.
			if (video.count_frame >= 113 && !*bus.ioctl_download) {
				// [SRBYTE] log each COMPLETED SR byte (serial_event / shift_active 1->0)
				// with direction (ACR shift-out=$1C vs shift-in=$0C) — the CPU<->Egret
				// byte stream. MAME exchanges a fixed 14-iteration packet; ours loops
				// because the Egret returns wrong response bytes. Diff this vs a MAME
				// lua tap on the VIA SR reg ($F01400) to find the first divergent byte.
				// [SRBIT] bit-level CB1/CB2/bit_cnt at the FIRST shift-in turnaround
				// (frame 117 only). Shows whether the VIA samples an idle CB2=1 bit
				// before the Egret drives valid data (the FF first byte).
				// [SRTRN] enriched bit-level turnaround capture: spans the last OUT byte
				// through the first IN bytes. Logs CB1/CB2 as seen by the VIA AND the
				// Egret's raw CB2 data + output-enable (pb_out[5]/pb_ddr[5]) so we can tell
				// whether the leading idle byte is (a) the Egret not yet driving CB2 (oe=0,
				// VIA reads the default 1) or (b) the Egret driving idle data (oe=1, cb2=1).
				// Also tracks the Egret's CB1 drive (pb_out[4]/pb_ddr[4]).
				if (video.count_frame >= 114 && video.count_frame <= 121) {
					static uint32_t trn_key = 0xFFFFFFFF; static int trn_logs = 0;
					uint32_t cb1b = (uint32_t)VERTOPINTERN->emu__DOT__dc0__DOT__via__DOT__shift_clock;
					uint32_t cb2v = 0; // cb2_i optimized away by this Verilator (input, no standalone storage); [SRTRN] VIA-SR debug trace only
					uint32_t bcb  = (uint32_t)VERTOPINTERN->emu__DOT__dc0__DOT__via__DOT__bit_cnt;
					uint32_t acb  = (uint32_t)VERTOPINTERN->emu__DOT__dc0__DOT__via__DOT__acr;
					uint32_t scb  = (uint32_t)VERTOPINTERN->emu__DOT__dc0__DOT__via__DOT__shift_active;
					uint32_t srb  = (uint32_t)VERTOPINTERN->emu__DOT__dc0__DOT__via__DOT__shift_reg;
					uint32_t pbo  = (uint32_t)VERTOPINTERN->emu__DOT__dc0__DOT__egret_inst__DOT__pb_out;
					uint32_t pbd  = (uint32_t)VERTOPINTERN->emu__DOT__dc0__DOT__egret_inst__DOT__pb_ddr;
					uint32_t ecb2=(pbo>>5)&1, ecb2oe=(pbd>>5)&1, ecb1=(pbo>>4)&1, ecb1oe=(pbd>>4)&1;
					uint32_t hpc  = (uint32_t)VERTOPINTERN->emu__DOT__dc0__DOT__egret_inst__DOT__last_pc;
					bool srmode = (acb & 0x10) || (((acb>>2)&7)==3);  // any SR/ext mode
					uint32_t bk = cb1b|(cb2v<<1)|(bcb<<2)|(scb<<6)|(ecb2<<7)|(ecb2oe<<8)|((acb&0x1C)<<9);
					if (srmode && bk != trn_key && trn_logs < 400) {
						DLOG("[SRTRN] F%d cb1=%u cb2via=%u|egr cb2=%u oe=%u cb1=%u oe=%u|bcnt=%u act=%u dir=%s ACR=%02X SReg=%02X hc05=%04X 68k=%06X\n",
							video.count_frame, cb1b, cb2v, ecb2, ecb2oe, ecb1, ecb1oe,
							bcb, scb, ((acb>>2)&7)==7?"OUT":(((acb>>2)&7)==3?"IN ":"?"),
							acb, srb, hpc, VERTOPINTERN->debug_pc & 0xFFFFFF);
						trn_key = bk; trn_logs++;
					}
					// [DDRT] Egret DDRB (pb_ddr) changes — when does CB2 bit5 flip input<->output
					// relative to the SR byte boundaries? Logs the HC05 PC driving the flip.
					static uint32_t ddr_prev = 0xFFFFFFFF; static int ddr_logs = 0;
					if (pbd != ddr_prev && ddr_logs < 60) {
						DLOG("[DDRT] F%d DDRB %02X->%02X (cb2oe=%u cb1oe=%u) pb_out=%02X SR(act=%u bcnt=%u dir=%s) hc05=%04X 68k=%06X\n",
							video.count_frame, ddr_prev==0xFFFFFFFF?pbd:ddr_prev, pbd, (pbd>>5)&1, (pbd>>4)&1, pbo,
							scb, bcb, ((acb>>2)&7)==7?"OUT":(((acb>>2)&7)==3?"IN ":"?"), hpc, VERTOPINTERN->debug_pc & 0xFFFFFF);
						ddr_logs++;
					}
					ddr_prev = pbd;
				}

				static uint32_t prev_act = 0; static int byteseq = 0;
				uint32_t sact = (uint32_t)VERTOPINTERN->emu__DOT__dc0__DOT__via__DOT__shift_active;
				if (prev_act == 1 && sact == 0 && byteseq < 200) {  // shift just completed
					uint32_t sreg = (uint32_t)VERTOPINTERN->emu__DOT__dc0__DOT__via__DOT__shift_reg;
					uint32_t acrv = (uint32_t)VERTOPINTERN->emu__DOT__dc0__DOT__via__DOT__acr;
					uint32_t pbi  = (uint32_t)VERTOPINTERN->emu__DOT__dc0__DOT__via_pb_i;
					DLOG("[SRBYTE] #%d F%d %s SReg=%02X PB=%02X(TREQ=%u BYTEACK=%u TIP=%u) pc=%06X\n",
						byteseq, video.count_frame,
						((acrv>>2)&7)==7 ? "OUT->Egret" : (((acrv>>2)&7)==3 ? "IN <-Egret" : "??"),
						sreg, pbi, (pbi>>3)&1, (pbi>>4)&1, (pbi>>5)&1,
						VERTOPINTERN->debug_pc & 0xFFFFFF);
					byteseq++;
				}
				prev_act = sact;
				// [HC5] one-shot HC05 instruction trace (PC + accumulator A/X) for the
				// FIRST cmd-07 transaction at F117: shows the exact bytes the HC05 sends
				// (regA at the $15C9 send-routine entry) and the path computing byte 5.
				{
					static bool hc5_armed=false; static int hc5_n=0; static uint32_t hc5_prev=0xFFFFFFFF;
					uint32_t hpc=(uint32_t)VERTOPINTERN->emu__DOT__dc0__DOT__egret_inst__DOT__last_pc;
					if (video.count_frame==117 && !hc5_armed && hpc==0x12C2) hc5_armed=true;
					if (hc5_armed && hc5_n<2000 && hpc!=hc5_prev) {
						uint32_t ra=(uint32_t)VERTOPINTERN->emu__DOT__dc0__DOT__egret_inst__DOT__u_cpu__DOT__regA;
						uint32_t rx=(uint32_t)VERTOPINTERN->emu__DOT__dc0__DOT__egret_inst__DOT__u_cpu__DOT__regX;
						DLOG("[HC5] pc=%04X A=%02X X=%02X\n", hpc, ra, rx);
						hc5_prev=hpc; hc5_n++;
					}
				}
			}

			// CPU trace output - skip while ROM is downloading
			// TG68 issues a bus fetch for every code-space word (opcode AND extension
			// words). We buffer consecutive sequential fetches and only emit a log
			// entry when we have enough context to disassemble the full instruction,
			// using Musashi's reported length to advance past extension words.
			if (cpu_trace_enable && VERTOPINTERN->debug_fetch_valid && !*bus.ioctl_download) {
				uint32_t pc = VERTOPINTERN->debug_pc;
				uint16_t opcode = VERTOPINTERN->debug_opcode;

				if (pc != cpu_trace_last_pc) {
					cpu_trace_last_pc = pc;
					int cur_frame = video.count_frame;
					uint32_t dataAddr = VERTOPINTERN->debug_data_addr;

					// If this fetch breaks sequential order (branch/exception),
					// flush the buffer by emitting the oldest entry as an opcode
					// with whatever words we have (single-word disasm is correct
					// for most instructions).
					bool sequential = (fetch_buf_len > 0) &&
						(pc == fetch_buf[fetch_buf_len-1].pc + 2);

					if (!sequential && fetch_buf_len > 0) {
						// Emit buffered entries as individual opcode guesses.
						// For a branch, fetch_buf[0] is a real opcode; anything
						// after would be extensions of it. Use length to skip.
						int i = 0;
						while (i < fetch_buf_len) {
							FetchEntry &e = fetch_buf[i];
							unsigned short opwords[5] = {0};
							int avail = fetch_buf_len - i;
							for (int k = 0; k < avail && k < 5; k++)
								opwords[k] = fetch_buf[i+k].word;
							unsigned int len = 2;
							const char* disasm = disassemble_68k_ext_len(e.pc, opwords, avail, &len);
							if (len < 2) len = 2;
							int words = len / 2;
							cpu_trace_count++;
							console.AddLog("[F%d] %08X: %04X  %s  @%06X", e.frame, e.pc, e.word, disasm, e.data_addr);
							if (cpu_trace_file && e.frame >= trace_from_frame && e.frame <= trace_to_frame) {
								if (e.frame != cpu_trace_last_frame) {
									fprintf(cpu_trace_file, "--- frame %d ---\n", e.frame);
									cpu_trace_last_frame = e.frame;
								}
								fprintf(cpu_trace_file, "[F%d] %08X: %04X  %s  @%06X\n", e.frame, e.pc, e.word, disasm, e.data_addr);
							}
							i += words;
						}
						fetch_buf_len = 0;
					}

					// Append this fetch to the buffer.
					if (fetch_buf_len < FETCH_BUF_SIZE) {
						fetch_buf[fetch_buf_len++] = { pc, opcode, cur_frame, dataAddr };
					} else {
						// Buffer full — emit oldest then shift.
						// (Shouldn't happen in practice; longest 68020 instruction is 11 words.)
						FetchEntry &e = fetch_buf[0];
						unsigned short opwords[5] = {0};
						for (int k = 0; k < 5; k++) opwords[k] = fetch_buf[k].word;
						unsigned int len = 2;
						const char* disasm = disassemble_68k_ext_len(e.pc, opwords, 5, &len);
						if (len < 2) len = 2;
						int words = len / 2;
						if (words > FETCH_BUF_SIZE) words = FETCH_BUF_SIZE;
						cpu_trace_count++;
						console.AddLog("[F%d] %08X: %04X  %s  @%06X", e.frame, e.pc, e.word, disasm, e.data_addr);
						if (cpu_trace_file && e.frame >= trace_from_frame && e.frame <= trace_to_frame) {
							if (e.frame != cpu_trace_last_frame) {
								fprintf(cpu_trace_file, "--- frame %d ---\n", e.frame);
								cpu_trace_last_frame = e.frame;
							}
							fprintf(cpu_trace_file, "[F%d] %08X: %04X  %s  @%06X\n", e.frame, e.pc, e.word, disasm, e.data_addr);
						}
						// Shift out `words` entries
						int keep = fetch_buf_len - words;
						for (int k = 0; k < keep; k++) fetch_buf[k] = fetch_buf[k + words];
						fetch_buf_len = keep;
						fetch_buf[fetch_buf_len++] = { pc, opcode, cur_frame, dataAddr };
					}

					if (cpu_trace_max > 0 && cpu_trace_count >= cpu_trace_max && cpu_trace_file) {
						fprintf(stderr, "CPU trace limit reached (%d instructions)\n", cpu_trace_count);
						fclose(cpu_trace_file);
						cpu_trace_file = nullptr;
					}
				}
			}

			// RAM debug output - skip while ROM is downloading
			if (ram_debug_enable && !*bus.ioctl_download && ram_debug_file) {
				bool we = VERTOPINTERN->debug_ram_we;
				bool oe = VERTOPINTERN->debug_ram_oe;
				bool selectRAM = VERTOPINTERN->debug_selectRAM;
				bool selectROM = VERTOPINTERN->debug_selectROM;
				bool cpu_write = !VERTOPINTERN->debug_cpuRW;  // RW=0 means write
				bool bus_control = VERTOPINTERN->debug_cpuBusControl;

				// Log actual RAM/ROM accesses, or attempted writes during overlay (selectROM but CPU write)
				bool is_access = (we || oe) && (selectRAM || selectROM);
				bool is_failed_write = selectROM && cpu_write && bus_control && !selectRAM;  // Write to overlay ROM area

				if ((is_access || is_failed_write) && ram_debug_count < ram_debug_max) {
					uint32_t addr = VERTOPINTERN->debug_ram_addr;
					uint32_t cpuAddr = VERTOPINTERN->debug_cpuAddr;
					uint16_t din = VERTOPINTERN->debug_ram_din;
					uint16_t dout = VERTOPINTERN->debug_ram_dout;
					uint8_t ds = VERTOPINTERN->debug_ram_ds;

					const char* op = we ? "WR" : (is_failed_write ? "WR-FAIL" : "RD");
					fprintf(ram_debug_file, "%s cpuAddr=%06X ramAddr=%07X din=%04X dout=%04X ds=%d%d selRAM=%d selROM=%d\n",
						op,
						cpuAddr, addr, din, dout,
						(ds >> 1) & 1, ds & 1,
						selectRAM ? 1 : 0,
						selectROM ? 1 : 0);
					ram_debug_count++;
					if (ram_debug_count >= ram_debug_max) {
						fprintf(stderr, "RAM debug limit reached (%d accesses)\n", ram_debug_max);
						fclose(ram_debug_file);
						ram_debug_file = nullptr;
					}
				}
			}

			// Peripheral debug output - log on falling edge of cpuBusControl
			if (periph_debug_enable && !*bus.ioctl_download && periph_debug_file) {
				bool bus_control = VERTOPINTERN->debug_cpuBusControl;
				// Log on rising edge of bus control (start of CPU cycle) when a peripheral is selected
				if (bus_control && !periph_debug_prev_bus_control) {
					bool selectVIA = VERTOPINTERN->debug_selectVIA;
					bool selectAriel = VERTOPINTERN->debug_selectAriel;
					bool selectPseudoVIA = VERTOPINTERN->debug_selectPseudoVIA;
					bool selectSCSI = VERTOPINTERN->debug_selectSCSI;
					bool selectSCC = VERTOPINTERN->debug_selectSCC;
					bool selectIWM = VERTOPINTERN->debug_selectIWM;
					bool selectVRAM = VERTOPINTERN->debug_selectVRAM;

					if ((selectVIA || selectAriel || selectPseudoVIA || selectSCSI || selectSCC || selectIWM || selectVRAM)
					    && periph_debug_count < periph_debug_max) {
						uint32_t addr = VERTOPINTERN->debug_cpuAddr;
						uint16_t data_in = VERTOPINTERN->debug_cpuDataIn;
						uint16_t data_out = VERTOPINTERN->debug_cpuDataOut;
						bool rw = VERTOPINTERN->debug_cpuRW;

						const char* periph_name = selectVIA ? "VIA" :
						                          selectAriel ? "ARIEL" :
						                          selectPseudoVIA ? "PVIA" :
						                          selectSCSI ? "SCSI" :
						                          selectSCC ? "SCC" :
						                          selectIWM ? "IWM" : 
						                          selectVRAM ? "VRAM" : "???";

						fprintf(periph_debug_file, "[%llu] %s %s addr=%06X data_in=%04X data_out=%04X\n",
							(unsigned long long)main_time,
							rw ? "RD" : "WR",
							periph_name,
							addr,
							data_in,
							data_out);
						periph_debug_count++;
						if (periph_debug_count >= periph_debug_max) {
							fprintf(stderr, "Peripheral debug limit reached (%d accesses)\n", periph_debug_max);
							fclose(periph_debug_file);
							periph_debug_file = nullptr;
						}
					}
				}
				periph_debug_prev_bus_control = bus_control;
			}
		}

#ifndef DISABLE_AUDIO
		if (clk_sys.IsRising())
		{
			audio.Clock(VERTOPINTERN->AUDIO_L, VERTOPINTERN->AUDIO_R);
		}
#endif

					// Output pixels on rising edge of pixel clock
				if (clk_sys.IsRising() && VERTOPINTERN->CE_PIXEL) {
					uint32_t colour = 0xFF000000 | VERTOPINTERN->VGA_B << 16 | VERTOPINTERN->VGA_G << 8 | VERTOPINTERN->VGA_R;
					video.Clock(VERTOPINTERN->VGA_HB, VERTOPINTERN->VGA_VB, VERTOPINTERN->VGA_HS, VERTOPINTERN->VGA_VS, colour);
				}
				// [RAWVID] un-CE-gated colour range at the top-level pins: every
				// rising edge, active area only. Distinguishes "module output is
				// uniform" from "CE_PIXEL sampling misses the colours".
				if (clk_sys.IsRising()) {
					static uint8_t rmin = 0xFF, rmax = 0; static uint64_t rawn = 0;
					if (!VERTOPINTERN->VGA_HB && !VERTOPINTERN->VGA_VB) {
						uint8_t r = VERTOPINTERN->VGA_R;
						if (r < rmin) rmin = r; if (r > rmax) rmax = r;
					}
					if ((++rawn % 5000000) == 0) {
						fprintf(stderr, "[RAWVID] n=%llu rmin=%02X rmax=%02X\n", (unsigned long long)rawn, rmin, rmax);
						rmin = 0xFF; rmax = 0;
					}
				}
		
				if (clk_sys.IsRising()) {
					// Serial terminal: tick soft UART and drive SCC RX
					{
						bool fpga_txd = VERTOPINTERN->serial_txd;
						bool sim_rxd = serialTerminal.Tick(fpga_txd);
						VERTOPINTERN->serial_rxd = sim_rxd;

						// Auto-detect baud rate from SCC's baud divider register
						static uint32_t last_baud_div = 0;
						uint32_t baud_div = VERTOPINTERN->emu__DOT__dc0__DOT__s__DOT__baud_divid_speed_a;
						if (baud_div != last_baud_div) {
							serialTerminal.UpdateConfigDirect(baud_div, 8, 1, false, false);
							last_baud_div = baud_div;
						}
					}

					main_time++;
					// Print progress every 10 million cycles (~300ms of simulated time at 32MHz)
					if ((main_time % 5000000) == 0) {
						DLOG( "Cycle %llu [F%d]: PC=%08X Op=%04X\n",
							(unsigned long long)main_time,
							video.count_frame,
							VERTOPINTERN->debug_pc,
							VERTOPINTERN->debug_opcode);
					}

					// --- Bus-stall measurement during the RAM-test march ---
					// Per clk_sys: classify the CPU bus state. AS asserted (=0) with
					// DTACK not yet acked (=1) => stalled waiting; AS asserted & DTACK
					// acked (=0) => transfer cycle; AS negated => internal/idle.
					{
						static uint64_t bm_total=0, bm_stall=0, bm_xfer=0, bm_idle=0, bm_accesses=0;
						static bool bm_as_prev=true; static int bm_last_report_frame=-1;
						uint32_t mpc = VERTOPINTERN->debug_pc & 0xFFFFFF;
						bool in_march = (mpc >= 0xA46880 && mpc <= 0xA46960);
						if (in_march) {
							bool as = VERTOPINTERN->debug_cpu_as;       // 1=negated,0=asserted
							bool dtack = VERTOPINTERN->debug_cpu_dtack; // 1=not acked,0=acked
							bm_total++;
							if (!as && dtack) bm_stall++;
							else if (!as && !dtack) bm_xfer++;
							else bm_idle++;
							if (bm_as_prev && !as) bm_accesses++; // AS falling edge = new access
							bm_as_prev = as;
							int f = video.count_frame;
							if (f != bm_last_report_frame && (f % 40)==0 && bm_total>0) {
								bm_last_report_frame = f;
								DLOG( "[BUS F%d] total=%llu stall=%llu xfer=%llu idle=%llu accesses=%llu | stall=%.0f%% xfer=%.0f%% idle=%.0f%% -> %.1f clk/access\n",
									f,
									(unsigned long long)bm_total,
									(unsigned long long)bm_stall,
									(unsigned long long)bm_xfer,
									(unsigned long long)bm_idle,
									(unsigned long long)bm_accesses,
									100.0*bm_stall/bm_total,
									100.0*bm_xfer/bm_total,
									100.0*bm_idle/bm_total,
									bm_accesses?(double)bm_total/bm_accesses:0.0);
							}
						}
					}
					// Enable trace after download completes to see initial 68K execution
					static bool last_download = false;
					if (last_download && !*bus.ioctl_download && !cpu_trace_enable && !cpu_trace_disabled) {
						cpu_trace_enable = true;
						DLOG( "*** Enabling CPU trace after ROM download ***\n");
						if (!cpu_trace_file) {
							cpu_trace_file = fopen(cpu_trace_filename, "w");
						}
					}
					last_download = *bus.ioctl_download;
				}
				return 1;
			}
	// Stop verilating and cleanup
	top->final();
	delete top;
	exit(0);
	return 0;
}

void show_help() {
	printf("Mac IIvi Hardware Simulator\n");
	printf("Usage: ./Vemu [options]\n\n");
	printf("Options:\n");
	printf("  -h, --help                    Show this help message\n");
	printf("  --headless, --no-gui          Run without SDL/ImGui (CI/headless)\n");
	printf("  --screenshot <frames>         Take screenshots at specified frame numbers\n");
	printf("                                (comma-separated list, e.g., 100,200,300)\n");
	printf("  --stop-at-frame <frame>       Exit simulation after specified frame\n");
	printf("  --rom <path>                  Boot ROM (default ../releases/boot0.rom)\n");
	printf("                                e.g. --rom ../releases/boot0-nomemcheck.rom\n");
	printf("  --heartbeat                   Print the 68k PC once per frame (progress on long runs)\n");
	printf("  --mouse-from <frame>          Inject synthetic ADB mouse motion from this frame on\n");
	printf("  --mouse-to <frame>            Stop the synthetic mouse motion after this frame\n");
	printf("  -v, --verbose                 Enable verbose bring-up diagnostics\n");
	printf("                                (overlay/FC/march/RAMCFG/bus/CPU-trace spam)\n");
	printf("\n");
	printf("Examples:\n");
	printf("  ./Vemu                        Run simulator in windowed mode\n");
	printf("  ./Vemu --screenshot 245       Take screenshot at frame 245\n");
	printf("  ./Vemu --stop-at-frame 300    Stop simulation after frame 300\n");
	printf("  ./Vemu --headless --screenshot 50 --stop-at-frame 100\n");
	printf("                                Headless, take screenshot at frame 50, stop at 100\n");
}

void save_screenshot(int frame_number) {
	if (!output_ptr) {
		printf("Error: output_ptr is null, cannot save screenshot\n");
		return;
	}

	char filename[256];
	snprintf(filename, sizeof(filename), "screenshot_frame_%04d.png", frame_number);

	// Read from the video output buffer that video.Clock() writes to
	// The colour format is: 0xFF000000 | B << 16 | G << 8 | R (ABGR)
	// Mac LC screen dimensions come from the video module

	int width = video.output_width;
	int height = video.output_height;

	uint8_t* rgb_data = (uint8_t*)malloc(width * height * 3);
	if (!rgb_data) {
		printf("Error: Could not allocate memory for screenshot\n");
		return;
	}

	for (int y = 0; y < height; y++) {
		for (int x = 0; x < width; x++) {
			uint32_t pixel = output_ptr[y * width + x];
			int dst_index = (y * width + x) * 3;

			// Format: 0xFF000000 | B << 16 | G << 8 | R (ABGR)
			uint8_t b = (pixel >> 16) & 0xFF;
			uint8_t g = (pixel >> 8) & 0xFF;
			uint8_t r = (pixel >> 0) & 0xFF;

			rgb_data[dst_index + 0] = r;
			rgb_data[dst_index + 1] = g;
			rgb_data[dst_index + 2] = b;
		}
	}

	// Save as PNG using stb_image_write
	int result = stbi_write_png(filename, width, height, 3, rgb_data, width * 3);

	free(rgb_data);

	if (result) {
		printf("Screenshot saved: %s (%dx%d)\n", filename, width, height);
	} else {
		printf("Error: Failed to save screenshot %s\n", filename);
	}
}

unsigned char mouse_clock = 0;
unsigned char mouse_buttons = 0;
unsigned char mouse_x = 0;
unsigned char mouse_y = 0;

// Real SDL mouse capture (like lbmactwo_MiSTer): click the VGA image to capture
// the host mouse; move/click to drive the ADB mouse; press Esc or F1 to release.
// Relative motion is accumulated during each frame's SDL event poll, then applied
// to ps2_mouse below.
extern SDL_Window* window;
bool mouse_captured = false;
int  sdl_mouse_dx = 0;
int  sdl_mouse_dy = 0;
int  sdl_mouse_btn = 0;

int main(int argc, char** argv, char** env) {

	// Parse command-line arguments
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
			show_help();
			return 0;
		} else if (strcmp(argv[i], "--headless") == 0 || strcmp(argv[i], "--no-gui") == 0) {
			headless = true;
		} else if (strcmp(argv[i], "--screenshot") == 0 && i + 1 < argc) {
			screenshot_mode = true;
			std::string frames_str = argv[i + 1];
			std::stringstream ss(frames_str);
			std::string frame_num;
			while (std::getline(ss, frame_num, ',')) {
				screenshot_frames.push_back(std::stoi(frame_num));
			}
			printf("Screenshot mode enabled for frames: %s\n", frames_str.c_str());
			i++;
		} else if (strcmp(argv[i], "--stop-at-frame") == 0 && i + 1 < argc) {
			stop_at_frame = std::stoi(argv[i + 1]);
			stop_at_frame_enabled = true;
			printf("Will stop at frame %d\n", stop_at_frame);
			i++;
		} else if (strcmp(argv[i], "--reset-at-frame") == 0 && i + 1 < argc) {
			reset_at_frame = std::stoi(argv[i + 1]);
			printf("Will pulse a WARM reset at frame %d (ROM kept in SDRAM)\n", reset_at_frame);
			i++;
		} else if (strcmp(argv[i], "--nmi-at-frame") == 0 && i + 1 < argc) {
			nmi_at_frame = std::stoi(argv[i + 1]);
			printf("Will pulse a Level-7 NMI at frame %d (MacsBug-path test)\n", nmi_at_frame);
			i++;
		} else if (strcmp(argv[i], "--no-cpu-trace") == 0) {
			cpu_trace_disabled = true;
			printf("Per-instruction CPU trace disabled (cpu_trace.log will not be written)\n");
		} else if (strcmp(argv[i], "--trace-frames") == 0 && i + 1 < argc) {
			// "A,B" — only write trace lines for frames in [A,B]
			std::string s = argv[++i];
			size_t comma = s.find(',');
			trace_from_frame = std::stoi(s.substr(0, comma));
			trace_to_frame = (comma == std::string::npos) ? trace_from_frame
			                                              : std::stoi(s.substr(comma + 1));
			printf("CPU trace restricted to frames [%d,%d]\n", trace_from_frame, trace_to_frame);
		} else if (strcmp(argv[i], "--verbose") == 0 || strcmp(argv[i], "-v") == 0) {
			verbose_diag = true;
			printf("Verbose bring-up diagnostics enabled\n");
		} else if (strcmp(argv[i], "--scsi0") == 0 && i + 1 < argc) {
			scsi_disk_files[0] = argv[++i];   // SCSI-6 (.img/.vhd) -> block device
		} else if (strcmp(argv[i], "--scsi1") == 0 && i + 1 < argc) {
			scsi_disk_files[1] = argv[++i];   // SCSI-5
		} else if (strcmp(argv[i], "--floppy0") == 0 && i + 1 < argc) {
			floppy_disk_files[0] = argv[++i]; // primary floppy (.dsk) -> SDRAM download
		} else if (strcmp(argv[i], "--floppy1") == 0 && i + 1 < argc) {
			floppy_disk_files[1] = argv[++i]; // secondary floppy
		} else if (strcmp(argv[i], "--rom") == 0 && i + 1 < argc) {
			rom_file_override = argv[++i];    // boot ROM path (default ../releases/boot0.rom)
		} else if (strcmp(argv[i], "--heartbeat") == 0) {
			pc_heartbeat = true;              // once-per-frame 68k PC print
		} else if (strcmp(argv[i], "--mouse-from") == 0 && i + 1 < argc) {
			mouse_inject_from = std::stoi(argv[++i]);
			printf("Synthetic ADB mouse motion from frame %d\n", mouse_inject_from);
		} else if (strcmp(argv[i], "--mouse-to") == 0 && i + 1 < argc) {
			mouse_inject_to = std::stoi(argv[++i]);
			printf("Synthetic ADB mouse motion stops after frame %d\n", mouse_inject_to);
		}
	}

	// Create core and initialise
	top = new Vemu();
	Verilated::commandArgs(argc, argv);
	Verilated::traceEverOn(true);

	// Attach bus - using 16-bit ioctl_dout for MacIIvi
	bus.ioctl_addr = &VERTOPINTERN->ioctl_addr;
	bus.ioctl_index = &VERTOPINTERN->ioctl_index;
	bus.ioctl_wait = &VERTOPINTERN->ioctl_wait;
	bus.ioctl_download = &VERTOPINTERN->ioctl_download;
	bus.ioctl_wr = &VERTOPINTERN->ioctl_wr;
	bus.ioctl_dout = &VERTOPINTERN->ioctl_dout;  // 16-bit for MacIIvi
	input.ps2_key = &VERTOPINTERN->ps2_key;

	// Hookup block device for SCSI (2 devices for MacIIvi)
	blockdevice.sd_lba[0] = &VERTOPINTERN->sd_lba[0];
	blockdevice.sd_lba[1] = &VERTOPINTERN->sd_lba[1];
	blockdevice.sd_rd = &VERTOPINTERN->sd_rd;
	blockdevice.sd_wr = &VERTOPINTERN->sd_wr;
	blockdevice.sd_ack = &VERTOPINTERN->sd_ack;
	blockdevice.sd_buff_addr = &VERTOPINTERN->sd_buff_addr;
	blockdevice.sd_buff_dout = &VERTOPINTERN->sd_buff_dout;
	blockdevice.sd_buff_din[0] = &VERTOPINTERN->sd_buff_din[0];
	blockdevice.sd_buff_din[1] = &VERTOPINTERN->sd_buff_din[1];
	blockdevice.sd_buff_wr = &VERTOPINTERN->sd_buff_wr;
	blockdevice.img_mounted = &VERTOPINTERN->img_mounted;
	blockdevice.img_size = &VERTOPINTERN->img_size;
	for (int disk_index = 0; disk_index < 2; disk_index++) {
		if (!scsi_disk_files[disk_index].empty()) {
			blockdevice.MountDisk(scsi_disk_files[disk_index], disk_index);
			fprintf(stderr, "Mounting SCSI%d image: %s\n", disk_index, scsi_disk_files[disk_index].c_str());
		}
	}

#ifndef DISABLE_AUDIO
	if (!headless) audio.Initialise();
#endif

	// Set up input module
	input.Initialise();
#ifdef WIN32
	input.SetMapping(input_up, DIK_UP);
	input.SetMapping(input_right, DIK_RIGHT);
	input.SetMapping(input_down, DIK_DOWN);
	input.SetMapping(input_left, DIK_LEFT);
	input.SetMapping(input_a, DIK_Z);
	input.SetMapping(input_b, DIK_X);
	input.SetMapping(input_x, DIK_A);
	input.SetMapping(input_y, DIK_S);
	input.SetMapping(input_l, DIK_Q);
	input.SetMapping(input_r, DIK_W);
	input.SetMapping(input_select, DIK_1);
	input.SetMapping(input_start, DIK_2);
	input.SetMapping(input_menu, DIK_M);
#else
	input.SetMapping(input_up, SDL_SCANCODE_UP);
	input.SetMapping(input_right, SDL_SCANCODE_RIGHT);
	input.SetMapping(input_down, SDL_SCANCODE_DOWN);
	input.SetMapping(input_left, SDL_SCANCODE_LEFT);
	input.SetMapping(input_a, SDL_SCANCODE_A);
	input.SetMapping(input_b, SDL_SCANCODE_B);
	input.SetMapping(input_x, SDL_SCANCODE_X);
	input.SetMapping(input_y, SDL_SCANCODE_Y);
	input.SetMapping(input_l, SDL_SCANCODE_L);
	input.SetMapping(input_r, SDL_SCANCODE_E);
	input.SetMapping(input_start, SDL_SCANCODE_1);
	input.SetMapping(input_select, SDL_SCANCODE_2);
	input.SetMapping(input_menu, SDL_SCANCODE_M);
#endif

	// Setup video output. Headless: allocate ONLY the pixel buffer that
	// video.Clock() fills and save_screenshot() reads — no SDL, no ImGui, no
	// window. (The --headless flag existed but was never wired; it crashed in
	// ImGui::NewFrame because SDL/ImGui were still initialised uncondition-
	// ally. Long sim runs must survive WSLg display outages.)
	if (headless) {
		output_ptr = (uint32_t*)malloc(video.output_width * video.output_height * 4);
		if (!output_ptr) { fprintf(stderr, "headless: framebuffer alloc failed\n"); return 1; }
		fprintf(stderr, "Headless mode: no window; screenshots + stop-at-frame active\n");
	} else if (video.Initialise(windowTitle) == 1) { return 1; }

	// Open CPU trace file
	if (cpu_trace_enable) {
		cpu_trace_file = fopen(cpu_trace_filename, "w");
		if (cpu_trace_file) {
			fprintf(stderr, "CPU trace enabled, writing to %s\n", cpu_trace_filename);
		} else {
			fprintf(stderr, "Failed to open trace file %s\n", cpu_trace_filename);
			cpu_trace_enable = false;
		}
	}

	// Open RAM debug file
	if (ram_debug_enable) {
		ram_debug_file = fopen(ram_debug_filename, "w");
		if (ram_debug_file) {
			fprintf(stderr, "RAM debug enabled, writing to %s\n", ram_debug_filename);
		} else {
			fprintf(stderr, "Failed to open RAM debug file %s\n", ram_debug_filename);
			ram_debug_enable = false;
		}
	}

	// Open peripheral debug file
	if (periph_debug_enable) {
		periph_debug_file = fopen(periph_debug_filename, "w");
		if (periph_debug_file) {
			fprintf(stderr, "Peripheral debug enabled, writing to %s\n", periph_debug_filename);
		} else {
			fprintf(stderr, "Failed to open peripheral debug file %s\n", periph_debug_filename);
			periph_debug_enable = false;
		}
	}

	// Auto-load Mac LC ROM at startup (--rom <path> overrides the default).
	const char* rom_file = rom_file_override.empty()
	                         ? "../releases/boot0.rom"
	                         : rom_file_override.c_str();
	bus.QueueDownload(rom_file, 0, 1);  // index 0 for ROM
	fprintf(stderr, "Machine type: Mac LC, loading ROM: %s\n", rom_file);

	// Floppy images stream into SDRAM via ioctl, same as a HPS mount.
	// MacIIvi uses ioctl_index 1 (F1/primary) and 2 (F2/secondary) — see
	// MacIIvi.sv dio_a decode. (lbmactwo uses 2/3 because index 1 is its NuBus ROM.)
	for (int disk_index = 0; disk_index < 2; disk_index++) {
		if (!floppy_disk_files[disk_index].empty()) {
			int ioctl_index = disk_index == 0 ? 1 : 2;
			bus.QueueDownload(floppy_disk_files[disk_index], ioctl_index, 1);
			fprintf(stderr, "Loading floppy%d image (ioctl_index %d): %s\n",
			        disk_index, ioctl_index, floppy_disk_files[disk_index].c_str());
		}
	}

	// Initial eval() to establish clock state for Verilator
	// This is needed for correct rising edge detection on the first cycle
	VERTOPINTERN->clk_sys = 0;
	VERTOPINTERN->reset = 1;
	top->eval();

#ifdef WIN32
	MSG msg;
	ZeroMemory(&msg, sizeof(msg));
	while (msg.message != WM_QUIT)
	{
		if (PeekMessage(&msg, NULL, 0U, 0U, PM_REMOVE))
		{
			TranslateMessage(&msg);
			DispatchMessage(&msg);
			continue;
		}
#else
	bool done = false;
	while (!done)
	{
		// Headless fast path: run the sim, honor screenshots + stop-at-frame,
		// touch nothing SDL/ImGui.
		if (headless) {
			bool took_ss = false;
			if (screenshot_mode) {
				auto it = std::find(screenshot_frames.begin(), screenshot_frames.end(), video.count_frame);
				if (it != screenshot_frames.end()) {
					save_screenshot(video.count_frame);
					screenshot_frames.erase(it);
					took_ss = true;
				}
			}
			if (stop_at_frame_enabled && video.count_frame >= stop_at_frame) {
				printf("Reached stop frame %d%s, exiting...\n", stop_at_frame,
				       took_ss ? " after taking screenshot" : "");
				break;
			}
			// Synthetic ADB mouse motion (--mouse-from): one ps2 packet per frame.
			// The GUI path below rebuilds ps2_mouse every UI frame, but this fast
			// path never touched it — the input sat frozen at zero, so adb_device
			// never saw a single event in any headless run.
			if (mouse_inject_from >= 0) {
				static int last_inject_frame = -1;
				int f = video.count_frame;
				if (f != last_inject_frame && f >= mouse_inject_from && f <= mouse_inject_to) {
					last_inject_frame = f;
					static const int wig[4][2] = { {2,0}, {0,2}, {-2,0}, {0,-2} };
					int dx = wig[f & 3][0], dy = wig[f & 3][1];
					unsigned char status_byte = 0x08;
					if (dx < 0) status_byte |= 0x10;   // X sign -> ps2_mouse[4]
					if (dy < 0) status_byte |= 0x20;   // Y sign -> ps2_mouse[5]
					unsigned long mouse_temp = status_byte;
					mouse_temp |= ((unsigned char)dx << 8);
					mouse_temp |= ((unsigned char)dy << 16);
					if (mouse_clock) { mouse_temp |= (1UL << 24); }
					mouse_clock = !mouse_clock;
					VERTOPINTERN->ps2_mouse = mouse_temp;
				}
			}
			if (run_enable) { for (int step = 0; step < batchSize; step++) { verilate(); } }
			continue;
		}
		sdl_mouse_dx = 0;
		sdl_mouse_dy = 0;
		SDL_Event event;
		while (SDL_PollEvent(&event))
		{
			ImGui_ImplSDL2_ProcessEvent(&event);
			if (event.type == SDL_QUIT)
				done = true;

			// Mouse capture uses SDL relative mode: the OS cursor is hidden and
			// confined, and motion.xrel/yrel give pure relative deltas, so the
			// pointer can never wander off the emulated screen.
			if (event.type == SDL_MOUSEMOTION && mouse_captured) {
				sdl_mouse_dx += event.motion.xrel;
				sdl_mouse_dy += event.motion.yrel;
			}
			if (mouse_captured) {
				if (event.type == SDL_MOUSEBUTTONDOWN && event.button.button == SDL_BUTTON_LEFT)
					sdl_mouse_btn = 1;
				if (event.type == SDL_MOUSEBUTTONUP && event.button.button == SDL_BUTTON_LEFT)
					sdl_mouse_btn = 0;
			}
			// Esc / F1 releases the captured mouse.
			if (event.type == SDL_KEYDOWN && mouse_captured &&
			    (event.key.keysym.sym == SDLK_ESCAPE || event.key.keysym.sym == SDLK_F1)) {
				mouse_captured = false;
				SDL_SetRelativeMouseMode(SDL_FALSE);
			}
		}
#endif
		video.StartFrame();

		input.Read();

		// Draw GUI
		// --------
		ImGui::NewFrame();

		// Simulation control window
		ImGui::Begin(windowTitle_Control);
		ImGui::SetWindowPos(windowTitle_Control, ImVec2(0, 0), ImGuiCond_Once);
		ImGui::SetWindowSize(windowTitle_Control, ImVec2(500, 200), ImGuiCond_Once);
		if (ImGui::Button("Reset simulation")) { resetSim(); } ImGui::SameLine();
		if (ImGui::Button("Start running")) { run_enable = 1; } ImGui::SameLine();
		if (ImGui::Button("Stop running")) { run_enable = 0; } ImGui::SameLine();
		ImGui::Checkbox("RUN", &run_enable);
		ImGui::SliderInt("Run batch size", &batchSize, 1, 250000);
		if (single_step == 1) { single_step = 0; }
		if (ImGui::Button("Single Step")) { run_enable = 0; single_step = 1; }
		ImGui::SameLine();
		if (multi_step == 1) { multi_step = 0; }
		if (ImGui::Button("Multi Step")) { run_enable = 0; multi_step = 1; }
		ImGui::SliderInt("Multi step amount", &multi_step_amount, 8, 1024);

		if (ImGui::Button("Load ROM"))
			ImGuiFileDialog::Instance()->OpenDialog("ChooseFileDlgKey", "Choose ROM File", ".rom,.bin", ".");

		// CPU trace controls
		ImGui::Separator();
		ImGui::Checkbox("CPU Trace", &cpu_trace_enable);
		ImGui::SameLine();
		ImGui::Text("PC: %08X  Op: %04X", VERTOPINTERN->debug_pc, VERTOPINTERN->debug_opcode);

		// Machine configuration (display only - requires restart to change)
		ImGui::Separator();
		ImGui::Text("Machine: Mac LC | CPU: TG68K | RAM: %s",
			cfg_memSize ? "4MB" : "1MB");

		ImGui::End();

		// Debug log window
		console.Draw(windowTitle_DebugLog, &showDebugLog, ImVec2(500, 700));
		ImGui::SetWindowPos(windowTitle_DebugLog, ImVec2(0, 210), ImGuiCond_Once);

		// Memory debug - access sim_ram memory
		ImGui::Begin("RAM Editor");
		ImGui::Text("Note: Memory editor requires direct RAM access");
		ImGui::Text("RAM module is sim_ram with 8MB capacity");
		ImGui::End();

		int windowX = 550;
		int windowWidth = (VGA_WIDTH * VGA_SCALE_X) + 24;
		// +120: room for the zoom/rotate/flip controls, the stats line, and the
		// mouse-capture status line below the image, so the full frame is visible.
		int windowHeight = (VGA_HEIGHT * VGA_SCALE_Y) + 120;

		// Video window
		ImGui::Begin(windowTitle_Video);
		ImGui::SetWindowPos(windowTitle_Video, ImVec2(windowX, 0), ImGuiCond_Once);
		ImGui::SetWindowSize(windowTitle_Video, ImVec2(windowWidth, windowHeight), ImGuiCond_Once);

		ImGui::SliderFloat("Zoom", &vga_scale, 1, 4); ImGui::SameLine();
		ImGui::SliderInt("Rotate", &video.output_rotate, -1, 1); ImGui::SameLine();
		ImGui::Checkbox("Flip V", &video.output_vflip);
		ImGui::Text("main_time: %ld frame_count: %d sim FPS: %f", main_time, video.count_frame, video.stats_fps);

		// Draw VGA output, and let a click on it capture the host mouse.
		ImVec2 vga_size(video.output_width * VGA_SCALE_X, video.output_height * VGA_SCALE_Y);
		ImVec2 vga_cursor = ImGui::GetCursorPos();
		ImGui::Image(video.texture_id, vga_size);
		ImGui::SetCursorPos(vga_cursor);
		ImGui::InvisibleButton("##vga_capture", vga_size);
		if (ImGui::IsItemClicked(0)) {
			mouse_captured = true;
			SDL_SetRelativeMouseMode(SDL_TRUE);   // hide + confine the host cursor
		}
		ImGui::Text("%s", mouse_captured ? "Mouse captured - press Esc or F1 to release"
		                                  : "Click display to capture mouse");
		ImGui::End();

		// Serial terminal window
		serialTerminal.UpdateSCCStatus(
			VERTOPINTERN->emu__DOT__dc0__DOT__s__DOT__wr3_a,
			VERTOPINTERN->emu__DOT__dc0__DOT__s__DOT__wr4_a,
			VERTOPINTERN->emu__DOT__dc0__DOT__s__DOT__wr5_a,
			VERTOPINTERN->emu__DOT__dc0__DOT__s__DOT__wr9,
			VERTOPINTERN->emu__DOT__dc0__DOT__s__DOT__wr14_a);
		static bool showSerial = true;
		serialTerminal.Draw("Serial Terminal A", &showSerial);

		if (ImGuiFileDialog::Instance()->Display("ChooseFileDlgKey"))
		{
			if (ImGuiFileDialog::Instance()->IsOk())
			{
				std::string filePathName = ImGuiFileDialog::Instance()->GetFilePathName();
				std::string filePath = ImGuiFileDialog::Instance()->GetCurrentPath();
				fprintf(stderr, "Loading ROM: %s\n", filePathName.c_str());
				bus.QueueDownload(filePathName, 0, 1);  // index 0 for ROM
			}
			ImGuiFileDialog::Instance()->Close();
		}

#ifndef DISABLE_AUDIO
		ImGui::Begin(windowTitle_Audio);
		ImGui::SetWindowPos(windowTitle_Audio, ImVec2(windowX, windowHeight), ImGuiCond_Once);
		ImGui::SetWindowSize(windowTitle_Audio, ImVec2(windowWidth, 250), ImGuiCond_Once);

		if (run_enable) {
			audio.CollectDebug((signed short)VERTOPINTERN->AUDIO_L, (signed short)VERTOPINTERN->AUDIO_R);
		}
		int channelWidth = (windowWidth / 2) - 16;
		ImPlot::CreateContext();
		if (ImPlot::BeginPlot("Audio - L", ImVec2(channelWidth, 220), ImPlotFlags_NoLegend | ImPlotFlags_NoMenus | ImPlotFlags_NoTitle)) {
			ImPlot::SetupAxes("T", "A", ImPlotAxisFlags_NoLabel | ImPlotAxisFlags_NoTickMarks, ImPlotAxisFlags_AutoFit | ImPlotAxisFlags_NoLabel | ImPlotAxisFlags_NoTickMarks);
			ImPlot::SetupAxesLimits(0, 1, -1, 1, ImPlotCond_Once);
			ImPlot::PlotStairs("", audio.debug_positions, audio.debug_wave_l, audio.debug_max_samples, audio.debug_pos);
			ImPlot::EndPlot();
		}
		ImGui::SameLine();
		if (ImPlot::BeginPlot("Audio - R", ImVec2(channelWidth, 220), ImPlotFlags_NoLegend | ImPlotFlags_NoMenus | ImPlotFlags_NoTitle)) {
			ImPlot::SetupAxes("T", "A", ImPlotAxisFlags_NoLabel | ImPlotAxisFlags_NoTickMarks, ImPlotAxisFlags_AutoFit | ImPlotAxisFlags_NoLabel | ImPlotAxisFlags_NoTickMarks);
			ImPlot::SetupAxesLimits(0, 1, -1, 1, ImPlotCond_Once);
			ImPlot::PlotStairs("", audio.debug_positions, audio.debug_wave_r, audio.debug_max_samples, audio.debug_pos);
			ImPlot::EndPlot();
		}
		ImPlot::DestroyContext();
		ImGui::End();
#endif

		video.UpdateTexture();

		// Handle screenshots at specified frames
		bool took_screenshot_this_frame = false;
		if (screenshot_mode) {
			auto it = std::find(screenshot_frames.begin(), screenshot_frames.end(), video.count_frame);
			if (it != screenshot_frames.end()) {
				save_screenshot(video.count_frame);
				screenshot_frames.erase(it);
				took_screenshot_this_frame = true;
			}
		}

		// Check if we should stop at this frame
		if (stop_at_frame_enabled && video.count_frame >= stop_at_frame) {
			if (took_screenshot_this_frame) {
				printf("Reached stop frame %d after taking screenshot, exiting...\n", stop_at_frame);
			} else {
				printf("Reached stop frame %d, exiting...\n", stop_at_frame);
			}
			break;
		}

		// Pass inputs to sim - PS2 mouse for Mac.  Build the MiSTer ps2_mouse
		// packet with the X/Y SIGN bits (bit4 = X<0, bit5 = Y<0) — the core reads
		// these as the 9th (sign) bit of the delta, so without them every negative
		// move looks like a large positive one (mouse only goes right/down).
		int dx = 0, dy = 0;
		int btn = 0;
		if (mouse_captured) {
			// Real host mouse: relative motion accumulated this frame.  SDL screen
			// Y is down-positive; the Mac wants up-positive, so negate dy.
			dx =  sdl_mouse_dx;
			dy = -sdl_mouse_dy;
			if (sdl_mouse_btn) btn |= 0x01;
		} else if (mouse_inject_from >= 0 && (int)video.count_frame >= mouse_inject_from
		           && (int)video.count_frame <= mouse_inject_to) {
			// Synthetic wiggle: rotate through +x/+y/-x/-y so every packet carries
			// a nonzero delta (mouse_evt fires each frame) with no net drift.
			static const int wig[4][2] = { {2,0}, {0,2}, {-2,0}, {0,-2} };
			dx = wig[video.count_frame & 3][0];
			dy = wig[video.count_frame & 3][1];
		} else {
			// Fallback: arrow keys / A,B buttons when the mouse isn't captured.
			if (input.inputs[input_left])  dx = -2;
			if (input.inputs[input_right]) dx =  2;
			if (input.inputs[input_up])    dy =  2;
			if (input.inputs[input_down])  dy = -2;
			if (input.inputs[input_a])     btn |= 0x01;
			if (input.inputs[input_b])     btn |= 0x02;
		}
		if (dx >  127) dx =  127; if (dx < -127) dx = -127;
		if (dy >  127) dy =  127; if (dy < -127) dy = -127;

		unsigned char status_byte = (unsigned char)(btn & 0x07) | 0x08;
		if (dx < 0) status_byte |= 0x10;   // X sign  -> ps2_mouse[4]
		if (dy < 0) status_byte |= 0x20;   // Y sign  -> ps2_mouse[5]

		unsigned long mouse_temp = status_byte;
		mouse_temp |= ((unsigned char)dx << 8);
		mouse_temp |= ((unsigned char)dy << 16);
		if (mouse_clock) { mouse_temp |= (1UL << 24); }
		mouse_clock = !mouse_clock;

		VERTOPINTERN->ps2_mouse = mouse_temp;

		// Run simulation
		if (run_enable) {
			for (int step = 0; step < batchSize; step++) { verilate(); }
		}
		else {
			if (single_step) { verilate(); }
			if (multi_step) {
				for (int step = 0; step < multi_step_amount; step++) { verilate(); }
			}
		}
	}

	// Clean up before exit
	// --------------------

#ifndef DISABLE_AUDIO
	if (!headless) audio.CleanUp();
#endif
	if (!headless) {
		video.CleanUp();
		input.CleanUp();
	}

	return 0;
}
