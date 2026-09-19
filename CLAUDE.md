# Hack the North 2026 Hacker Badge — app development

This repo is a workspace for writing **Lua apps for the 2026 Hacker Badge**.
`README.md` is the authoritative platform brief shipped by the badge team
(IDE workflow, full API reference, runtime limits, worked examples,
troubleshooting table). It is the source of truth — when this file and
`README.md` disagree, `README.md` wins. Do not invent APIs that are not in it.

## Workspace layout

| Path               | Purpose                                                       |
| ------------------ | ------------------------------------------------------------- |
| `README.md`        | Platform brief from the badge team. Reference, not app code.   |
| `main.lua`         | Active app's code (Goose Duel). Commented, readable source.    |
| `manifest.cfg`     | Active app's config (`key=value`).                             |
| `goose_duel.lua`   | **Build output** - the single file to Import. Do not hand-edit.|
| `apps/<slug>/`     | Other apps, one directory each (e.g. `apps/pixel_goose/`).     |
| `tools/`           | Build and test scripts. Never pushed to the badge.             |

The badge is programmed through the
[Badge IDE](https://badge.hackthenorth.com/ide/) in desktop Chrome or Edge over
USB. Only hardware proves an app works: nothing here reproduces ESP32 timing,
LVGL allocation, or flash latency.

### Build and test

```bash
python3 tools/build.py                  # main.lua + manifest.cfg -> goose_duel.lua
lua tools/test_battle.lua               # play the real main.lua against a mock badge
lua tools/test_power.lua                # LED energy, idle blanking, wake lock, radio
python3 .claude/skills/badge-app/scripts/check_app.py goose_duel.lua
luac -p main.lua                        # syntax only (brew install lua)
```

**Always run `tools/build.py` after editing `main.lua`** - `goose_duel.lua` is
generated, and it ships with comments and blank lines stripped because the badge
compiles the entire file before `on_enter` runs, and that compile is what hits
the Lua memory ceiling.

`tools/harness.lua` mocks the documented `badge.*` API - widgets, LEDs, store,
buttons, and a radio two instances can talk over - so `main.lua` can be driven
through real battles, including duels with injected frame loss and duplication.
It asserts the documented limits (integer LED channels, 44-byte payloads, the
512-widget cap), so a violation fails the test rather than surfacing on device.
It is a model of the badge, not the badge.

## Skills

- **`badge-app`** — invoke for any request to write, change, or review a badge
  app. Covers the single-file format, the API subset, deadline/memory budgets,
  LED design, and what to hand the user for installation.
- **`badge-debug`** — invoke when the user reports an IDE console error,
  traceback, error card, failed Push, or an app misbehaving on hardware.

## Non-negotiables when writing badge code

- Deliver **one fenced `lua` block**: `--[==[badge-app` manifest header, `]==]`,
  then the entire `main.lua`. No diffs, no split blocks, no extra files.
- `api=2`, unique lowercase slug, `heap_kb=48` unless measured otherwise.
- Sandbox: no `os`, `io`, `coroutine`, `debug`, `package`, `pcall`, `xpcall`,
  `load`, `setmetatable`. No Wi-Fi, HTTP, audio, touch, threads, or sleep.
- Screen is 320x240, input is physical buttons only (`on_button`); widget
  factories expose no Lua event handlers.
- Callback budgets: main chunk / `on_enter` 3000 ms, `on_tick` and `on_recv`
  250 ms shared, `on_button` 1000 ms, `on_exit` 1000 ms. Target a few ms per
  tick. Older firmware is far stricter (6 ms ticks) — see `README.md`.
- Use the six LEDs expressively and clear them in `on_exit`.
- Never claim an app was pushed, run, or tested on hardware. You cannot verify
  that from here. State exactly what you did check.
