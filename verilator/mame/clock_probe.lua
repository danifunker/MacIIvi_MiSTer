-- clock_probe.lua — identify what advances the Mac OS time-of-day clock.
--
-- Boots maciivi and, from frame PROBE_START on, taps:
--   * maincpu writes to Time ($20C) — logs writer PC (which routine bumps it)
--   * maincpu writes to Ticks ($16A) — 60.15 Hz tick ISR activity
--   * VIA1 register accesses (both $5000xxxx and $50F0xxxx mirrors),
--     classifying shift-register (reg 10, Egret comms) and port B (reg 0,
--     Egret handshake) traffic
--   * Egret 68HC05 internal writes: $CC (one-second ISR seconds counter),
--     $AB-$AE (RTC), $A2 (host-notify flags), $01 (port B = CB1/CB2 lines)
-- and prints one [SUM] correlation line per guest second (60 frames).
--
-- Env: PROBE_START (default 1800), MAX_FRAME (default 8400),
--      SNAP1/SNAP2 (snapshot frames, default 3300/8340)
--
-- Run (WSL):
--   PROBE_START=1800 MAX_FRAME=8400 /usr/games/mame maciivi \
--     -rompath verilator/mame/roms -ramsize 8M -scsi:0 harddisk \
--     -hard1 <copy.hda> -skip_gameinfo -video none -sound none -nothrottle \
--     -autoboot_script verilator/mame/clock_probe.lua \
--     -snapname 'maciivi/f%i' -snapshot_directory scratch/<dir>

local function envnum(n, d) local v = os.getenv(n); return v and (tonumber(v) or d) or d end
local START     = envnum("PROBE_START", 1800)
local MAX_FRAME = envnum("MAX_FRAME", 8400)
local SNAP1     = envnum("SNAP1", 3300)
local SNAP2     = envnum("SNAP2", 8340)

local frame = 0
local installed = false
local taps = {}          -- keep tap objects alive (GC removes them)
local mc, eg, mspace, espace

-- per-second counters
local c = { ticksw = 0, viar = 0, viaw = 0, srr = 0, srw = 0, pbr = 0, pbw = 0, egpb = 0 }
local caps = { tickpc = 0, sr = 0, pbw = 0, ega2 = 0 }
local egpcs = {}         -- unique egret PCs seen on port-B writes this second

local function mpc()
  local ok, v = pcall(function() return mc.state['CURPC'].value end)
  if ok and v then return v end
  local ok2, v2 = pcall(function() return mc.state['PC'].value end)
  return (ok2 and v2) or 0xFFFFFFFF
end

local function epc()
  if not eg then return 0xFFFF end
  local ok, v = pcall(function() return eg.state['PC'].value end)
  return (ok and v) or 0xFFFF
end

