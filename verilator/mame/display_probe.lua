-- display_probe.lua — walk the QuickDraw GDevice DeviceList on a booted
-- maciivi+mdc824 to see BOTH displays (onboard VASP + card), which one the
-- ROM flags as main, and where each frame buffer lives. Answers the Story A
-- mechanism question (docs/resume_2026-07-12_adb_investigation.md): is
-- onboard-as-main a PRAM setting or a hardwired default, and can the card be
-- main at all. Pure lua memory reads — no debugger, no ioport writes (so no
-- cfg-poison). Vary the PRAM/montype OUTSIDE this script and re-run.
--
--   verilator/mame/run_mame_maciivi.sh -nbe mdc824 \
--     -autoboot_script verilator/mame/display_probe.lua -seconds_to_run 20 -video none
-- Env: DP_OUT (default /tmp/mame_display_probe.txt), DP_AT (dump frame, def 900)

local OUT = os.getenv("DP_OUT") or "/tmp/mame_display_probe.txt"
local AT  = tonumber(os.getenv("DP_AT") or "900")
local f = io.open(OUT, "w")
local frame, cpu, mem = 0, nil, nil
local function r32(a) local v=0; pcall(function() v=mem:read_u32(a) end); return v end
local function r16(a) local v=0; pcall(function() v=mem:read_u16(a) end); return v end
local function s16(a) local v=r16(a); if v>=0x8000 then v=v-0x10000 end; return v end
local function rect(a) return string.format("(t%d,l%d,b%d,r%d)", s16(a),s16(a+2),s16(a+4),s16(a+6)) end
local function valid(p) return p ~= 0 and p < 0x4400000 end

emu.register_frame_done(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]; mem = cpu.spaces["program"]
        local mt = os.getenv("DP_MONTYPE")
        if mt then
            for tag, port in pairs(manager.machine.ioport.ports) do
                if tag:find("MONTYPE") then
                    for fn, fl in pairs(port.fields) do
                        pcall(function() fl:set_value(tonumber(mt)) end)
                        f:write(string.format("# forced %s = %s\n", tag, mt)); f:flush()
                    end
                end
            end
        end
    end
    -- also emit an early heartbeat so a WEDGE (no ScrnBase) is distinguishable
    if frame == 200 or frame == 1500 then
        f:write(string.format("# F%d pc=%08X ScrnBase=%08X\n", frame,
            (function() local v=0; pcall(function() v=cpu.state["PC"].value end); return v end)(), r32(0x824))); f:flush()
    end
    if frame == AT then
        local scrn = r32(0x824)   -- ScrnBase
        local maind = r32(0x8A4)  -- MainDevice (handle)
        local devl  = r32(0x8A8)  -- DeviceList (handle to 1st GDevice)
        local gray  = r32(0x9EE)  -- GrayRgn handle
        f:write(string.format("ScrnBase=%08X MainDevice^=%08X DeviceList^=%08X GrayRgn^=%08X\n",
            scrn, maind, devl, gray))
        -- GrayRgn bbox (desktop union — its width tells us 1 vs 2 active screens)
        if valid(gray) then
            local rp = r32(gray)
            if valid(rp) then f:write("  GrayRgn bbox="..rect(rp+2).." (rgn size "..r16(rp)..")\n") end
        end
        -- walk the GDevice list via gdNextGD (+$1E)
        local gh, n = devl, 0
        while valid(gh) and n < 8 do
            local gd = r32(gh)
            if not valid(gd) then break end
            local flags = r16(gd + 0x14)
            local pmh   = r32(gd + 0x16)
            local base, rb, bnds = 0, 0, "?"
            if valid(pmh) then local pm = r32(pmh)
                if valid(pm) then base=r32(pm); rb=r16(pm+4); bnds=rect(pm+6) end end
            f:write(string.format("  GDev[%d]^=%08X %s refNum=%d flags=%04X gdRect=%s pmBase=%08X rowBytes=%d pmBounds=%s\n",
                n, gh, (gh==maind) and "**MAIN**" or "      ",
                s16(gd+0x00), flags, rect(gd+0x22), base, rb, bnds))
            gh = r32(gd + 0x1E)   -- gdNextGD
            n = n + 1
        end
        f:write("# END\n"); f:close(); manager.machine:exit()
    end
end)
