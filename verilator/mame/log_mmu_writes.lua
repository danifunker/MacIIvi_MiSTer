-- log_mmu_writes.lua — log every CHANGE of the 68030 MMU registers (TC/CRP/SRP)
-- during MAME maclc2 boot. This is the REFERENCE sequence to compare against TG68's
-- HW TC/CRP write-ring: the first pmove whose value diverges is the corruption origin.
local OUT = os.getenv("REG_OUT") or "/tmp/mame_mmu_writes.txt"
local f = io.open(OUT, "w")
local cpu, frame, installed = nil, 0, false
local function R(nm) local v=0; pcall(function() v=cpu.state[nm].value end); return v end
local last = {}
local function chk(nm)
    local v = R(nm)
    if last[nm] == nil then last[nm] = -1 end
    if v ~= last[nm] then
        f:write(string.format("F%-3d pc=%08X  %-5s <- %X\n", frame, R"PC", nm, v))
        f:flush()
        last[nm] = v
    end
end
emu.register_frame_done(function()
    frame = frame + 1
    if not installed then
        installed = true
        cpu = manager.machine.devices[":maincpu"]
        f:write("# state symbols:")
        for k,v in pairs(cpu.state) do pcall(function() f:write(" "..tostring(v.symbol)) end) end
        f:write("\n"); f:flush()
    end
    -- try the common 68030 MMU state names; nonexistent ones read 0 (harmless)
    for _,nm in ipairs({"TC","CRP_APTR","CRP_LIMIT","SRP_APTR","SRP_LIMIT","TT0","TT1"}) do chk(nm) end
    if frame >= 200 then f:write("# END\n"); f:flush(); f:close(); manager.machine:exit() end
end)
