-- maincpu_regs.lua — dump MAME maclc2 MAINCPU (68030) register state at the RAM
-- descriptor-build + march points, to diff against our core's [MARCH]/[TBL] detectors.
-- Lua read-taps DO fire on opcode fetches (proven: $A46910 fires per fetch), so a read
-- tap on a code word lets us read cpu.state at that instruction.
--
-- MUST run with -skip_gameinfo (else the CPU is frozen on the info/warning screen).
-- Run: verilator/mame/run_mame_maclc2.sh -skip_gameinfo -autoboot_delay 1 \
--        -autoboot_script verilator/mame/maincpu_regs.lua -seconds_to_run 8

local OUT = os.getenv("REG_OUT") or "/tmp/maincpu_regs.txt"
local f = io.open(OUT, "w")
local cpu, space
local taps = {}
local frame, installed = 0, false
local hits = {}

local function R(n) local v=0; pcall(function() v=cpu.state[n].value end); return v end
local function dump(tag)
    return string.format("%s F=%d D0=%08X D1=%08X D2=%08X D7=%08X A0=%08X A1=%08X A2=%08X A3=%08X A4=%08X A5=%08X A7=%08X",
        tag, frame, R"D0",R"D1",R"D2",R"D7", R"A0",R"A1",R"A2",R"A3",R"A4",R"A5",R"A7")
end

-- code PCs to watch (24-bit overlay $A4xxxx); cap each so loops don't flood
local WATCH = {
    [0xA46582] = {name="TBL_a4@+", cap=16},   -- movea.l (a4)+,a0 : A4=table ptr, A0=region start
    [0xA4658A] = {name="TBL_len",  cap=16},   -- move.l (a4)+,d0  : D0=region length
    [0xA4A698] = {name="TBLTOP",   cap=16},   -- movea.l a2,a7    : A2=base, A0=size -> table top
    [0xA4A6CC] = {name="PROBE",    cap=40},   -- cmp.l (a1),d1    : A1=probe addr, D1=pattern
    [0xA46910] = {name="MARCH",    cap=30},   -- region-test check: A0/A1 = region bounds
    [0xA467F4] = {name="VBANKbeq", cap=12},   -- beq after back-to-back cmp.l video probe
}

local function install()
    for _,t in ipairs(taps) do pcall(function() t:remove() end) end
    taps = {}
    for addr, info in pairs(WATCH) do
        taps[#taps+1] = space:install_read_tap(addr, addr+1, info.name, function(o,d,m)
            hits[addr] = (hits[addr] or 0) + 1
            if hits[addr] <= info.cap then
                f:write(dump(info.name) .. "\n"); f:flush()
            end
        end)
    end
end

emu.register_frame_done(function()
    frame = frame + 1
    if not installed then
        installed = true
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        f:write("# maincpu_regs install\n"); f:flush()
        install()
    end
    if frame % 30 == 0 then install() end   -- re-arm in case of any remap
    if frame >= 300 then
        f:write("# END\n"); f:flush(); f:close(); manager.machine:exit()
    end
end)
