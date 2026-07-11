-- mmu_reconfig.lua — does MAME's maclc2 survive the MMU-reconfig at $A03EFC..$A03F12
-- (pload/pmove TT0/TT1/CRP/TC)? Our core bus-errors right after `pmove (8,A0),TC`.
-- Post-reconfig the boot enables the i-cache, so CODE read-taps don't fire (fetches
-- run from cache). Instead tap the DATA the routine touches (low mem, uncached):
--   read  $0CB4/$0CB8 : the `movea.l $cbX.w,a0` that loads the descriptor ptr A0
--   write $0CB2       : `move.b d1,$cb2.w` at $A03F18 — the instruction AFTER pmove TC,
--                       so it firing == MAME executed the pmove TC and SURVIVED.
-- On each hit dump PC + A0 + the descriptor block (CRP/(8)=TC/(c)=TT0/(10)=TT1 source).
--
-- Run: REG_OUT=/tmp/mame_mmu.txt verilator/mame/run_mame_maclc2.sh -skip_gameinfo \
--        -autoboot_delay 1 -autoboot_script verilator/mame/mmu_reconfig.lua -seconds_to_run 12
local OUT = os.getenv("REG_OUT") or "/tmp/mame_mmu.txt"
local f = io.open(OUT, "w")
local cpu, space
local taps = {}
local frame, installed = 0, false
local n = {}

local function R(nm) local v=0; pcall(function() v=cpu.state[nm].value end); return v end
local function RD32(a) local v=0; pcall(function() v=space:read_u32(a) end); return v end

local function dump(tag)
    local a0 = R"A0"
    f:write(string.format("%s F=%d PC=%08X A0=%08X A7=%08X D0=%08X D1=%08X SR=%04X\n",
        tag, frame, R"PC", a0, R"A7", R"D0", R"D1", R"SR"))
    f:write(string.format("  descr A0=%08X (A0/CRPhi)=%08X (4/CRPlo)=%08X (8/TC)=%08X (c/TT0)=%08X (10/TT1)=%08X  [0CB4]=%08X [0CB8]=%08X\n",
        a0, RD32(a0), RD32(a0+4), RD32(a0+8), RD32(a0+0xc), RD32(a0+0x10), RD32(0x0CB4), RD32(0x0CB8)))
    f:flush()
end

local function install()
    for _,t in ipairs(taps) do pcall(function() t:remove() end) end
    taps = {}
    -- read taps on the A0-source longwords
    for _,a in ipairs({0x0CB4, 0x0CB8}) do
        taps[#taps+1] = space:install_read_tap(a, a+3, "rd", function(o,d,m)
            n["R"..a]=(n["R"..a] or 0)+1
            if n["R"..a] <= 6 then dump(string.format("READ_%04X", a)) end
        end)
    end
    -- write tap on $0CB2 (the post-pmove-TC store -> "survived" marker)
    taps[#taps+1] = space:install_write_tap(0x0CB2, 0x0CB2, "wr", function(o,d,m)
        n.W=(n.W or 0)+1
        if n.W <= 10 then dump("WRITE_0CB2_survived_pmoveTC") end
    end)
end

emu.register_frame_done(function()
    frame = frame + 1
    if not installed then
        installed = true
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        f:write("# mmu_reconfig (data taps) install\n"); f:flush()
        install()
    end
    if frame % 20 == 0 then install() end
    if frame >= 360 then
        f:write("# END\n"); f:flush(); f:close(); manager.machine:exit()
    end
end)
