--[==[badge-app
slug=goose_solo
name=Goose Solo
icon=G1
api=2
heap_kb=96
]==]

local MOVE_DATA =
"Honk Blast,1,40;Wing Slap,3,35;Waddle Jab,2,30;Neck Lunge,2,45;" ..
"Gust Dash,3,42;Feather Flick,3,28;Hiss,1,32;Bread Snatch,2,38;" ..
"Belly Flop,2,50;Nest Guard,2,25;Alpha Screech,1,55;Dive Bomb,3,48"
local GOOSE_DATA =
"Campus Honker,1,58,14,12,11,1,2,3,4;" ..
"Ring Road Runner,3,48,15,9,17,5,6,3,7;" ..
"Bread Baron,2,68,12,16,7,8,9,10,4;" ..
"Alpha Gander,1,50,18,9,13,11,2,12,7"
local TYPE_NAME = { "Honk", "Peck", "Flap" }
local TYPE_RGB = { { 60, 19, 47 }, { 60, 35, 0 }, { 0, 45, 60 } }
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
local ST_MENU, ST_PICK, ST_BATTLE, ST_RESULT, ST_PASS = 1, 2, 3, 4, 5
local ui = {}
local st = ST_MENU
local menu_sel = 1
local pick_sel = 1
local move_sel = 1
local save = { species = 1, level = 1, xp = 0, wins = 0, losses = 0 }
local dirty = false
local me, foe
local hotseat = false
local active = 1
local picking_p2 = false
local turn = 1
local my_move, foe_move
local resolve_at = 0
local outcome = 0
local rng = 1
local function rnd(n)
rng = (rng * 75 + 74) % 65537
return rng % n
end
local led_at = 0
local led_blank = false
local last_input = 0
local flash_until, flash_side, flash_rgb = 0, 0, nil
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
local function set_screen()
ui.menu:hidden(st ~= ST_MENU)
ui.pick:hidden(st ~= ST_PICK)
ui.battle:hidden(st ~= ST_BATTLE and st ~= ST_RESULT and st ~= ST_PASS)
end
local MENU = { "Battle a wild goose", "Duel a friend", "Choose your goose" }
local function render_menu()
local items = MENU
for i = 1, 3 do
local mark = (i == menu_sel) and "> " or "  "
ui.menu_item[i]:set_text(mark .. items[i])
ui.menu_item[i]:set_color(i == menu_sel and 0xffffff or 0x8a93a0)
end
local g = GEESE[save.species]
ui.menu_you:set_text(g.name .. "  Lv" .. save.level ..
"  W" .. save.wins .. " L" .. save.losses)
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
local f = (st == ST_PASS) and nil
or ((hotseat and active == 2) and foe or me)
local hide = (st ~= ST_BATTLE) or (not hotseat and my_move ~= nil)
for i = 1, 4 do
local lbl = ui.move[i]
if not f then
lbl:set_text("")
else
local m = MOVES[f.moves[i]]
local mark = (i == move_sel and not hide) and ">" or " "
lbl:set_text(mark .. m.name .. " " .. m.pow)
lbl:set_color((i == move_sel and not hide) and 0xffffff or 0x8a93a0)
end
end
end
local function render_bars()
if not me or not foe then return end
ui.foe_name:set_text((hotseat and "P2 " or "") .. foe.name .. " Lv" .. foe.level)
ui.foe_bar:set_value(foe.hp * 100 // foe.max)
ui.me_name:set_text((hotseat and "P1 " or "") .. me.name .. " Lv" .. me.level)
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
local function load_save()
save.species = badge.store.get_int("gsp", 1)
save.level = badge.store.get_int("glvl", 1)
save.xp = badge.store.get_int("gxp", 0)
save.wins = badge.store.get_int("gwin", 0)
save.losses = badge.store.get_int("gloss", 0)
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
dirty = false
end
local function start_battle(foe_species, foe_level)
me = make_fighter(save.species, save.level, 1)
foe = make_fighter(foe_species, foe_level, 2)
turn = 1
my_move, foe_move = nil, nil
outcome = 0
move_sel = 1
active = 1
st = ST_BATTLE
set_screen()
render_bars()
render_moves()
say(hotseat and "Two geese, one badge." or "A wild duel begins!")
status(hotseat and "Player 1: choose a move" or "Your move")
end
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
if hotseat then
local n = won and 1 or 2
say((won and foe.name or me.name) .. " is out of feathers!")
status("Player " .. n .. " wins!  A rematch, B menu")
return
end
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
end
local function strike(att, def, mv, label)
if att.hp <= 0 or def.hp <= 0 then return end
local dmg, e = damage(att, def, mv)
def.hp = def.hp - dmg
if def.hp < 0 then def.hp = 0 end
flash_until = badge.sys.ms() + 260
flash_side = def.who
flash_rgb = TYPE_RGB[MOVES[mv].ty]
say(label .. " " .. MOVES[mv].name .. " for " .. dmg ..
((e == 1) and " (strong!)" or (e == -1) and " (weak)" or ""))
end
local function resolve()
local mine, theirs = me.moves[my_move], foe.moves[foe_move]
local me_first
if me.spd ~= foe.spd then
me_first = me.spd > foe.spd
else
me_first = rnd(2) == 0
end
local a, b = "You:", "Foe:"
if hotseat then a, b = "P1:", "P2:" end
if me_first then
strike(me, foe, mine, a)
strike(foe, me, theirs, b)
else
strike(foe, me, theirs, b)
strike(me, foe, mine, a)
end
render_bars()
turn = turn + 1
my_move, foe_move = nil, nil
active = 1
if foe.hp <= 0 then
finish(true)
elseif me.hp <= 0 then
finish(false)
else
status(hotseat and "Player 1: choose a move" or "Your move")
end
render_moves()
end
local function cpu_move()
if badge.sys.random(10) < 3 then return badge.sys.random(4) + 1 end
local best, best_score = 1, -1
for i = 1, 4 do
local m = MOVES[foe.moves[i]]
local score = m.pow + effect(m.ty, me.ty) * 20
if score > best_score then best, best_score = i, score end
end
return best
end
local function led_column(base, frac)
local r, g, b = 60, 9, 0
if frac > 0.5 then r, g, b = 0, 47, 9
elseif frac > 0.2 then r, g, b = 60, 35, 0 end
local lit = frac * 3
for i = 1, 3 do
if lit >= i - 0.34 then
badge.led.set(base[i], r, g, b)
end
end
end
local LEFT = { 1, 6, 5 }
local RIGHT = { 2, 3, 4 }
local RING = { 1, 2, 3, 4, 5, 6 }
local function draw_leds(now)
if now - led_at < 90 then return end
led_at = now
if (st == ST_MENU or st == ST_PICK) and now - last_input > 20000 then
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
local phase = now % 2400
if phase > 1200 then phase = 2400 - phase end
local k = phase * 255 // 1200
badge.led.set_all(c[1] * k // 255, c[2] * k // 255, c[3] * k // 255)
elseif me and foe then
if st == ST_RESULT and outcome == 1 then
local step = (now // 120) % 6 + 1
badge.led.set(RING[step], 60, 47, 0)
badge.led.set(RING[(step % 6) + 1], 21, 16, 0)
elseif st == ST_RESULT then
local phase = now % 1600
if phase > 800 then phase = 1600 - phase end
badge.led.set_all(phase * 38 // 800, 0, 0)
else
led_column(LEFT, me.hp / me.max)
led_column(RIGHT, foe.hp / foe.max)
end
if now < flash_until and flash_rgb then
local side = (flash_side == 1) and LEFT or RIGHT
for i = 1, 3 do
badge.led.set(side[i], flash_rgb[1], flash_rgb[2], flash_rgb[3])
end
end
end
badge.led.show()
end
local function go_menu()
st = ST_MENU
me, foe = nil, nil
hotseat, picking_p2 = false, false
set_screen()
render_menu()
end
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
lbl(ui.menu, "UP/DOWN choose   A select   HOME exit", 0x6b7280, true,
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
if st == ST_BATTLE and my_move and resolve_at > 0 and now >= resolve_at then
resolve_at = 0
foe_move = cpu_move()
resolve()
end
draw_leds(now)
end
local function choose_move()
if hotseat then
if active == 1 then
my_move = move_sel
active = 2
move_sel = 1
st = ST_PASS
render_moves()
say("Player 1 has chosen.")
status("Pass the badge to Player 2, then press A")
else
foe_move = move_sel
st = ST_BATTLE
resolve()
end
return
end
if my_move then return end
my_move = move_sel
render_moves()
resolve_at = badge.sys.ms() + 450
status("...")
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
elseif button == B.A then
if menu_sel == 1 then
hotseat = false
rng = badge.sys.random(65536) % 65537
start_battle(badge.sys.random(#GEESE) + 1,
save.level > 2 and save.level - 1 or 1)
else
picking_p2 = (menu_sel == 2)
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
if picking_p2 then
hotseat = true
rng = badge.sys.random(65536) % 65537
start_battle(pick_sel, save.level)
else
save.species = pick_sel
dirty = true
flush_save()
go_menu()
end
elseif button == B.B then
go_menu()
end
elseif st == ST_PASS then
if button == B.A then
st = ST_BATTLE
render_moves()
say("")
status("Player 2: choose a move")
elseif button == B.B then
go_menu()
end
elseif st == ST_BATTLE then
if button == B.B then
finish(false)
return
end
if my_move and not hotseat then return end
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
flush_save()
if button == B.A then
rng = badge.sys.random(65536) % 65537
if hotseat then
start_battle(foe.sp, save.level)
else
start_battle(badge.sys.random(#GEESE) + 1,
save.level > 2 and save.level - 1 or 1)
end
elseif button == B.B then
go_menu()
end
end
end
function on_exit()
flush_save()
badge.led.clear()
badge.led.show()
end
