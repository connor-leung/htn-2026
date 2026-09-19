-- Drives the real main.lua: solo battles, then two badges duelling over a
-- deliberately unreliable fake radio.
package.path = "tools/?.lua;" .. package.path
local H = require("harness")

local fails = 0
local function check(cond, msg)
  if cond then return true end
  fails = fails + 1
  print("  FAIL: " .. msg)
  return false
end

local function tick(b, ms)
  for _ = 1, math.max(1, ms // 20) do
    b.now = b.now + 20
    b.env.on_tick()
  end
end

local function press(b, name)
  b.env.on_button(b.badge.input.BUTTON[name], b.badge.input.KIND.PRESSED)
end

local function has(b, pat) return b.screen():find(pat, 1, true) ~= nil end
local function verdict(b)
  if has(b, "You win") then return "win" end
  if has(b, "You lose") then return "lose" end
  -- graceful degradation: the link died, which is a terminal state too
  if has(b, "abandoned") or has(b, "Lost contact") then return "dropped" end
  return nil
end
local function bars(b)
  local out = {}
  for _, w in ipairs(b.all) do
    if w._kind == "bar" then out[#out + 1] = w end
  end
  return out[1], out[2]   -- foe bar, me bar (creation order in on_enter)
end

--------------------------------------------------------------------- solo --
print("== solo: play to a real conclusion, no forfeits ==")
local rounds_hist, wins, losses = {}, 0, 0
for trial = 1, 300 do
  local b = H.new("Connor", trial * 7 + 1)
  b.env.on_enter(b.root)
  press(b, "DOWN"); press(b, "A")          -- Solo practice
  check(has(b, "Lv"), "battle screen shows levels")

  local r = 0
  while r < 100 and not (has(b, "You win") or has(b, "You lose")) do
    press(b, "A")                          -- attack with the selected move
    tick(b, 800)                           -- let the resolve delay elapse
    r = r + 1
  end
  rounds_hist[#rounds_hist + 1] = r
  if has(b, "You win") then wins = wins + 1 end
  if has(b, "You lose") then losses = losses + 1 end
  check(has(b, "You win") or has(b, "You lose"),
    "trial " .. trial .. " reached a result (screen: " .. b.screen():sub(1, 90) .. ")")

  press(b, "B")                            -- back to menu: flushes the record
  check(b.store.gwin ~= nil and b.store.gloss ~= nil, "record written on leaving result")
  b.env.on_exit()
  check(next(b.leds) == nil, "LEDs cleared on exit")
end
local mn, mx, sum = 99, 0, 0
for _, v in ipairs(rounds_hist) do
  mn = math.min(mn, v); mx = math.max(mx, v); sum = sum + v
end
print(("  300 solo battles: %d won / %d lost, rounds min %d avg %.1f max %d")
  :format(wins, losses, mn, sum / #rounds_hist, mx))
check(wins > 0 and losses > 0, "both outcomes occur (game is not one-sided)")

--------------------------------------------------------- two-badge duel ----
print("\n== radio: two badges duel over a lossy link ==")

local function duel(seedA, seedB, drop, dup)
  local A = H.new("Connor", seedA)
  local B = H.new("Friend", seedB)
  A.env.on_enter(A.root); B.env.on_enter(B.root)
  press(A, "A"); press(B, "A")             -- menu item 1: Duel a nearby goose

  local rng = seedA + seedB
  local function rand(n) rng = (rng * 1103515245 + 12345) % 2147483648; return rng % n end

  local function deliver(from, to)
    local box = from.outbox
    from.outbox = {}
    for _, msg in ipairs(box) do
      if rand(100) >= drop then
        to.recv(from.badge.radio.mac(), -40, msg)
        if rand(100) < dup then to.recv(from.badge.radio.mac(), -40, msg) end
      end
    end
  end

  for step = 1, 4000 do
    tick(A, 20); tick(B, 20)
    deliver(A, B); deliver(B, A)
    -- Attack as soon as able, but never press A on a badge that has already
    -- finished: there, A restarts matchmaking instead of attacking.
    if step % 5 == 0 then
      if not verdict(A) then press(A, "A") end
      if not verdict(B) then press(B, "A") end
    end
    if verdict(A) and verdict(B) then break end
  end
  return A, B
end

local paired, consistent, mirrored = 0, 0, 0
local trials = 60
for t = 1, trials do
  local A, B = duel(t * 31 + 3, t * 97 + 11, 0, 0)
  local va, vb = verdict(A), verdict(B)
  if va and vb then
    paired = paired + 1
    if (va == "win" and vb == "lose") or (va == "lose" and vb == "win") then
      consistent = consistent + 1
    end
    local afoe, ame = bars(A)
    local bfoe, bme = bars(B)
    if ame._value == bfoe._value and afoe._value == bme._value then
      mirrored = mirrored + 1
    end
  end
end
print(("  clean link:  %d/%d duels finished, %d consistent winner, %d mirrored HP")
  :format(paired, trials, consistent, mirrored))
check(paired == trials, "every clean duel finishes")
check(consistent == trials, "exactly one winner per duel")
check(mirrored == trials, "both badges agree on both HP bars")

local p2, c2, m2, dropped = 0, 0, 0, 0
for t = 1, trials do
  local A, B = duel(t * 53 + 7, t * 71 + 13, 35, 20)   -- 35% loss, 20% dupes
  local va, vb = verdict(A), verdict(B)
  if va and vb then p2 = p2 + 1 end
  if va == "dropped" or vb == "dropped" then
    dropped = dropped + 1
    c2 = c2 + 1; m2 = m2 + 1     -- a dead link cannot contradict anything
  else
    if (va == "win" and vb == "lose") or (va == "lose" and vb == "win") then
      c2 = c2 + 1
    end
    local afoe, ame = bars(A)
    local bfoe, bme = bars(B)
    if ame._value == bfoe._value and afoe._value == bme._value then m2 = m2 + 1 end
  end
end
print(("  35%% loss + 20%% dupes: %d/%d reached a terminal state (%d link drops), %d consistent, %d mirrored")
  :format(p2, trials, dropped, c2, m2))
check(p2 == trials, "every duel reaches a terminal state, never a silent hang")
check(c2 == trials, "no contradictory winners under loss")
check(m2 == trials, "no HP desync under loss and duplication")

print(("\n%d failure(s)"):format(fails))
os.exit(fails == 0 and 0 or 1)
