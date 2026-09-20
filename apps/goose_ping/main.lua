-- Goose Ping - does the radio actually work between two badges?
--
-- Run it on both badges and stand near each other. Each beacons twice a
-- second and reports what it hears. Nothing else in this workspace has ever
-- had badge.radio run on real hardware, so this exists to prove the channel
-- before a game is built on top of it.
--
-- It starts DOING AS LITTLE AS POSSIBLE - radio listening, nothing sent, LEDs
-- dark - so that if the badge dies you know it died on the bare radio and not
-- on something this app chose to do. Turn one thing on at a time.
--
--   A      start/stop beaconing (only once the radio is up)
--   B      LEDs on/off           (six LEDs plus a TX burst is peak draw)
--   START  clear the counters
--   HOME   exit
--
-- on_tick runs on a nominal 20 ms cadence and wants a few ms of work. An
-- earlier version of this app rewrote five labels every tick - 150 set_text
-- calls a second - which was fine on USB and froze the badge into a watchdog
-- restart on   battery, where it downclocks and sleeps. Everything below is
-- throttled and compared-before-written for that reason. Measure with
-- tools/profile_tick.lua before changing it.

local PREFIX = "GP1:"
local BEACON_MS = 500
local UI_MS = 250          -- 4 Hz is plenty for numbers a human reads
local LED_MS = 90          -- matches goose_solo, which survives on battery
local SAVE_MS = 10000      -- flash, so rare and only when the value moved

local ui, shown = {}, {}
local my_id
local radio_on = false
local beaconing, leds_on = false, false
local seq, sent, got = 0, 0, 0
local last_at, flash_until = 0, 0
local next_beacon, next_ui, next_led, next_save = 0, 0, 0, SAVE_MS
local led_sig = -1
local worst, saved_worst, run_n = 0, 0, 0
local peers = {}
local ui_step = 1            -- one screen line refreshed per tick, not four
local pending_clear = false

-- Only touch LVGL when the text actually changed. An idle screen should issue
-- no set_text calls at all; each one reallocates and relays out the label.
local function put(key, text)
  if shown[key] ~= text then
    shown[key] = text
    ui[key]:set_text(text)
  end
end

