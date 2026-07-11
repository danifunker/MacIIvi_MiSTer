// JTAG In-System probes for MacIIvi — ported from the LBMacTwo dbg_min.sv
// methodology (same instance IDs and layouts wherever a probe has an
// LBMacTwo twin, so the decode knowledge and reader tooling carry over).
//
// Read with:  bash scripts/read_probes.sh          (all probes, decoded)
//             quartus_stp_tcl -t scripts/sample_loop.tcl 120   (loop sampler)
//
// FPGA-ONLY: this module is instantiated from MacIIvi.sv (never sim.v), so
// the altsource_probe Altera primitive never reaches Verilator. Keep it
// that way — do NOT add it to the simulator top.
//
// Probe deck (15 instances; LBMacTwo's JTAG hub ceiling was ~20 on a much
// fuller device — headroom is fine, but if a future fit fails trim PASC/
// PAUD/PVID first):
//
//   PADR  cpuAddr snapshot              PSTA  bus/decoder/IRQ state
//   PACT  bus-cycle counter             PIFA  last instruction-fetch addr
//   PIFD  live {IF addr16, opcode16}    PDRD  live {I/O rd addr field, data}
//   PSCS  last SCSI reg read + value    PSC3  phases/max-phase/io+sd acks
//   PSCW  write-stall snapshot          PSNC  pseudo-DMA engine state
//   PSWL  IRQ/deferral machine state    PSC6  {rst/completion, last opcodes}
//   PASC  ASC irq vs CPU-write cadence  PAUD  audio sample min/max
//   PVID  video mode/vbl/CLUT/VRAM activity
module dbg_probes (
    input wire        clk,

    // CPU bus
    input wire [23:0] cpuAddr,
    input wire [7:0]  cpuAddrHi,   // cpuAddr[31:24] — 32-bit qualifier
    input wire        cpuReset_n,    // system/Egret-driven CPU reset (active low)
    input wire        resetInstr_n,  // 68k RESET-instruction output (active low)
    input wire [2:0]  cpuFC,
    input wire        cpuAS_n,
    input wire        cpuRW,
    input wire        cpuDTACK_n,
    input wire        cpuVPA_n,
    input wire        cpuUDS_n,
    input wire        cpuLDS_n,
    input wire [2:0]  cpuIPL_n,
    input wire [15:0] cpu_din,        // muxed CPU read data (dataControllerDataOut)
    input wire        cpu_make_berr,
    input wire [31:0] cpu_berr_frame_pc,
    input wire [31:0] cpu_exe_pc,
    input wire [31:0] cpu_tg68_pc,    // LOGICAL prefetch pointer (pre-MMU)
    input wire [15:0] cpu_exe_opcode,
    input wire [15:0] cpu_berr_opcode,

    // address decoder selects
    input wire        selectSCSI,
    input wire        selectSCSIDMA,
    input wire        selectRAM,
    input wire        selectROM,
    input wire        selectVRAM,
    input wire        selectVIA,
    input wire        selectPseudoVIA,
    input wire        selectASC,
    input wire        selectAriel,
    input wire        selectIWM,
    input wire        selectSCC,

    // SCSI
    input wire        scsiDREQ,
    input wire        scsiIRQ,
    input wire [15:0] scsi_dbg,       // selection: out_en/SEL/BSY/bsy/mounted/data
    input wire [15:0] scsi_dbg2,      // phases + io handshake
    input wire [15:0] scsi_dbg4,      // bus-reset count + completion flags
    input wire [15:0] scsi_dbg5,      // last opcodes
    input wire [31:0] scsi_dbg_ncr,   // pseudo-DMA engine
    input wire [31:0] scsi_dbg_ncr2,  // IRQ/deferral machine
    input wire [31:0] scsi_dbg_wr,    // write-stall snapshot
    input wire [1:0]  img_mounted,
    input wire [1:0]  sd_rd,
    input wire [1:0]  sd_wr,
    input wire [1:0]  sd_ack,

    // sound (ASC)
    input wire        asc_irq,
    input wire signed [15:0] asc_sample_l,

    // video (V8 / Ariel)
    input wire [7:0]  pvia_video_config,
    input wire        v8_vblank,

    // BERR investigation (#3 cold-boot reboot loop): the real hardware
    // bus-error signals (NOT the $8-vector-read inference PEXC/PFR use, which
    // false-alarms on routine supervisor reads).
    input wire        cpu_berr,    // asserted BERR to the CPU (fc7_berr | sdma_berr)
    input wire        fc7_berr,    // FC=7 CPU-space probe BERR (already gated by !AS)
    input wire        sdma_berr,   // SCSI pseudo-DMA watchdog BERR (the suspected #3 killer)

    // #3 ROM re-init detector
    input wire        memoryOverlayOn, // ROM overlay active (1 = ROM mapped at $0)

    // PMMU logical/physical for the mode-switch mistranslation capture (2026-06-23)
    input wire [31:0] cpu_pmmu_log,    // pmmu_addr_log  (LOGICAL fetch addr = A5/jmp target)
    input wire [31:0] cpu_pmmu_phys,   // pmmu_addr_phys (PHYSICAL translated)
    // MMU-input forensics latched at the derail (which input is wrong?)
    input wire [31:0] cpu_pmmu_tc,     // TC register
    input wire [31:0] cpu_pmmu_crp,    // CRP_lo (root table base)
    input wire [31:0] cpu_pmmu_wda,    // last walk descriptor ADDRESS read
    input wire [31:0] cpu_pmmu_wdd,    // last walk descriptor DATA read
    input wire [31:0] cpu_pmmu_st,     // {11'b0, wstate[4:0], fault_status[15:0]}
    input wire [15:0] cpu_dout,        // CPU write data (tg68_dout) — table-build store capture
    input wire [22:0] cpu_memaddr,     // SDRAM word address from addrController (clobber capture)
    input wire        cpu_ramwe_n,     // _ramWE (active low) — actual SDRAM write strobe
    input wire        mb_hi_i,         // BUILD#9: motherboard-bank relocation select (sdram_addr[23])
    input wire        walk_cycle,      // BUILD#10: PMMU walker borrowing the bus
    input wire        ramOE_n,         // BUILD#10: _ramOE (active low) — SDRAM read strobe
    input wire        selectUnmapped,  // BUILD#10: addrDecoder selectUnmapped
    input wire        cpuBusControl    // BUILD#10: CPU owns the SDRAM slot this busCycle
);

    // ---- PADR / PSTA / PACT: where is the CPU, what bus state, is it alive

    reg cpuAS_n_d;
    always @(posedge clk) cpuAS_n_d <= cpuAS_n;

    reg [31:0] padr_r;
    always @(posedge clk) padr_r <= {8'd0, cpuAddr};

    // PSTA layout:
    //   [24]=AS_n [23:21]=IPL_n [20]=scsiIRQ [19]=scsiDREQ [18]=selSCSIDMA
    //   [17]=selSCSI [16]=selVRAM [15]=selROM [14]=selRAM [13]=selASC
    //   [12]=selAriel [11]=selPseudoVIA [10]=selVIA [9]=selIWM [8]=selSCC
    //   [7]=VPA_n [6]=DTACK_n [5]=LDS_n [4]=UDS_n [3]=RW [2:0]=FC
    reg [31:0] psta_r;
    always @(posedge clk)
        psta_r <= {7'd0, cpuAS_n, cpuIPL_n, scsiIRQ, scsiDREQ,
                   selectSCSIDMA, selectSCSI, selectVRAM, selectROM, selectRAM,
                   selectASC, selectAriel, selectPseudoVIA, selectVIA,
                   selectIWM, selectSCC,
                   cpuVPA_n, cpuDTACK_n, cpuLDS_n, cpuUDS_n, cpuRW, cpuFC};

    reg [31:0] as_cycles;
    always @(posedge clk)
        if (cpuAS_n_d && !cpuAS_n) as_cycles <= as_cycles + 32'd1;

    altsource_probe #(
        .instance_id ("PADR"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_padr (.probe(padr_r), .source(), .source_clk(clk), .source_ena(1'b1));

    altsource_probe #(
        .instance_id ("PSTA"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_psta (.probe(psta_r), .source(), .source_clk(clk), .source_ena(1'b1));

    altsource_probe #(
        .instance_id ("PACT"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pact (.probe(as_cycles), .source(), .source_clk(clk), .source_ena(1'b1));

    // ---- PIFA / PIFD: instruction-fetch sampler (the remote disassembler)
    // PIFA captures cpuAddr ONLY at real instruction-fetch cycles (AS falling
    // edge, read, FC in {2,6}); repeated JTAG samples of a stable wedge loop
    // histogram its PCs. PIFA[31:24] = wrap8 IF count (frozen = CPU wedged in
    // a zero-fetch state; advancing = loop alive).
    wire if_cycle = cpuAS_n_d && !cpuAS_n && cpuRW &&
                    (cpuFC == 3'b010 || cpuFC == 3'b110);
    reg [7:0]  if_cnt;
    reg [23:0] if_addr;
    always @(posedge clk)
        if (if_cycle) begin
            if_addr <= cpuAddr;
            if_cnt  <= if_cnt + 8'd1;
        end
    reg [31:0] pifa_r;
    always @(posedge clk) pifa_r <= {if_cnt, if_addr};

    // PIFD: live atomic {IF addr[15:0], fetched data[15:0]} pair, committed
    // at the END of the fetch bus cycle (AS rising edge), when the muxed
    // read data is valid and held. Repeated samples + scripts/loop_disasm.py
    // reconstruct RAM code we cannot otherwise read (the lbmactwo technique
    // that decoded the System 7 TIB settle loop).
    reg        ifd_wait;
    reg [15:0] ifd_addr;
    reg [31:0] pifd_pair;
    always @(posedge clk) begin
        if (if_cycle) begin
            ifd_wait <= 1'b1;
            ifd_addr <= cpuAddr[15:0];
        end else if (ifd_wait && !cpuAS_n_d && cpuAS_n) begin // AS rose: cycle done
            pifd_pair <= {ifd_addr, cpu_din};
            ifd_wait  <= 1'b0;
        end
    end
    reg [31:0] pifd_r;
    always @(posedge clk) pifd_r <= pifd_pair;

    altsource_probe #(
        .instance_id ("PIFA"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pifa (.probe(pifa_r), .source(), .source_clk(clk), .source_ena(1'b1));

    altsource_probe #(
        .instance_id ("PIFD"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pifd (.probe(pifd_r), .source(), .source_clk(clk), .source_ena(1'b1));

    // ---- PEXC / PEX2 / PEX3: exception-vector latches ----------------------
    // vec_fetch fires on a supervisor read of the low vector table
    // ($000008-$000024: buserr=2, addrerr=3, ILLEGAL=4, div0=5, CHK=6,
    // TRAPV=7, priv=8, trace=9). Line-A ($28) and line-F ($2C) are EXCLUDED:
    // the Mac OS dispatches every system call through line-A, which would
    // overwrite the interesting fatal vector thousands of times a second.
    // The vector read happens while if_addr still holds the faulting
    // instruction's fetch address.
    //   PEXC (rolling, last fatal) = {if_addr[23:0], vec#[3:0], cnt wrap4}
    //   PEX2 (STICKY, first ILLEGAL vec 4) = pifd_pair at the fault =
    //        {fetch addr16, OPCODE16} of the last completed fetch
    //   PEX3 (STICKY, first ILLEGAL) = {if_addr[23:0], illegal_cnt[7:0]}
    // Note: the boot ROM's hardware probes take INTENTIONAL bus errors and
    // a soft restart re-runs them — hence rolling for PEXC but sticky
    // first-ILLEGAL for PEX2/PEX3 (the Sad Mac 0F/0003 class).
    // cpuAddrHi == 0 qualifier: without it, 32-bit device probes (e.g. the
    // ROM's $FE000010 PDS slot read) alias into the low vector window on the
    // 24-bit cpuAddr slice and fire false "exceptions".
    wire vec_fetch = cpuAS_n_d && !cpuAS_n && cpuRW &&
                     cpuFC[2] && (cpuFC[1:0] != 2'b11) &&
                     (cpuAddrHi == 8'd0) &&
                     (cpuAddr[23:6] == 18'd0) &&
                     (cpuAddr[5:0] >= 6'h08) && (cpuAddr[5:0] <= 6'h24);
    wire illegal_fetch = vec_fetch && (cpuAddr[5:2] == 4'd4);
    reg [3:0]  vec_cnt     = 4'd0;
    reg [7:0]  illegal_cnt = 8'd0;
    reg        illegal_seen = 1'b0;
    reg [31:0] pexc_r = 32'd0;
    reg [31:0] pex2_r = 32'd0;
    reg [31:0] pex3_r = 32'd0;
    always @(posedge clk) begin
        if (vec_fetch) begin
            pexc_r  <= {if_addr, cpuAddr[5:2], vec_cnt + 4'd1};
            vec_cnt <= vec_cnt + 4'd1;
        end
        if (illegal_fetch) begin
            if (illegal_cnt != 8'hFF) illegal_cnt <= illegal_cnt + 8'd1;
            if (!illegal_seen) begin
                illegal_seen <= 1'b1;
                pex2_r <= pifd_pair;
                pex3_r <= {if_addr, 8'd1};
            end else
                pex3_r[7:0] <= illegal_cnt + 8'd1;
        end
    end

    altsource_probe #(
        .instance_id ("PEXC"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pexc (.probe(pexc_r), .source(), .source_clk(clk), .source_ena(1'b1));

    altsource_probe #(
        .instance_id ("PEX2"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pex2 (.probe(pex2_r), .source(), .source_clk(clk), .source_ena(1'b1));

    altsource_probe #(
        .instance_id ("PEX3"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pex3 (.probe(pex3_r), .source(), .source_clk(clk), .source_ena(1'b1));

    // ---- PFR0-3: restart flight recorder, rev 2 ------------------------------
    // Findings from rev 1: the mid-boot restart asserts NO reset line and does
    // NOT execute RESET — it is a software transfer into ROM init. Leading
    // theory: a deterministic SCSI bus error near dack=14592 is "handled" by
    // the OS, but TG68's bus-fault frame is malformed, so the handler's RTE
    // lands at garbage (ROM init). This rev captures exactly that:
    //   * arms only after 4096 instruction fetches (rev-1 froze on the
    //     core-load reset with an empty trail)
    //   * cause 1/2 (reset-line falls) kept, gated by armed
    //   * cause 4: BUS-ERROR vector fetch while dack_beats > 14000 — the
    //     death-adjacent bus error. Freezes the pre-trail {pc0=faulting IF,
    //     pc1=previous IF}, then waits for the handler's RTE opcode ($4E73)
    //     and captures the 2 fetch addresses that follow = WHERE RTE LANDED.
    // Readout: PFR0={0,frozen,cause,pre_pc0} PFR1={rst_falls,instr_falls,pre_pc1}
    //          PFR2={0,rte_caught,rte_pc0} PFR3={berr_trig_count,rte_pc1}
    // ---- PFR0-3 REPURPOSED (2026-06-21): kernel-signal first-fault capture -------
    // The external-bus recorder only ever caught post-derail garbage (this bug
    // storms within a few instructions of the fault). Instead latch the CPU
    // KERNEL's own fault state on the FIRST make_berr (clean, before any derail),
    // via the new tg68k taps. A short delay after the make_berr rising edge lets
    // berr_frame_pc settle (it updates at exception dispatch). Readout:
    //   PFR0 = berr_frame_pc            (stacked PC = where the handler RTE resumes)
    //   PFR1 = exe_pc                   (faulting instr start; correct next=exe_pc+len)
    //   PFR2 = {exe_opcode, opcode}     (which tap holds the faulting instr vs prefetch)
    //   PFR3 = {berr_trigs[7:0], 23'd0, frozen}   (berr_trigs>1 => first fault derailed)
    // ---- BUS-TXN TRACE (2026-06-22): the access pattern INTO the derail ---------
    // The derail (ROM $A416B8 MMU-setup -> physical $9FE87x) has NO make_berr and NO
    // illegal. To tell a VECTORED EXCEPTION (stack-frame writes + a vector read at
    // VBR+vecnum*4) from a register/rts jump, capture the last 3 bus transactions
    // {addr,FC,RW} before the high-RAM program fetch. A supervisor-data read whose
    // address = vecnum*4 (VBR is still 0 here, set later at $A4170E) names the vector
    // -> Sad Mac $0F suggests vector 15 (uninitialised interrupt). Armed after 1st fault.
    // DECISIVE TEST: latch the kernel's LOGICAL exe_pc at the derail. If it is in ROM
    // ($A4xxxx) while the physical bus fetch (derail_addr) is high-RAM $9FExxx, the MMU
    // is mistranslating a ROM-logical fetch to a high-RAM physical page. If exe_pc is
    // itself $9FExxx, the logical PC genuinely derailed (control-flow corruption).
    reg [27:0] tx0 = 28'd0;                             // {addr[23:0], FC[2:0], RW}
    reg [23:0] derail_addr = 24'd0;
    reg [31:0] derail_exe_pc = 32'd0;
    reg [31:0] derail_tg68_pc = 32'd0;                  // LOGICAL prefetch pointer at the derail
    reg [31:0] derail_pmmu_log  = 32'd0;                // pmmu_addr_log  at derail (= A5/jmp target)
    reg [31:0] derail_pmmu_phys = 32'd0;                // pmmu_addr_phys at derail (kernel-side cross-check)
    reg [31:0] derail_tc = 32'd0, derail_crp = 32'd0;   // TC + CRP_lo at derail (which MMU input is wrong?)
    reg [31:0] derail_wda = 32'd0, derail_wdd = 32'd0;  // walk descriptor addr + data the walk actually read
    reg [31:0] derail_st  = 32'd0;                      // {wstate, fault_status} at derail
    reg        pc_armed = 1'b0, pc_frozen = 1'b0;
    reg [7:0]  bf_trigs = 8'd0;
    reg        mberr_d = 1'b0;
    wire bus_cyc  = cpuAS_n_d && !cpuAS_n;                  // any bus cycle (AS falling)
    wire hiram_pf = bus_cyc && cpuRW && (cpuFC == 3'b010 || cpuFC == 3'b110) &&
                    (cpuAddr[23:20] >= 4'h4 && cpuAddr[23:20] <= 4'h9);
    always @(posedge clk) begin
        mberr_d <= cpu_make_berr;
        if (cpu_make_berr && !mberr_d) begin                  // make_berr rising edge
            if (bf_trigs != 8'hFF) bf_trigs <= bf_trigs + 8'd1;
            pc_armed <= 1'b1;                                  // arm after the first fault
        end
        if (bus_cyc && pc_armed && !pc_frozen) begin
            if (hiram_pf) begin
                pc_frozen        <= 1'b1;                     // freeze: tx0 = last txn into derail
                derail_addr      <= cpuAddr[23:0];           // PHYSICAL fetch addr ($9FEE40)
                derail_exe_pc    <= cpu_exe_pc;              // LOGICAL exe_pc (executing instr)
                derail_tg68_pc   <= cpu_tg68_pc;             // LOGICAL prefetch pointer (was unreliable)
                // 2026-06-23: latch the kernel PMMU log/phys at the SAME proven trigger.
                // pmmu_addr_log = the derailing fetch's LOGICAL addr = A5/jmp target,
                // captured whether A5 is correct (ROM/alias) OR corrupted (any value).
                derail_pmmu_log  <= cpu_pmmu_log;
                derail_pmmu_phys <= cpu_pmmu_phys;
                derail_tc  <= cpu_pmmu_tc;   // is TC = $80F84500 (oracle)?
                derail_crp <= cpu_pmmu_crp;  // is CRP_lo = $9FE820 (oracle 10M)?
                derail_wda <= cpu_pmmu_wda;  // did the walk read root[10] @ $9FE870?
                derail_wdd <= cpu_pmmu_wdd;  // did it read 7FFFFC19/00A00000?
                derail_st  <= cpu_pmmu_st;   // walk state + fault status
            end else begin
                tx0 <= {cpuAddr[23:0], cpuFC, cpuRW};
            end
        end
    end

    // PMMU mistranslation capture: derail_pmmu_log/phys are latched in the proven
    // hiram_pf freeze above (PFR2 = pmmu_addr_log = A5/jmp target; PRT3 = pmmu_addr_phys).

    // ---- BUILD #8: write-STROBE commit confirmation (does _ramWE/sdram_we fire?) ----
    // Build #7 pinned: exactly 1 CPU write of $000B to SDRAM word $0FF720 (= $9FEE40
    // root[8] hi-word), but the walker/derail READS $0000 back. Ruled out: overwrite
    // (cw_cnt=1), download (writes SDRAM $5/6/7xxxxx), SDRAM aliasing (unique bank/row/
    // col over addr[22:0]), decode range-gating (_ramWE not range-gated). REMAINING:
    // does the SDRAM write strobe (_ramWE => sdram_we) actually ASSERT for that write
    // (= commit), or is it DROPPED (cpuBusControl low / bus not granted)?
    //   we_fired/we_cnt/we_data: _ramWE asserted (cpu_ramwe_n low) while memoryAddr==
    //     $0FF720 -> the SDRAM write committed. we_fired=0 => write silently dropped.
    //   rd_memaddr: the READ of $9FEE40's SDRAM word -> confirms read targets $0FF720
    //     (closes the read-maps-elsewhere possibility).
    // BUILD #9 (2026-06-24): relocating the bank to the upper 16MB did NOT change the
    // derail (still reads 0000) -> the write-loss FOLLOWS the motherboard bank logically,
    // not physically. Disambiguate: (1) is the relocation even active at runtime —
    // wr_mbhi/rd_mbhi latch mb_hi at the table-build write and at the $9FEE40 read (both
    // must be 1 for the fix to be in effect); (2) the WALKER'S OWN descriptor read —
    // wda_l/wdd_l latch cpu_pmmu_wda/wdd (addr it read + data it got) for the derailing
    // walk, independent of the CPU read path.
    reg [31:0] c0=0, c1=0, c2=0;           // ring {cpuAddr[15:0], data} of writes to $0FF720
    reg [31:0] c0_cpa=0, c1_cpa=0;          // full cpuAddr (PHYSICAL) of the last 2 writes
    reg [15:0] cw_cnt=0;
    reg        we_fired=0; reg [15:0] we_cnt=0; reg [15:0] we_data=0;  // BUILD#8: _ramWE strobe to $0FF720
    reg        rd_seen=0; reg [15:0] rd_data=0; reg [31:0] rd_cpa=0; reg [22:0] rd_memaddr=0;
    reg        wr_mbhi=0, rd_mbhi=0;        // BUILD#9: mb_hi at the write / at the read (fix active?)
    reg [31:0] wda_l=0, wdd_l=0;            // BUILD#9: walker's last descriptor addr / data (live until freeze)
    // BUILD #10 (2026-06-24): RTL read says the walk read SHOULD decode as selectRAM and
    // return $000B, yet the walker gets $0000. OBSERVE the walk read of $9FEE40 directly:
    // its decode (selectRAM/ROM/VRAM/Unmapped), whether cpuBusControl & _ramOE (SDRAM read
    // strobe) actually assert, mb_hi, and the SDRAM word. Tells if the walk read reaches RAM.
    reg        walk_seen=0, walk_busctl=0, walk_ramoe=0;   // sticky over the walk read of $9FEE40
    reg        walk_sRAM=0, walk_sROM=0, walk_sVRAM=0, walk_sUnm=0, walk_mbhi=0;
    reg [22:0] walk_memaddr=0;
    // BUILD #11: split read-mistimed vs write-lost — watch din across the whole walk-read
    // window. If din EVER == $000B during the $9FEE40 walk read, the SDRAM held the data and
    // the walker latched too early (read-mistimed). If din stays 0, the write was lost.
    reg [15:0] walk_din_or=0;    // OR of din across the walk read of $9FEE40
    reg        walk_saw_b=0;     // din == $000B seen during the walk read
    wire wr720 = cpuAS_n_d && !cpuAS_n && !cpuRW && selectRAM && (cpu_memaddr==23'h0FF720);
    wire we720 = (cpu_memaddr==23'h0FF720) && !cpu_ramwe_n;  // BUILD#8: _ramWE asserted addressing $0FF720
    wire rd40  = cpuAS_n_d && !cpuAS_n &&  cpuRW && (cpuAddrHi==8'd0) && (cpuAddr[23:1]==23'h4FF720); // CPU $9FEE40/41
    wire walk_rd = walk_cycle && (cpuAddr[23:1]==23'h4FF720);   // BUILD#10: walker reading root[8] hi-word $9FEE40
    wire _unused_log = |cpu_pmmu_log;
    always @(posedge clk) begin
        if (!pc_frozen) begin
            if (wr720) begin
                c2<=c1; c1<=c0; c0<={cpuAddr[15:0],cpu_dout};
                c1_cpa<=c0_cpa; c0_cpa<={cpuAddrHi,cpuAddr};
                wr_mbhi<=mb_hi_i;
                if (cw_cnt!=16'hFFFF) cw_cnt<=cw_cnt+16'd1;
            end
            if (we720) begin
                we_fired<=1'b1; we_data<=cpu_dout;
                if (we_cnt!=16'hFFFF) we_cnt<=we_cnt+16'd1;
            end
            if (rd40) begin rd_seen<=1'b1; rd_data<=cpu_din; rd_cpa<={cpuAddrHi,cpuAddr}; rd_memaddr<=cpu_memaddr; rd_mbhi<=mb_hi_i; end
            if (walk_rd) begin
                walk_seen<=1'b1;
                walk_sRAM<=selectRAM; walk_sROM<=selectROM; walk_sVRAM<=selectVRAM; walk_sUnm<=selectUnmapped;
                walk_mbhi<=mb_hi_i; walk_memaddr<=cpu_memaddr;
                if (cpuBusControl) walk_busctl<=1'b1;   // sticky: CPU SDRAM slot occurred during the walk read
                if (!ramOE_n)      walk_ramoe<=1'b1;    // sticky: _ramOE (SDRAM read strobe) asserted
                walk_din_or <= walk_din_or | cpu_din;   // BUILD#11: any data that appeared on the bus
                if (cpu_din == 16'h000B) walk_saw_b <= 1'b1;
            end
            wda_l<=cpu_pmmu_wda; wdd_l<=cpu_pmmu_wdd;   // freeze at derail = the derailing walk
        end
    end

    altsource_probe #(
        .instance_id ("PFR0"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pfr0 (.probe({bf_trigs[5:0], pc_armed, pc_frozen, derail_addr}), .source(), .source_clk(clk), .source_ena(1'b1));
    altsource_probe #(
        .instance_id ("PFR1"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pfr1 (.probe(derail_exe_pc), .source(), .source_clk(clk), .source_ena(1'b1));
    altsource_probe #(
        .instance_id ("PFR2"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pfr2 (.probe(derail_pmmu_log), .source(), .source_clk(clk), .source_ena(1'b1));  // REPURPOSED: A5/jmp-target logical at derail
    altsource_probe #(
        .instance_id ("PFR3"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pfr3 (.probe({4'd0, tx0}), .source(), .source_clk(clk), .source_ena(1'b1));

    // (PBER/PBEA bus-error probes removed 2026-06-14 — they PROVED #3 is not a
    // bus error: sdma_berr never fired, cpu_berr was 100% routine fc7 probes, and
    // there was no BERR->reset correlation. Their probe budget is reused by the
    // PRC0/PRT re-init trail below. cpu_berr/fc7_berr/sdma_berr inputs are now
    // unused here; PSDT.berr_fires + PEXC still cover bus-error visibility.)

    // ---- PRC0 / PRT1-3: #3 reboot isolation (SCSI-abort trail + init entry) ----
    // The reboot has NO clean HW signature (no _cpuReset/RESET/BERR/overlay), and
    // address-based boot-entry detection missed (cold boot runs the overlay at
    // $00008C, the restart re-enters at an unknown high-ROM point). So capture two
    // complementary things, address-independently:
    //  (1) SCSI-ABORT PC TRAIL — freeze the 2 most recent IF PCs at the 2nd SCSI
    //      bus reset (dbg_rst_count = scsi_dbg4[15:8] increments). The driver
    //      asserts RST when it ABORTS a transfer; that abort is the prime suspect
    //      for what drives the System restart. PRT1 = CPU PC asserting the reset,
    //      PRT2 = the fetch before it -> disassemble = the SCSI driver abort path.
    //  (2) BOOT-INIT ENTRY BY OPCODE — detect `move.w #$2700,sr` ($46FC then
    //      $2700) in the fetch stream (the init's first instruction, wherever it
    //      enters). sr2700_cnt = how many inits ran (cold boot = 1; +1 if the
    //      reboot re-runs SR setup); PRT3 = the latest such entry PC = where init
    //      (re-)enters. (Replaced the address-based PRC0/PRT.)
    wire fetch_cplt = ifd_wait && !cpuAS_n_d && cpuAS_n;   // a fetch completed (PIFD commit pt)
    reg [15:0] op_prev = 16'd0;
    reg [23:0] pc_prev = 24'd0, pc_prev2 = 24'd0;
    reg [7:0]  sr2700_cnt = 8'd0;
    reg [23:0] sr_entry = 24'd0;          // latest move#$2700,sr PC (the init entry)
    reg [7:0]  rstc_d = 8'd0, busrst_cnt = 8'd0;
    reg        trail_frozen = 1'b0;
    reg [23:0] trail_pc1 = 24'd0, trail_pc2 = 24'd0;
    always @(posedge clk) begin
        // (2) opcode-based boot-init detection (address-independent)
        if (fetch_cplt) begin
            if (op_prev == 16'h46FC && cpu_din == 16'h2700) begin
                if (sr2700_cnt != 8'hFF) sr2700_cnt <= sr2700_cnt + 8'd1;
                sr_entry <= pc_prev;       // pc_prev = PC of the $46FC = init entry
            end
            op_prev  <= cpu_din;
            pc_prev2 <= pc_prev;
            pc_prev  <= if_addr;
        end
        // (1) SCSI bus-reset PC trail
        rstc_d <= scsi_dbg4[15:8];
        if (scsi_dbg4[15:8] != rstc_d) begin       // a SCSI bus reset occurred
            if (busrst_cnt != 8'hFF) busrst_cnt <= busrst_cnt + 8'd1;
            if (busrst_cnt >= 8'd1 && !trail_frozen) begin   // freeze at the 2nd
                trail_frozen <= 1'b1;
                trail_pc1 <= if_addr;
                trail_pc2 <= pc_prev;
            end
        end
    end
    reg [31:0] prc_r, pt1_r, pt2_r, pt3_r;
    always @(posedge clk) begin
        prc_r <= {busrst_cnt, sr2700_cnt, 15'd0, trail_frozen};
        pt1_r <= {8'd0, trail_pc1};
        pt2_r <= {8'd0, trail_pc2};
        pt3_r <= {8'd0, sr_entry};
    end

    altsource_probe #(
        .instance_id ("PRC0"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_prc0 (.probe(prc_r), .source(), .source_clk(clk), .source_ena(1'b1));
    altsource_probe #(
        .instance_id ("PRT1"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_prt1 (.probe(pt1_r), .source(), .source_clk(clk), .source_ena(1'b1));
    altsource_probe #(
        .instance_id ("PRT2"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_prt2 (.probe(pt2_r), .source(), .source_clk(clk), .source_ena(1'b1));
    altsource_probe #(
        .instance_id ("PRT3"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_prt3 (.probe(derail_pmmu_phys), .source(), .source_clk(clk), .source_ena(1'b1));  // REPURPOSED: PHYSICAL at PMMU mistranslation

    // ---- PDRD: live atomic {I/O-read addr field, data} ---------------------
    // Same end-of-cycle commit for DATA-space reads in the $F00000 I/O region.
    // Answers "what is the wait loop polling and what does it see" directly.
    // addr field = cpuAddr[19:4]; full offset within $F00000 = field<<4:
    //   0x0xxx=VIA1  0x4xxx=SCC  0x6xxx=SCSI DACK  0x1000x=SCSI reg(x)
    //   0x12xxx=SCSI DACK  0x14xxx=ASC  0x16xxx=IWM  0x24xxx=Ariel
    //   0x26xxx=PseudoVIA (scripts/loop_disasm.py decodes this).
    wire io_rd_cycle = cpuAS_n_d && !cpuAS_n && cpuRW &&
                       (cpuFC == 3'b001 || cpuFC == 3'b101) &&
                       (cpuAddr[23:21] == 3'b111);
    reg        drd_wait;
    reg [15:0] drd_addr;
    reg [31:0] pdrd_pair;
    always @(posedge clk) begin
        if (io_rd_cycle) begin
            drd_wait <= 1'b1;
            drd_addr <= cpuAddr[19:4];
        end else if (drd_wait && !cpuAS_n_d && cpuAS_n) begin
            pdrd_pair <= {drd_addr, cpu_din};
            drd_wait  <= 1'b0;
        end
    end
    reg [31:0] pdrd_r;
    always @(posedge clk) pdrd_r <= pdrd_pair;

    altsource_probe #(
        .instance_id ("PDRD"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pdrd (.probe(pdrd_r), .source(), .source_clk(clk), .source_ena(1'b1));  // restored: live {I/O rd addr field, data} (was walk din_or)

    // ---- PSCS: last SCSI register read + value (the poll target) ----------
    // {sdwr_seen[1:0], sdrd_seen[1:0], img_seen[1:0], 3'b0, last_reg[6:0],
    //  last_value[15:0]}  — last_reg = cpuAddr[6:0]; SCSI regs decode on
    // A6-A4, so reg# = last_reg[6:4].
    reg [15:0] scsi_last_rd;
    reg [6:0]  scsi_last_reg;
    reg [1:0]  img_seen, sdrd_seen, sdwr_seen;
    always @(posedge clk) begin
        if (selectSCSI && cpuRW && !cpuAS_n) begin
            scsi_last_rd  <= cpu_din;
            scsi_last_reg <= cpuAddr[6:0];
        end
        img_seen  <= img_seen  | img_mounted;
        sdrd_seen <= sdrd_seen | sd_rd;
        sdwr_seen <= sdwr_seen | sd_wr;
    end
    reg [31:0] pscs_r;
    always @(posedge clk)
        pscs_r <= {sdwr_seen, sdrd_seen, img_seen, 3'b0, scsi_last_reg, scsi_last_rd};

    altsource_probe #(
        .instance_id ("PSCS"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pscs (.probe(pscs_r), .source(), .source_clk(clk), .source_ena(1'b1));  // restored: last SCSI reg read + img/sd flags (was $0FF720 clobber)

    // ---- PSC2: selection transaction visibility ---------------------------
    // scsi_dbg layout (ncr5380.sv): [15]=out_en [14]=SEL [13]=BSY
    // [12:11]=target_bsy [10:9]=target_MOUNTED [8]=ICR.A_DATA
    // [7:0]=scsi_bus_data (the ID bits driven during selection).
    // PSC2 = {at_sel_data[7:0], dbg_at_sel[15:8], dbg_scsi_live[15:0]}:
    //   [31:24] data byte on the bus at the LAST SEL assertion — the ID
    //           bits the targets actually saw (din[ID] match evidence)
    //   [23:16] upper byte of scsi_dbg latched at the last SEL assertion
    //           (out_en/BSY/target_bsy/MOUNTED at the selection moment)
    //   [15:0]  live scsi_dbg
    // Directly answers "is the target mounted and does it see its ID" for
    // the deaf-disk-after-reset state.
    reg [7:0] at_sel_data = 8'h00;
    reg [7:0] dbg_at_sel  = 8'h00;
    always @(posedge clk)
        if (scsi_dbg[14]) begin       // SEL asserted
            at_sel_data <= scsi_dbg[7:0];
            dbg_at_sel  <= scsi_dbg[15:8];
        end
    reg [31:0] psc2_r;
    always @(posedge clk) psc2_r <= {at_sel_data, dbg_at_sel, scsi_dbg};

    altsource_probe #(
        .instance_id ("PSC2"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_psc2 (.probe(psc2_r), .source(), .source_clk(clk), .source_ena(1'b1));  // restored: selection transaction (was walk cpuAddr)

    // ---- PSC3: target phases + max-phase + io/sd handshake ----------------
    // LBMacTwo layout with the spare top nibble carrying the bus-reset count:
    //   [31:28]=rst_count[3:0] [23:21]=ph1 [20:18]=ph0 [17:16]=sd_ack_seen
    //   [15:14]=io_ack_seen [12:10]=max_ph1 [8:6]=max_ph0 [5:0]=live io_rd/wr/ack
    // phases: 0 IDLE,1 CMD_IN,2 DATA_OUT(rd),3 DATA_IN(wr),4 STATUS,5 MSG
    wire [2:0] ph0 = scsi_dbg2[10:8];
    wire [2:0] ph1 = scsi_dbg2[13:11];
    reg [2:0] max_ph0, max_ph1;
    reg [1:0] io_ack_seen, sd_ack_seen;
    always @(posedge clk) begin
        if (ph0 > max_ph0) max_ph0 <= ph0;
        if (ph1 > max_ph1) max_ph1 <= ph1;
        io_ack_seen <= io_ack_seen | scsi_dbg2[1:0];
        sd_ack_seen <= sd_ack_seen | sd_ack;
    end
    reg [31:0] psc3_r;
    always @(posedge clk)
        psc3_r <= {scsi_dbg4[11:8], 4'd0, ph1, ph0, sd_ack_seen, io_ack_seen,
                   1'b0, max_ph1, 1'b0, max_ph0, scsi_dbg2[5:0]};

    altsource_probe #(
        .instance_id ("PSC3"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_psc3 (.probe(psc3_r), .source(), .source_clk(clk), .source_ena(1'b1));  // restored: target phases + acks (was walker desc ADDR)

    // ---- PSCW / PSNC / PSWL: live SCSI engine snapshots (layouts in
    // ---- ncr5380.sv port comments; identical to lbmactwo) -----------------
    reg [31:0] pscw_r, psnc_r, pswl_r;
    always @(posedge clk) begin
        pscw_r <= scsi_dbg_wr;
        psnc_r <= scsi_dbg_ncr;
        pswl_r <= scsi_dbg_ncr2;
    end

    altsource_probe #(
        .instance_id ("PSCW"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pscw (.probe(pscw_r), .source(), .source_clk(clk), .source_ena(1'b1));  // restored: write-stall snapshot (was walk cpuAddr)

    altsource_probe #(
        .instance_id ("PSNC"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_psnc (.probe(psnc_r), .source(), .source_clk(clk), .source_ena(1'b1));  // restored: pseudo-DMA engine state (was walk-read decode)

    altsource_probe #(
        .instance_id ("PSWL"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pswl (.probe(pswl_r), .source(), .source_clk(clk), .source_ena(1'b1));  // restored: IRQ/deferral machine (was walker desc DATA)

    // ---- PSC6: {bus-reset count + completion flags, last opcodes} ---------
    //   [31:24]=rst_count [23:20]=t1 hs2 [19:16]=t0 hs2
    //   [15:8]=t1 last opcode [7:0]=t0 last opcode
    reg [31:0] psc6_r;
    always @(posedge clk) psc6_r <= {scsi_dbg4, scsi_dbg5};

    altsource_probe #(
        .instance_id ("PSC6"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_psc6 (.probe(psc6_r), .source(), .source_clk(clk), .source_ena(1'b1));  // restored: rst/completion + last opcodes (was cw_cnt)

    // (PASC/PAUD audio probes removed — re-add from git history if the sound
    // path needs JTAG visibility again.)

    // ---- PVID: video liveness — {vbl_cnt, clut_wr_cnt, vram_wr_cnt, config}
    //   [31:24] vblank count (wrap8)      — frozen = video timing dead
    //   [23:16] Ariel CLUT write count    — is the OS loading the palette?
    //   [15:8]  CPU VRAM write count      — is the Mac drawing?
    //   [7:0]   pseudo-VIA video config   — programmed mode (depth etc.)
    reg vbl_d;
    reg [7:0] vbl_cnt, clut_wr_cnt, vram_wr_cnt;
    always @(posedge clk) begin
        vbl_d <= v8_vblank;
        if (v8_vblank && !vbl_d) vbl_cnt <= vbl_cnt + 8'd1;
        if (cpuAS_n_d && !cpuAS_n && selectAriel && !cpuRW)
            clut_wr_cnt <= clut_wr_cnt + 8'd1;
        if (cpuAS_n_d && !cpuAS_n && selectVRAM && !cpuRW)
            vram_wr_cnt <= vram_wr_cnt + 8'd1;
    end
    reg [31:0] pvid_r;
    always @(posedge clk) pvid_r <= {vbl_cnt, clut_wr_cnt, vram_wr_cnt, pvia_video_config};

    altsource_probe #(
        .instance_id ("PVID"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pvid (.probe(pvid_r), .source(), .source_clk(clk), .source_ena(1'b1));  // restored: video liveness (was walk rd_cpa)

endmodule
