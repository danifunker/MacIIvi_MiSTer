-- loopback_vals.lua — capture MAME maclc2 read VALUES at the hardware-presence
-- loopback test ($A03124) addresses, where our core diverges (cmp at $A0313A:
-- MAME not-equal, ours equal). Logs every I/O read with value+PC while PC is in
-- the loopback routine, so we can match MAME's response in our chipset.
-- Run with -skip_gameinfo.
local OUT = os.getenv("LB_OUT") or "/tmp/loopback_mame.txt"
local f = io.open(OUT, "w")
local cpu, space, taps = nil, nil, {}
local frame, installed, cap = 0, false, 0
local function pcnow() local v=0; pcall(function() v=cpu.state["CURPC"].value end); return v end
local function install()
  for _,t in ipairs(taps) do pcall(function() t:remove() end) end
  taps = {}
  -- whole I/O range; only log when PC is inside the loopback routine
  taps[#taps+1] = space:install_read_tap(0xF00000, 0xFFFFFF, "io", function(o,d,m)
    local p = pcnow()
    if p >= 0xA03100 and p <= 0xA03160 and cap < 400 then
      cap = cap + 1
      f:write(string.format("R pc=%06X addr=%06X data=%08X mask=%08X\n", p, o, d, m)); f:flush()
    end
  end)
  taps[#taps+1] = space:install_write_tap(0xF00000, 0xFFFFFF, "iow", function(o,d,m)
    local p = pcnow()
    if p >= 0xA03100 and p <= 0xA03160 and cap < 400 then
      cap = cap + 1
      f:write(string.format("W pc=%06X addr=%06X data=%08X mask=%08X\n", p, o, d, m)); f:flush()
    end
  end)
end
emu.register_frame_done(function()
  frame = frame + 1
  if not installed then installed = true
    cpu = manager.machine.devices[":maincpu"]; space = cpu.spaces["program"]
    f:write("# loopback_vals install\n"); f:flush(); install() end
  if frame % 30 == 0 then install() end
  if frame >= 200 then f:write("# END cap="..cap.."\n"); f:close(); manager.machine:exit() end
end)
