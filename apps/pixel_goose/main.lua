-- Pixel Goose: a hand-drawn goose sprite rendered from a character map.
-- A cycles the palette, B honks, HOME exits.

local S = 8                 -- pixel size in screen pixels
local ART = {
  "....KKKKK.......................",
  "...KKKKKKK......................",
  "..KKKKKKKKK.....................",
  "KKKWKKWWKKK.....................",
  "KKKKKKWWKKK.....................",
  "..KKKKWWKKK.....................",
  "...KKKKKKKK.....................",
  ".....KKKKK......................",
  "......KKKK......................",
  "......KKKK......................",
  ".....KKKKK......................",
  "....KKKKKKGGG...................",
  "...KKKKKGGGGGGGG................",
  "..KKKKGGGGGGGGGGGGG.............",
  "..KKKGGGGGGGGDDDDDGGGG..........",
  "..KKGGGGGGGDDDDDDDDGGGGW........",
  "..KGGGGGGGDDDDDDDDDGGGWWW.......",
  "..GGGGGGGGDDDDDDDDGGGGWWKKK.....",
  "...GGGGGGGGDDDDDDGGGGWWKKKK.....",
  "....GGGGGGGGGGGGGGGGWWKK........",
  ".....GGGGGGGGGGGGGGWW...........",
  "......WWWWWWWWWWWW..............",
  "........OO....OO................",
  "........OO....OO................",
  ".......OOOO..OOOO...............",
}

local PALETTES = {
  { name = "Canada Goose",
    bg = 0x101a22,
    led = {  0,  60,  30 },
    c = { K = 0x14161a, W = 0xf2f2ee, G = 0x8a7358, D = 0x5e4c39, O = 0xd98a2b } },
  { name = "Snow Goose",
    bg = 0x1b2430,
    led = { 60,  60,  80 },
    c = { K = 0x2b2b32, W = 0xffffff, G = 0xe6e8ef, D = 0xbcc0cc, O = 0xff6b3d } },
  { name = "Cyber Goose",
    bg = 0x0a0612,
    led = { 70,   0,  70 },
    c = { K = 0x1a0b2e, W = 0x00f5ff, G = 0x7b2ff7, D = 0x3c1361, O = 0xff2fa0 } },
}

local backdrop, honk_label, name_label
local pixels = {}
local pal = 1
local honk_until = 0
local last_led = 0

local function paint()
  local p = PALETTES[pal]
  backdrop:set_color(p.bg)
  for i = 1, #pixels do
    local px = pixels[i]
    px.box:set_color(p.c[px.key])
  end
  name_label:set_text(p.name)
end

local function build_sprite(root, x0, y0)
  for r = 1, #ART do
    local row = ART[r]
    local c = 1
    local n = #row
    while c <= n do
      local ch = string.sub(row, c, c)
      if ch == "." then
        c = c + 1
      else
        local run = c
        while run < n and string.sub(row, run + 1, run + 1) == ch do
          run = run + 1
        end
        local b = badge.ui.box(root, (run - c + 1) * S, S)
        b:set_pos(x0 + (c - 1) * S, y0 + (r - 1) * S)
        b:style({ border_width = 0, radius = 0 })
        pixels[#pixels + 1] = { box = b, key = ch }
        c = run + 1
      end
    end
  end
end

local function leds(now)
  local p = PALETTES[pal]
  if now < honk_until then
    local on = (math.floor(now / 90) % 2) == 0
    if on then
      badge.led.set_all(255, 190, 40)
    else
      badge.led.set_all(20, 10, 0)
    end
  else
    -- slow breathing wash in the palette accent
    local phase = math.floor(now / 40) % 100
    if phase > 50 then phase = 100 - phase end
    local k = 40 + phase * 4
    badge.led.clear()
    for i = 1, 6 do
      local lag = ((phase + i * 8) % 60)
      local scale = (k + lag * 2)
      badge.led.set(i,
        math.floor(p.led[1] * scale / 255),
        math.floor(p.led[2] * scale / 255),
        math.floor(p.led[3] * scale / 255))
    end
  end
  badge.led.show()
end

function on_enter(root)
  local art_w = 32 * S
  local x0 = math.floor((badge.ui.screen_width - art_w) / 2)
  local y0 = 4

  backdrop = badge.ui.box(root, badge.ui.screen_width, badge.ui.screen_height)
  backdrop:set_pos(0, 0)
  backdrop:style({ border_width = 0, radius = 0 })

  build_sprite(root, x0, y0)

  honk_label = badge.ui.label(root, "HONK!")
  honk_label:style({ text_font = 24, text_color = 0xffd23f })
  honk_label:align("top_right", -12, 14)
  honk_label:hidden(true)

  name_label = badge.ui.label(root, "")
  name_label:style({ text_font = 16, text_color = 0xffffff })
  name_label:align("bottom_mid", 0, -24)

  local hint = badge.ui.label(root, "A palette   B honk   HOME exit")
  hint:style({ text_font = 14, text_color = 0x9aa4b2 })
  hint:align("bottom_mid", 0, -6)

  pal = badge.store.get_int("pal", 1)
  if pal < 1 or pal > #PALETTES then pal = 1 end
  paint()
  leds(badge.sys.ms())
end

function on_tick()
  local now = badge.sys.ms()
  if honk_until > 0 and now >= honk_until then
    honk_until = 0
    honk_label:hidden(true)
  end
  if now - last_led >= 50 then
    last_led = now
    leds(now)
  end
end

function on_button(button, kind)
  if kind ~= badge.input.KIND.PRESSED then return end
  if button == badge.input.BUTTON.A then
    pal = pal % #PALETTES + 1
    paint()
  elseif button == badge.input.BUTTON.B then
    honk_until = badge.sys.ms() + 800
    honk_label:hidden(false)
  end
end

function on_exit()
  badge.store.set_int("pal", pal)
  badge.led.clear()
  badge.led.show()
end
