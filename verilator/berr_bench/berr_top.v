// BERR continue-past micro-bench wrapper.
//
// Drives the FULL TG68KdotC_Kernel (CPU="10", 68030+PMMU, MMU off) through the
// Mac OS BERR-protected pointer-probe idiom (ROM $A0DB50/$A0DB5C handlers):
//   install temp vector-2 handler -> read through a bad pointer -> external
//   BERR -> handler clears SSW.DF at frame+$0A, stores data in the DIB at
//   frame+$2C, RTE -> the 030 must resume at the NEXT instruction with the
//   faulted read's destination register loaded from the DIB.
//
// The C++ harness owns RAM, services the CPU + walker buses, asserts berr on
// accesses to $E00000-$EFFFFF (hold-until-make_berr like tg68k.v's berr_held),
// and checks the architectural result.
module berr_top
  (input         clk,
   input         reset,            // active high
   input         clkena_in,
   input  [15:0] data_in,
   input         berr,
   output [31:0] addr_out,
   output [15:0] data_write,
   output        nWr,
   output        nUDS,
   output        nLDS,
   output [1:0]  busstate,
   output [2:0]  fc,
   // PMMU walker memory bus (unused: MMU stays off; serviced anyway)
   output        pmmu_walker_req,
   output        pmmu_walker_we,
   output [31:0] pmmu_walker_addr,
   output [31:0] pmmu_walker_wdat,
   input         pmmu_walker_ack,
   input  [31:0] pmmu_walker_data,
   // kernel fault status (berr hold release + diagnostics)
   output        make_berr_out,
   output        trap_berr_out,
   output        busy_out,
   output [31:0] pc_out,
   // continue-past fix machinery taps (hierarchical)
   output        fix_write_out,     // rte_mmu_fix_write (writeback gate fires)
   output [15:0] fix_opcode_out,    // opcode the gate decodes (frame +$14 stash)
   output [15:0] fix_ssw_out,       // stacked SSW captured at RTE unwind
   output [31:0] fix_dib_out,       // stacked data-input buffer (+$2C)
   output [31:0] frame_pc_out,      // berr_frame_pc (stacked resume PC)
   // resume-PC candidate taps (empirically pick the correct next-instr source)
   output [15:0] cap_op_out,        // berr_capture_opcode
   output [31:0] boundary_pc_out,   // instr_boundary_pc (setstate=01 TG68_PC latch)
   output [31:0] exe_pc_out,        // exe_pc (instruction start)
   output [31:0] nextpc_out);       // berr_capture_nextpc (prefetch ptr at first-fire)

   assign pc_out         = cpu.tg68_pc;
   assign busy_out       = cpu.pmmu_busy;
   assign fix_write_out  = cpu.rte_mmu_fix_write;
   assign fix_opcode_out = cpu.rte_mmu_fix_opcode;
   assign fix_ssw_out    = cpu.rte_mmu_fix_ssw;
   assign fix_dib_out    = cpu.rte_mmu_fix_input_buffer;
   assign frame_pc_out   = cpu.berr_frame_pc;
   assign cap_op_out     = cpu.berr_capture_opcode;
   assign boundary_pc_out= cpu.instr_boundary_pc;
   assign exe_pc_out     = cpu.exe_pc;
   assign nextpc_out     = cpu.berr_capture_nextpc;

   TG68KdotC_Kernel cpu
     (.clk(clk),
      .nReset(~reset),
      .clkena_in(clkena_in),
      .data_in(data_in),
      .IPL(3'b111),
      .IPL_autovector(1'b0),
      .berr(berr),
      .CPU(2'b10),                 // 68030 + PMMU (MMU disabled: TC never written)
      .addr_out(addr_out),
      .data_write(data_write),
      .nWr(nWr),
      .nUDS(nUDS),
      .nLDS(nLDS),
      .busstate(busstate),
      .longword(),
      .nResetOut(),
      .FC(fc),
      .clr_berr(),
      .debug_make_berr(make_berr_out),
      .debug_trap_berr(trap_berr_out),
      .pmmu_walker_req(pmmu_walker_req),
      .pmmu_walker_we(pmmu_walker_we),
      .pmmu_walker_addr(pmmu_walker_addr),
      .pmmu_walker_wdat(pmmu_walker_wdat),
      .pmmu_walker_ack(pmmu_walker_ack),
      .pmmu_walker_data(pmmu_walker_data),
      .pmmu_walker_berr(1'b0)
      );
endmodule
