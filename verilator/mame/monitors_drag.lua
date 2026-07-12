-- monitors_drag.lua — automate System 7.5.5 Monitors "drag menu bar to the
-- 8*24 display" in MAME maciivi, to capture the main-display PRAM encoding
-- (Story A fix, docs/resume_2026-07-12_adb_investigation.md REFRAME).
--
-- Blind UI driving with relative ADB deltas: every move starts with a SLAM
-- into the top-left corner (large negative deltas; the OS pins the cursor),
-- making subsequent counted walks absolute. Stages are frame-scheduled; each
-- stage ends with a PNG snapshot for offline verification.
--
--   rm -f ~/.mame/cfg/maciivi.cfg   # (keep nvram/egret if continuing a boot)
--   cp /tmp/mame755_scratch.hd /tmp/m755_drag.hd
--   verilator/mame/run_mame_maciivi.sh -nbe mdc824 \
--     -harddisk /tmp/m755_drag.hd \
--     -autoboot_script verilator/mame/monitors_drag.lua \
--     -seconds_to_run 200 -video none
--
-- Env: MD_SNAPDIR (default /tmp/md_snaps), MD_BOOT (Finder-ready frame,
-- default 3200), MD_STAGES ("go" to run the click stages; default snap-only)

local SNAPDIR = os.getenv("MD_SNAPDIR") or "/tmp/md_snaps"
local BOOTF   = tonumber(os.getenv("MD_BOOT") or "3200")
local DO      = os.getenv("MD_STAGES") or "probe"
os.execute("mkdir -p " .. SNAPDIR)

local frame, cpu, mem = 0, nil, nil
local mx, my, mbtn
local function r32(a) local v=0; pcall(function() v=mem:read_u32(a) end); return v end

-- pending input script: list of {dx,dy,btn} applied one per frame
local queue = {}
local function q_move(dx, dy)
    -- decompose into <=100-unit steps, one per frame
    while dx ~= 0 or dy ~= 0 do
        local sx = math.max(-100, math.min(100, dx))
        local sy = math.max(-100, math.min(100, dy))
        queue[#queue+1] = {sx, sy, nil}
        dx = dx - sx; dy = dy - sy
    end
end
local function q_slam()  for i=1,10 do queue[#queue+1] = {-100,-100,nil} end end
local function q_btn(b)  queue[#queue+1] = {0,0,b} end
local function q_wait(n) for i=1,n do queue[#queue+1] = {0,0,nil} end end
local function q_click() q_btn(1); q_wait(3); q_btn(0); q_wait(10) end

local function snap(name)
    local scr
    for tag, s in pairs(manager.machine.screens) do
        scr = s
        if tag:find("vasp") or tag:find("screen") then break end
    end
    if scr then scr:snapshot(string.format("%s/%s_F%d.png", SNAPDIR, name, frame)) end
end
local function snap_all(name)
    local i = 0
    for tag, s in pairs(manager.machine.screens) do
        i = i + 1
        pcall(function() s:snapshot(string.format("%s/%s_scr%d_F%d.png", SNAPDIR, name, i, frame)) end)
    end
end

local stages_armed = false
emu.register_frame_done(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        mem = cpu.spaces["program"]
        for tag, port in pairs(manager.machine.ioport.ports) do
            if tag:find("MOUSE0") then for _, fl in pairs(port.fields) do mbtn = fl end end
            if tag:find("MOUSE1") then for _, fl in pairs(port.fields) do mx = fl end end
            if tag:find("MOUSE2") then for _, fl in pairs(port.fields) do my = fl end end
        end
    end
    -- drain one queued input per frame
    local ev = table.remove(queue, 1)
    if ev then
        pcall(function()
            if ev[1] ~= 0 then mx:set_value(ev[1] % 256) end
            if ev[2] ~= 0 then my:set_value(ev[2] % 256) end
            if ev[3] ~= nil then mbtn:set_value(ev[3]) end
        end)
    end
    if frame == BOOTF then
        snap_all("boot")
        if DO == "go" then
            -- Stage 1: Apple menu (8,8): slam then small right/down walk
            q_slam(); q_move(8, 8); q_click()
            stages_armed = true
        end
    end
    if stages_armed and frame == BOOTF + 40 then snap_all("applemenu") end
    if frame >= BOOTF + 80 then
        snap_all("final")
        manager.machine:exit()
    end
end)
