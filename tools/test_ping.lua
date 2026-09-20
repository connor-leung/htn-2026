-- Drives apps/goose_ping/main.lua: two mock badges beaconing at each other.
-- The point of the app is to test real hardware, but these checks make sure
-- what we hand the badge is not broken before it gets there.
package.path = "tools/?.lua;" .. package.path
local H = require("harness")
H.source = "apps/goose_ping/main.lua"

local fails = 0
local function check(c, m) if not c then fails = fails + 1; print("  FAIL: " .. m) end end
local function tick(b, ms) for _ = 1, math.max(1, ms // 20) do b.now = b.now + 20; b.env.on_tick() end end
local function press(b, n) b.env.on_button(b.badge.input.BUTTON[n], b.badge.input.KIND.PRESSED) end
local function deliver(from, to)
  local box = from.outbox
  from.outbox = {}
  for _, m in ipairs(box) do to.recv(from.badge.radio.mac(), -42, m) end
  return #box
end

print("== it starts quiet ==")
local Q = H.new("Q", 2)
Q.env.on_enter(Q.root)
check(Q.radio_up == true, "radio is enabled and listening")
check(Q.wake == true, "wake lock held - a radio app cannot work asleep")
tick(Q, 3000)
check(#Q.outbox == 0, "nothing is transmitted until asked")
check(next(Q.leds) == nil, "LEDs stay dark until asked")
press(Q, "A")
tick(Q, 600)
check(#Q.outbox > 0, "A starts the beacon")
press(Q, "A")
local n = #Q.outbox
tick(Q, 2000)
check(#Q.outbox == n, "A again stops it")
Q.env.on_exit()
check(Q.wake == false, "wake lock released on exit")

print("\n== two badges hear each other ==")
local A, B = H.new("A", 3), H.new("B", 8)
A.env.on_enter(A.root); B.env.on_enter(B.root)
press(A, "A"); press(B, "A")
check(A.radio_up == true, "radio enabled on enter")
check(A.screen():find("ENABLED", 1, true) ~= nil, "screen says so")

local delivered = 0
for _ = 1, 10 do
  tick(A, 200); tick(B, 200)
  delivered = delivered + deliver(A, B) + deliver(B, A)
end
check(delivered > 0, "frames were actually sent")
check(A.screen():find("heard", 1, true) ~= nil, "counter is on screen")
check(not A.screen():find("no other badge heard yet", 1, true),
  "A stopped saying it heard nobody")
print("  delivered " .. delivered .. " frames in 2 s of ticks")

print("\n== a badge ignores its own echo ==")
local C = H.new("C", 4)
C.env.on_enter(C.root)
press(C, "A")
tick(C, 600)
local own = C.outbox[1]
check(own ~= nil, "beacon was queued")
C.recv(C.badge.radio.mac(), -30, own)      -- echo it straight back
tick(C, 40)
check(C.screen():find("no other badge heard yet", 1, true) ~= nil,
  "own frame is not counted as a peer")

print("\n== junk on the channel is ignored ==")
C.recv("AA:BB", -30, "LUA1 something else entirely")
C.recv("AA:BB", -30, "GG1:H:1234:1:1")     -- another app's prefix
tick(C, 40)
check(C.screen():find("no other badge heard yet", 1, true) ~= nil,
  "only the GP1 prefix counts")

print("\n== the peer list stays bounded ==")
for i = 1, 9 do
  C.recv("AA:BB", -50 - i, "GP1:" .. string.format("%04d", i) .. ":1")
end
tick(C, 40)
local shown = select(2, C.screen():gsub("dBm", ""))
check(shown <= 4, "at most four peers listed, got " .. shown)

print("\n== a badge whose radio will not start ==")
-- Observed on hardware: BLE init failed with only 22 KB contiguous free.
-- The app must stay up and say so, not die or sit silently.
local F = H.new("F", 6)
F.radio_fails = true
F.env.on_enter(F.root)
check(F.radio_up ~= true, "radio did not come up")
check(F.screen():find("FAILED", 1, true) ~= nil, "says so on screen")
check(F.screen():find("free", 1, true) ~= nil, "reports the heap it had")
press(F, "A")
press(F, "B")
press(F, "START")
tick(F, 600)
check(#F.outbox == 0, "A does not beacon into a dead radio")
check(F.radio_up ~= true, "no button re-enters the radio")
check(F.wake ~= true, "no wake lock held for a radio that never started")
-- Enabling BLE is a slow synchronous init. on_button gets 20 ms on older
-- firmware and one failure suspends input permanently, so that work belongs
-- in on_enter (3,000 ms): reopening the app is how you retry.
check(F.screen():find("FAILED", 1, true) ~= nil, "still up and still saying so")
F.env.on_exit()

print("\n== no callback does heavy work ==")
local G = H.new("G", 7)
G.env.on_enter(G.root)
local calls = 0
for _, w in ipairs(G.all) do
  local f = w.set_text
  if f then w.set_text = function(self, t) calls = calls + 1; return f(self, t) end end
end
for _, name in ipairs({ "A", "B", "START", "UP", "DOWN" }) do
  calls = 0
  G.env.on_button(G.badge.input.BUTTON[name], G.badge.input.KIND.PRESSED)
  check(calls == 0, name .. " touches no widget in the button callback")
end
local shows = 0
G.badge.led.show = function() shows = shows + 1 end
local worst_text, worst_show = 0, 0
for _ = 1, 100 do                       -- 2 s of ticks
  calls, shows = 0, 0
  G.now = G.now + 20
  G.env.on_tick()
  if calls > worst_text then worst_text = calls end
  if shows > worst_show then worst_show = shows end
end
check(worst_text <= 1, "no tick writes more than one label (" .. worst_text .. ")")
check(worst_show <= 1, "no tick latches the strip twice (" .. worst_show .. ")")

print("\n== START clears, exit tidies up ==")
press(C, "START")
tick(C, 40)
check(C.screen():find("sent 0", 1, true) ~= nil, "counters cleared")
C.env.on_exit()
check(C.radio_up == false, "radio disabled on exit")
check(next(C.leds) == nil, "LEDs cleared on exit")

print("\n" .. fails .. " failure(s)")
os.exit(fails == 0 and 0 or 1)
