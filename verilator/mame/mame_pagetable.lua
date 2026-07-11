-- mame_pagetable.lua — dump MAME maclc2's live 24-bit-mode page table (CRP aptr=$3FE820,
-- DT=11 long descriptors, 8 bytes each) so we can compare what our PMMU walk SHOULD read
-- when translating logical $0CB2 (root index 0 -> $3FE820).
local OUT = os.getenv("REG_OUT") or "/tmp/mame_pt.txt"
local f = io.open(OUT, "w")
local cpu, space, frame, installed = nil,nil,0,false
local function R(nm) local v=0; pcall(function() v=cpu.state[nm].value end); return v end
local function RD32(a) local v=0; pcall(function() v=space:read_u32(a) end); return v end
emu.register_frame_done(function()
    frame = frame + 1
    if not installed then
        installed = true
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
    end
    if frame == 300 then
        local crp_aptr = R"CRP_APTR" & 0xFFFFFFF0
        f:write(string.format("F%d CRP_APTR=%08X TC=%08X\n", frame, R"CRP_APTR", R"TC"))
        -- root table: first 8 long descriptors (8 bytes each)
        f:write("root table @"..string.format("%08X", crp_aptr)..":\n")
        for i=0,7 do
            local a = crp_aptr + i*8
            f:write(string.format("  [%d] @%08X = %08X %08X\n", i, a, RD32(a), RD32(a+4)))
        end
        -- follow root[0] to level-1 table (if it's a table descriptor, low word = next aptr)
        local r0lo = RD32(crp_aptr+4)
        local nxt = r0lo & 0xFFFFFFF0
        f:write(string.format("root[0] low=%08X -> next table @%08X:\n", r0lo, nxt))
        for i=0,3 do
            local a = nxt + i*8
            f:write(string.format("  L1[%d] @%08X = %08X %08X\n", i, a, RD32(a), RD32(a+4)))
        end
        f:write("# END\n"); f:flush(); f:close(); manager.machine:exit()
    end
    if frame >= 360 then f:write("# END(to)\n"); f:flush(); f:close(); manager.machine:exit() end
end)
