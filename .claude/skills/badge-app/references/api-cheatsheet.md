# Badge API cheatsheet

Condensed index of the whole Lua surface. Authoritative detail lives in
`badge-app-guide.md` at the repo root — grep it by section heading for specifics.

## Manifest (`manifest.cfg` / header block)

`key=value` lines, `#` comments only on their own line, no duplicate keys.

| Key | Values |
| --- | --- |
| `slug` (req) | `[a-z0-9][a-z0-9_-]{0,31}`, equals the folder name, not a built-in slug |
| `name` (req) | 1-48 bytes |
| `icon` | 1-12 ASCII bytes, default `?` |
| `api` | `1` or `2` (use `2`; drops legacy `badge.label`/`badge.box`) |
| `heap_kb` | `48` (default) or `96` |
| `wake_lock` | `0`/`1` — stay awake in foreground |
| `home_button` | `0`/`1` — receive HOME instead of exiting |
| `confirm_home` | `0`/`1` — Home confirmation, pauses ticks; not with `home_button=1` |
| `version`, `author` | <=48 bytes, informational |

Changing a runtime option (`api`, `heap_kb`, `wake_lock`, `home_button`,
`confirm_home`) on an already-installed slug needs a **Reboot**, not just Push.

## Lifecycle and budgets

```lua
function on_enter(root) end          -- build UI/state
function on_tick() end               -- ~20 ms cadence, foreground only
function on_button(button, kind) end -- integers from badge.input
function on_exit() end               -- save + clean up
```

| Callback | Budget (current firmware) | Older firmware |
| --- | --- | --- |
| main chunk | 3,000 ms | 500 ms |
| `on_enter` | 3,000 ms | 250 / 1,000 ms |
| `on_tick` + queued `on_recv` | 250 ms shared | 6 ms |
| `on_button` | 1,000 ms | 20 ms |
| `on_exit` | 1,000 ms | 100 ms |

These are failure cutoffs, not targets — aim for a few ms per tick. Three
consecutive tick failures suspend ticks; one button failure suspends
immediately. `badge.app.exit()`, `badge.nfc.disable()`, `badge.radio.disable()`
are deferred to after the current callback.

## Sandbox

Present: `base` (minus `dofile`, `loadfile`, `load`, `pcall`, `xpcall`,
`setmetatable`), `table`, `string`, `math`, `utf8`, and a sandboxed `require`.
Absent: `os`, `io`, `package`, `debug`, `coroutine`. Bytecode is refused.

`require("pkg.mod")` -> `<appdir>/pkg/mod.lua`; depth 8, 16 modules, cycle-safe.
Prefer a single self-contained `main.lua`.

## `badge.ui`

Screen `badge.ui.screen_width` x `badge.ui.screen_height` = 320x240.

Factories (positional or one table): `label box bar arc slider image line
button switch checkbox roller textarea`.

```lua
badge.ui.label(root, "hi")        badge.ui.box(root, w, h)
badge.ui.bar(root, min, max, val) badge.ui.arc/slider(root, min, max, val)
badge.ui.image(root, "icon.bin")  badge.ui.line(root, {{0,0},{40,20}})
badge.ui.switch(root, true)       badge.ui.checkbox(root, "t", false)
badge.ui.roller(root, "a\nb")     badge.ui.button(root, w, h) -- add child label
badge.ui.box{ parent=root, w=292, h=196, bg_color=0x222222, border_width=1 }
```

Table keys: `parent x y w h align align_x align_y hidden clickable` plus
per-type `text value min max checked options src points`.

Methods (`:`): `set_pos set_size align parent child child_count type hidden
clickable bring_to_front delete set_text set_value set_range set_src set_points
set_checked get_checked set_options get_selected set_color set_border
set_font_size style`.

- `set_text` only on label/checkbox/textarea. No `button:set_text()`.
- No `set_selected`, no `get_text`, no Lua widget events — input is `on_button`.
- `root` is read-only: parent your widgets to it, never style or delete it.
- Handles are non-owning; GC never deletes a widget. Deleting a parent deletes
  children and invalidates their handles.
