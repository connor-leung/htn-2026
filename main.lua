-- Goose Duel - a Waterloo goose battler for the 2026 Hacker Badge.
--
-- MENU: UP/DOWN pick, A select.  PICK: arrows, A confirm, B back.
-- SEEK: B cancels.  BATTLE: arrows pick a move, A attack, B forfeit.
-- RESULT: A rematch, B menu.  HOME exits and saves.
--
-- Two badges duel over the radio. Neither sends HP or damage: both send only
-- the move they chose and compute the result from a shared seed, so dropped
-- or duplicated frames cannot desync the battle.

-- data
-- Parsed once at startup: fewer table constructors in the compiled chunk,
-- which is the real memory ceiling on this badge.

-- name,type,power   (type 1=Honk 2=Peck 3=Flap)
local MOVE_DATA =
  "Honk Blast,1,40;Wing Slap,3,35;Waddle Jab,2,30;Neck Lunge,2,45;" ..
  "Gust Dash,3,42;Feather Flick,3,28;Hiss,1,32;Bread Snatch,2,38;" ..
  "Belly Flop,2,50;Nest Guard,2,25;Alpha Screech,1,55;Dive Bomb,3,48"

-- name,type,hp,atk,def,spd,move1,move2,move3,move4
local GOOSE_DATA =
  "Campus Honker,1,58,14,12,11,1,2,3,4;" ..
  "Ring Road Runner,3,48,15,9,17,5,6,3,7;" ..
  "Bread Baron,2,68,12,16,7,8,9,10,4;" ..
  "Alpha Gander,1,50,18,9,13,11,2,12,7"

local TYPE_NAME = { "Honk", "Peck", "Flap" }
local TYPE_RGB = { { 255, 80, 200 }, { 255, 150, 0 }, { 0, 190, 255 } }

local MOVES = {}
local GEESE = {}

