--[==[badge-app
slug=radio_min
name=Radio Test
icon=RM
api=2
heap_kb=48
wake_lock=1
]==]

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
if id == my_id then return end
got = got + 1
peer_id, peer_rssi = id, rssi
end
function on_enter(root)
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
shown = "RADIO FAILED\n\nfree " .. free0 .. " -> " .. free1 ..
"\n\nBLE wants about 47000 free.\nReboot, open this first,\nand run nothing else before it."
ui:set_text(shown)
end
end
function on_tick()
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
if text ~= shown then
shown = text
ui:set_text(text)
end
end
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
