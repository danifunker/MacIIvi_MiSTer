-- gdev_dump.lua — healthy-machine dump of the screen bookkeeping the
-- 2026-07-12 endless-fill hang corrupts: MainDevice GDevice → PixMap
-- (bounds/rowBytes/baseAddr), QD-globals screenBits (via CurrentA5), and
-- the low-mem video globals. Plain lua memory reads each 100 frames (the
-- structures are stable once built) — no debugger involvement.
-- Run with the mouse wiggle:
--   rm -f ~/.mame/cfg/maciivi.cfg ~/.mame/nvram/maciivi/egret
--   verilator/mame/run_mame_maciivi.sh -nbe mdc824 \
--     -autoboot_script verilator/mame/gdev_dump.lua -seconds_to_run 30 -video none
local OUT = os.getenv("GD_OUT") or "/tmp/mame_gdev.txt"
local f = io.open(OUT, "w")
local frame, cpu, mem = 0, nil, nil
local mx, my
local wig = { {2,0}, {0,2}, {-2,0}, {0,-2} }
local function r32(a) local v=0; pcall(function() v=mem:read_u32(a) end); return v end
local function r16(a) local v=0; pcall(function() v=mem:read_u16(a) end); return v end
local function rect(a) return string.format("(%d,%d,%d,%d)",
    (r16(a)+0x8000)%0x10000-0x8000, (r16(a+2)+0x8000)%0x10000-0x8000,
    (r16(a+4)+0x8000)%0x10000-0x8000, (r16(a+6)+0x8000)%0x10000-0x8000) end

emu.register_frame_done(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        mem = cpu.spaces["program"]
        for tag, port in pairs(manager.machine.ioport.ports) do
            if tag:find("MOUSE1") then for _, fl in pairs(port.fields) do mx = fl end end
            if tag:find("MOUSE2") then for _, fl in pairs(port.fields) do my = fl end end
        end
    end
    if frame >= 300 and mx and my then
        local w = wig[(frame % 4) + 1]
        pcall(function() mx:set_value(w[1] % 256); my:set_value(w[2] % 256) end)
    end
    if frame % 100 == 0 then
        local main_h = r32(0x8A4)               -- MainDevice (handle)
        local scrn   = r32(0x824)               -- ScrnBase
        local a5     = r32(0x904)               -- CurrentA5
        local line = string.format("[GD] F%d MainDevice^=%08X ScrnBase=%08X A5=%08X",
            frame, main_h, scrn, a5)
        if main_h ~= 0 and main_h < 0x2400000 then
            local gd = r32(main_h)              -- deref handle -> GDevice
            if gd ~= 0 and gd < 0x2400000 then
                local pmh = r32(gd + 0x16)      -- gdPMap (handle)
                local pm = (pmh ~= 0 and pmh < 0x2400000) and r32(pmh) or 0
                if pm ~= 0 and pm < 0x2400000 then
                    line = line .. string.format(" gdRect=%s pmBase=%08X pmRB=%04X pmBounds=%s",
                        rect(gd + 0x22), r32(pm), r16(pm+4), rect(pm+6))
                end
            end
        end
        if a5 ~= 0 and a5 < 0x2400000 then
            -- QD globals: screenBits at (A5)-$7A [baseAddr -7A, rowBytes -76, bounds -74]
            local qd = r32(a5)                  -- (A5) -> thePort ptr slot base
            line = line .. string.format(" QD@=%08X sbBase=%08X sbRB=%04X sbBounds=%s",
                qd, r32(qd - 0x7A), r16(qd - 0x76), rect(qd - 0x74))
        end
        f:write(line .. "\n"); f:flush()
    end
    if frame >= 1200 then f:write("# END\n"); f:close(); manager.machine:exit() end
end)