local function note_peer(id, rssi)
  for i = 1, #peers do
    if peers[i].id == id then
      peers[i].rssi = rssi
      peers[i].n = peers[i].n + 1
      peers[i].at = badge.sys.ms()
      return
    end
  end
  peers[#peers + 1] = { id = id, rssi = rssi, n = 1, at = badge.sys.ms() }
  -- Drop the stalest entry rather than the newest: a badge that just walked
  -- up is more interesting than one that left.
  if #peers > 4 then
    local oldest, oi = peers[1].at, 1
    for i = 2, #peers do
      if peers[i].at < oldest then oldest, oi = peers[i].at, i end
    end
    table.remove(peers, oi)
  end
end

-- Runs inside the tick budget, drained up to 4 frames per tick: keep it short.
local function on_radio(mac, rssi, payload)
  if string.sub(payload, 1, 4) ~= PREFIX then return end
  local id = string.sub(payload, 5, 8)
  if id == my_id then return end          -- our own frame, echoed back
  got = got + 1
  last_at = badge.sys.ms()
  flash_until = last_at + 200
  note_peer(id, rssi)
end

-- Bluetooth needs its own system RAM, separate from the Lua quota, and it can
-- simply not be there: NimBLE wants a large contiguous block and reports
-- "nimble host init failed" when it cannot get one. Everything this app
-- allocates - every widget included - comes out of the same system heap, so
-- claim the radio BEFORE building anything. Observed on hardware: entering
-- this app dropped the largest free block to 22,528 bytes, and BLE init failed.
local free_at_enable, free_after_enable = 0, 0

local function claim_radio()
  -- Compiling this chunk leaves collectable garbage holding system heap that
  -- BLE wants. gc_step is incremental, so several are needed to finish a
  -- cycle; on_enter has a 3,000 ms budget and these are microseconds.
  for _ = 1, 12 do badge.sys.gc_step() end
  free_at_enable = badge.sys.stats().free_heap
  radio_on = badge.radio.enable()
  free_after_enable = badge.sys.stats().free_heap
end

local function show_radio()
  if radio_on then
    badge.radio.on_recv(on_radio)
    put("radio", "radio: ENABLED, listening (A beacons, B LEDs)")
    ui.radio:set_color(0x6ee7a0)
  else
    put("radio", "radio: FAILED - had " .. free_at_enable .. " free")
    ui.radio:set_color(0xff5a3c)
  end
end

local function lbl(key, color, small, dy, text)
  local l = badge.ui.label(ui.bg, text or "")
  if small then l:set_font_size("small") end
  l:set_color(color)
  l:align("top_left", 12, dy)
  if key then ui[key] = l; shown[key] = text or "" end
  return l
end

function on_enter(root)
  -- FIRST, before a single widget exists. This is the whole point: on the
  -- badge, BLE init failed with the UI already built and only 22 KB of
  -- contiguous heap left. Nothing below here is allowed to run before it.
  claim_radio()
  if radio_on then badge.radio.on_recv(on_radio) end

  my_id = string.format("%04x", badge.sys.random(65536))

  -- Survives the watchdog restart this app is here to investigate: on the way
  -- back up it reports what the previous run reached.
  run_n = badge.store.get_int("gprun", 0) + 1
  badge.store.set_int("gprun", run_n)
  saved_worst = badge.store.get_int("gpworst", 0)

  ui.bg = badge.ui.box{ parent = root, w = 320, h = 240, bg_color = 0x0d1117 }
  ui.bg:align("center", 0, 0)
  lbl(nil, 0xffc400, false, 8, "GOOSE PING  " .. my_id)
  lbl("radio", 0xe5e7eb, true, 36)
  lbl("count", 0xe5e7eb, false, 56)
  lbl("peers", 0x6ee7a0, true, 84, "no other badge heard yet")
  lbl("tick", 0xffc400, true, 142)
  lbl("heap", 0x6b7280, true, 160)
  lbl("ver", 0x6b7280, true, 178)
  lbl("mem", 0x6b7280, true, 196)
  lbl(nil, 0x6b7280, true, 216, "A beacon   B LEDs   START clears   HOME exits")

  -- A radio app cannot work asleep, so hold the badge awake - but only if
  -- there is actually a radio to service. goose_solo survives on battery and
  -- holds no wake lock; with BLE failing to init, this was the only other
  -- thing this app did differently, and holding a dead radio awake buys
  -- nothing but drain.
  if radio_on then badge.sys.wake_lock(true) end

  -- The firmware version decides whether on_tick gets 250 ms or 6 ms, and it
  -- is the first thing to collect when the radio will not start. Guarded: if
  -- the call itself is missing, that is its own answer.
  local ver = badge.sys.version
  put("ver", "fw " .. (ver and ver() or "?"))
  put("heap", "radio heap " .. free_at_enable .. " -> " .. free_after_enable)

  show_radio()
end

-- One line per tick, never the whole screen at once. This badge reports a
-- 6 ms worst tick, which is exactly the older firmware's tick budget, so a
-- refresh that touched four labels in one callback was living dangerously.
local function refresh_one(step, now)
  if step == 1 then
    local drop = badge.radio.dropped      -- guarded: absent on older firmware
    put("count", (beaconing and "TX  " or "rx  ") .. "sent " .. sent ..
      "   heard " .. got .. "   dropped " .. (drop and drop() or 0))
  elseif step == 2 then
    if #peers > 0 then
      local out = ""
      for i = 1, #peers do
        local p = peers[i]
        out = out .. p.id .. "  " .. p.rssi .. "dBm  x" .. p.n ..
          ((now - p.at > 3000) and "  (quiet)" or "") .. "\n"
      end
      put("peers", out)
    end
  elseif step == 3 then
    put("tick", "run #" .. run_n .. "   worst tick " .. worst ..
      "ms   last run " .. saved_worst .. "ms")
  else
    local s = badge.sys.stats()
    put("mem", "lua " .. s.lua_used .. "/" .. s.lua_limit ..
      "  peak " .. s.lua_peak .. "  free " .. s.free_heap)
    badge.sys.gc_step()
  end
end

local function draw_leds(now)
  -- One integer describes the whole frame, so an unchanged frame costs
  -- nothing: no clear, no set, no show.
  local sig = 0
  if leds_on then
    sig = (now < flash_until) and -1 or ((now // 300) % 6 + 1)
  end
  if sig == led_sig then return end
  led_sig = sig

  badge.led.clear()
  if sig == -1 then
    badge.led.set_all(0, 24, 4)
  elseif sig > 0 then
    badge.led.set(sig, 30, 18, 0)
  end
  badge.led.show()
end

function on_tick()
  local t0 = badge.sys.ms()

  if radio_on and beaconing and t0 >= next_beacon then
    next_beacon = t0 + BEACON_MS
    seq = seq + 1
    if badge.radio.send(PREFIX .. my_id .. ":" .. seq) then sent = sent + 1 end
  end

  -- Button presses only set flags; their work happens here, where a dropped
  -- frame costs nothing. A failed button callback suspends input immediately.
  if pending_clear then
    pending_clear = false
    sent, got, seq, worst = 0, 0, 0, 0
    peers = {}
    put("peers", "no other badge heard yet")
  end

  if ui_step <= 4 then
    refresh_one(ui_step, t0)
    ui_step = ui_step + 1
    if ui_step > 4 then next_ui = t0 + UI_MS end
  elseif t0 >= next_ui then
    ui_step = 1
  end

  if t0 >= next_led then
    next_led = t0 + LED_MS
    draw_leds(t0)
  end

  local dt = badge.sys.ms() - t0
  if dt > worst then worst = dt end
  -- Flash is kept off the tick path as a rule; this is the deliberate
  -- exception, bounded to once per 10 s and only when the number moved,
  -- because a watchdog restart never reaches on_exit.
  if worst > saved_worst and t0 >= next_save then
    next_save = t0 + SAVE_MS
    saved_worst = worst
    badge.store.set_int("gpworst", worst)
  end
end

-- Flags only. No LVGL, no stats, no radio: on older firmware this callback
-- gets 20 ms, and one failure suspends input for good. Enabling the radio
-- from here - a synchronous NimBLE init that can fail slowly - was well over
-- that, which is why pressing a button killed the app. Retrying the radio is
-- on_enter's job now, and reopening the app is how you retry it.
function on_button(button, kind)
  if kind ~= badge.input.KIND.PRESSED then return end
  local B = badge.input.BUTTON
  if button == B.A then
    beaconing = radio_on and not beaconing
    next_beacon = 0
  elseif button == B.B then
    leds_on = not leds_on
    led_sig = -99                         -- force one redraw
  elseif button == B.START then
    pending_clear = true
  end
  next_ui = 0
  ui_step = 1
end

function on_exit()
  if worst > saved_worst then badge.store.set_int("gpworst", worst) end
  badge.sys.wake_lock(false)
  if radio_on then
    badge.radio.on_recv(nil)
    badge.radio.disable()
  end
  badge.led.clear()
  badge.led.show()
end
