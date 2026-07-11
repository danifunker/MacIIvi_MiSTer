-- pt_root10.lua — dump MAME maclc2's live 24-bit page table root[0..15] (CRP DT=11
-- long descriptors, 8 bytes each) and FULLY decode root[10] (where $40Axxxxx /ROM
-- lands: IS=8 strips $40 -> $A0xxxx -> TIA bits[23:20]=$A=10). Settles whether ROM
-- is mapped (root[10] valid) — refuting/confirming the "root[10] invalid" assumption.
-- Also manually translates $40A07A5A (a PC MAME sustains) to its physical address.
local OUT = os.getenv("REG_OUT") or "/tmp/mame_pt10.txt"
local f = io.open(OUT, "w")
local cpu, space, frame, installed = nil,nil,0,false
local function R(nm) local v=0; pcall(function() v=cpu.state[nm].value end); return v end
local function RD32(a) local v=0; pcall(function() v=space:read_u32(a) end); return v end
local function dt(hi) return hi & 3 end
local done = false
emu.register_frame_done(function()
    frame = frame + 1
    if not installed then
        installed = true
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
    end
    -- Trigger when the MMU reaches the configured 24-bit state (TC=$80F84500),
    -- regardless of frame number (boot timing varies run-to-run).
    if not done and (R"TC" == 0x80F84500) then
        done = true
        local crp = R"CRP_APTR" & 0xFFFFFFF0
        f:write(string.format("F%d CRP_APTR=%08X TC=%08X TT0=%08X TT1=%08X\n",
            frame, R"CRP_APTR", R"TC", R"TT0", R"TT1"))
        f:write("root table @"..string.format("%08X", crp)..":\n")
        for i=0,15 do
            local a = crp + i*8
            local hi, lo = RD32(a), RD32(a+4)
            f:write(string.format("  root[%2d] @%08X = %08X %08X  DT=%d\n", i, a, hi, lo, dt(hi)))
        end
        -- Decode root[10] for the ROM region.
        local a10 = crp + 10*8
        local hi10, lo10 = RD32(a10), RD32(a10+4)
        f:write(string.format("\nroot[10] hi=%08X lo=%08X DT=%d\n", hi10, lo10, dt(hi10)))
        if dt(hi10) == 1 then
            f:write(string.format("  EARLY-TERM page descriptor; phys base (lo&f-mask)=%08X\n", lo10 & 0xFFFF8000))
        elseif dt(hi10) >= 2 then
            local nxt = lo10 & 0xFFFFFFF0
            f:write(string.format("  TABLE descriptor -> level-1 @%08X:\n", nxt))
            -- For $A07A5A: bits[19:16]=$0 -> L1 index 0 (TIB=5 -> bits[19:15], =0)
            for i=0,7 do
                local a = nxt + i*8
                f:write(string.format("    L1[%d] @%08X = %08X %08X DT=%d\n", i, a, RD32(a), RD32(a+4), dt(RD32(a))))
            end
        end
        f:write("# END\n"); f:flush(); f:close(); manager.machine:exit()
    end
    if frame >= 600 then f:write("# END(timeout, never reached TC=80F84500)\n"); f:flush(); f:close(); manager.machine:exit() end
end)
