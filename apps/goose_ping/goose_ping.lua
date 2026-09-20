--[==[badge-app
slug=goose_ping
name=Goose Ping
icon=GP
api=2
heap_kb=48
wake_lock=1
]==]

local PREFIX = "GP1:"
local BEACON_MS = 500
local UI_MS = 250
local LED_MS = 90
local SAVE_MS = 10000
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
local ui_step = 1
local pending_clear = false
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
if #peers > 4 then
local oldest, oi = peers[1].at, 1
for i = 2, #peers do
if peers[i].at < oldest then oldest, oi = peers[i].at, i end
end
table.remove(peers, oi)
end
end
local function on_radio(mac, rssi, payload)
if string.sub(payload, 1, 4) ~= PREFIX then return end
local id = string.sub(payload, 5, 8)
if id == my_id then return end
got = got + 1
last_at = badge.sys.ms()
flash_until = last_at + 200
note_peer(id, rssi)
end
local free_at_enable, free_after_enable = 0, 0
local function claim_radio()
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
claim_radio()
if radio_on then badge.radio.on_recv(on_radio) end
my_id = string.format("%04x", badge.sys.random(65536))
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
if radio_on then badge.sys.wake_lock(true) end
local ver = badge.sys.version
put("ver", "fw " .. (ver and ver() or "?"))
put("heap", "radio heap " .. free_at_enable .. " -> " .. free_after_enable)
show_radio()
end
local function refresh_one(step, now)
if step == 1 then
local drop = badge.radio.dropped
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
if worst > saved_worst and t0 >= next_save then
next_save = t0 + SAVE_MS
saved_worst = worst
badge.store.set_int("gpworst", worst)
end
end
function on_button(button, kind)
if kind ~= badge.input.KIND.PRESSED then return end
local B = badge.input.BUTTON
if button == B.A then
beaconing = radio_on and not beaconing
next_beacon = 0
elseif button == B.B then
leds_on = not leds_on
led_sig = -99
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
