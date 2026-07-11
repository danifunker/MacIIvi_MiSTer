-- mmu_state.lua — per-frame watch of the A-trap MMU-reconfig inputs/outputs in MAME
-- maclc2: PC, the handler-branch byte [$0CB2], the two descriptor pointers
-- [$0CB4]/[$0CB8], and the live MMU TC/CRP registers. Lua memory reads bypass the
-- d-cache, so [$0CB2] is the TRUE value. If TC/CRP never change after the initial
-- enable and [$0CB2] stays 0, MAME never runs the pmove-reconfig path our core takes.
local OUT = os.getenv("REG_OUT") or "/tmp/mame_state.txt"
local f = io.open(OUT, "w")
local cpu, space, frame, installed = nil,nil,0,false
local function R(nm) local v=0; pcall(function() v=cpu.state[nm].value end); return v end
local function RD32(a) local v=0; pcall(function() v=space:read_u32(a) end); return v end
local function RD8(a) local v=0; pcall(function() v=space:read_u8(a) end); return v end
local last=""
emu.register_frame_done(function()
    frame = frame + 1
    if not installed then
        installed = true
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        -- enumerate available state entries once (find MMU reg names)
        f:write("# state names:")
        for k,v in pairs(cpu.state) do pcall(function() f:write(" "..tostring(v.symbol)) end) end
        f:write("\n"); f:flush()
    end
    -- only log when something interesting changes, plus every 20th frame
    local line = string.format("F%d pc=%08X [0CB2]=%02X [0CB4]=%08X [0CB8]=%08X TC=%08X",
        frame, R"PC", RD8(0x0CB2), RD32(0x0CB4), RD32(0x0CB8), R"TC")
    if line:sub(line:find("%[0CB2")) ~= last or frame % 20 == 0 then
        f:write(line.."\n"); f:flush()
        last = line:sub(line:find("%[0CB2"))
    end
    if frame >= 420 then f:write("# END\n"); f:flush(); f:close(); manager.machine:exit() end
end)
