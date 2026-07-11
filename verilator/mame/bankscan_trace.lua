-- bankscan_trace.lua — MAME maclc2 oracle: does it run the same RAM-detection
-- code path as the FPGA core? The core's boot runs StartTest1 ($A46540) + the
-- bank-scan RAM enumeration ($A4A5xx); this checks whether MAME (same byte-identical
-- ROM) executes them, and samples what PC MAME's POST RAM-test writes come from.
--
-- Env: BS_OUT (default /tmp/bankscan_mame.txt), MAX_FRAME (default 240).
-- Run: verilator/mame/run_mame_maclc2.sh \
--        -autoboot_script verilator/mame/bankscan_trace.lua -seconds_to_run 8

local BS_OUT = os.getenv("BS_OUT") or "/tmp/bankscan_mame.txt"
local function envnum(n,d) local v=os.getenv(n); return v and (tonumber(v) or d) or d end
local MAX_FRAME = envnum("MAX_FRAME", 240)

local f = io.open(BS_OUT, "w")
local frame, installed = 0, false
local cpu, space
local ftap, wtap
local buf = {}
local function emit(s) buf[#buf+1] = s end
local function pcnow() local v=0; pcall(function() v = cpu.state["CURPC"].value end); return v end

-- Narrow probe-address windows (so pc() per access is affordable): the top-of-RAM
-- walk $X0FFF0..$X0FFFF for X=0..9 (covers $0FFFFE..$9FFFFE + the 'PanD' $1FFFFE),
-- plus the data-bus-width test region $400000-$40000F.
local probe_taps = {}
local cap = 0
local function logacc(kind, off, data)
	if cap < 3000 then
		cap = cap + 1
		emit(string.format("%s F=%d pc=%08X addr=%06X data=%08X", kind, frame, pcnow(), off, data))
	end
end

-- Capture every DISTINCT (pc,register) VIA1 + pseudovia READ with its value — deduped
-- so the VIA poll loop doesn't flood it. Shows exactly which config registers the RAM
-- enumeration reads and what MAME returns, to diff vs our core's chipset responses.
local seen = {}
local function install()
	for _,t in ipairs(probe_taps) do pcall(function() t:remove() end) end
	probe_taps = {}
	probe_taps[#probe_taps+1] = space:install_read_tap(0xF00000, 0xF01FFF, "v1", function(o,d,m)
		local p = pcnow(); local reg = (o >> 9) & 0xF
		local k = string.format("V1.%X.%08X", reg, p)
		if not seen[k] then seen[k] = true
			emit(string.format("VIA1r reg=%X data=%02X pc=%08X F=%d", reg, d & 0xFF, p, frame)) end
	end)
	probe_taps[#probe_taps+1] = space:install_read_tap(0xF26000, 0xF27FFF, "pv", function(o,d,m)
		local p = pcnow(); local reg = o & 0x13
		local k = string.format("PV.%02X.%08X", reg, p)
		if not seen[k] then seen[k] = true
			emit(string.format("PVr reg=%02X data=%02X pc=%08X F=%d", reg, d & 0xFF, p, frame)) end
	end)
end

local function setup()
	cpu = manager.machine.devices[":maincpu"]
	space = cpu.spaces["program"]
	f:write(string.format("# bankscan_trace max_frame=%d\n", MAX_FRAME)); f:flush()
	install()
end

emu.register_frame_done(function()
	frame = frame + 1
	if not installed then installed = true; setup() end
	install()
	if frame % 20 == 0 then emit(string.format("# F=%d probe_accs=%d", frame, cap)) end
	if #buf > 0 then f:write(table.concat(buf, "\n")); f:write("\n"); buf = {}; f:flush() end
	if frame >= MAX_FRAME then
		f:write(string.format("# END F=%d accs=%d\n", frame, cap)); f:flush(); f:close()
		manager.machine:exit()
	end
end)
