-- Battery-behaviour checks: LED energy, idle blanking, wake lock, radio giveup.
package.path = "tools/?.lua;" .. package.path
local H = require("harness")

local fails = 0
local function check(c, m) if not c then fails = fails + 1; print("  FAIL: " .. m) end end
local function tick(b, ms) for _ = 1, ms // 20 do b.now = b.now + 20; b.env.on_tick() end end
local function press(b, n) b.env.on_button(b.badge.input.BUTTON[n], b.badge.input.KIND.PRESSED) end

-- LED energy sitting on the menu. The brightness setting was removed to save
-- compiled memory, so there is one level; what is checked is that the fixed
-- scale is actually applied, not that a menu can change it.
print("== LED energy, 15 s idle on the menu ==")
local b0 = H.new("C", 3)
b0.env.on_enter(b0.root)
b0.led_energy = 0
tick(b0, 15000)
local scaled = b0.led_energy
print(string.format("  15 s of menu breathing: energy %d", scaled))
check(scaled > 0, "the strip animates on the menu")
-- Unscaled, six LEDs breathing to full for 15 s would be an order of
-- magnitude more than this. The exact figure tracks LED_SCALE / 255.
check(scaled < 15000000 // 255 * 60, "colours are scaled down before the strip")

print("\n== idle blanking ==")
local b = H.new("C", 3)
b.env.on_enter(b.root)
tick(b, 19000)
b.led_energy = 0
tick(b, 5000)                                        -- crosses the 20 s mark
local during = b.led_energy
b.led_energy = 0
tick(b, 20000)                                       -- fully idle now
print(("  energy while going idle: %d, then %d over the next 20 s")
  :format(during, b.led_energy))
check(b.led_energy == 0, "strip is blanked when idle on a menu")
press(b, "DOWN")                                     -- any input wakes it
b.led_energy = 0
tick(b, 2000)
check(b.led_energy > 0, "a button press brings the LEDs back")
print("  after a press: energy " .. b.led_energy)

print("\n== wake lock ==")
local c = H.new("C", 9)
c.env.on_enter(c.root)
check(c.wake ~= true, "not held awake on the menu")
press(c, "DOWN"); press(c, "A")                      -- solo practice
tick(c, 200)
check(c.wake ~= true, "not held awake for a solo battle")
local d = H.new("D", 11)
d.env.on_enter(d.root)
press(d, "A")                                        -- seek a duel
tick(d, 100)
d.recv("MAC", -40, "GG1:H:0001:1:1")                 -- a peer appears
tick(d, 100)
check(d.wake == true, "held awake during a radio duel")
d.env.on_exit()
check(d.wake == false, "released on exit")

print("\n== radio gives up rather than advertising forever ==")
local e = H.new("E", 21)
e.env.on_enter(e.root)
press(e, "A")
check(e.radio_up == true, "radio enabled while seeking")
tick(e, 61000)
check(e.radio_up == false, "radio disabled after nobody answers")
check(e.screen():find("save battery", 1, true) ~= nil, "tells the user why")
check(e.wake == false, "wake lock released too")
local sends = 0
for _ in pairs(e.outbox) do sends = sends + 1 end
e.outbox = {}
tick(e, 10000)
check(#e.outbox == 0, "stops transmitting once it has given up")
print("  frames sent after giving up: " .. #e.outbox)

print(("\n%d failure(s)"):format(fails))
os.exit(fails == 0 and 0 or 1)