- Alignment: `center top_left top_mid top_right bottom_left bottom_mid
  bottom_right left_mid right_mid`.
- Style keys: `bg_color bg_opa color opa radius border_* text_color text_opa
  text_font text_align arc_* line_* pad_* shadow_* flex_flow`. Colors are
  `0xRRGGBB`; fonts `14 16 18 20 22 24` or `small default large`; opacity 0-255.
  Selectors `main indicator knob items scrollbar` + `:pressed :checked
  :disabled :focused`.
- `bg_color` implies `bg_opa=255`; set `bg_opa=0` explicitly for transparency.
- `badge.ui.theme`: `background panel surface track border accent accent_detail
  text text_soft text_muted text_dim`.

## `badge.led` — 6 RGB LEDs, Lua indices 1-6

Front view, screen upright:

```
   1 upper-left      2 upper-right
   6 middle-left     3 middle-right
   5 bottom-left     4 bottom-right
```

Left side top->bottom `{1,6,5}`; right side `{2,3,4}`; clockwise `{1,2,3,4,5,6}`.

```lua
badge.led.set(i, r, g, b)  -- 1-based index, integer channels 0-255
badge.led.set_all(r, g, b) badge.led.clear() badge.led.show() badge.led.count()
```

Stage the whole frame, then **one** `show()`. Advance animations from
`badge.sys.ms()` across ticks (e.g. 50 ms fade, 150 ms chase), never in a loop.
`clear()` + `show()` in `on_exit`. No brightness/rainbow/effect helpers exist.

## Other namespaces

```lua
badge.sensor.accel()        -- x,y,z milligravity; nil+err if unavailable
badge.sensor.shake() / .tap() / .orientation()

badge.input.BUTTON.{A,B,HOME,DOWN,LEFT,RIGHT,UP,AUX1,START}
badge.input.KIND.{PRESSED,RELEASED}
badge.input.is_down(btn)  badge.input.held()   -- HOME never reports held

badge.sys.ms() uptime() log(s) random([n]) heap() gc_step() version()
badge.sys.wake_lock(bool)  badge.sys.stats()   -- lua_used/peak/limit, widgets,
                                               -- uptime_ms, free_heap

badge.store.set/get  set_int/get_int  set_str/get_str
  -- own slug only; 32 keys, key [A-Za-z0-9_] <=24 B, strings <=128 B no newlines

badge.me.name() role() role_name() color() badge_id() provisioned()
  -- badge_id() is nil when unprovisioned; no email/phone/socials exist
badge.contacts.count()  badge.contacts.get(i)  -- 1-based; name/role/badge_id/received_unix

badge.app.slug() name() exit()   -- exit is deferred

badge.fs.write/append/read/exists/remove/list/mkdir
  -- app-relative; `appdata/` = private data; no `..`, absolute paths,
  -- backslashes or NUL. 64 KiB quota total, 16 KiB per file.

badge.nfc.enable() disable() card() read_text() clear()   -- reader only
badge.radio.enable() disable() send(s) on_recv(fn) mac() dropped()
  -- 1-44 byte payloads, LUA1-prefixed channel, 8-slot RX ring, 4 drained/tick
```

## Limits cheat sheet

48 KB Lua heap (96 via `heap_kb=96`) - 512 widgets - 64 KiB `main.lua` -
1,024 bytes per widget text - 32 store keys - 64 KiB fs quota / 16 KiB per file
- 44-byte radio payloads - require depth 8 / 16 modules - Share bundle 48 KiB /
16 files.

`heap_kb` is a ceiling, not a reservation; it buys no RAM and no execution time.

## Frequent mistakes

- `local function on_enter` (must be global).
- `badge.label` with `api=2`; `.` vs `:` on widget methods.
- Using `pcall`, `os.time`, `coroutine`, or inventing LED/audio helpers.
- Float coordinates from accelerometer math — `math.floor` them.
- Acting on both PRESSED and RELEASED, so one press fires twice.
- Writing flash every tick; rebuilding widgets every frame.
- Forgetting `badge.led.show()`, or calling it per LED.
- Non-ASCII punctuation (em dash, curly quotes, emoji) in labels — the bundled
  fonts render them as boxes.