local function find_devices()
  local names = {}
  for tag, dev in pairs(manager.machine.devices) do
    if tag:find('egret') or tag:find('via') or tag:find('vasp') or tag == ':maincpu' then
      names[#names + 1] = tag
      if tag:find('egret') then
        local ok, sp = pcall(function() return dev.spaces['program'] end)
        if ok and sp then eg = dev; espace = sp end
      end
    end
  end
  table.sort(names)
  print('[PROBE] devices: ' .. table.concat(names, ' '))
  mc = manager.machine.devices[':maincpu']
  mspace = mc.spaces['program']
  print('[PROBE] maincpu ok; egret cpu = ' .. (eg and 'found (internal space tapped)' or 'NOT FOUND (host-side taps only)'))
end

local function trytap(label, fn)
  local ok, r = pcall(fn)
  if ok and r then taps[label] = r; print('[PROBE] tap ok:   ' .. label)
  else print('[PROBE] tap FAIL: ' .. label .. ' — ' .. tostring(r)) end
end

-- classify a VIA1 access: reg = (byteaddr >> 9) & 0xF ; reg 10 = SR, reg 0 = PB
local function via_read_cb(offset, data, mask)
  c.viar = c.viar + 1
  local reg = (offset >> 9) & 0xF
  if reg == 10 then
    c.srr = c.srr + 1
    if caps.sr < 400 then
      caps.sr = caps.sr + 1
      print(string.format('[SRR ] f=%d pc=%08X a=%08X d=%08X m=%08X', frame, mpc(), offset, data, mask))
    end
  elseif reg == 0 then
    c.pbr = c.pbr + 1
  end
end

local function via_write_cb(offset, data, mask)
  c.viaw = c.viaw + 1
  local reg = (offset >> 9) & 0xF
  if reg == 10 then
    c.srw = c.srw + 1
    if caps.sr < 400 then
      caps.sr = caps.sr + 1
      print(string.format('[SRW ] f=%d pc=%08X a=%08X d=%08X m=%08X', frame, mpc(), offset, data, mask))
    end
  elseif reg == 0 then
    c.pbw = c.pbw + 1
    if caps.pbw < 300 then
      caps.pbw = caps.pbw + 1
      print(string.format('[PBW ] f=%d pc=%08X a=%08X d=%08X m=%08X', frame, mpc(), offset, data, mask))
    end
  end
end

local function install()
  find_devices()

  -- Time global ($20C): every write, with writer PC — the core question.
  trytap('Time($20C) w', function()
    return mspace:install_write_tap(0x20c, 0x20f, 'timew', function(offset, data, mask)
      local cur = mspace:read_u32(0x20c)
      local tk  = mspace:read_u32(0x16a)
      print(string.format('[TIMEW] f=%d pc=%08X off=%X d=%08X m=%08X old=%08X ticks=%d',
        frame, mpc(), offset, data, mask, cur, tk))
    end)
  end)

  -- Ticks global ($16A): count writes; log first few PCs to identify tick ISR.
  trytap('Ticks($16A) w', function()
    return mspace:install_write_tap(0x16a, 0x16d, 'ticksw', function(offset, data, mask)
      c.ticksw = c.ticksw + 1
      if caps.tickpc < 5 then
        caps.tickpc = caps.tickpc + 1
        print(string.format('[TICKW] f=%d pc=%08X off=%X d=%08X m=%08X', frame, mpc(), offset, data, mask))
      end
    end)
  end)

  -- VIA1, both mirrors.
  trytap('VIA1 $50000000 r', function() return mspace:install_read_tap (0x50000000, 0x50001fff, 'via0r', via_read_cb) end)
  trytap('VIA1 $50000000 w', function() return mspace:install_write_tap(0x50000000, 0x50001fff, 'via0w', via_write_cb) end)
  trytap('VIA1 $50F00000 r', function() return mspace:install_read_tap (0x50f00000, 0x50f01fff, 'viaFr', via_read_cb) end)
  trytap('VIA1 $50F00000 w', function() return mspace:install_write_tap(0x50f00000, 0x50f01fff, 'viaFw', via_write_cb) end)

  if espace then
    -- Egret one-second ISR increments $CC once per second.
    trytap('egret $CC w', function()
      return espace:install_write_tap(0xcc, 0xcc, 'egcc', function(offset, data, mask)
        print(string.format('[EGCC] f=%d egpc=%04X d=%02X', frame, epc(), data & 0xff))
      end)
    end)
    -- RTC bytes $AB-$AE (drained from $CC by $1E4E).
    trytap('egret RTC w', function()
      return espace:install_write_tap(0xab, 0xae, 'egrtc', function(offset, data, mask)
        print(string.format('[RTCW] f=%d egpc=%04X a=%02X d=%02X', frame, epc(), offset, data & 0xff))
      end)
    end)
    -- $A2 host-notify flags (ISR sets bit3, bit0 when armed).
    trytap('egret $A2 w', function()
      return espace:install_write_tap(0xa2, 0xa2, 'ega2', function(offset, data, mask)
        if caps.ega2 < 300 then
          caps.ega2 = caps.ega2 + 1
          print(string.format('[EGA2] f=%d egpc=%04X d=%02X', frame, epc(), data & 0xff))
        end
      end)
    end)
    -- Port B data ($01): CB1/CB2 bit-banging → count + collect PCs.
    trytap('egret PB w', function()
      return espace:install_write_tap(0x01, 0x01, 'egpb', function(offset, data, mask)
        c.egpb = c.egpb + 1
        local k = string.format('%04X', epc())
        if egpcs[k] == nil then
          local n = 0
          for _ in pairs(egpcs) do n = n + 1 end
          if n < 8 then egpcs[k] = true end
        end
      end)
    end)
  end
end

local function summary()
  local t  = mspace:read_u32(0x20c)
  local tk = mspace:read_u32(0x16a)
  local cc, rtc = -1, '--------'
  if espace then
    cc  = espace:read_u8(0xcc)
    rtc = string.format('%02X%02X%02X%02X',
      espace:read_u8(0xab), espace:read_u8(0xac), espace:read_u8(0xad), espace:read_u8(0xae))
  end
  local pcs = {}
  for k in pairs(egpcs) do pcs[#pcs + 1] = k end
  table.sort(pcs)
  print(string.format(
    '[SUM] f=%d Time=%08X Ticks=%d dTickW=%d via(r=%d,w=%d) sr(r=%d,w=%d) pb0(r=%d,w=%d) egPBw=%d cc=%d rtc=%s egpc={%s}',
    frame, t, tk, c.ticksw, c.viar, c.viaw, c.srr, c.srw, c.pbr, c.pbw, c.egpb, cc, rtc,
    table.concat(pcs, ',')))
  c = { ticksw = 0, viar = 0, viaw = 0, srr = 0, srw = 0, pbr = 0, pbw = 0, egpb = 0 }
  egpcs = {}
end

emu.register_frame_done(function()
  frame = frame + 1
  if frame == START then
    local ok, err = pcall(install)
    if not ok then print('[PROBE] INSTALL FAILED: ' .. tostring(err)) end
    installed = ok
  end
  if installed and (frame % 60) == 0 then pcall(summary) end
  if frame == SNAP1 or frame == SNAP2 then manager.machine.video:snapshot() end
  if frame >= MAX_FRAME then manager.machine:exit() end
end)

print('[PROBE] clock_probe loaded; START=' .. START .. ' MAX_FRAME=' .. MAX_FRAME)
