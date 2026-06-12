-- MAME Lua script: capture 68030 PMMU instruction state for the
-- Macintosh IIvi core testbench.
--
-- Sibling of mame_cpu_capture.lua, specialized for the on-chip PMMU.
-- Run it against any MAME 68030 Macintosh driver:
--   * maciivi  -- the target machine (needs maciivx ROM set)
--   * maciici  -- works with the ROMs on hand today; the CPU+PMMU oracle
--                 is identical (same MC68030 device), only the chipset
--                 around it differs, which these tests never touch.
--
-- Unlike the CPU corpus, PMMU state can't be dumped by unprivileged
-- store instructions, and PMOVE-based dump epilogues would perturb the
-- ATC under test. So this capture snapshots ALL state (GP regs + MMU
-- regs + RAM windows) through the Lua state interface instead, before
-- and after each test. mame_pmmu_smoke.lua proves the Lua state view
-- and the PMOVE architectural readback agree, which makes this valid.
--
-- Every test's program is:   [test bytes][CATCHER]
--   CATCHER = PMOVE (TC_OFF).L,TC ; JMP self
-- All 256 exception vectors point at the catcher, so faulting tests
-- also converge there -- with translation forcibly re-disabled, because
-- the catcher's PMOVE always executes. (TC_OFF holds 0x00000000.)
-- A test that took an exception is visible through the stack window
-- diff (the pushed frame) and final.a7 < initial.a7.
--
-- Test flags:
--   privileged       -- all PMMU tests (always true)
--   mmu_live         -- enables translation (TC.E=1) during the test
--   raises_exception -- expected to take a fault (berr / MMU config)
--   hw_unsafe        -- do not run on real hardware yet (mmu_live and
--                       fault tests start out hw_unsafe until the
--                       LC II supervisor bench proves them safe)
--
-- Outputs:
--   /tmp/pmmu_corpus.json  -- JSON Lines, one test per line (SCHEMA.md)
--   /tmp/pmmu_tests.h      -- C header for the preboot supervisor bench
--
-- USAGE
--   cd ~/repos/mame
--   ./mame maciici -skip_gameinfo -nothrottle -video none -sound none -seconds_to_run 120 -autoboot_delay 1 \
--       -autoboot_script <repo>/SingleStepTests/gen/mame_pmmu_capture.lua

local OUT_JSON  = "/tmp/pmmu_corpus.json"
local OUT_H     = "/tmp/pmmu_tests.h"

