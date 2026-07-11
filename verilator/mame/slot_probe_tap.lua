-- slot_probe_tap.lua — when does the ROM/OS first touch NuBus slot space?
-- Installs read taps on the mdc824's windows (standard slot $FE000000-$FEFFFFFF
-- and super slot $E0000000-$EEFFFFFF), logs the first hits with frame + PC, and
-- optionally forces the built-in video's monitor sense first (MONTYPE=7 = "no
-- display" -> the ROM must hunt NuBus for its boot screen).
--
-- Env: TAP_OUT (default /tmp/mame_slot_tap.txt), MAX_FRAME (default 3600),
--      MONTYPE (optional; forces :vasp:MONTYPE via the field scan),
--      HITS (per-region log cap, default 60)
-- Run: verilator/mame/run_mame_maciivi.sh -nbe mdc824 [-harddisk hd.hd] \
--        -autoboot_script verilator/mame/slot_probe_tap.lua -seconds_to_run 62
--
-- Gotchas per tap.lua: install taps in the first register_frame_done (not
-- machine_reset), keep tap handles referenced, write to a file (headless).

local function envnum(n, d) local v=os.getenv(n); return v and (tonumber(v) or d) or d end
local OUT      = os.getenv("TAP_OUT") or "/tmp/mame_slot_tap.txt"
local MAXF     = envnum("MAX_FRAME", 3600)
local MONTYPE  = os.getenv("MONTYPE") and envnum("MONTYPE", 6) or nil
local HITS     = envnum("HITS", 60)

local f = io.open(OUT, "w")
local frame, installed = 0, false
local taps = {}
local hits = { slot = 0, super = 0 }
local cpu

local function log_tap(region)
	return function(offset, data, mask)
		if hits[region] < HITS then
			hits[region] = hits[region] + 1
			local pc = 0
			pcall(function() pc = cpu.state["PC"].value end)
			f:write(string.format("[%s] F%d pc=%08X addr=%08X data=%08X mask=%08X\n",
				region, frame, pc, offset, data, mask))
			f:flush()
		end
	end
end

local function force_montype()
	if not MONTYPE then return end
	local ioport = manager.machine.ioport
	for tag, port in pairs(ioport.ports) do
		for name, fld in pairs(port.fields) do
			if tostring(name):find("monitor") or tostring(name):find("Monitor") then
				fld:set_value(MONTYPE)
				f:write(string.format("# MONTYPE forced to %d via %s\n", MONTYPE, tag)); f:flush()
				return
			end
		end
	end
	f:write("# MONTYPE field NOT FOUND\n"); f:flush()
end

emu.register_frame_done(function()
	frame = frame + 1
	if not installed then
		installed = true
		cpu = manager.machine.devices[":maincpu"]
		local mem = cpu.spaces["program"]
		taps[1] = mem:install_read_tap(0xFE000000, 0xFEFFFFFF, "slotE", log_tap("slot"))
		taps[2] = mem:install_read_tap(0xE0000000, 0xEEFFFFFF, "superE", log_tap("super"))
		force_montype()
		f:write("# taps installed F1\n"); f:flush()
	end
	if frame % 100 == 0 then
		local pc = 0; pcall(function() pc = cpu.state["PC"].value end)
		f:write(string.format("[MHB] F%d pc=%08X slot_hits=%d super_hits=%d\n",
			frame, pc, hits.slot, hits.super)); f:flush()
	end
	if frame >= MAXF then f:write("# END\n"); f:close(); manager.machine:exit() end
end)
