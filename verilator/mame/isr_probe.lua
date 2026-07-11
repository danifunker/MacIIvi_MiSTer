-- isr_probe.lua — snapshot MAME maclc2 (68030) state inside the post-MMU Egret/ADB
-- VIA-SR ISR ($A14912..$A14AF4) to compare against our core's $1FF35A wedge.
-- Read taps fire on opcode fetch; the program space sees POST-MMU physical, so the
-- ISR (logical $40A148xx) is tapped at BARE $00A148xx (like maincpu_regs.lua).
--
-- Run: REG_OUT=/tmp/mame_isr.txt verilator/mame/run_mame_maclc2.sh -skip_gameinfo \
--        -autoboot_delay 1 -autoboot_script verilator/mame/isr_probe.lua -seconds_to_run 12
local OUT = os.getenv("REG_OUT") or "/tmp/mame_isr.txt"
local f = io.open(OUT, "w")
local cpu, space
local taps = {}
local frame, installed = 0, false
local hits = {}

local function R(n) local v=0; pcall(function() v=cpu.state[n].value end); return v end
local function RD32(a) local v=0; pcall(function() v=space:read_u32(a) end); return v end
local function RD16(a) local v=0; pcall(function() v=space:read_u16(a) end); return v end

local function regs(tag)
    return string.format("%s F=%d PC=%08X A0=%08X A1=%08X A2=%08X A7=%08X D0=%08X D1=%08X D5=%08X",
        tag, frame, R"PC", R"A0",R"A1",R"A2",R"A7", R"D0",R"D1",R"D5")
end
local function struct(a2)
    -- dump the Egret/ADB buffer fields the ISR walks (+0..+0x1A) + low-mem globals
    local s = string.format("  A2=%08X [+0]=%08X [+4]=%08X [+8]=%08X [+a]=%08X [+e]=%08X [+10]=%08X [+12]=%08X [+14]=%08X [+18]=%08X",
        a2, RD32(a2), RD32(a2+4), RD32(a2+8), RD32(a2+0xa), RD32(a2+0xe), RD32(a2+0x10), RD32(a2+0x12), RD32(a2+0x14), RD32(a2+0x18))
    local g = string.format("  GLOB: [0DE0]=%08X [019A]=%08X [0CEA]=%04X [0358]=%08X",
        RD32(0x0DE0), RD32(0x019A), RD16(0x0CEA), RD32(0x0358))
    return s .. "\n" .. g
end

-- ISR PCs to watch (bare $00Axxxxx physical)
local WATCH = {
    [0xA14918] = {name="ISR_ENTRY", cap=6},   -- movea.l $de0.w,a2  (A2<-[0DE0])
    [0xA148F0] = {name="JSR_19A",   cap=8},    -- jsr (a0)  : A0 = [019A] indirect target
    [0xA1493C] = {name="WALK_bsr",  cap=8},    -- bsr.b $a148d8 (per-byte)
    [0xA14AF4] = {name="ISR_RTS",   cap=8},    -- rts (ISR exit) : top-of-stack = return PC
    [0xA07A5A] = {name="DELAY7A5A", cap=2},    -- MAME's eventual delay loop (success marker)
}

local function install()
    for _,t in ipairs(taps) do pcall(function() t:remove() end) end
    taps = {}
    for addr, info in pairs(WATCH) do
        taps[#taps+1] = space:install_read_tap(addr, addr+1, info.name, function(o,d,m)
            hits[addr] = (hits[addr] or 0) + 1
            if hits[addr] <= info.cap then
                f:write(regs(info.name) .. "\n")
                f:write(struct(R"A2") .. "\n")
                if info.name == "ISR_RTS" then
                    f:write(string.format("  RET@A7=%08X\n", RD32(R"A7")))
                end
                f:flush()
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
        f:write("# isr_probe install\n"); f:flush()
        install()
    end
    if frame % 30 == 0 then install() end
    if frame >= 360 then
        f:write("# END\n"); f:flush(); f:close(); manager.machine:exit()
    end
end)
