-- session_probe.lua — byte-level Egret<->host conversation tap for maciivi.
-- Logs every VIA1 SR read/write VALUE and every VIA1 ORB(PB) write VALUE
-- with frame stamps, in a bounded frame window, so one Egret session can be
-- reconstructed byte-for-byte and diffed against the core's sim $displays
-- (VIA_ORB / VIA_SR lines). VIA1 register stride is 0x200: ORB at +0x0000,
-- SR at +0x1400, on both the $50F0xxxx primary and $5000xxxx mirror.
--
-- Env: PROBE_START (default 400), PROBE_END (default 760), MAX_FRAME
--      (default 900, exits after the window).
-- Run like clock_probe.lua (see that file); pair with -nvram_directory on a
-- FRESH dir for the zero-PRAM InitUtil conversation.

local function envnum(n, d) local v = os.getenv(n); return v and (tonumber(v) or d) or d end
local START     = envnum("PROBE_START", 400)
local FINISH    = envnum("PROBE_END", 760)
local MAX_FRAME = envnum("MAX_FRAME", 900)

local frame = 0
local installed = false
local taps = {}

local function in_window() return frame >= START and frame <= FINISH end

local function install()
    local mac = manager.machine
    local cpu = mac.devices[":maincpu"]
    local prog = cpu.spaces["program"]

    local bases = { 0x50f00000, 0x50000000 }
    for _, base in ipairs(bases) do
        -- ORB writes (reg 0 = base+0x0000..0x01ff)
        taps[#taps + 1] = prog:install_write_tap(base + 0x0000, base + 0x01ff, "orbw" .. base,
            function(offset, data, mask)
                if in_window() then
                    print(string.format("[PBW] f=%d v=%02X", frame, (data >> 8) & 0xff))
                end
            end)
        -- SR accesses (reg 10 = base+0x1400..0x15ff)
        taps[#taps + 1] = prog:install_write_tap(base + 0x1400, base + 0x15ff, "srw" .. base,
            function(offset, data, mask)
                if in_window() then
                    print(string.format("[SRW] f=%d v=%02X", frame, (data >> 8) & 0xff))
                end
            end)
        taps[#taps + 1] = prog:install_read_tap(base + 0x1400, base + 0x15ff, "srr" .. base,
            function(offset, data, mask)
                if in_window() then
                    print(string.format("[SRR] f=%d v=%02X", frame, (data >> 8) & 0xff))
                end
            end)
    end
    print("[PROBE] session taps installed at frame " .. frame)
end

emu.register_frame_done(function()
    frame = frame + 1
    if not installed and frame >= (START - 10) then
        installed = true
        install()
    end
    if frame == FINISH + 1 then print("[PROBE] window closed at frame " .. frame) end
    if frame >= MAX_FRAME then manager.machine:exit() end
end)
