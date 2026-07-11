-- pc_sp_hb.lua — per-frame PC + A7(SP) heartbeat for MAME maclc2 maincpu,
-- to diff against our core's [HB] F.. pc=.. a7=.. trace.
-- Run: verilator/mame/run_mame_maclc2.sh -skip_gameinfo -autoboot_delay 0 \
--        -autoboot_script verilator/mame/pc_sp_hb.lua -seconds_to_run 14
local OUT = os.getenv("HB_OUT") or "/tmp/mame_hb.txt"
local f = io.open(OUT, "w")
local cpu, frame, installed = nil, 0, false
local function R(n) local v=0; pcall(function() v=cpu.state[n].value end); return v end
emu.register_frame_done(function()
    frame = frame + 1
    if not installed then
        installed = true
        cpu = manager.machine.devices[":maincpu"]
    end
    f:write(string.format("[MHB] F%d pc=%08X a7=%08X\n", frame, R"PC", R"SP")); f:flush()
    if frame >= 700 then f:write("# END\n"); f:close(); manager.machine:exit() end
end)
