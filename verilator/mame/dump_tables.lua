-- dump_tables.lua — dump MAME maclc2's two MMU root tables (Config A @ $9FEE00,
-- Config B @ $9FE820) to settle: is Config A's root[8] @ $9FEE40 a VALID descriptor
-- in MAME (=> TG68's 0 there is a table/store bug) or also 0 (=> TG68 is in the wrong
-- config; should be Config B)?  Dumps at several frames (tables may be built late).
local OUT = os.getenv("REG_OUT") or "/tmp/mame_tables.txt"
local f = io.open(OUT, "w")
local cpu, space, frame, installed = nil,nil,0,false
local function RD32(a) local v=0; pcall(function() v=space:read_u32(a) end); return v end
local function dump(base, label)
    f:write(string.format("  %s table @ %08X:\n", label, base))
    for i=0,15 do
        local hi = RD32(base + i*8)
        local lo = RD32(base + i*8 + 4)
        f:write(string.format("    root[%2d] @%08X = %08X %08X  DT=%d\n", i, base+i*8, hi, lo, hi & 3))
    end
end
emu.register_frame_done(function()
    frame = frame + 1
    if not installed then
        installed = true
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
    end
    if frame==60 or frame==120 or frame==180 then
        f:write(string.format("==== frame %d  TC=%X CRP_APTR=%X ====\n", frame,
            cpu.state["TC"].value, cpu.state["CRP_APTR"].value))
        dump(0x9FEE00, "ConfigA")
        dump(0x9FE820, "ConfigB")
        f:flush()
    end
    if frame >= 185 then f:write("# END\n"); f:flush(); f:close(); manager.machine:exit() end
end)
