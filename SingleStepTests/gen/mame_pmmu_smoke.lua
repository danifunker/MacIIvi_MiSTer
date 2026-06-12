-- MAME Lua script: 68030 PMMU smoke test (oracle-path verification).
--
-- Companion to mame_pmmu_capture.lua. This is NOT a corpus generator --
-- it is the end-to-end sanity check that proves, on a given MAME build
-- and 68030 driver (maciivi once ROMs are present; maciici works today):
--
--   1. The PMMU register state is visible to Lua via cpu.state
--      (TC / TT0 / TT1 / CRP_LIMIT / CRP_APTR / SRP_LIMIT / SRP_APTR / PSR).
--   2. PMOVE to/from TC, TT0, TT1, CRP, SRP executes (no F-line trap)
--      and round-trips through memory.
--   3. PFLUSHA executes.
--   4. PTESTR walks a planted translation table (early-termination page
--      descriptor) and updates PSR.
--   5. The Lua state view and the PMOVE architectural readback agree --
--      which is the invariant the corpus generator depends on.
--
-- All PMMU instructions run in supervisor mode (SR=$2700), translation
-- DISABLED (TC.E=0) -- the same "tier 1" conditions the hardware bench
-- uses on a real Macintosh LC II / IIvi.
--
-- USAGE
--   cd ~/repos/mame
--   ./mame maciici -skip_gameinfo -nothrottle -video none -sound none -seconds_to_run 60 -autoboot_delay 1 \
--       -autoboot_script <repo>/SingleStepTests/gen/mame_pmmu_smoke.lua
--
-- Exit: prints PASS/FAIL per check plus a summary line, then quits MAME.

local PROG_BASE   = 0x00001000
local DATA_BASE   = 0x00001800   -- PMOVE write-side source values
local RB_BASE     = 0x00001900   -- PMOVE read-side (architectural readback)
local CRP_TABLE   = 0x00003000   -- planted translation table (CRP)
local SRP_TABLE   = 0x00004000   -- planted translation table (SRP)
local STOP_PC     = 0x00001066   -- JMP-self at end of program
local VEC_BASE    = 0x00000000
local VEC_COUNT   = 256

-- Values written into the MMU registers by the planted program.
-- All chosen so translation stays OFF and TT matching stays OFF.
local TT0_VAL  = 0x12340000     -- bit 15 (E) clear -> TT0 disabled
local TT1_VAL  = 0x56780000     -- disabled
local TC_VAL   = 0x00C08840     -- E=0. Valid geometry if enabled:
                                -- PS=12(4K) IS=0 TIA=8 TIB=8 TIC=4 TID=0 (sum 32)
local CRP_LIM  = 0x7FFF0002     -- limit $7FFF, DT=2 (valid, 4-byte descriptors)
local CRP_PTR  = CRP_TABLE
local SRP_LIM  = 0x7FFF0002
local SRP_PTR  = SRP_TABLE

local cpu, prog
local function init_handles()
    cpu  = manager.machine.devices[":maincpu"]
    prog = cpu.spaces["program"]
end
local function rget(name) return cpu.state[name].value end
local function rset(name, v) cpu.state[name].value = v end

local function w8(a, v)  prog:write_u8(a, v) end
local function w16(a, v) w8(a, (v >> 8) & 0xFF); w8(a + 1, v & 0xFF) end
local function w32(a, v) w16(a, (v >> 16) & 0xFFFF); w16(a + 2, v & 0xFFFF) end
local function r16(a) return (prog:read_u8(a) << 8) | prog:read_u8(a + 1) end
local function r32(a) return (r16(a) << 16) | r16(a + 2) end

