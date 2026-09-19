--[==[badge-app
slug=my_app
name=My App
icon=MA
api=2
heap_kb=48
]==]

-- Controls: A = action, B = back, START = reset, HOME = exit (saves).
-- LEDs: upper pair = state, bottom pair = progress. Cleared on exit.

local ui = {}            -- widget handles, created once in on_enter
local state = {
  score = 0,
  best = 0,
  dirty = false,         -- true when `best` needs a flash write
  last_led_ms = 0,
}

local LED_ACCENT = { 0, 180, 255 }

local function render()
  ui.score:set_text("Score: " .. state.score)
  ui.best:set_text("Best: " .. state.best)
end

-- Stage every affected LED, then show() exactly once.
local function draw_leds(now)
  if now - state.last_led_ms < 50 then return end
  state.last_led_ms = now
  badge.led.clear()
  badge.led.set(1, LED_ACCENT[1], LED_ACCENT[2], LED_ACCENT[3])
  badge.led.set(2, LED_ACCENT[1], LED_ACCENT[2], LED_ACCENT[3])
  badge.led.show()
end

function on_enter(root)
  state.best = badge.store.get_int("best", 0)

  local bg = badge.ui.box{ parent = root, w = 320, h = 240,
    bg_color = 0x101418, radius = 0 }
  bg:align("center", 0, 0)

  ui.title = badge.ui.label(bg, "My App")
  ui.title:set_font_size("large")
  ui.title:align("top_mid", 0, 12)

  ui.score = badge.ui.label(bg, "")
  ui.score:align("center", 0, -10)

  ui.best = badge.ui.label(bg, "")
  ui.best:align("center", 0, 14)

  ui.help = badge.ui.label(bg, "A: score  START: reset  HOME: exit")
  ui.help:set_font_size("small")
  ui.help:align("bottom_mid", 0, -10)

  render()
end

function on_tick()
  draw_leds(badge.sys.ms())
end

function on_button(button, kind)
  if kind ~= badge.input.KIND.PRESSED then return end
  local B = badge.input.BUTTON

  if button == B.A then
    state.score = state.score + 1
    if state.score > state.best then
      state.best = state.score
      state.dirty = true
    end
    render()
  elseif button == B.START then
    state.score = 0
    render()
  end
end

function on_exit()
  if state.dirty then
    badge.store.set_int("best", state.best)
    state.dirty = false
  end
  badge.led.clear()
  badge.led.show()
end
