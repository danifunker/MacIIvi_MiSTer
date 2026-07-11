-- mmu_descr.lua — dump MAME maclc2 final MMU config + the descriptor block the
-- $A03Exx mode-switch pmoves read (A0 = [$0DDC]-$2E = $3FFFBE region), so we know what
-- our pmove (8,A0),TC SHOULD load and what TC/CRP/TT the MMU SHOULD end up with.
local OUT = os.getenv("REG_OUT") or "/tmp/mame_descr.txt"
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
        f:write(string.format("F%d MMU: TC=%08X TT0=%08X TT1=%08X PSR=%04X CRP=%08X:%08X SRP=%08X:%08X\n",
            frame, R"TC", R"TT0", R"TT1", R"PSR", R"CRP_LIMIT", R"CRP_APTR", R"SRP_LIMIT", R"SRP_APTR"))
        local ddc = RD32(0x0DDC)
        f:write(string.format("  [0DDC]=%08X  [0CB4]=%08X [0CB8]=%08X\n", ddc, RD32(0x0CB4), RD32(0x0CB8)))
        -- descriptor blocks at A1-$2E (=$0CB4 ptr) and A1-$42 (=$0CB8 ptr)
        for _,base in ipairs({RD32(0x0CB4), RD32(0x0CB8)}) do
            f:write(string.format("  block @%08X: +0(CRP)=%08X +4=%08X +8(TC)=%08X +c(TT0)=%08X +10(TT1)=%08X +14=%08X\n",
                base, RD32(base), RD32(base+4), RD32(base+8), RD32(base+0xc), RD32(base+0x10), RD32(base+0x14)))
        end
        -- translate logical $0CB2 to see what physical it maps to (should stay ~$0CB2)
        f:write("# END\n"); f:flush(); f:close(); manager.machine:exit()
    end
    if frame >= 360 then f:write("# END(to)\n"); f:flush(); f:close(); manager.machine:exit() end
end)
