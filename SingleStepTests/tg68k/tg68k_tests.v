// SingleStep bench wrapper for the MC68030 TG68KdotC_Kernel (Minimig 030 core).
//
// Target: Macintosh IIvi 68030. CPU=2'b10 selects the 030 path (PMMU + caches
// integrated in the kernel). The PMMU is present but inactive in this bench:
// out of reset TC.E=0, so translation is logical=physical and the table walker
// never runs — hence the walker bus is tied idle below.
//
// The kernel runs one bus access per `clkena_in` pulse. The C++ harness owns RAM
// and inspects `busstate` each enabled cycle to drive `data_in` (reads) or
// capture `data_write` (writes). Byte lanes via nUDS/nLDS.
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
   // Verification taps -- read by the C++ harness at the post-test capture
   // moment so we can compare architectural PC/SR/USP against the corpus.
   //   pc_out  : kernel's TG68_PC (runs one prefetch ahead of architectural PC)
   //   sr_out  : full 16-bit SR = {FlagsSR, Flags}; bits 8-10 (IPL) masked out
   //   usp_out : User Stack Pointer
   output [31:0] pc_out,
   output [15:0] sr_out,
   output [31:0] usp_out
   );

   // Hierarchical taps into the ghdl-generated kernel. Referencing these from
   // here forces verilator to preserve them through dead-code elimination.
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
      .CPU             (2'b10),     // 68030
      .addr_out        (addr_out),
      .data_write      (data_write),
      .nWr             (nWr),
      .nUDS            (nUDS),
      .nLDS            (nLDS),
      .busstate        (busstate),
      .longword        (longword),
      .FC              (fc),
      .VBR_out         (vbr_out),
      // PMMU table-walker bus: tied idle (no walks while TC.E=0).
      .pmmu_walker_ack (1'b0),
      .pmmu_walker_data(32'b0),
      .pmmu_walker_berr(1'b0)
      );
endmodule
