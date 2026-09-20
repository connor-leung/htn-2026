-- Drives apps/goose_solo/main.lua: the single-badge build. Checks that
-- battles still terminate and save, and that the radio is genuinely gone -
-- nothing enables it, nothing transmits, and nothing holds the badge awake.
package.path = "tools/?.lua;" .. package.path
local H = require("harness")
H.source = "apps/goose_solo/main.lua"

local fails = 0
local function check(cond, msg)
  if cond then return true end
  fails = fails + 1
  print("  FAIL: " .. msg)
  return false
end
local function tick(b, ms)
  for _ = 1, math.max(1, ms // 20) do b.now = b.now + 20; b.env.on_tick() end
end
local function press(b, name)
  b.env.on_button(b.badge.input.BUTTON[name], b.badge.input.KIND.PRESSED)
end
local function has(b, pat) return b.screen():find(pat, 1, true) ~= nil end

print("== solo build: battles play to a conclusion ==")
local rounds, wins, losses = {}, 0, 0
for trial = 1, 300 do
  local b = H.new("Connor", trial * 7 + 1)
  b.env.on_enter(b.root)
  press(b, "A")                            -- menu item 1: Battle a wild goose
  check(has(b, "Lv"), "battle screen shows levels")

  local r = 0
  while r < 100 and not (has(b, "You win") or has(b, "You lose")) do
    press(b, "A")
    tick(b, 800)
    r = r + 1
  end
  rounds[#rounds + 1] = r
  if has(b, "You win") then wins = wins + 1 end
  if has(b, "You lose") then losses = losses + 1 end
  check(has(b, "You win") or has(b, "You lose"),
    "trial " .. trial .. " reached a result")

  press(b, "B")
  check(b.store.gwin ~= nil and b.store.gloss ~= nil, "record written")
  b.env.on_exit()
  check(next(b.leds) == nil, "LEDs cleared on exit")
end
local mn, mx, sum = 99, 0, 0
for _, v in ipairs(rounds) do
  mn = math.min(mn, v); mx = math.max(mx, v); sum = sum + v
end
print(string.format("  300 battles: %d won / %d lost, rounds min %d avg %.1f max %d",
  wins, losses, mn, sum / #rounds, mx))

print("\n== hot seat: two players, one badge ==")
for trial = 1, 60 do
  local b = H.new("Connor", trial * 13 + 5)
  b.env.on_enter(b.root)
  press(b, "DOWN"); press(b, "A")          -- menu item 2: Duel a friend
  check(has(b, "Campus Honker"), "the goose picker came up for player 2")
  press(b, "DOWN"); press(b, "A")          -- player 2 takes a different goose
  check(has(b, "Player 1"), "player 1 is asked first")

  local guard = 0
  while guard < 60 and not (has(b, "Player 1 wins") or has(b, "Player 2 wins")) do
    guard = guard + 1
    press(b, "A")                          -- player 1 commits
    if has(b, "Player 1 wins") or has(b, "Player 2 wins") then break end
    check(has(b, "Pass the badge"), "the badge is handed over")
    -- The whole point: player 2 must not be able to read player 1's choice.
    local screen = b.screen()
    check(not screen:find("Honk Blast", 1, true) and
          not screen:find("Wing Slap", 1, true),
      "no move list is visible during the hand-over")
    press(b, "A")                          -- player 2 takes the badge
    check(has(b, "Player 2: choose"), "player 2 is asked")
    press(b, "A")                          -- player 2 commits, turn resolves
    tick(b, 40)
  end
  check(has(b, "Player 1 wins") or has(b, "Player 2 wins"),
    "trial " .. trial .. " reached a winner")

  -- A friend's duel is not the badge owner's record.
  check(b.store.gwin == nil and b.store.gloss == nil,
    "a hot-seat duel does not touch the owner's win/loss record")
  press(b, "B")
  check(has(b, "Duel a friend"), "B returns to the menu")
  b.env.on_exit()
end
print("  60 hot-seat duels reached a winner, records untouched")

print("\n== the radio really is gone ==")
local b = H.new("Connor", 5)
b.env.on_enter(b.root)
for _ = 1, 3 do press(b, "DOWN") end       -- walk the whole menu
press(b, "A"); tick(b, 2000)               -- and into a battle
press(b, "A"); tick(b, 2000)
local sends = 0
for _ in pairs(b.outbox) do sends = sends + 1 end
check(sends == 0, "nothing is transmitted")
check(b.radio_up ~= true, "the radio is never enabled")
check(b.wake ~= true, "the badge is never held awake")
b.env.on_exit()
check(b.wake ~= true, "and is not left awake on exit")

print("\n" .. fails .. " failure(s)")
os.exit(fails == 0 and 0 or 1)