local function split(s, sep)
  local out = {}
  for field in string.gmatch(s, "([^" .. sep .. "]+)") do
    out[#out + 1] = field
  end
  return out
end

local function load_data()
  local recs = split(MOVE_DATA, ";")
  for i = 1, #recs do
    local f = split(recs[i], ",")
    MOVES[i] = { name = f[1], ty = tonumber(f[2]), pow = tonumber(f[3]) }
  end
  recs = split(GOOSE_DATA, ";")
  for i = 1, #recs do
    local f = split(recs[i], ",")
    GEESE[i] = {
      name = f[1], ty = tonumber(f[2]),
      hp = tonumber(f[3]), atk = tonumber(f[4]),
      def = tonumber(f[5]), spd = tonumber(f[6]),
      moves = { tonumber(f[7]), tonumber(f[8]), tonumber(f[9]), tonumber(f[10]) },
    }
  end
end

-- state
local ST_MENU, ST_PICK, ST_SEEK, ST_BATTLE, ST_RESULT = 1, 2, 3, 4, 5

local ui = {}
local st = ST_MENU
local menu_sel = 1
local pick_sel = 1
local move_sel = 1

local save = { species = 1, level = 1, xp = 0, wins = 0, losses = 0 }
local dirty = false

local me, foe            -- live combatants
local is_radio = false   -- radio duel vs solo practice
local turn = 1
local my_move, foe_move
-- Move played on the turn just resolved: a peer that missed it would wait
-- forever, since we only ever retransmit the current turn.
local prev_turn, prev_move
local resolve_at = 0     -- solo: delay before showing the exchange
local outcome = 0        -- 1 win, -1 loss, 0 undecided

-- radio session
local radio_on = false
local my_id, peer_id, seed, host
local peer_confirmed = false
local last_rx = 0
local next_beacon = 0
local next_move_tx = 0

-- shared PRNG: small enough to be exact in any number representation, so both
-- badges always produce the same rolls.
local rng = 1
local function rnd(n)
  rng = (rng * 75 + 74) % 65537
  return rng % n
end

-- LED animation. The six LEDs are the largest battery draw in the app, so
-- every colour is scaled by the chosen level before it reaches the strip, and
-- the strip is blanked entirely when nothing is happening.
local LED_STEP = { 0, 60, 140, 255 }
local LED_NAME = { "Off", "Low", "Med", "Full" }
local led_level = 2
local led_at = 0
local led_scale = 255
local led_blank = false
local last_input = 0
local flash_until, flash_side, flash_rgb = 0, 0, nil

local function ledset(i, r, g, b)
  badge.led.set(i, r * led_scale // 255, g * led_scale // 255,
    b * led_scale // 255)
end

local function ledall(r, g, b)
  for i = 1, 6 do ledset(i, r, g, b) end
end

-- combat
local function make_fighter(species, level, who)
  local g = GEESE[species]
  local l = level - 1
  local max = g.hp + l * 4
  return {
    sp = species, level = level, name = g.name, ty = g.ty,
    hp = max, max = max,
    atk = g.atk + l * 2, def = g.def + l * 2, spd = g.spd + l,
    moves = g.moves, who = who,
  }
end

-- 1 = super effective, -1 = resisted, 0 = neutral. Honk > Flap > Peck > Honk.
local function effect(atk_ty, def_ty)
  if (atk_ty == 1 and def_ty == 3) or (atk_ty == 3 and def_ty == 2) or
     (atk_ty == 2 and def_ty == 1) then
    return 1
  elseif (atk_ty == 3 and def_ty == 1) or (atk_ty == 2 and def_ty == 3) or
         (atk_ty == 1 and def_ty == 2) then
    return -1
  end
  return 0
end

local function damage(att, def, mv)
  local m = MOVES[mv]
  local raw = (m.pow * att.atk) // (def.def * 8) + 2
  local e = effect(m.ty, def.ty)
  if e == 1 then
    raw = raw * 3 // 2
  elseif e == -1 then
    raw = raw * 2 // 3
  end
  raw = raw * (85 + rnd(16)) // 100
  if raw < 1 then raw = 1 end
  return raw, e
end

local function eff_word(e)
  if e == 1 then return " (strong!)" end
  if e == -1 then return " (weak)" end
  return ""
end

-- display
local function hp_rgb(frac)
  if frac > 0.5 then return 0, 200, 40 end
  if frac > 0.2 then return 255, 150, 0 end
  return 255, 40, 0
end

local function set_screen()
  ui.menu:hidden(st ~= ST_MENU)
  ui.pick:hidden(st ~= ST_PICK)
  ui.battle:hidden(st ~= ST_BATTLE and st ~= ST_RESULT and st ~= ST_SEEK)
end

local function render_menu()
  local items = { "Duel a nearby goose", "Solo practice", "Choose your goose" }
  for i = 1, 3 do
    local mark = (i == menu_sel) and "> " or "  "
    ui.menu_item[i]:set_text(mark .. items[i])
    ui.menu_item[i]:set_color(i == menu_sel and 0xffffff or 0x8a93a0)
  end
  local g = GEESE[save.species]
  ui.menu_you:set_text(g.name .. "  Lv" .. save.level ..
    "  W" .. save.wins .. " L" .. save.losses ..
    "   LEDs " .. LED_NAME[led_level])
end

local function render_pick()
  for i = 1, 4 do
    local g = GEESE[i]
    local mark = (i == pick_sel) and "> " or "  "
    ui.pick_item[i]:set_text(mark .. g.name .. " (" .. TYPE_NAME[g.ty] .. ")")
    ui.pick_item[i]:set_color(i == pick_sel and 0xffffff or 0x8a93a0)
  end
  local g = GEESE[pick_sel]
  ui.pick_stat:set_text("HP " .. g.hp .. "  ATK " .. g.atk ..
    "  DEF " .. g.def .. "  SPD " .. g.spd)
end

local function render_moves()
  local hide = (st ~= ST_BATTLE) or (my_move ~= nil)
  for i = 1, 4 do
    local lbl = ui.move[i]
    if not me then
      lbl:set_text("")
    else
      local m = MOVES[me.moves[i]]
      local mark = (i == move_sel and not hide) and ">" or " "
      -- "Honk Blast H40": type initial + power, readable against the tags.
      lbl:set_text(mark .. m.name .. " " ..
        string.sub(TYPE_NAME[m.ty], 1, 1) .. m.pow)
      lbl:set_color((i == move_sel and not hide) and 0xffffff or 0x8a93a0)
    end
  end
end

local function render_bars()
  if not me or not foe then return end
  -- Type on screen: move choice is worth 2x+ the win rate, so it must show.
  ui.foe_name:set_text(foe.name .. " Lv" .. foe.level ..
    " [" .. TYPE_NAME[foe.ty] .. "]")
  ui.foe_bar:set_value(foe.hp * 100 // foe.max)
  ui.me_name:set_text(me.name .. " Lv" .. me.level ..
    " [" .. TYPE_NAME[me.ty] .. "]")
  ui.me_bar:set_value(me.hp * 100 // me.max)
  ui.me_hp:set_text(me.hp .. "/" .. me.max)
  ui.foe_hp:set_text(foe.hp .. "/" .. foe.max)
end

local function say(text)
  ui.log:set_text(text)
end

local function status(text)
  ui.status:set_text(text)
end

-- persist
local function load_save()
  save.species = badge.store.get_int("gsp", 1)
  save.level = badge.store.get_int("glvl", 1)
  save.xp = badge.store.get_int("gxp", 0)
  save.wins = badge.store.get_int("gwin", 0)
  save.losses = badge.store.get_int("gloss", 0)
  led_level = badge.store.get_int("gled", 2)
  if led_level < 1 or led_level > 4 then led_level = 2 end
  if save.species < 1 or save.species > #GEESE then save.species = 1 end
  if save.level < 1 then save.level = 1 end
end

local function flush_save()
  if not dirty then return end
  badge.store.set_int("gsp", save.species)
  badge.store.set_int("glvl", save.level)
  badge.store.set_int("gxp", save.xp)
  badge.store.set_int("gwin", save.wins)
  badge.store.set_int("gloss", save.losses)
  badge.store.set_int("gled", led_level)
  dirty = false
end

-- radio
local function radio_send(msg)
  if radio_on then badge.radio.send(msg) end
end

local function radio_stop()
  -- Releasing the wake lock is the single biggest battery win: the badge can
  -- sleep normally everywhere except inside a live duel.
  badge.sys.wake_lock(false)
  if radio_on then
    -- Only announce a bye if we are walking out of a duel that never finished.
    if outcome == 0 then radio_send("GG1:B:" .. my_id) end
    badge.radio.on_recv(nil)
    badge.radio.disable()
    radio_on = false
  end
  peer_id, peer_confirmed = nil, false
end

local function start_battle(foe_species, foe_level)
  me = make_fighter(save.species, save.level, 1)
  foe = make_fighter(foe_species, foe_level, 2)
  turn = 1
  my_move, foe_move = nil, nil
  prev_turn, prev_move = nil, nil
  outcome = 0
  move_sel = 1
  st = ST_BATTLE
  set_screen()
  render_bars()
  render_moves()
  say("A wild duel begins!")
  status(is_radio and "Your move" or "Practice - your move")
end

local function on_radio(mac, rssi, payload)
  if st ~= ST_SEEK and st ~= ST_BATTLE then return end
  if string.sub(payload, 1, 4) ~= "GG1:" then return end
  local f = split(payload, ":")
  local kind, sender = f[2], f[3]
  if not kind or not sender or sender == my_id then return end
  -- Any peer frame counts as contact, keepalives included: otherwise a long
  -- think reads as a dropped link.
  if sender == peer_id then last_rx = badge.sys.ms() end

  if kind == "H" and st == ST_SEEK and not peer_id then
    -- Lower id hosts. That is a tie-break both badges compute identically,
    -- so no negotiation round trip is needed.
    peer_id = sender
    host = my_id < peer_id
    last_rx = badge.sys.ms()
    if host then
      seed = badge.sys.random(65536)
      rng = seed % 65537
      is_radio = true
      next_beacon = 0   -- offer the pairing on the very next tick
      start_battle(tonumber(f[4]) or 1, tonumber(f[5]) or 1)
      status("Opponent found - your move")
    else
      status("Opponent found - linking")
    end
    return
  end

  if kind == "P" and st == ST_SEEK and f[4] == my_id then
    peer_id = sender
    host = false
    seed = tonumber(f[5]) or 1
    rng = seed % 65537
    last_rx = badge.sys.ms()
    is_radio = true
    start_battle(tonumber(f[6]) or 1, tonumber(f[7]) or 1)
    peer_confirmed = true
    return
  end

  if kind == "M" and (st == ST_BATTLE or st == ST_RESULT) and
     sender == peer_id then
    peer_confirmed = true
    last_rx = badge.sys.ms()
    local t = tonumber(f[4])
    if t == turn and not foe_move and st == ST_BATTLE then
      foe_move = tonumber(f[5])
    elseif t == prev_turn and prev_move then
      -- The peer is a turn behind: it is still asking for the move we already
      -- played. Answer from history so it can resolve and catch up.
      radio_send("GG1:M:" .. my_id .. ":" .. prev_turn .. ":" .. prev_move)
    end
    return
  end

  if kind == "B" and sender == peer_id then
    last_rx = badge.sys.ms()
    if st == ST_BATTLE and outcome == 0 then
      outcome = 1
      save.wins = save.wins + 1
      dirty = true
      st = ST_RESULT
      say("Opponent left the duel.")
      status("You win by forfeit. A rematch, B menu")
      -- No flash write here either: this runs on the shared tick budget.
    end
  end
end

-- turns
local function gain_xp(amount)
  save.xp = save.xp + amount
  while save.level < 50 and save.xp >= save.level * 20 do
    save.xp = save.xp - save.level * 20
    save.level = save.level + 1
  end
  dirty = true
end

local function finish(won)
  outcome = won and 1 or -1
  st = ST_RESULT
  if won then
    save.wins = save.wins + 1
    gain_xp(10 + foe.level * 2)
    say(foe.name .. " is out of feathers!")
    status("You win! Lv" .. save.level .. ". A rematch, B menu")
  else
    save.losses = save.losses + 1
    gain_xp(3)
    say(me.name .. " retreats to the pond.")
    status("You lose. A rematch, B menu")
  end
  dirty = true
  -- Not saved here: finish() is reachable from on_tick's 250 ms budget. The
  -- write happens on the first result-screen press, or on_exit.
  -- No "bye" on a normal finish either: bye means "I quit" and the peer takes
  -- it as a win, which would hand a win to someone who actually lost but had
  -- not resolved the last turn. We answer their catch-up requests instead.
end

local function forfeit()
  if is_radio then radio_send("GG1:B:" .. my_id) end
  finish(false)
end

local function strike(att, def, mv, label)
  if att.hp <= 0 or def.hp <= 0 then return end
  local dmg, e = damage(att, def, mv)
  def.hp = def.hp - dmg
  if def.hp < 0 then def.hp = 0 end
  flash_until = badge.sys.ms() + 260
  flash_side = def.who
  flash_rgb = TYPE_RGB[MOVES[mv].ty]
  say(label .. " " .. MOVES[mv].name .. " for " .. dmg .. eff_word(e))
end

local function resolve()
  local mine, theirs = me.moves[my_move], foe.moves[foe_move]
  local me_first
  if me.spd ~= foe.spd then
    me_first = me.spd > foe.spd
  else
    -- Both badges draw the same number, so this must resolve to a fixed
    -- player: "me" would make each badge think it goes first.
    me_first = (rnd(2) == 0) == (host ~= false)
  end

  if me_first then
    strike(me, foe, mine, "You:")
    strike(foe, me, theirs, "Foe:")
  else
    strike(foe, me, theirs, "Foe:")
    strike(me, foe, mine, "You:")
  end

  render_bars()
  prev_turn, prev_move = turn, my_move
  turn = turn + 1
  my_move, foe_move = nil, nil

  if foe.hp <= 0 then
    finish(true)
  elseif me.hp <= 0 then
    finish(false)
  else
    status(is_radio and "Your move" or "Practice - your move")
  end
  render_moves()
end

local function cpu_move()
  -- Half the time it plays the best matchup, half the time it just picks.
  -- Always-optimal made practice mode punishing rather than encouraging.
  if badge.sys.random(10) < 5 then return badge.sys.random(4) + 1 end
  local best, best_score = 1, -1
  for i = 1, 4 do
    local m = MOVES[foe.moves[i]]
    local score = m.pow + effect(m.ty, me.ty) * 20
    if score > best_score then best, best_score = i, score end
  end
  return best
end

-- ----------------------------------------------------------------- LEDs --
local function led_column(base, frac, r, g, b)
  local lit = frac * 3
  for i = 1, 3 do
    if lit >= i - 0.34 then
      ledset(base[i], r, g, b)
    end
  end
end

local LEFT = { 1, 6, 5 }    -- your side, matching the screen
local RIGHT = { 2, 3, 4 }   -- opponent side
local RING = { 1, 2, 3, 4, 5, 6 }

local function draw_leds(now)
  -- 90 ms rather than 50: still smooth for fades and chases, ~45% fewer
  -- strip writes and wakeups.
  if now - led_at < 90 then return end
  led_at = now

  led_scale = LED_STEP[led_level]
  -- Idle on a menu is the common "left in a pocket" case: blank the strip
  -- rather than breathing at it for hours.
  if (st == ST_MENU or st == ST_PICK) and now - last_input > 20000 then
    led_scale = 0
  end
  if led_scale == 0 then
    if not led_blank then
      badge.led.clear()
      badge.led.show()
      led_blank = true
    end
    return
  end
  led_blank = false
  badge.led.clear()

  if st == ST_MENU or st == ST_PICK then
    local sp = (st == ST_PICK) and pick_sel or save.species
    local c = TYPE_RGB[GEESE[sp].ty]
    -- triangle-wave breathing, no float math needed beyond the scale
    local phase = now % 2400
    if phase > 1200 then phase = 2400 - phase end
    local k = phase * 255 // 1200
    ledall(c[1] * k // 255, c[2] * k // 255, c[3] * k // 255)
  elseif st == ST_SEEK then
    local step = (now // 150) % 6 + 1
    ledset(RING[step], 0, 180, 255)
    local trail = (step == 1) and 6 or step - 1
    ledset(RING[trail], 0, 50, 90)
  elseif me and foe then
    if st == ST_RESULT and outcome == 1 then
      local step = (now // 120) % 6 + 1
      ledset(RING[step], 255, 200, 0)
      ledset(RING[(step % 6) + 1], 90, 70, 0)
    elseif st == ST_RESULT then
      local phase = now % 1600
      if phase > 800 then phase = 1600 - phase end
      local k = phase * 160 // 800
      ledall(k, 0, 0)
    else
      local mf = me.hp / me.max
      local ff = foe.hp / foe.max
      local r, g, b = hp_rgb(mf)
      led_column(LEFT, mf, r, g, b)
      r, g, b = hp_rgb(ff)
      led_column(RIGHT, ff, r, g, b)
    end
    if now < flash_until and flash_rgb then
      local side = (flash_side == 1) and LEFT or RIGHT
      for i = 1, 3 do
        ledset(side[i], flash_rgb[1], flash_rgb[2], flash_rgb[3])
      end
    end
  end

  badge.led.show()
end

-- lifecycle
local function go_menu()
  radio_stop()
  st = ST_MENU
  me, foe = nil, nil
  is_radio = false
  set_screen()
  render_menu()
end

local function begin_seek()
  my_id = string.format("%04x", badge.sys.random(65536))
  peer_id, peer_confirmed, host, seed = nil, false, nil, nil
  -- On a rematch the radio is already up. Re-enabling would race the deferred
  -- ~2 s BLE teardown, so only enable when it is actually off.
  if not radio_on then radio_on = badge.radio.enable() end
  if not radio_on then
    status("Radio unavailable - try Solo practice")
    st = ST_MENU
    set_screen()
    render_menu()
    say("Radio would not start. Reboot and retry.")
    return
  end
  badge.radio.on_recv(on_radio)
  -- Held from the search through the duel: the badge cannot pair or take a
  -- turn while asleep. radio_stop() releases it, and the search gives up
  -- after 60 s, so this is always bounded.
  badge.sys.wake_lock(true)
  st = ST_SEEK
  last_rx = badge.sys.ms()
  next_beacon = 0
  me = make_fighter(save.species, save.level, 1)
  foe = nil
  set_screen()
  ui.foe_name:set_text("Looking for a goose...")
  ui.foe_hp:set_text("")
  ui.foe_bar:set_value(0)
  ui.me_name:set_text(me.name .. " Lv" .. me.level)
  ui.me_bar:set_value(100)
  ui.me_hp:set_text(me.hp .. "/" .. me.max)
  render_moves()
  say("Open Goose Duel on the other badge.")
  status("Searching nearby. B cancels.")
end

-- One label helper: the widget setup is otherwise the largest block of
-- repeated constructors in the compiled chunk.
local function lbl(parent, text, color, small, where, dx, dy)
  local l = badge.ui.label(parent, text)
  if small then l:set_font_size("small") end
  if color then l:set_color(color) end
  l:align(where, dx, dy)
  return l
end

local function hp_bar(parent, y, fill)
  local b = badge.ui.bar(parent, 0, 100, 100)
  b:set_size(296, 10)
  b:align("top_mid", 0, y)
  b:style({ bg_color = 0x2b3340 })
  b:style({ bg_color = fill }, "indicator")
  return b
end

local function panel(parent)
  local p = badge.ui.box{ parent = parent, w = 320, h = 200, bg_opa = 0 }
  p:align("bottom_mid", 0, 0)
  return p
end

function on_enter(root)
  load_data()
  load_save()

  local bg = badge.ui.box{ parent = root, w = 320, h = 240, bg_color = 0x0d1117 }
  bg:align("center", 0, 0)
  local title = badge.ui.label(bg, "GOOSE DUEL")
  title:set_font_size("large")
  title:set_color(0xffc400)
  title:align("top_mid", 0, 8)

  ui.menu = panel(bg)
  ui.menu_item = {}
  for i = 1, 3 do
    ui.menu_item[i] = lbl(ui.menu, "", nil, false, "top_left", 40, 30 + (i - 1) * 26)
  end
  ui.menu_you = lbl(ui.menu, "", 0x6ee7a0, true, "bottom_mid", 0, -34)
  lbl(ui.menu, "UP/DOWN choose  A select  L/R LEDs  HOME exit", 0x6b7280, true,
    "bottom_mid", 0, -10)

  ui.pick = panel(bg)
  ui.pick_item = {}
  for i = 1, 4 do
    ui.pick_item[i] = lbl(ui.pick, "", nil, false, "top_left", 28, 22 + (i - 1) * 24)
  end
  ui.pick_stat = lbl(ui.pick, "", 0x6ee7a0, true, "bottom_mid", 0, -34)
  lbl(ui.pick, "Arrows choose   A confirm   B back", 0x6b7280, true,
    "bottom_mid", 0, -10)

  ui.battle = panel(bg)
  ui.foe_name = lbl(ui.battle, "", nil, false, "top_left", 12, 6)
  ui.foe_hp = lbl(ui.battle, "", nil, true, "top_right", -12, 8)
  ui.foe_bar = hp_bar(ui.battle, 26, 0xff5a3c)
  ui.me_name = lbl(ui.battle, "", nil, false, "top_left", 12, 44)
  ui.me_hp = lbl(ui.battle, "", nil, true, "top_right", -12, 46)
  ui.me_bar = hp_bar(ui.battle, 64, 0x35d07f)
  ui.log = lbl(ui.battle, "", 0xe5e7eb, true, "top_mid", 0, 84)

  ui.move = {}
  for i = 1, 4 do
    ui.move[i] = lbl(ui.battle, "", nil, true, "top_left",
      ((i - 1) % 2 == 0) and 16 or 168, 106 + ((i - 1) // 2) * 22)
  end
  ui.status = lbl(ui.battle, "", 0x6b7280, true, "bottom_mid", 0, -10)

  go_menu()
end

function on_tick()
  local now = badge.sys.ms()

  if st == ST_SEEK then
    if now >= next_beacon then
      next_beacon = now + 500
      radio_send("GG1:H:" .. my_id .. ":" .. save.species .. ":" .. save.level)
    end
    -- Advertising forever in a bag is pure drain: give up and drop the radio.
    if now - last_rx > 60000 then
      go_menu()
      say("No goose nearby. Radio off to save battery.")
      status("A to search again.")
    end
  elseif st == ST_BATTLE and is_radio then
    -- The host keeps offering the pairing until the peer's first move proves
    -- it arrived; after that only move frames are retransmitted.
    if host and not peer_confirmed and now >= next_beacon then
      next_beacon = now + 500
      -- %d so the seed cannot cross the link in a float spelling: both badges
      -- must start the shared PRNG from a bit-identical value.
      radio_send("GG1:P:" .. my_id .. ":" .. peer_id ..
        ":" .. string.format("%d", seed) ..
        ":" .. save.species .. ":" .. save.level)
    end
    if now >= next_move_tx then
      if my_move and not foe_move then
        -- Retransmission is the whole loss-recovery mechanism: keep offering
        -- this turn's move until the peer's move for the same turn arrives.
        next_move_tx = now + 300
        radio_send("GG1:M:" .. my_id .. ":" .. turn .. ":" .. my_move)
      elseif not my_move then
        next_move_tx = now + 2000
        radio_send("GG1:K:" .. my_id)
      end
    end
    if my_move and foe_move then
      resolve()
    end
    if now - last_rx > 15000 and outcome == 0 then
      outcome = -1
      st = ST_RESULT
      say("Lost contact with the other badge.")
      status("Duel abandoned. A rematch, B menu")
    end
  elseif st == ST_BATTLE and my_move and resolve_at > 0 and now >= resolve_at then
    resolve_at = 0
    foe_move = cpu_move()
    resolve()
  end

  draw_leds(now)
end

local function choose_move()
  if my_move then return end
  my_move = move_sel
  render_moves()
  if is_radio then
    next_move_tx = 0
    status("Move sent - waiting for the other goose")
  else
    resolve_at = badge.sys.ms() + 450
    status("...")
  end
end

function on_button(button, kind)
  if kind ~= badge.input.KIND.PRESSED then return end
  last_input = badge.sys.ms()
  led_blank = false
  local B = badge.input.BUTTON

  if st == ST_MENU then
    if button == B.UP then
      menu_sel = (menu_sel == 1) and 3 or menu_sel - 1
      render_menu()
    elseif button == B.DOWN then
      menu_sel = (menu_sel == 3) and 1 or menu_sel + 1
      render_menu()
    elseif button == B.LEFT or button == B.RIGHT then
      if button == B.RIGHT then
        led_level = (led_level == 4) and 1 or led_level + 1
      else
        led_level = (led_level == 1) and 4 or led_level - 1
      end
      dirty = true
      render_menu()
    elseif button == B.A then
      if menu_sel == 1 then
        begin_seek()
      elseif menu_sel == 2 then
        is_radio = false
        rng = badge.sys.random(65536) % 65537
        start_battle(badge.sys.random(#GEESE) + 1,
          save.level > 2 and save.level - 1 or 1)
      else
        pick_sel = save.species
        st = ST_PICK
        set_screen()
        render_pick()
      end
    end

  elseif st == ST_PICK then
    if button == B.UP or button == B.LEFT then
      pick_sel = (pick_sel == 1) and #GEESE or pick_sel - 1
      render_pick()
    elseif button == B.DOWN or button == B.RIGHT then
      pick_sel = (pick_sel == #GEESE) and 1 or pick_sel + 1
      render_pick()
    elseif button == B.A then
      save.species = pick_sel
      dirty = true
      flush_save()
      go_menu()
    elseif button == B.B then
      go_menu()
    end

  elseif st == ST_SEEK then
    if button == B.B then go_menu() end

  elseif st == ST_BATTLE then
    -- Forfeit stays available after committing a move, so a vanished opponent
    -- does not trap you until the contact timeout fires.
    if button == B.B then
      forfeit()
      return
    end
    if my_move then return end
    if button == B.LEFT then
      move_sel = (move_sel == 1) and 4 or move_sel - 1
      render_moves()
    elseif button == B.RIGHT then
      move_sel = (move_sel == 4) and 1 or move_sel + 1
      render_moves()
    elseif button == B.UP or button == B.DOWN then
      move_sel = ((move_sel + 1) % 4) + 1
      render_moves()
    elseif button == B.A then
      choose_move()
    end

  elseif st == ST_RESULT then
    flush_save()   -- the battle's record lands here, on the button budget
    if button == B.A then
      if is_radio then
        begin_seek()
      else
        rng = badge.sys.random(65536) % 65537
        start_battle(badge.sys.random(#GEESE) + 1,
          save.level > 2 and save.level - 1 or 1)
      end
    elseif button == B.B then
      go_menu()
    end
  end
end

function on_exit()
  radio_stop()
  flush_save()
  badge.led.clear()
  badge.led.show()
end