-- ----------------------------------------------------------------------
-- Planted program. PMOVE ext words verified against MAME
-- src/devices/cpu/m68000/m68kmmu.h (m68851_pmove/_get/_put):
--   TT0 w/r = $0800/$0A00   TT1 w/r = $0C00/$0E00
--   TC  w/r = $4000/$4200   SRP w/r = $4800/$4A00   CRP w/r = $4C00/$4E00
--   PSR r   = $6200         PFLUSHA = $2400
--   PTESTR #5,(A0),#7 ext = $8000|7<<10|$200|($10|5) = $9E15
-- ----------------------------------------------------------------------
local function plant_program()
    local a = PROG_BASE
    local function ins(...)
        for _, w in ipairs({...}) do w16(a, w); a = a + 2 end
    end
    -- write side (memory -> MMU reg)
    ins(0xF039, 0x0800, 0x0000, 0x1800)   -- PMOVE (DATA+$00).L,TT0
    ins(0xF039, 0x0C00, 0x0000, 0x1804)   -- PMOVE (DATA+$04).L,TT1
    ins(0xF039, 0x4000, 0x0000, 0x1808)   -- PMOVE (DATA+$08).L,TC
    ins(0xF039, 0x4C00, 0x0000, 0x1810)   -- PMOVE (DATA+$10).L,CRP (limit,aptr)
    ins(0xF039, 0x4800, 0x0000, 0x1818)   -- PMOVE (DATA+$18).L,SRP
    ins(0xF000, 0x2400)                   -- PFLUSHA
    ins(0x41F9, 0x0000, 0x1800)           -- LEA (DATA).L,A0
    ins(0xF010, 0x9E15)                   -- PTESTR #5,(A0),#7
    -- read side (MMU reg -> memory)
    ins(0xF039, 0x0A00, 0x0000, 0x1900)   -- PMOVE TT0,(RB+$00).L
    ins(0xF039, 0x0E00, 0x0000, 0x1904)   -- PMOVE TT1,(RB+$04).L
    ins(0xF039, 0x4200, 0x0000, 0x1908)   -- PMOVE TC,(RB+$08).L
    ins(0xF039, 0x4E00, 0x0000, 0x1910)   -- PMOVE CRP,(RB+$10).L
    ins(0xF039, 0x4A00, 0x0000, 0x1918)   -- PMOVE SRP,(RB+$18).L
    ins(0xF039, 0x6200, 0x0000, 0x1920)   -- PMOVE PSR,(RB+$20).L (16-bit)
    assert(a == STOP_PC, string.format("layout drift: end=%04X", a))
    ins(0x4EF9, 0x0000, STOP_PC)          -- JMP (STOP_PC).L  -- spin
end

local function plant_data()
    w32(DATA_BASE + 0x00, TT0_VAL)
    w32(DATA_BASE + 0x04, TT1_VAL)
    w32(DATA_BASE + 0x08, TC_VAL)
    w32(DATA_BASE + 0x10, CRP_LIM); w32(DATA_BASE + 0x14, CRP_PTR)
    w32(DATA_BASE + 0x18, SRP_LIM); w32(DATA_BASE + 0x1C, SRP_PTR)
    -- readback area poisoned so a trapped/skipped PMOVE is visible
    for i = 0, 0x3F do w8(RB_BASE + i, 0xCD) end
    -- translation tables: entry 0 (va[31:24]=0) = early-termination page
    -- descriptor, base 0 (DT=1) -> identity map for low addresses.
    w32(CRP_TABLE, 0x00000001)
    w32(SRP_TABLE, 0x00000001)
    -- vectors: any exception lands on the spin loop (looks like a finish,
    -- but leaves the $CD poison in place -> detected as FAIL)
    for v = 0, VEC_COUNT - 1 do w32(VEC_BASE + v * 4, STOP_PC) end
end

-- ----------------------------------------------------------------------
-- Frame-driven state machine (same skeleton as mame_cpu_capture.lua)
-- ----------------------------------------------------------------------
local RAM_PROBE_VALUE = 0xDEADBEEF
local MAX_WAIT_FRAMES = 1800
local MAX_RUN_FRAMES  = 120

local phase  = "WAIT_RAM"
local frames = 0
local n_pass, n_fail = 0, 0

local function check(name, got, want)
    if got == want then
        print(string.format("PASS  %-28s = %08X", name, got))
        n_pass = n_pass + 1
    else
        print(string.format("FAIL  %-28s = %08X (want %08X)", name, got, want))
        n_fail = n_fail + 1
    end
