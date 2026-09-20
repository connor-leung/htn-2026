-- How expensive is this app's on_tick, in native calls per second?
--
-- The badge runs on_tick on a nominal 20 ms cadence and wants "a few ms" of
-- work in it. Lua-side cost is not the problem; the native calls are -
-- set_text reallocates and relays out an LVGL label, led.show latches the
-- strip. An app that issues those 50 times a second runs fine on USB and can
-- stop feeding the system on battery, where the badge downclocks and sleeps.
--
-- goose_ping did exactly that and froze the badge into a watchdog restart.
-- This turns "is that callback too expensive" into a number.
--
--     lua tools/profile_tick.lua apps/goose_ping/main.lua
--     lua tools/profile_tick.lua apps/goose_ping/main.lua A B   # press first
--
-- Trailing arguments are buttons pressed before profiling, to reach the state
-- you care about.

package.path = "tools/?.lua;" .. package.path
local H = require("harness")

local src = arg[1] or "main.lua"
H.source = src

local b = H.new("Profile", 3)
local n = { set_text = 0, show = 0, led_set = 0, stats = 0, store = 0, send = 0 }

local badge = b.badge
local o_show, o_stats = badge.led.show, badge.sys.stats
local o_set, o_all = badge.led.set, badge.led.set_all
local o_store, o_send = badge.store.set_int, badge.radio.send
badge.led.show = function(...) n.show = n.show + 1; return o_show(...) end
badge.sys.stats = function(...) n.stats = n.stats + 1; return o_stats(...) end
badge.led.set = function(...) n.led_set = n.led_set + 1; return o_set(...) end
badge.led.set_all = function(...) n.led_set = n.led_set + 6; return o_all(...) end
badge.store.set_int = function(...) n.store = n.store + 1; return o_store(...) end
badge.radio.send = function(...) n.send = n.send + 1; return o_send(...) end

b.env.on_enter(b.root)

-- Widgets only exist after on_enter, so wrap their set_text now.
for _, w in ipairs(b.all) do
  local f = w.set_text
  if f then
    w.set_text = function(self, t) n.set_text = n.set_text + 1; return f(self, t) end
  end
end

for i = 2, #arg do
  b.env.on_button(badge.input.BUTTON[arg[i]], badge.input.KIND.PRESSED)
end

for k in pairs(n) do n[k] = 0 end
for _ = 1, 50 do                       -- 1 second at the badge's 20 ms cadence
  b.now = b.now + 20
  b.env.on_tick()
end

print(("%s%s"):format(src, #arg > 1 and ("  (after " .. table.concat(arg, "+", 2) .. ")") or ""))
print(("  set_text %4d/s   led.show %3d/s   led.set %4d/s   sys.stats %3d/s   store %d/s   radio.send %d/s")
  :format(n.set_text, n.show, n.led_set, n.stats, n.store, n.send))

-- goose_solo is the reference: it is the only app here proven to survive on
-- battery, so beating its native-call rate is the bar.
local over = {}
if n.set_text > 20 then over[#over + 1] = "set_text " .. n.set_text .. "/s (idle should be 0)" end
if n.show > 12 then over[#over + 1] = "led.show " .. n.show .. "/s (throttle to ~90 ms)" end
if n.stats > 8 then over[#over + 1] = "sys.stats " .. n.stats .. "/s (move onto the UI refresh)" end
if n.store > 0 then over[#over + 1] = "store writes " .. n.store .. "/s (flash on the tick path)" end
if #over > 0 then
  print("  OVER BUDGET: " .. table.concat(over, ", "))
  os.exit(1)
end
print("  within budget")
