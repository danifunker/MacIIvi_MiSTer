-- cursor_ctx.lua — golden cursor-context capture for maciivi with a MOVING
-- ADB mouse during boot. Oracle for the 2026-07-12 cursor-engine hang: our
-- core parks forever in the cursor hide/restore blit at $4082EA18 whose
-- parameters load from the struct at ([$D62])+$3C (MOVEM order D2,D3,D4,A2 =
-- inner count, outer count, row stride, screen dest). Dump those golden
-- values (plus the ($574)/($644) vectors and CrsrVis $8CC) as MAME boots
-- with continuous mouse motion, so the sim trace can be diffed field by
-- field against a machine that survives the same stimulus.
--
-- Run (cfg-poison hygiene first — see resume doc):
--   rm -f ~/.mame/cfg/maciivi.cfg ~/.mame/nvram/maciivi/egret
--   verilator/mame/run_mame_maciivi.sh -nbe mdc824 \
--       -autoboot_script verilator/mame/cursor_ctx.lua -seconds_to_run 30
-- Env: CTX_OUT (default /tmp/mame_cursor_ctx.txt), CTX_FRAMES (default 1800)

local OUT  = os.getenv("CTX_OUT") or "/tmp/mame_cursor_ctx.txt"
local CAP  = tonumber(os.getenv("CTX_FRAMES") or "1800")
local f = io.open(OUT, "w")
local frame, cpu, mem = 0, nil, nil
local mx, my = nil, nil          -- MOUSE1 (X) / MOUSE2 (Y) analog fields
local wig = { {2,0}, {0,2}, {-2,0}, {0,-2} }

local function find_mouse()
    for tag, port in pairs(manager.machine.ioport.ports) do
        for fname, field in pairs(port.fields) do
            if tag:find("MOUSE1") then mx = field end
            if tag:find("MOUSE2") then my = field end
        end
    end
    f:write(string.format("# mouse fields: X=%s Y=%s\n",
        mx and "found" or "MISSING", my and "found" or "MISSING")); f:flush()
end

local function r32(a) local v=0; pcall(function() v = mem:read_u32(a) end); return v end
local function r8(a)  local v=0; pcall(function() v = mem:read_u8(a)  end); return v end

local function dump_ctx(why)
    local p574 = r32(0x574)
    local p644 = r32(0x644)
    local pD62 = r32(0xD62)
    local crsrvis = r8(0x8CC)
    local line = string.format(
        "[CTX] F%d %s ($574)=%08X ($644)=%08X ($D62)=%08X CrsrVis=%02X",
        frame, why, p574, p644, pD62, crsrvis)
    if pD62 ~= 0 and pD62 < 0x40000000 then
        -- struct: +$12 = save-buffer ptr (A1 base); +$3C.. = D2,D3,D4,A2
        line = line .. string.format(
            " ctx+12=%08X D2=%08X D3=%08X D4(stride)=%08X A2(dest)=%08X",
            r32(pD62+0x12), r32(pD62+0x3C), r32(pD62+0x40),
            r32(pD62+0x44), r32(pD62+0x48))
    end
    f:write(line .. "\n"); f:flush()
end

emu.register_frame_done(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        mem = cpu.spaces["program"]
        find_mouse()
    end
    -- continuous wiggle from frame 300 (mirrors the sim's --mouse-from 300)
    if frame >= 300 and mx and my then
        local w = wig[(frame % 4) + 1]
        pcall(function()
            mx:set_value(w[1] % 256)   -- relative axis: two's-complement byte
            my:set_value(w[2] % 256)
        end)
    end
    local pc = 0; pcall(function() pc = cpu.state["PC"].value end)
    if frame % 10 == 0 then
        -- RawMouse $82C / MTemp $828: low-mem mouse position — proves whether
        -- the ioport wiggle actually reaches the ADB mouse driver.
        f:write(string.format("[MHB] F%d pc=%08X a7=%08X raw=%08X mtemp=%08X\n",
            frame, pc, cpu.state["SP"].value, r32(0x82C), r32(0x828))); f:flush()
    end
    if frame % 50 == 0 or frame == 299 then dump_ctx("periodic") end
    if frame >= CAP then
        dump_ctx("final"); f:write("# END\n"); f:close(); manager.machine:exit()
    end
end)
