// SingleStep bench wrapper for TG68KdotC_Kernel.
//
// Target: Macintosh IIvi (MC68030 + on-chip PMMU). CPU=2'b11 below
// selects the kernel's most capable mode (VBR + extended stack frames
// + the extended integer ISA), which covers the 68030's user-mode
// integer behavior. Remaining 68030-parity gaps are tracked in
// test-blockers.md and 68030_PMMU_TESTBENCH.md:
//   * CALLM/RTM must trap as illegal (the 68030 dropped that 020 pair)
//   * CACR needs the 030 data-cache bits (WA/DBE/CD/CED/FD/ED)
//   * no PMMU: PMOVE/PTEST/PLOAD/PFLUSH are F-line on the raw kernel;
//     the PMMU lives in a wrapper module and gets its own bench
//     (SingleStepTests/pmmu/) once the RTL exists.
//
// The kernel runs one bus access per `clkena_in` pulse. The C++ harness owns
// RAM and inspects `busstate` each enabled cycle to drive `data_in` (reads)
// or capture `data_write` (writes). Byte lanes via nUDS/nLDS.
//
// busstate encoding (from TG68K source):
//   00 -> fetch code     10 -> read data
//   11 -> write data     01 -> no bus access (idle)

module tg68k_tests
  (
   input         clk,
   input         reset,           // active high
   input         clkena_in,
   input  [15:0] data_in,
   output [15:0] data_write,
   output [31:0] addr_out,
   output [1:0]  busstate,
   output        nWr,
   output        nUDS,
   output        nLDS,
   output        longword,
   output [2:0]  fc,
   output [31:0] vbr_out,
   // Verification taps -- read by the C++ harness at the post-test
   // capture moment so we can compare architectural PC/SR/USP against
   // the MAME-derived corpus. Not used for normal bus operation.
   //   pc_out  : kernel's TG68_PC. Runs one prefetch (typically 4 bytes)
   //             AHEAD of the architectural post-instruction PC.
   //   sr_out  : full 16-bit SR = {FlagsSR, Flags}. Bits 8-10 (IPL) are
   //             setup-dependent and should be masked off when comparing.
   //   usp_out : User Stack Pointer. Stable unless test executes
   //             MOVE An,USP / MOVE USP,An (privileged).
   output [31:0] pc_out,
   output [15:0] sr_out,
   output [31:0] usp_out
   );

   // Hierarchical taps into the ghdl-generated kernel. These wires are
   // declared at the top of the TG68KdotC_Kernel module body; reading
   // them from here forces verilator to preserve them through dead-code
   // elimination.
   assign pc_out  = cpu.tg68_pc;
   assign sr_out  = {cpu.flagssr, cpu.flags};
   assign usp_out = cpu.usp;

   TG68KdotC_Kernel cpu
     (
      .clk             (clk),
      .nReset          (~reset),
      .clkena_in       (clkena_in),
      .data_in         (data_in),
      .IPL             (3'b111),
      .IPL_autovector  (1'b0),
      .berr            (1'b0),
      .CPU             (2'b11),     // 68020 mode (VBR + stack frames)
      .addr_out        (addr_out),
      .data_write      (data_write),
      .nWr             (nWr),
      .nUDS            (nUDS),
      .nLDS            (nLDS),
      .busstate        (busstate),
      .longword        (longword),
      .nResetOut       (),
      .FC              (fc),
      .clr_berr        (),
      .cpu_halted      (),
      .berr_inhibit    (),
      .berr_data       (),
      .skipFetch       (),
      .regin_out       (),
      .CACR_out        (),
      .VBR_out         (vbr_out)
      );
endmodule
