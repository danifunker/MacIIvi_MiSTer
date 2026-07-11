-- asc_trace.lua — MAME maclc2 ground-truth capture for the LC II startup-chime
-- ASC FIFO hang (docs/handoff_asc_chime_mame_2026-06-15.md).
--
-- The LC II boot reaches the chime then hangs in our core's 4-PC loop polling
-- ASC FIFOSTAT ($F14804 bit0 = STAT_HALF_FULL_A) for "FIFO half-empty". This
-- script captures what MAME's V8 ASC actually does there, to decide:
--   H1 — FIFO drain (pop) rate too slow in our asc.sv (SAMPLE_DIV=1460=22257Hz)
--   H2 — IRQ pacing / clear-on-read wrong (our $804 read always clears IRQ;
--        MAME V8 keeps status bits across reads and only clears IRQ when bit0=0)
--
-- CPU-visible ASC window (maclc2 maclc_map, global_mask 0x80ffffff, V8 @ a00000,
-- ASC @ V8-internal 514000): $F14000-$F15FFF.
--   FIFO A write window : $F14000-$F143FF  (one byte fed per write = feed rate)
--   Register window     : $F14800-$F1480F  ($804 = FIFOSTAT)
-- The chime poll loop lives at ROM PCs $A45E3A (read $804) .. $A45E44 (exit).
--
-- Captures, as one CSV-ish line per event (t=emu seconds, F=frame, pc=maincpu):
--   RS  : FIFOSTAT ($804) read  — val (bit0=half-empty, bit1=empty/full), pc,
--         running fed-byte counter, whether pc is in the chime poll range
--   RR  : other register read  ($800-$80F except $804)
--   FW  : FIFO A write          — running byte counter, pc
--   RW  : register write        — val, pc (MODE/FIFOMODE/CLOCK setup + chime)
--   IRQ-ish is INFERRED from pc: a $804 read or FIFO write whose pc is NOT in
--         the chime poll range during the chime = an ISR access (the handoff's
--         "interrupt-driven feed" hypothesis is true iff such accesses appear).
--
-- Env: ASC_OUT (default /tmp/asc_trace.txt), MAX_FRAME (default 1500),
--      SNAP_EVERY (default 150), POLL_LO/POLL_HI (chime PC range, default
--      0xA45E00/0xA45F40), QUIET_EXIT (frames of no ASC access after the chime
--      poll first seen, after which we snapshot+exit; default 240, 0=off).
--
-- Run:  MAME=/opt/homebrew/bin/mame ROMPATH=/private/tmp/goodroms \
--         verilator/mame/run_mame.sh ... (but run_mame.sh hardcodes `maclc`;
--       use run_mame_maclc2.sh, or invoke mame directly with system maclc2.)
--
-- Gotchas honored (docs/mame_compare.md): install taps on the first
-- register_frame_done; keep tap refs in a table; buffer lines and flush
-- per-frame; the $F14xxx window is in the V8 map (a00000-ffffff), NOT low
-- memory, so it is NOT killed by the overlay/RAM-config remaps (no reinstall
-- needed, unlike scsi_trace's $8/$60 low-mem taps).

local function envnum(n, d) local v = os.getenv(n); return v and (tonumber(v) or d) or d end
local ASC_OUT    = os.getenv("ASC_OUT") or "/tmp/asc_trace.txt"
local MAX_FRAME  = envnum("MAX_FRAME", 1500)
local SNAP_EVERY = envnum("SNAP_EVERY", 150)
local POLL_LO    = envnum("POLL_LO", 0xA45E00)
local POLL_HI    = envnum("POLL_HI", 0xA45F40)
local QUIET_EXIT = envnum("QUIET_EXIT", 240)

local ASC_BASE   = 0xF14000
local FIFO_A_LO   = 0xF14000
local FIFO_A_HI   = 0xF143FF
local REG_LO      = 0xF14800
local REG_HI      = 0xF1480F
local FIFOSTAT    = 0xF14804

local f = io.open(ASC_OUT, "w")
local frame, installed = 0, false
local cpu, space, taps = nil, nil, {}
local buf = {}
local timefn = nil

-- running stats
local fed_bytes      = 0     -- total FIFO A bytes written by CPU (feed)
local fifostat_reads = 0     -- total $804 reads
local poll_reads     = 0     -- $804 reads from the chime poll PC range
local poll_bit0_hi   = 0     -- of those, how many returned bit0=1 (half-empty)
local isr_accesses   = 0     -- ASC accesses with pc OUTSIDE the chime range,
                             -- seen AFTER the chime poll first appeared
local chime_seen     = false
local chime_seen_F   = 0
local last_asc_frame = 0
local last_fed_log   = -1

local function emit(s) buf[#buf+1] = s end

local function now()
	if not timefn then
		if pcall(function() return emu.time() + 0 end) then
			timefn = function() return emu.time() end
		elseif pcall(function() return manager.machine.time:as_double() end) then
			timefn = function() return manager.machine.time:as_double() end
		else
			timefn = function() return -1 end
		end
	end
	return timefn()
end

local function pc()
	local v = 0
	pcall(function() v = cpu.state["CURPC"].value end)
	return v
end

-- first active byte lane (m68k big-endian: one lane for a byte access)
local function maskval(data, mask)
	for i = 3, 0, -1 do
		if ((mask >> (i*8)) & 0xff) ~= 0 then return (data >> (i*8)) & 0xff end
	end
	return data & 0xff
end

local function in_poll(p) return p >= POLL_LO and p <= POLL_HI end

local function note_asc(p)
	last_asc_frame = frame
	if chime_seen and not in_poll(p) then
		isr_accesses = isr_accesses + 1
	end
end

local function setup()
	cpu = manager.machine.devices[":maincpu"]
	space = cpu.spaces["program"]

	f:write(string.format("# asc_trace install F=%d t=%.6f max_frame=%d poll=%06X..%06X\n",
	                      frame, now(), MAX_FRAME, POLL_LO, POLL_HI))

	-- FIFO A write window: the feed. One byte per write.
	taps[#taps+1] = space:install_write_tap(FIFO_A_LO, FIFO_A_HI, "ascfw", function(off, data, mask)
		local p = pc()
		fed_bytes = fed_bytes + 1
		note_asc(p)
		emit(string.format("FW t=%.6f F=%d off=%06X data=%02X fed=%d pc=%06X%s",
		                   now(), frame, off & 0xffffff, maskval(data, mask), fed_bytes, p,
		                   (chime_seen and not in_poll(p)) and " ISR" or ""))
	end)

	-- Register window reads: FIFOSTAT ($804) is the poll target.
	taps[#taps+1] = space:install_read_tap(REG_LO, REG_HI, "ascrr", function(off, data, mask)
		local a = off & 0xffffff
		local p = pc()
		local v = maskval(data, mask)
		if a == FIFOSTAT then
			fifostat_reads = fifostat_reads + 1
			note_asc(p)
			local polled = in_poll(p)
			if polled then
				if not chime_seen then chime_seen = true; chime_seen_F = frame
					emit(string.format("# CHIME POLL FIRST SEEN F=%d t=%.6f pc=%06X", frame, now(), p)) end
				poll_reads = poll_reads + 1
				if (v & 1) == 1 then poll_bit0_hi = poll_bit0_hi + 1 end
			end
			emit(string.format("RS t=%.6f F=%d off=%06X val=%02X b0=%d b1=%d fed=%d pc=%06X%s",
			                   now(), frame, a, v, v & 1, (v >> 1) & 1, fed_bytes, p,
			                   polled and " POLL" or (chime_seen and " ISR" or "")))
		else
			-- other register reads (MODE/CONTROL/FIFOMODE/VERSION/...) — count + log sparsely
			emit(string.format("RR t=%.6f F=%d off=%06X val=%02X pc=%06X", now(), frame, a, v, p))
		end
	end)

	-- Register window writes: MODE/FIFOMODE/CLOCK/VOLUME setup + chime control.
	taps[#taps+1] = space:install_write_tap(REG_LO, REG_HI, "ascrw", function(off, data, mask)
		local p = pc()
		note_asc(p)
		emit(string.format("RW t=%.6f F=%d off=%06X reg=%X val=%02X pc=%06X",
		                   now(), frame, off & 0xffffff, (off & 0xf), maskval(data, mask), p))
	end)

	f:flush()
end

emu.register_frame_done(function()
	frame = frame + 1
	if not installed then installed = true; setup() end

	-- heartbeat with the running stats every 30 frames
	if frame % 30 == 0 then
		emit(string.format("B F=%d t=%.6f fed=%d statrd=%d pollrd=%d pollb0hi=%d isr=%d chime=%s",
		                   frame, now(), fed_bytes, fifostat_reads, poll_reads, poll_bit0_hi,
		                   isr_accesses, tostring(chime_seen)))
	end
	if SNAP_EVERY ~= 0 and frame % SNAP_EVERY == 0 then
		pcall(function() manager.machine.video:snapshot() end)
		emit(string.format("SNAP F=%d", frame))
	end

	if #buf > 0 then f:write(table.concat(buf, "\n")); f:write("\n"); buf = {}; f:flush() end

	-- exit once the chime poll has been seen and ASC has gone quiet (boot moved on
	-- or hung elsewhere), or at the hard frame cap.
	local quiet = QUIET_EXIT ~= 0 and chime_seen and last_asc_frame > 0
	              and (frame - last_asc_frame) > QUIET_EXIT
	if frame >= MAX_FRAME or quiet then
		pcall(function() manager.machine.video:snapshot() end)
		f:write(string.format("# END F=%d t=%.6f fed=%d statrd=%d pollrd=%d pollb0hi=%d isr=%d quiet=%s\n",
		                      frame, now(), fed_bytes, fifostat_reads, poll_reads, poll_bit0_hi,
		                      isr_accesses, tostring(quiet)))
		f:flush(); f:close()
		manager.machine:exit()
	end
end)
