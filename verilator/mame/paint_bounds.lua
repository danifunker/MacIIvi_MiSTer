-- paint_bounds.lua — healthy-machine capture of the QuickDraw screen-paint
-- frame slots for the 2026-07-12 endless-fill hang. Uses the lua debugger
-- bridge (works with -debugger none): breakpoints fire, their printf output
-- lands in the debugger console log, and we copy it to a file each frame.
--
--   bp $40834B16: paint setup complete (JSR ([$574]) site) — dump the A6
--     frame slots the fill engine consumes: rect bottom (-$164), top (-$172),
--     dest ptr (-$12C), baseAddr (-$F4), rowBytes (-$F0).
--   bp $40834BD4 (cond D7==0): first row-loop compare of each invocation —
--     dump D7 + live bottom.
--
-- Run (with the mouse wiggle so the cursor engages like our sim):
--   rm -f ~/.mame/cfg/maciivi.cfg ~/.mame/nvram/maciivi/egret
--   verilator/mame/run_mame_maciivi.sh -nbe mdc824 \
--     -autoboot_script verilator/mame/paint_bounds.lua \
--     -debug -debugger none -seconds_to_run 35 -video none
-- Output: PB_OUT (default /tmp/mame_paint_bounds.txt)

local OUT = os.getenv("PB_OUT") or "/tmp/mame_paint_bounds.txt"
local f = io.open(OUT, "w")
local frame, cpu, dbg = 0, nil, nil
local mx, my = nil, nil
local wig = { {2,0}, {0,2}, {-2,0}, {0,-2} }
local seen = 0

emu.register_frame_done(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        for tag, port in pairs(manager.machine.ioport.ports) do
            if tag:find("MOUSE1") then for _, fl in pairs(port.fields) do mx = fl end end
            if tag:find("MOUSE2") then for _, fl in pairs(port.fields) do my = fl end end
        end
        dbg = manager.machine.debugger
        if dbg then
            dbg:command("bp 40834B16,1,{printf \"SETUP bot=%04X top=%04X dst=%08X base=%08X rb=%04X\",w@(a6-164),w@(a6-172),d@(a6-12c),d@(a6-f4),w@(a6-f0); g}")
            dbg:command("bp 40834BD4,{d7==0},{printf \"ROW0 d7=%04X bot=%04X\",d7,w@(a6-164); g}")
            dbg:command("bp 4082F1B2,{(pc)!=0},{printf \"FILLLOOP hit\"; bpclear 2; g}")
            dbg:command("bp 40807870,1,{printf \"SCANWAIT hit\"; bpclear 3; g}")
            dbg:command("g")
            f:write("# breakpoints armed\n"); f:flush()
        else
            f:write("# NO DEBUGGER (run with -debug)\n"); f:flush()
        end
    end
    if frame >= 300 and mx and my then
        local w = wig[(frame % 4) + 1]
        pcall(function() mx:set_value(w[1] % 256); my:set_value(w[2] % 256) end)
    end
    -- drain new debugger console lines to the file, stamped with our frame
    if dbg then
        local log = dbg.consolelog
        if log then
            local n = #log
            while seen < n do
                seen = seen + 1
                local line = log[seen]
                if line and (line:find("SETUP") or line:find("ROW0")) then
                    f:write(string.format("F%d %s\n", frame, line)); f:flush()
                end
            end
        end
    end
    if frame >= tonumber(os.getenv("PB_FRAMES") or "1200") then
        f:write("# END\n"); f:close(); manager.machine:exit()
    end
end)
