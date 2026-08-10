# MacIIvi project timing constraints (read after sys/sys_top.sdc).
#
# ----------------------------------------------------------------------------
# TG68 kernel multicycle — REQUIRED for reliable timing closure.
# ----------------------------------------------------------------------------
# The TG68 kernel (TG68KdotC_Kernel) is a clock-enabled CPU: it advances ONLY on
# clkena = phi1 && (s_state==7 || busstate==01)  (see rtl/tg68k/tg68k.v:43), and
# phi1 = clk16_en_p = !busPhase[0] (addrController_top.v) is high only on EVEN
# clk_sys phases. So clkena can never pulse on two consecutive clk_sys cycles —
# consecutive kernel updates are always >= 2 clk_sys periods apart. Every kernel
# register (including the inferred register-file RAM regfile_rtl_0/1 and its
# read-during-write bypass) takes its meaningful input from, and feeds, other
# clkena-gated kernel logic. So kernel-internal reg->reg paths genuinely have TWO
# clk_sys periods to settle, not one.
#
# Without this, STA over-constrains the kernel to a single clk_sys period (~30.8ns
# @ 32.5MHz). The CPU's long decode/datapath/regfile-bypass paths are ~33ns, so
# they "fail" (the worst, regfile WE->bypass, measured -2.699ns) yet are
# placement-fragile enough to *sometimes* squeak by (+0.2ns) — the design was
# closing timing by luck. Relaxing the genuinely-2-cycle kernel paths to 2 periods
# takes the worst kernel slack hugely positive; the design's real limiter becomes
# the framework ascal scaler (~+0.56ns), independent of the CPU and of the DDR3
# video work. See docs/handoff_ddr3_video_2026-06-06.md.
#
# Scope is kernel-INTERNAL only (-from kernel -to kernel): it deliberately does NOT
# touch the tg68k WRAPPER state machine (s_state/eCntr update on phi1|phi2 = every
# clk_sys = genuine 1-cycle) nor any CPU<->SDRAM/peripheral path (those sample at
# full clk_sys rate and must stay single-cycle). HW-validated by a clean boot to
# the Finder desktop (the CPU executes millions of instructions through these paths
# to boot; a wrong multicycle would corrupt/crash it).
set_multicycle_path -setup -end 2 -from [get_keepers {*TG68KdotC_Kernel*}] -to [get_keepers {*TG68KdotC_Kernel*}]
set_multicycle_path -hold  -end 1 -from [get_keepers {*TG68KdotC_Kernel*}] -to [get_keepers {*TG68KdotC_Kernel*}]

# ----------------------------------------------------------------------------
# CPU write-data -> SDRAM capture multicycle (clk_sys 32.5MHz -> clk_mem 65MHz).
# ----------------------------------------------------------------------------
# clk_sys (general[1], 32.5MHz, the CPU domain) and clk_mem (general[0], 65MHz,
# the sdram.v state machine on .clk_64) are a 2:1 pair off the SAME PLL, so STA
# analyzes clk_sys->clk_mem transfers synchronously and gives a register in the
# CPU domain only ONE 65MHz period (15.38ns) to reach a register in the sdram
# domain. The 68k write-data bus is exactly such a path: a kernel reg drives,
# combinationally, dout -> sdram_din -> sdram|sd_data[*] (the write-data output
# register). After the 030 MMU sync this cone runs kernel reg -> PMMU reg-read
# mux -> ALU adder -> data_write_mux -> dout, ~21.3ns of mostly routing at 95%
# ALM fill, so it misses the 15.38ns window (worst -6.18ns; the whole 16-bit
# bus = -77ns TNS). It is the ONLY clk_sys->clk_mem failure (address/control
# and the sdram->CPU read direction all close).
#
# Relaxing it to 2 clk_mem periods (30.76ns) is physically correct, not a paper
# fix: sd_data is loaded from din ONLY at t==STATE_CMD_CONT (state 2 of the
# 8-state, ~123ns sdram cycle, rtl/sdram.v:174), and during a write the 68k is
# stalled on DTACK so din is held stable for the WHOLE access (many clk_mem
# periods) before state 2 samples it. Independently, the launching kernel regs
# only advance on clkena (>= 2 clk_sys = 4 clk_mem periods apart, same basis as
# the kernel multicycle above), so din cannot change within a single clk_mem
# period regardless. Either way the 1-period-early edge would latch the same
# settled value, so -setup -end 2 is safe. Scope is -from clk_sys -to the
# sd_data registers only: it does NOT touch the clk_mem->sd_data load-enable
# (we_latch) path nor the address/command paths, which stay single-cycle.
# The keeper pattern must also catch fitter-created DUPLICATES of the output
# register (sd_data[N]~reg0_Duplicate_M): the 2026-08-07 VRAM work added
# fanout on the din cone and the fitter began cloning sd_data regs — the
# clone carried this exact already-waived path but its name escaped the
# original ~reg0 pattern, resurfacing the known -1.9ns as a "new" violation.
set_multicycle_path -setup -end 2 \
    -from [get_clocks {*|pll|pll_inst|altera_pll_i|general[1].*|divclk}] \
    -to   [get_keepers {*sdram:sdram|sd_data[*]~reg0*}]