local PROG_BASE = 0x00001000
local TC_OFF    = 0x000017F8   -- holds 0x00000000 (the catcher's TC source)
local DATA_BASE = 0x00001800   -- per-test data values (PMOVE sources etc.)
local ROOT_TBL  = 0x00003000   -- root (level A) translation table
local LEVB_TBL  = 0x00003100   -- level B table
local LEVC_TBL  = 0x00003200   -- level C table
local SRP_TBL   = 0x00004000   -- root table for SRP-path tests
local REMAP_PA  = 0x00009000   -- physical page that va $8000 remaps to
local REMAP2_PA = 0x0000A000   -- second remap target (ATC staleness tests)
local STACK_TOP = 0x00080000
local VEC_BASE  = 0x00000000

-- Memory windows snapshotted (zeroed, planted, diffed) for every test.
local WINDOWS = {
    { DATA_BASE,        0x40 },
    { ROOT_TBL,         0x40 },
    { LEVB_TBL,         0x40 },
    { LEVC_TBL,         0x40 },
    { SRP_TBL,          0x40 },
    { REMAP_PA,         0x40 },
    { REMAP2_PA,        0x40 },
    { STACK_TOP - 0x60, 0x60 },   -- exception frame lands here
}

-- Default MMU geometry: PS=12 (4K pages), IS=0, TIA=8, TIB=8, TIC=4,
-- TID=0 (sums to 32 -> valid when enabled). E=0 in the default.
local TC_GEOM   = 0x00C08840
local CRP_DEF_L = 0x7FFF0002   -- limit $7FFF, DT=2 (4-byte table at aptr)
local CRP_DEF_A = ROOT_TBL
local SRP_DEF_L = 0x7FFF0002
local SRP_DEF_A = SRP_TBL

-- ----------------------------------------------------------------------
-- Handles + helpers
-- ----------------------------------------------------------------------
local cpu, prog
local function init_handles()
    cpu  = manager.machine.devices[":maincpu"]
    prog = cpu.spaces["program"]
end
local function rget(name) return cpu.state[name].value end
local function rset(name, v) cpu.state[name].value = v end

local function bw(w) return { (w >> 8) & 0xFF, w & 0xFF } end
local function bl(l)
    return { (l >> 24) & 0xFF, (l >> 16) & 0xFF,
             (l >>  8) & 0xFF,  l        & 0xFF }
end
local function concat(...)
    local out = {}
    for _, t in ipairs({...}) do
        for _, b in ipairs(t) do out[#out + 1] = b end
    end
    return out
end
local function write_bytes(addr, bytes)
    for i, b in ipairs(bytes) do prog:write_u8(addr + i - 1, b) end
end

-- Instruction emitters --------------------------------------------------
-- PMOVE ext words (verified against MAME m68kmmu.h, m68851_pmove*):
--   TT0 w/r=$0800/$0A00  TT1 w/r=$0C00/$0E00  TC w/r=$4000/$4200
--   SRP w/r=$4800/$4A00  CRP w/r=$4C00/$4E00  PSR w/r=$6000/$6200
local function pmove_w_abs(ext, addr)   -- PMOVE (addr).L,<reg>
    return concat(bw(0xF039), bw(ext), bl(addr))
end
local function pmove_r_abs(ext, addr)   -- PMOVE <reg>,(addr).L
    return concat(bw(0xF039), bw(ext | 0x0200), bl(addr))
end
local function pflusha() return concat(bw(0xF000), bw(0x2400)) end
local function pflush_fc_mask(fc, mask) -- PFLUSH #fc,#mask
    return concat(bw(0xF000), bw(0x3000 | ((mask & 7) << 5) | 0x10 | (fc & 7)))
end
local function pflush_fc_mask_a0(fc, mask) -- PFLUSH #fc,#mask,(A0)
    return concat(bw(0xF010), bw(0x3800 | ((mask & 7) << 5) | 0x10 | (fc & 7)))
end
local function pload_a0(fc, read)       -- PLOAD{R|W} #fc,(A0)
    return concat(bw(0xF010),
                  bw(0x2000 | (read and 0x200 or 0) | 0x10 | (fc & 7)))
end
local function ptest_a0(fc, level, read, areg) -- PTEST{R|W} #fc,(A0),#level[,An]
    local ext = 0x8000 | ((level & 7) << 10) | (read and 0x200 or 0)
                       | 0x10 | (fc & 7)
    if areg then ext = ext | 0x100 | ((areg & 7) << 5) end
    return concat(bw(0xF010), bw(ext))
end
local function move_l_dn_abs(dn, addr)  -- MOVE.L Dn,(addr).L
    return concat(bw(0x23C0 | (dn & 7)), bl(addr))
end
local function move_l_abs_dn(addr, dn)  -- MOVE.L (addr).L,Dn
    return concat(bw(0x2039 | ((dn & 7) << 9)), bl(addr))
end
local function move_l_imm_abs(imm, addr) -- MOVE.L #imm,(addr).L
    return concat(bw(0x23FC), bl(imm), bl(addr))
end
local function lea_abs_a0(addr)          -- LEA (addr).L,A0
    return concat(bw(0x41F9), bl(addr))
end

-- Short-format descriptors ---------------------------------------------
local function page_desc(pa, flags) return (pa & 0xFFFFFF00) | (flags or 0) | 1 end
local function table_desc(pa)       return (pa & 0xFFFFFFF0) | 2 end
local WP = 0x04   -- write-protect flag in short descriptors

-- ----------------------------------------------------------------------
-- Test table
-- ----------------------------------------------------------------------
-- Each test:
--   name    string
--   test    byte list (the instruction(s) under test, catcher appended)
--   mmu     overrides for initial MMU regs (defaults below)
--   plants  list of {addr, longword} planted after windows are zeroed
--   regs    optional {dN=..., aN=...} initial GP overrides
--   flags   {mmu_live=, raises_exception=, hw_unsafe=}
--
-- Defaults per test: TC=TC_GEOM (E=0), TT0/TT1=0, CRP={CRP_DEF_L, ROOT_TBL},
-- SRP={SRP_DEF_L, SRP_TBL}, PSR=0; ROOT[0] and SRP_TBL[0] = identity
-- early-termination page descriptor (everything maps 1:1).

local DEF_PLANTS = {
    { ROOT_TBL, page_desc(0, 0) },
    { SRP_TBL,  page_desc(0, 0) },
}

-- plants for a 3-level walk: ROOT[0] -> LEVB, LEVB[0] -> LEVC,
-- LEVC[i] = identity pages, with optional overrides.
-- LEVB[7] identity-maps va $070000-$07FFFF (early termination) so the
-- supervisor stack at STACK_TOP=$80000 pushes exception frames through
-- the MMU without itself faulting. (Lesson learned: without this, a
-- bus-error test double-faults inside MAME's exception processing.)
local function three_level(c_overrides)
    local p = {
        { ROOT_TBL, table_desc(LEVB_TBL) },
        { LEVB_TBL, table_desc(LEVC_TBL) },
        { LEVB_TBL + 7 * 4, page_desc(0x00070000, 0) },
        { SRP_TBL,  page_desc(0, 0) },
    }
    for i = 0, 15 do
        local desc = page_desc(i * 0x1000, 0)
        if c_overrides and c_overrides[i] ~= nil then desc = c_overrides[i] end
        p[#p + 1] = { LEVC_TBL + i * 4, desc }
    end
    return p
end

local tests = {}
local function T(t) tests[#tests + 1] = t end

-- ---- PMOVE register round-trips (safe everywhere) ---------------------
local function pmove_rt(name, wext, rext, val, val2)
    -- write <val> from DATA+0 into the reg, read it back to DATA+$20
    local body = concat(pmove_w_abs(wext, DATA_BASE),
                        pmove_r_abs(rext & 0xFDFF, DATA_BASE + 0x20))
    local plants = { { DATA_BASE, val } }
    if val2 then plants[#plants + 1] = { DATA_BASE + 4, val2 } end
    T{ name = name, test = body, plants = plants }
end
-- note: rext arg above is the WRITE ext; pmove_r_abs adds the R bit.
pmove_rt("PMOVE TC w/r (4K geometry, E=0)", 0x4000, 0x4000, TC_GEOM)
pmove_rt("PMOVE TC w/r (256B pages, E=0)",  0x4000, 0x4000, 0x00808880)
pmove_rt("PMOVE TC w/r (SRE=1, E=0)",       0x4000, 0x4000, 0x02C08840)
pmove_rt("PMOVE TC w/r (FCL=1, E=0)",       0x4000, 0x4000, 0x01C08840)
pmove_rt("PMOVE TC w/r (zero)",             0x4000, 0x4000, 0x00000000)
pmove_rt("PMOVE TT0 w/r (disabled)",        0x0800, 0x0800, 0x12340000)
pmove_rt("PMOVE TT0 w/r (enabled, match-all)", 0x0800, 0x0800, 0x00FF8777)
pmove_rt("PMOVE TT1 w/r (disabled)",        0x0C00, 0x0C00, 0x56780000)
pmove_rt("PMOVE TT1 w/r (enabled, match-all)", 0x0C00, 0x0C00, 0x00FF8777)

-- CRP/SRP are 64-bit: write limit+aptr from DATA+0/+4, read to DATA+$20/+$24
local function pmove_rt64(name, wext, lim, aptr)
    local body = concat(pmove_w_abs(wext, DATA_BASE),
                        pmove_r_abs(wext, DATA_BASE + 0x20))
    T{ name = name, test = body,
       plants = { { DATA_BASE, lim }, { DATA_BASE + 4, aptr } } }
end
pmove_rt64("PMOVE CRP w/r (DT=2 short table)", 0x4C00, 0x7FFF0002, ROOT_TBL)
pmove_rt64("PMOVE CRP w/r (DT=1 early term)",  0x4C00, 0x7FFF0001, 0x00000000)
pmove_rt64("PMOVE CRP w/r (DT=3 long table)",  0x4C00, 0x7FFF0003, ROOT_TBL)
pmove_rt64("PMOVE CRP w/r (lower limit L/U=1)",0x4C00, 0x80010002, ROOT_TBL)
pmove_rt64("PMOVE SRP w/r (DT=2 short table)", 0x4800, 0x7FFF0002, SRP_TBL)
pmove_rt64("PMOVE SRP w/r (DT=1 early term)",  0x4800, 0x7FFF0001, 0x00000000)

-- PSR round-trip: 16-bit reg, shows the writable-bit mask.
T{ name = "PMOVE PSR w/r (write $FFFF)",
   test = concat(pmove_w_abs(0x6000, DATA_BASE),
                 pmove_r_abs(0x6000, DATA_BASE + 0x20)),
   plants = { { DATA_BASE, 0xFFFF0000 } } }   -- word at DATA+0 = $FFFF

-- ---- PFLUSH / PLOAD ----------------------------------------------------
T{ name = "PFLUSHA", test = pflusha() }
T{ name = "PFLUSH #5,#7", test = pflush_fc_mask(5, 7) }
T{ name = "PFLUSH #1,#7,(A0)", test = pflush_fc_mask_a0(1, 7),
   regs = { a0 = DATA_BASE } }
T{ name = "PLOADW #5,(A0) early-term (U-bit in ROOT[0])",
   test = pload_a0(5, false), regs = { a0 = DATA_BASE } }
T{ name = "PLOADR #5,(A0) 3-level (U-bits down the walk)",
   test = pload_a0(5, true), regs = { a0 = DATA_BASE },
   plants = three_level() }

-- ---- PTEST -------------------------------------------------------------
local function ptest(name, opts)
    T{ name = name,
       test   = ptest_a0(opts.fc or 5, opts.level, opts.read, opts.areg),
       regs   = { a0 = opts.va or DATA_BASE, a1 = 0 },
       plants = opts.plants,
       mmu    = opts.mmu,
       flags  = opts.flags }
end
-- NOTE: depth-limited PTEST (#1..#6) that ends its search on a TABLE
-- descriptor (not a page descriptor) is NOT capturable on this MAME
-- build: pmmu_walk_tables() returns unresolved and m68kmmu.h:591
-- raises fatalerror("Table walk did not resolve"), killing the
-- emulator. MAME counts the root-pointer fetch as a level, so even
-- "#1" against an early-termination tree dies. Real 68030 silicon
-- reports the partial walk in PSR instead. Only #0 (pure ATC probe)
-- and full-depth (#7) forms are in corpus v1; depth-limited variants
-- must come from real-LC II captures (or a patched MAME).
ptest("PTESTR #5,(A0),#7 early-term (N=1)",   { level = 7, read = true })
ptest("PTESTR #5,(A0),#0 (ATC probe, empty)",  { level = 0, read = true })
ptest("PTESTW #5,(A0),#7 early-term",          { level = 7, read = false })
ptest("PTESTR #5,(A0),#7 3-level (N=3)",       { level = 7, read = true,
      plants = three_level() })
ptest("PTESTR #5,(A0),#7,A1 phys writeback",   { level = 7, read = true,
      areg = 1, plants = three_level() })
ptest("PTESTW #5,(A0),#7 write-protected page (W)", { level = 7, read = false,
      va = 0x00008010, plants = three_level({ [8] = page_desc(REMAP_PA, WP) }) })
ptest("PTESTR #5,(A0),#7 invalid descriptor (I)",   { level = 7, read = true,
      va = 0x0000B010, plants = three_level({ [11] = 0 }) })
ptest("PTESTR #5,(A0),#7 root limit violation (L)", { level = 7, read = true,
      va = 0x01000000,
      mmu = { crp_limit = 0x00000002 } })   -- upper limit 0: index 1 violates
ptest("PTESTR #5,(A0),#7 through TT0 (T)",          { level = 7, read = true,
      mmu = { tt0 = 0x00FF8777 } })          -- TT0 enabled, matches everything
ptest("PTESTR #5,(A0),#7 long-format root (DT=3)",  { level = 7, read = true,
      mmu = { crp_limit = 0x7FFF0003 },
      plants = { { ROOT_TBL, 0x7FFF0001 }, { ROOT_TBL + 4, 0x00000000 },
                 { SRP_TBL, page_desc(0, 0) } } })
ptest("PTESTR #5,(A0),#7 via SRP (SRE=1, WP marks SRP path)", { level = 7,
      read = true, mmu = { tc = 0x02C08840 },
      plants = { { ROOT_TBL, page_desc(0, 0) },
                 { SRP_TBL,  page_desc(0, WP) } } })

-- ---- Live translation (TC.E=1 inside the test) -------------------------
-- TC enable value is planted at DATA+8; tests bracket the body with
-- PMOVE-enable / PMOVE-disable (the catcher re-disables on faults).
local TC_ON = TC_GEOM | 0x80000000
local function live(name, body, opts)
    opts = opts or {}
    local plants = opts.plants or three_level()
    plants[#plants + 1] = { DATA_BASE + 8, TC_ON }
    T{ name  = name,
       test  = concat(pmove_w_abs(0x4000, DATA_BASE + 8), body,
                      pmove_w_abs(0x4000, TC_OFF)),
       regs  = opts.regs, plants = plants,
       flags = { mmu_live = true, hw_unsafe = true,
                 raises_exception = opts.raises_exception } }
end
live("LIVE identity store (early-term map)",
     move_l_dn_abs(1, DATA_BASE + 0x30),
     { plants = { { ROOT_TBL, page_desc(0, 0) },
                  { SRP_TBL,  page_desc(0, 0) } },
       regs = { d1 = 0xCAFED00D } })
live("LIVE remap store: va $8010 -> pa $9010 (M-bit in LEVC[8])",
     move_l_dn_abs(1, 0x00008010),
     { plants = three_level({ [8] = page_desc(REMAP_PA, 0) }),
       regs = { d1 = 0xFEEDC0DE } })
live("LIVE remap load: va $8020 reads pa $9020 (U-bit, M clear)",
     move_l_abs_dn(0x00008020, 2),
     { plants = (function()
           local p = three_level({ [8] = page_desc(REMAP_PA, 0) })
           p[#p + 1] = { REMAP_PA + 0x20, 0xCAFEBABE }
           return p
       end)(), regs = { d2 = 0 } })
live("LIVE ATC stale: edit LEVC[8] without PFLUSH, store again",
     concat(move_l_dn_abs(1, 0x00008010),                       -- loads ATC
            move_l_imm_abs(page_desc(REMAP2_PA, 0), LEVC_TBL + 8 * 4),
            move_l_dn_abs(2, 0x00008014)),                      -- stale or not?
     { plants = three_level({ [8] = page_desc(REMAP_PA, 0) }),
       regs = { d1 = 0x11111111, d2 = 0x22222222 } })
live("LIVE ATC flush: edit LEVC[8] + PFLUSHA, store goes to new pa",
     concat(move_l_dn_abs(1, 0x00008010),
            move_l_imm_abs(page_desc(REMAP2_PA, 0), LEVC_TBL + 8 * 4),
            pflusha(),
            move_l_dn_abs(2, 0x00008014)),
     { plants = three_level({ [8] = page_desc(REMAP_PA, 0) }),
       regs = { d1 = 0x33333333, d2 = 0x44444444 } })

-- ---- Faults -------------------------------------------------------------
live("FAULT store to invalid page (berr, frame on stack)",
     move_l_dn_abs(1, 0x0000B010),
     { plants = three_level({ [11] = 0 }),
       regs = { d1 = 0x55555555 }, raises_exception = true })
live("FAULT store to write-protected page (berr)",
     move_l_dn_abs(1, 0x00008010),
     { plants = three_level({ [8] = page_desc(REMAP_PA, WP) }),
       regs = { d1 = 0x66666666 }, raises_exception = true })
T{ name  = "FAULT PMOVE TC enable with bad geometry (MMU config exc)",
   test  = pmove_w_abs(0x4000, DATA_BASE),
   plants = { { DATA_BASE, 0x80C08844 },     -- sums to 36, not 32
              { ROOT_TBL, page_desc(0, 0) }, { SRP_TBL, page_desc(0, 0) } },
   flags = { mmu_live = true, raises_exception = true, hw_unsafe = true } }

-- ----------------------------------------------------------------------
-- Snapshot machinery
-- ----------------------------------------------------------------------
local function read_windows()
    local snap = {}
    for _, w in ipairs(WINDOWS) do
        local base, len = w[1], w[2]
        local bytes = {}
        for i = 0, len - 1 do bytes[i] = prog:read_u8(base + i) end
        snap[#snap + 1] = { base = base, len = len, bytes = bytes }
    end
    return snap
end

local function snap_state()
    local s = { d = {}, a = {} }
    for r = 0, 7 do
        s.d[r] = rget("D" .. r)
        s.a[r] = rget("A" .. r)
    end
    s.pc  = rget("PC")
    s.sr  = rget("SR")
    s.usp = (cpu.state["USP"] and rget("USP")) or 0
    s.mmu = {
        tc        = rget("TC"),
        tt0       = rget("TT0"),
        tt1       = rget("TT1"),
        crp_limit = rget("CRP_LIMIT"),
        crp_aptr  = rget("CRP_APTR"),
        srp_limit = rget("SRP_LIMIT"),
        srp_aptr  = rget("SRP_APTR"),
        psr       = rget("PSR") & 0xFFFF,
    }
    return s
end

local function json_state(s, ram_pairs)
    local d, a = {}, {}
    for r = 0, 7 do
        d[#d + 1] = string.format("%u", s.d[r])
        a[#a + 1] = string.format("%u", s.a[r])
    end
    local ram = {}
    for _, p in ipairs(ram_pairs) do
        ram[#ram + 1] = string.format("[%u,%u]", p[1], p[2])
    end
    return string.format(
        '{"d":[%s],"a":[%s],"pc":%u,"sr":%u,"usp":%u,' ..
        '"mmu":{"tc":%u,"tt0":%u,"tt1":%u,"crp_limit":%u,"crp_aptr":%u,' ..
        '"srp_limit":%u,"srp_aptr":%u,"psr":%u},"ram":[%s]}',
        table.concat(d, ","), table.concat(a, ","),
        s.pc, s.sr, s.usp,
        s.mmu.tc, s.mmu.tt0, s.mmu.tt1, s.mmu.crp_limit, s.mmu.crp_aptr,
        s.mmu.srp_limit, s.mmu.srp_aptr, s.mmu.psr,
        table.concat(ram, ","))
end

-- ----------------------------------------------------------------------
-- C header emission (preboot supervisor bench input)
-- ----------------------------------------------------------------------
local hdr_rows = {}
local function hdr_add(t, test_bytes, plant_list, mmu, regs)
    local tb = {}
    for _, b in ipairs(test_bytes) do tb[#tb + 1] = string.format("0x%02X", b) end
    local plants = {}
    for _, p in ipairs(plant_list) do
        plants[#plants + 1] = string.format("{0x%08XU,0x%08XU}", p[1], p[2])
    end
    local f = t.flags or {}
    local dl, al = {}, {}
    for r = 0, 7 do dl[#dl + 1] = string.format("0x%08XU", regs.d[r]) end
    for r = 0, 7 do al[#al + 1] = string.format("0x%08XU", regs.a[r]) end
    hdr_rows[#hdr_rows + 1] = string.format(
        '    {"%s",\n      {%s}, %d,\n      {%s}, %d,\n' ..
        '      {%s},\n      {%s},\n' ..
        '      0x%08XU,0x%08XU,0x%08XU,0x%08XU,0x%08XU,0x%08XU,0x%08XU,\n' ..
        '      1, %d, %d, %d},',
        t.name:gsub('"', '\\"'),
        table.concat(tb, ","), #test_bytes,
        table.concat(plants, ","), #plants,
        table.concat(dl, ","), table.concat(al, ","),
        mmu.tc, mmu.tt0, mmu.tt1,
        mmu.crp_limit, mmu.crp_aptr, mmu.srp_limit, mmu.srp_aptr,
        f.mmu_live and 1 or 0, f.raises_exception and 1 or 0,
        f.hw_unsafe and 1 or 0)
end

local function write_header()
    local fh = io.open(OUT_H, "w")
    fh:write([[
/* Auto-generated by SingleStepTests/gen/mame_pmmu_capture.lua.
 * Do not edit by hand -- regenerate by re-running the script. */
#ifndef PMMU_TESTS_H
#define PMMU_TESTS_H

#define PMMU_TEST_MAX_BYTES  96
#define PMMU_TEST_MAX_PLANTS 24

typedef struct {
    unsigned long addr;
    unsigned long value;          /* 32-bit big-endian longword */
} PmmuPlant;

typedef struct {
    const char *name;
    unsigned char test[PMMU_TEST_MAX_BYTES];
    unsigned short test_len;
    PmmuPlant plants[PMMU_TEST_MAX_PLANTS];
    unsigned short n_plants;
    /* initial GP registers (a[7] = corpus SSP; hardware runner
     * substitutes its relocated test stack) */
    unsigned long d[8];
    unsigned long a[8];
    /* initial MMU register state (set via PMOVE prologue on hardware) */
    unsigned long tc, tt0, tt1;
    unsigned long crp_limit, crp_aptr, srp_limit, srp_aptr;
    unsigned char privileged;     /* always 1 */
    unsigned char mmu_live;       /* enables translation mid-test */
    unsigned char raises_exception;
    unsigned char hw_unsafe;      /* skip on real hardware */
} PmmuTestSpec;

static PmmuTestSpec g_pmmu_tests[] = {
]])
    fh:write(table.concat(hdr_rows, "\n"))
    fh:write(string.format([[

};
#define PMMU_N_TESTS %d
#endif /* PMMU_TESTS_H */
]], #hdr_rows))
    fh:close()
end

-- ----------------------------------------------------------------------
-- Frame-driven state machine
-- ----------------------------------------------------------------------
local RAM_PROBE_VALUE = 0xDEADBEEF
local MAX_WAIT_FRAMES = 1800
local MAX_RUN_FRAMES  = 120

local phase     = "WAIT_RAM"
local frames    = 0
local test_i    = 1
local stop_pc   = 0
local out_file  = nil
local n_written = 0
local n_timeout = 0
local cur_init  = nil
local cur_plant = nil   -- planted [addr,byte] pairs for the running test

local function start_test(t)
    -- zero all windows, then plant
    for _, w in ipairs(WINDOWS) do
        for i = 0, w[2] - 1 do prog:write_u8(w[1] + i, 0) end
    end
    prog:write_u32(TC_OFF, 0)

    local plant_pairs = {}
    local plants = {}
    for _, p in ipairs(DEF_PLANTS) do plants[#plants + 1] = p end
    if t.plants then plants = t.plants end
    for _, p in ipairs(plants) do
        prog:write_u32(p[1], p[2])
        for i = 0, 3 do
            plant_pairs[#plant_pairs + 1] =
                { p[1] + i, (p[2] >> ((3 - i) * 8)) & 0xFF }
        end
    end

    -- program = test bytes + catcher
    local body = t.test
    local catcher = PROG_BASE + #body
    local prog_bytes = concat(body,
        pmove_w_abs(0x4000, TC_OFF),         -- catcher: force TC off
        {})
    local jmp_pc = PROG_BASE + #prog_bytes
    prog_bytes = concat(prog_bytes, bw(0x4EF9), bl(jmp_pc))
    write_bytes(PROG_BASE, prog_bytes)
    stop_pc = jmp_pc

    for v = 0, 255 do prog:write_u32(VEC_BASE + v * 4, catcher) end

    -- GP registers: distinctive defaults, then per-test overrides
    for r = 0, 7 do
        rset("D" .. r, 0xD0000000 + r * 0x01010101)
        if r < 7 then rset("A" .. r, 0xA0000000 + r * 0x01010101) end
    end
    rset("A0", DATA_BASE)
    rset("A7", STACK_TOP)
    if t.regs then
        for k, v in pairs(t.regs) do rset(k:upper(), v) end
    end
    rset("SR", 0x2700)
    rset("PC", PROG_BASE)
    rset("VBR", VEC_BASE)
    if cpu.state["SFC"]  then rset("SFC", 5) end
    if cpu.state["DFC"]  then rset("DFC", 5) end
    if cpu.state["CACR"] then rset("CACR", 0) end

    -- MMU registers: defaults + overrides. TC.E is ALWAYS 0 initially;
    -- live tests enable via PMOVE inside the test body.
    local mmu = {
        tc = TC_GEOM, tt0 = 0, tt1 = 0,
        crp_limit = CRP_DEF_L, crp_aptr = CRP_DEF_A,
        srp_limit = SRP_DEF_L, srp_aptr = SRP_DEF_A,
        psr = 0,
    }
    if t.mmu then for k, v in pairs(t.mmu) do mmu[k] = v end end
    rset("TC", mmu.tc); rset("TT0", mmu.tt0); rset("TT1", mmu.tt1)
    rset("CRP_LIMIT", mmu.crp_limit); rset("CRP_APTR", mmu.crp_aptr)
    rset("SRP_LIMIT", mmu.srp_limit); rset("SRP_APTR", mmu.srp_aptr)
    rset("PSR", mmu.psr)

    cur_init  = snap_state()
    cur_plant = plant_pairs
    hdr_add(t, body, plants, mmu, cur_init)
    frames = 0
end

local function finish_test(t, timed_out)
    local final = snap_state()
    -- final ram = diffs against (zeroed windows + plants)
    local init_byte = {}
    for _, p in ipairs(cur_plant) do init_byte[p[1]] = p[2] end
    local diffs = {}
    for _, w in ipairs(WINDOWS) do
        for i = 0, w[2] - 1 do
            local addr = w[1] + i
            local now  = prog:read_u8(addr)
            local was  = init_byte[addr] or 0
            if now ~= was then diffs[#diffs + 1] = { addr, now } end
        end
    end
    local f = t.flags or {}
    local flagstr = string.format(
        '{"privileged":true,"mmu_live":%s,"raises_exception":%s,"hw_unsafe":%s}',
        f.mmu_live and "true" or "false",
        f.raises_exception and "true" or "false",
        f.hw_unsafe and "true" or "false")
    out_file:write(string.format(
        '{"name":%q,"flags":%s,"timed_out":%s,"initial":%s,"final":%s}\n',
        t.name, flagstr, timed_out and "true" or "false",
        json_state(cur_init, cur_plant),
        json_state(final, diffs)))
    out_file:flush()
    n_written = n_written + 1
    if timed_out then n_timeout = n_timeout + 1 end
end

local function tick()
    init_handles()
    if phase == "WAIT_RAM" then
        prog:write_u32(PROG_BASE, RAM_PROBE_VALUE)
        frames = frames + 1
        if prog:read_u32(PROG_BASE) == RAM_PROBE_VALUE then
            print(string.format("RAM mapped at $%08X after %d frames.",
                PROG_BASE, frames))
            out_file = io.open(OUT_JSON, "w")
            if out_file == nil then
                print("ERROR: cannot open " .. OUT_JSON)
                phase = "EXITED"; manager.machine:exit(); return
            end
            phase = "SETUP_NEXT"; frames = 0
        elseif frames >= MAX_WAIT_FRAMES then
            print("ERROR: RAM never mapped; aborting.")
            phase = "EXITED"; manager.machine:exit()
        end
    elseif phase == "SETUP_NEXT" then
        if test_i > #tests then phase = "DONE"; return end
        local t = tests[test_i]
        print(string.format("[%d/%d] %s", test_i, #tests, t.name))
        emu.pause(); start_test(t); emu.unpause()
        phase = "RUN"
    elseif phase == "RUN" then
        frames = frames + 1
        if rget("PC") == stop_pc then
            emu.pause()
            finish_test(tests[test_i], false)
            emu.unpause()
            test_i = test_i + 1
            phase = "SETUP_NEXT"
        elseif frames >= MAX_RUN_FRAMES then
            print(string.format("  TIMEOUT: PC=$%08X expected $%08X SR=$%04X",
                rget("PC"), stop_pc, rget("SR")))
            emu.pause()
            finish_test(tests[test_i], true)
            -- force the MMU off so the next test starts clean
            rset("TC", 0)
            emu.unpause()
            test_i = test_i + 1
            phase = "SETUP_NEXT"
        end
    elseif phase == "DONE" then
        out_file:close()
        write_header()
        print(string.format("Wrote %d tests (%d timeouts) to %s and %s",
            n_written, n_timeout, OUT_JSON, OUT_H))
        phase = "EXITED"; manager.machine:exit()
    end
end

emu.register_frame_done(tick, "pmmu_capture")
print(string.format(
    "mame_pmmu_capture.lua loaded -- %d tests queued.", #tests))