end

local function run_checks()
    -- 1) architectural readback (what the program saw via PMOVE)
    check("rb: TT0",       r32(RB_BASE + 0x00), TT0_VAL)
    check("rb: TT1",       r32(RB_BASE + 0x04), TT1_VAL)
    check("rb: TC",        r32(RB_BASE + 0x08), TC_VAL)
    check("rb: CRP limit", r32(RB_BASE + 0x10), CRP_LIM)
    check("rb: CRP aptr",  r32(RB_BASE + 0x14), CRP_PTR)
    check("rb: SRP limit", r32(RB_BASE + 0x18), SRP_LIM)
    check("rb: SRP aptr",  r32(RB_BASE + 0x1C), SRP_PTR)
    -- 2) Lua state view must agree with the architectural readback
    check("state: TC",        rget("TC"),        TC_VAL)
    check("state: TT0",       rget("TT0"),       TT0_VAL)
    check("state: TT1",       rget("TT1"),       TT1_VAL)
    check("state: CRP_LIMIT", rget("CRP_LIMIT"), CRP_LIM)
    check("state: CRP_APTR",  rget("CRP_APTR"),  CRP_PTR)
    check("state: SRP_LIMIT", rget("SRP_LIMIT"), SRP_LIM)
    check("state: SRP_APTR",  rget("SRP_APTR"),  SRP_PTR)
    -- 3) PTESTR result: PSR via PMOVE readback and via state. Don't
    --    hard-assert a value here (that's corpus work) -- just require
    --    the two views agree and print what the walk produced.
    local psr_rb = r16(RB_BASE + 0x20)
    local psr_st = rget("PSR") & 0xFFFF
    check("PSR (rb vs state)", psr_rb, psr_st)
    print(string.format("INFO  PTESTR #5,(A0=%08X),#7 -> PSR=%04X  (N=%d%s%s%s)",
        DATA_BASE, psr_rb, psr_rb & 7,
        (psr_rb & 0x8000) ~= 0 and " B" or "",
        (psr_rb & 0x0400) ~= 0 and " I" or "",
        (psr_rb & 0x4000) ~= 0 and " L" or ""))
    print(string.format("RESULT %d passed, %d failed", n_pass, n_fail))
end

local function tick()
    init_handles()
    if phase == "WAIT_RAM" then
        prog:write_u32(PROG_BASE, RAM_PROBE_VALUE)
        frames = frames + 1
        if prog:read_u32(PROG_BASE) == RAM_PROBE_VALUE then
            print(string.format("RAM mapped at $%08X after %d frames.",
                PROG_BASE, frames))
            emu.pause()
            plant_program()
            plant_data()
            for r = 0, 7 do rset("D" .. r, 0); rset("A" .. r, 0) end
            rset("SR", 0x2700)
            rset("A7", 0x00080000)
            rset("PC", PROG_BASE)
            rset("VBR", VEC_BASE)
            if cpu.state["SFC"]  then rset("SFC", 5) end
            if cpu.state["DFC"]  then rset("DFC", 5) end
            if cpu.state["CACR"] then rset("CACR", 0) end
            emu.unpause()
            frames = 0
            phase = "RUN"
        elseif frames >= MAX_WAIT_FRAMES then
            print("ERROR: RAM never mapped; aborting.")
            phase = "EXITED"; manager.machine:exit()
        end
    elseif phase == "RUN" then
        frames = frames + 1
        if rget("PC") == STOP_PC then
            emu.pause()
            run_checks()
            phase = "EXITED"; manager.machine:exit()
        elseif frames >= MAX_RUN_FRAMES then
            print(string.format("TIMEOUT: PC=$%08X (expected $%08X) SR=$%04X",
                rget("PC"), STOP_PC, rget("SR")))
            print("RESULT 0 passed, 99 failed (timeout)")
            phase = "EXITED"; manager.machine:exit()
        end
    end
end

emu.register_frame_done(tick, "pmmu_smoke")
print("mame_pmmu_smoke.lua loaded -- waiting for RAM at $1000.")