set_multicycle_path -hold  -end 1 \
    -from [get_clocks {*|pll|pll_inst|altera_pll_i|general[1].*|divclk}] \
    -to   [get_keepers {*sdram:sdram|sd_data[*]~reg0*}]

# ----------------------------------------------------------------------------
# Peripheral (VPA) read-data register — SCSI read-path fit-stabilization.
# ----------------------------------------------------------------------------
# periph_din_reg (MacIIvi.sv) captures the peripheral read mux (dataControllerDataOut)
# one clk_sys stage before the CPU samples it on VPA/6800 cycles. Its deepest input
# cone is the SCSI CSR's scsi_bsy bit (scsi.v phase -> |target_bsy -> CSR -> far
# route -> 7-way mux) — historically THE fit-sensitive net (bit6/scsi_bsy read
# wrong while shallow bit1/scsi_sel read right) behind dice-roll SCSI boots and
# the #3 cold-boot spontaneous reboot (docs/handoff_cold_boot_reboot_2026-06-15.md).
#
# Peripheral reads are E-paced: the wrapper stalls at s_state 4 for xVma (near
# E-fall) and latches read data at s_state 6, ALWAYS >= 5 clk_sys after the
# address/select settle (rtl/tg68k/tg68k.v:277,288,308). So the cone into
# periph_din_reg genuinely has multiple clk_sys to resolve, not one. Credit a
# CONSERVATIVE 2x (61.6 ns @ 32.5 MHz) — well inside the >=5-cycle window — so
# STA reports the real margin instead of over-constraining this E-paced read to
# a single 30.8 ns period (the "STA passes but HW fails" trap). periph_din_reg
# is only CONSUMED during VPA reads, when its input is held stable by the CPU;
# its fan-OUT (-> tg68_din_r, near the CPU) stays a normal single-cycle path and
# is deliberately NOT relaxed. (Ported from MacLC 0c8844b; supersedes the earlier
# constraint-only relaxation `-from {*ncr5380*} -to {*tg68_din_r*}` — with the
# register in place, all remaining direct paths into the CPU din latch must
# close single-cycle.)
set_multicycle_path -setup -end 2 -to [get_keepers {*periph_din_reg*}]
set_multicycle_path -hold  -end 1 -to [get_keepers {*periph_din_reg*}]

# ----------------------------------------------------------------------------
# Pixel-clock domain (pll_video) CDC — false-path the 2FF synchronizer heads.
# ----------------------------------------------------------------------------
# The V8 scanout runs on clk_vid (pll_video, reconfigured 25.175/15.664/58.742
# MHz). sys_top.sdc decouples every clock domain with set_clock_groups, but
# its core-PLL pattern (*|pll|pll_inst|...) matches only the MAIN pll — the
# pll_video clock landed in NO group, so every framework path touching
# CLK_VIDEO (ascal video-in, OSD, HDMI transfer) was timed against unrelated
# domains: design-wide false violations (worst -27.9 ns, clk_sys TNS -89k).
# Declare it asynchronous to everything else, exactly like pll_hdmi/pll_audio.
#
# The deliberate clk_sys<->clk_vid crossings this blesses are all safe by
# construction: (a) dual-clock M10Ks (vram_bram framebuffer, ariel palette —
# no timed cross-port arc), (b) 2FF *_meta synchronizers (config into the
# video module, video-domain reset, VBL/HBL back into clk_sys), and (c) the
# quasi-static words_per_line bus into addrController's VRAM write packing —
# incoherent only across a monitor/depth change, when the guest redraws the
# whole screen anyway.
set_clock_groups -asynchronous -group [get_clocks {emu|pllv|*|divclk}]

# Belt-and-braces documentation of the synchronizer heads (redundant with the
# clock group above, harmless).
set_false_path -to [get_keepers {*vmode_meta* *monid_meta* *tbyp_meta* *tsel_meta*}]
set_false_path -to [get_keepers {*vidrst_meta* *vbl_meta* *hbl_meta*}]

# HDMI-scaler closure margin (2026-08-08): the pll_hdmi divclk domain is the
# core's documented knife-edge — seed sweeps land between roughly -0.2 and
# +0.2 ns on it while every Mac-side domain holds >= +2. Pad its intra-domain
# setup uncertainty by 50 ps so a sweep only ever accepts a seed with real
# margin: a "met" report here means met by more than temperature/aging luck.
# (-add stacks on top of derive_clock_uncertainty's jitter numbers.)
set_clock_uncertainty -add -setup \
    -from [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}] \
    -to   [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}] \
    0.050
