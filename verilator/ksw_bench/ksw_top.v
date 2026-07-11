// Kernel-level mode-switch micro-reproduction wrapper.
//
// Drives the FULL TG68KdotC_Kernel (CPU="10", 68030+PMMU) through the exact
// boot derail condition: MMU already enabled, then `pmove (A3),tc` RECONFIG
// (E=1 -> E=1, which glitches tc_en 1->0->1 and re-arms mmu_fetch_grace),
// immediately followed by `jmp (A5)` to the 32-bit ROM alias $40A0010E.
//
// The C++ harness owns RAM and services BOTH buses:
//   - CPU bus (16-bit) via addr_out/busstate/data_in/data_write
//   - PMMU walker bus (32-bit) via pmmu_walker_* (page-table reads live in RAM)
// and watches whether the jmp-target fetch translates to $00A0010E (correct)
// or derails.

module ksw_top
  (input         clk,
   input         reset,            // active high
   input         clkena_in,
   input  [15:0] data_in,
   output [31:0] addr_out,
   output [15:0] data_write,
   output        nWr,
   output        nUDS,
   output        nLDS,
   output [1:0]  busstate,
   output [2:0]  fc,
   // PMMU visibility (kernel entity ports)
   output [31:0] pmmu_addr_log,
   output [31:0] pmmu_addr_phys,
   output        pmmu_reg_we,
   output [4:0]  pmmu_reg_sel,
   output [31:0] pmmu_reg_wdat,
   output        pmmu_reg_part,
   // PMMU walker memory bus (driven by harness)
   output        pmmu_walker_req,
   output        pmmu_walker_we,
   output [31:0] pmmu_walker_addr,
   output [31:0] pmmu_walker_wdat,
   input         pmmu_walker_ack,
   input  [31:0] pmmu_walker_data,
   // hierarchical taps (forced public by referencing here)
   output [31:0] pc_out,
   output        tc_en_out,
   output        grace_out,
   output        busy_out);

   assign pc_out    = cpu.tg68_pc;
   assign tc_en_out = cpu.pmmu_tc_en;
   assign grace_out = cpu.mmu_grace_suppress;
   assign busy_out  = cpu.pmmu_busy;

   TG68KdotC_Kernel cpu
     (.clk(clk),
      .nReset(~reset),
      .clkena_in(clkena_in),
      .data_in(data_in),
      .IPL(3'b111),
      .IPL_autovector(1'b0),
      .berr(1'b0),
      .CPU(2'b10),                 // 68030 + PMMU
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
      .pmmu_reg_we(pmmu_reg_we),
      .pmmu_reg_re(),
      .pmmu_reg_sel(pmmu_reg_sel),
      .pmmu_reg_wdat(pmmu_reg_wdat),
      .pmmu_reg_part(pmmu_reg_part),
      .pmmu_addr_log(pmmu_addr_log),
      .pmmu_addr_phys(pmmu_addr_phys),
      .pmmu_walker_req(pmmu_walker_req),
      .pmmu_walker_we(pmmu_walker_we),
      .pmmu_walker_addr(pmmu_walker_addr),
      .pmmu_walker_wdat(pmmu_walker_wdat),
      .pmmu_walker_ack(pmmu_walker_ack),
      .pmmu_walker_data(pmmu_walker_data),
      .pmmu_walker_berr(1'b0)
      );
endmodule
