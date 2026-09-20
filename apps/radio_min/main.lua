-- Radio Test - turn the radio on and ping the other badge, continuously.
--
-- Run it on both badges, stand them near each other, and watch the numbers.
-- Each badge beacons twice a second and counts what it hears. If "heard"
-- climbs on both, the radio works badge-to-badge and the duel protocol has
-- something to run on.
--
-- Deliberately tiny. Measured on hardware: BLE init needs about 47 KB of free
-- system heap, and it is the app's own Lua state that decides what is left -
-- Goose Ping (17 KB of state) left only 41 KB and could never start the
-- radio. So this app has no menus, no LED effects and no game data. Adding
-- any is what breaks it.
--
--   A      start/stop sending (it always listens)
--   HOME   exit

local BEACON_MS = 500
local UI_MS = 500

local ui, shown
local my_id
local radio_on, sending = false, false
local seq, sent, got = 0, 0, 0
local peer_id, peer_rssi = "-", 0
local next_beacon, next_ui = 0, 0
local free0, free1 = 0, 0

local function on_frame(mac, rssi, payload)
  if string.sub(payload, 1, 3) ~= "RM:" then return end
  local id = string.sub(payload, 4, 7)
  if id == my_id then return end          -- our own frame, echoed back
  got = got + 1
  peer_id, peer_rssi = id, rssi
end

function on_enter(root)
  -- The label comes FIRST, before the radio, even though that leaves NimBLE
  -- ~1 KB less. Measured on hardware: a failed enable() kept 47,264 bytes and
  -- left 2,968 free, and a badge with 3 KB left cannot allocate a widget to
  -- tell you what happened. One small allocation up front buys the ability to
  -- report the failure at all.
  my_id = string.format("%04x", badge.sys.random(65536))
  ui = badge.ui.label(root, "starting radio...")
  ui:align("top_left", 10, 10)
  shown = "starting radio..."

  free0 = badge.sys.stats().free_heap
  radio_on = badge.radio.enable()
  free1 = badge.sys.stats().free_heap
  if radio_on then
    badge.radio.on_recv(on_frame)
  else
    -- Say it once, here, while there is still a callback budget of 3,000 ms
    -- and before the tick loop is allowed to allocate anything at all.
    shown = "RADIO FAILED\n\nfree " .. free0 .. " -> " .. free1 ..
      "\n\nBLE wants about 47000 free.\nReboot, open this first,\nand run nothing else before it."
    ui:set_text(shown)
  end
  -- Deliberately NOT calling disable() here when it failed. The version that
  -- did crashed the badge; the version that left it alone survived and could
  -- still draw its screen. Tearing down a stack that never came up is not
  -- something to do on a guess.
end

function on_tick()
  -- When the radio never started, the heap may be nearly gone and there is
  -- nothing to report that on_enter did not already say. Allocate nothing,
  -- build no strings, just leave. This is what crashed: a tick that
  -- concatenated a screenful of text twice a second with 3 KB free.
  if not radio_on then return end

  local now = badge.sys.ms()

  if sending and now >= next_beacon then
    next_beacon = now + BEACON_MS
    seq = seq + 1
    if badge.radio.send("RM:" .. my_id .. ":" .. seq) then sent = sent + 1 end
  end

  if now < next_ui then return end
  next_ui = now + UI_MS

  local text = "RADIO OK   me " .. my_id ..
    "\n\n" .. (sending and "SENDING" or "listening only") .. "  (A toggles)" ..
    "\n\nsent   " .. sent ..
    "\nheard  " .. got ..
    "\npeer   " .. peer_id .. "  " .. peer_rssi .. " dBm" ..
    "\n\nfree " .. free0 .. " -> " .. free1
  -- Only touch LVGL when the text changed: an unchanged screen costs nothing.
  if text ~= shown then
    shown = text
    ui:set_text(text)
  end
end

-- Flags only. On older firmware this callback gets 20 ms and one failure
-- suspends input permanently.
function on_button(button, kind)
  if kind == badge.input.KIND.PRESSED and button == badge.input.BUTTON.A then
    sending = radio_on and not sending
    next_beacon = 0
    next_ui = 0
  end
end

function on_exit()
  if radio_on then
    badge.radio.on_recv(nil)
    badge.radio.disable()
  end
end
