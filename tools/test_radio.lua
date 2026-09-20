-- Drives apps/radio_min/main.lua: two mock badges pinging each other, plus a
-- badge whose radio will not start. The real test is two badges on a table;
-- this just proves the app is not broken before it gets there.
package.path = "tools/?.lua;" .. package.path
local H = require("harness"); H.source = "apps/radio_min/main.lua"
local fails = 0
local function check(c, m) if not c then fails = fails + 1; print("  FAIL: " .. m) end end
local function tick(b, ms) for _ = 1, math.max(1, ms // 20) do b.now = b.now + 20; b.env.on_tick() end end
local function press(b, n) b.env.on_button(b.badge.input.BUTTON[n], b.badge.input.KIND.PRESSED) end
local function deliver(f, t) local x = f.outbox; f.outbox = {}
  for _, m in ipairs(x) do t.recv(f.badge.radio.mac(), -41, m) end; return #x end

local A, B = H.new("A", 3), H.new("B", 8)
A.env.on_enter(A.root); B.env.on_enter(B.root)
check(A.radio_up == true, "radio enabled")
tick(A, 2000); tick(B, 2000)
check(#A.outbox == 0, "listens only until A is pressed")
press(A, "A"); press(B, "A")
local n = 0
for _ = 1, 10 do tick(A, 200); tick(B, 200); n = n + deliver(A, B) + deliver(B, A) end
check(n > 0, "frames sent")
check(A.screen():find("heard  ", 1, true) ~= nil, "counts on screen")
check(not A.screen():find("heard  0", 1, true), "A heard B")
check(not B.screen():find("heard  0", 1, true), "B heard A")
print("  " .. n .. " frames in 2 s; A screen: " .. (A.screen():gsub("%s+", " ")))

local F = H.new("F", 6); F.radio_fails = true
F.env.on_enter(F.root)
check(F.screen():find("RADIO FAILED", 1, true) ~= nil,
  "failure reported from on_enter, not from a tick")
-- A failed enable() can leave the badge with ~3 KB free. The tick loop must
-- not allocate anything in that state: building a screenful of text twice a
-- second on 3 KB is what crashed the badge.
local writes = 0
for _, w in ipairs(F.all) do
  local f = w.set_text
  if f then w.set_text = function(self, t) writes = writes + 1; return f(self, t) end end
end
press(F, "A"); tick(F, 5000)
check(writes == 0, "no tick touches the screen once the radio has failed")
check(#F.outbox == 0, "never sends into a dead radio")
print("\n" .. fails .. " failure(s)")
os.exit(fails == 0 and 0 or 1)
