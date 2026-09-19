-- Mock badge runtime: loads main.lua in an isolated env so two "badges" can
-- be driven independently and cross-wired over a fake radio.

local M = {}

local function mkwidget(kind, reg)
  local w = { _kind = kind, _text = "", _hidden = false, _value = 0, _children = {} }
  if reg then reg[#reg + 1] = w end
  local function self_ret(name)
    w[name] = function(self, ...) return self end
  end
  w.set_text = function(self, t)
    assert(type(t) == "string", "set_text needs a string, got " .. type(t))
    self._text = t; return self
  end
  w.set_value = function(self, v)
    assert(math.type(v) == "integer", "set_value needs an integer, got " .. tostring(v))
    self._value = v; return self
  end
  w.hidden = function(self, b) self._hidden = b; return self end
  w.set_color = function(self, c)
    assert(math.type(c) == "integer", "set_color needs an integer colour")
    return self
  end
  w.align = function(self, where, dx, dy)
    assert(type(where) == "string", "align name must be a string")
    assert(math.type(dx) == "integer" and math.type(dy) == "integer",
      "align offsets must be integers, got " .. tostring(dx) .. "," .. tostring(dy))
    return self
  end
  w.set_size = function(self, a, b)
    assert(math.type(a) == "integer" and math.type(b) == "integer",
      "set_size needs integers")
    return self
  end
  for _, n in ipairs({ "set_font_size", "style", "set_border", "bring_to_front",
                       "set_range", "set_src", "set_points", "set_checked" }) do
    self_ret(n)
  end
  return w
end

function M.new(name, seed)
  local b = {
    name = name, now = 0, leds = {}, led_shown = 0, widgets = 0,
    store = {}, outbox = {}, recv = nil, radio_up = false, log = {},
  }
  local rng = seed

  local function nextrand(n)
    rng = (rng * 1103515245 + 12345) % 2147483648
    return rng % n
  end

  local badge = {}
  badge.ui = {
    screen_width = 320, screen_height = 240,
    theme = { background = 0, text = 0xffffff },
  }
  b.all = {}
  local function factory(kind)
    return function(a, ...)
      b.widgets = b.widgets + 1
      assert(b.widgets <= 512, "exceeded the 512 native widget cap")
      return mkwidget(kind, b.all)
    end
  end
  for _, k in ipairs({ "label", "box", "bar", "arc", "slider", "image", "line",
                       "button", "switch", "checkbox", "roller", "textarea" }) do
    badge.ui[k] = factory(k)
  end

  badge.led = {
    count = function() return 6 end,
    set = function(i, r, g, bl)
      assert(math.type(i) == "integer" and i >= 1 and i <= 6,
        "LED index must be an integer 1..6, got " .. tostring(i))
      for _, v in ipairs({ r, g, bl }) do
        assert(math.type(v) == "integer" and v >= 0 and v <= 255,
          "LED channel must be an integer 0..255, got " .. tostring(v))
      end
      b.leds[i] = { r, g, bl }
    end,
    set_all = function(r, g, bl)
      for i = 1, 6 do badge.led.set(i, r, g, bl) end
    end,
    clear = function() b.leds = {} end,
    show = function()
      b.led_shown = b.led_shown + 1
      -- Crude proxy for LED energy: sum of all channel values latched, which
      -- is what actually drives current through the strip.
      local sum = 0
      for _, c in pairs(b.leds) do sum = sum + c[1] + c[2] + c[3] end
      b.led_energy = (b.led_energy or 0) + sum
    end,
  }

  badge.sys = {
    ms = function() return b.now end,
    uptime = function() return b.now // 1000 end,
    random = function(n) return n and nextrand(n) or nextrand(2 ^ 31) end,
    log = function(s) b.log[#b.log + 1] = s end,
    version = function() return "mock-1.0" end,
    heap = function() return 1024 end,
    gc_step = function() end,
    wake_lock = function(on)
      b.wake = on and true or false
      b.wake_changes = (b.wake_changes or 0) + 1
    end,
    stats = function()
      return { lua_used = 1024, lua_peak = 2048, lua_limit = 49152,
               widgets = b.widgets, uptime_ms = b.now, free_heap = 60000 }
    end,
  }

  badge.store = {
    get_int = function(k, d) return b.store[k] or d end,
    set_int = function(k, v)
      assert(#k <= 24, "store key too long")
      assert(math.type(v) == "integer", "set_int needs an integer, got " .. tostring(v))
      b.store[k] = v
    end,
    get = function(k, d) return b.store[k] or d end,
    set = function(k, v) b.store[k] = v end,
    get_str = function(k, d) return b.store[k] or d end,
    set_str = function(k, v) b.store[k] = v end,
  }

  badge.radio = {
    enable = function() b.radio_up = true; return true end,
    disable = function() b.radio_up = false end,
    send = function(payload)
      assert(type(payload) == "string", "radio payload must be a string")
      assert(#payload >= 1 and #payload <= 44,
        "radio payload must be 1..44 bytes, got " .. #payload .. ": " .. payload)
      if not b.radio_up then return false end
      b.outbox[#b.outbox + 1] = payload
      return true
    end,
    on_recv = function(fn) b.recv = fn end,
    mac = function() return "AA:BB:CC:DD:EE:0" .. seed % 10 end,
    dropped = function() return 0 end,
  }

  badge.input = {
    BUTTON = { A = 1, B = 2, HOME = 3, DOWN = 4, LEFT = 5, RIGHT = 6, UP = 7,
               AUX1 = 8, START = 9 },
    KIND = { PRESSED = 1, RELEASED = 2 },
    is_down = function() return false end,
    held = function() return 0 end,
  }

  badge.me = {
    name = function() return name end,
    role = function() return 1 end,
    role_name = function() return "Hacker" end,
    color = function() return 255, 255, 255 end,
    badge_id = function() return nil end,   -- unprovisioned, the harder path
    provisioned = function() return false end,
  }
  badge.app = { slug = function() return "goose_duel" end,
                name = function() return "Goose Duel" end,
                exit = function() b.exited = true end }
  badge.contacts = { count = function() return 0 end, get = function() return nil end }
  badge.fs = {}

  -- Sandbox roughly as documented: no os/io/coroutine/pcall/setmetatable.
  local env = {
    badge = badge, string = string, table = table, math = math, utf8 = utf8,
    ipairs = ipairs, pairs = pairs, tonumber = tonumber, tostring = tostring,
    type = type, select = select, next = next, error = error, assert = assert,
    rawget = rawget, rawset = rawset, rawequal = rawequal, rawlen = rawlen,
    print = print, unpack = table.unpack,
  }
  env._G = env

  local f = assert(io.open("main.lua", "r"))
  local src = f:read("a")
  f:close()
  local chunk = assert(load(src, "main.lua", "t", env))
  chunk()

  b.env = env
  b.badge = badge
  b.root = mkwidget("root")
  -- screen(): every visible label text, like the badge console's uitree
  b.screen = function()
    local out = {}
    for _, w in ipairs(b.all) do
      if w._text ~= "" then out[#out + 1] = w._text end
    end
    return table.concat(out, " | ")
  end
  return b
end

return M
