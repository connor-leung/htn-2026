---
name: badge-app
description: Write, update, or review a Lua app for the Hack the North 2026 Hacker Badge. Use whenever the user asks for a badge app, game, timer, LED effect, sensor/NFC/radio app, or wants an existing badge app changed, extended, or checked before pushing. Covers the single-file manifest+code format, the sandboxed API subset, callback deadlines, memory limits, and the IDE install steps to hand back.
---

# Badge app authoring

The badge team's brief `README.md` at the repo root is the source of truth.
This skill is the working procedure; pull exact details from `README.md`
as you need them rather than from memory.

## 1. Start from the user's idea

If they have not said what to build, ask first — one short question, offering
examples (game, timer, light effect, motion-reactive app). Do not pick an idea
for them and present it as theirs. If they already gave one, build it; ask at
most one clarifying question about controls or scope.

## 2. Load only what the app needs

`README.md` is ~1500 lines. Grep to the sections you need instead of reading it
whole:

```bash
grep -n '^#\{2,4\} ' README.md          # section index
sed -n '/^### `badge.led`/,/^### `badge.sensor`/p' README.md
```

- `references/api-cheatsheet.md` in this skill is a condensed index of every
  API, limit, and gotcha — read it first, then go to `README.md` for detail.
- `README.md` "Complete single-file apps" has seven full worked apps
  (counter/persistence, reaction game, tilt level, pocket light, LED tour,
  NFC viewer, radio hello). Adapt the nearest one rather than starting blank.

## 3. Write the app

Hard rules (details and rationale in `README.md`):

- Global `on_enter(root)`, `on_tick()`, `on_button(button, kind)`, `on_exit()`.
  Never `local function on_enter`.
- Only documented `badge.*` APIs. No raw LVGL, no `os`/`io`/`coroutine`/
  `pcall`/`load`/`setmetatable`, no networking, audio, touch, threads, or sleep.
- 320x240, integer coordinates, ASCII-only on-screen text.
- Build UI once in `on_enter` and reuse widgets. Large grids: create a few
  cells per `on_tick`, gate input until built. 512 native widgets max.
- Time with `badge.sys.ms()`. No busy waits, no unbounded catch-up loops.
- Cache stored values in memory; write to `badge.store`/`badge.fs` only on
  explicit actions or `on_exit`.
- Handle `nil` from sensors and `false` from `badge.nfc.enable()` /
  `badge.radio.enable()`.
- Use all six LEDs with purpose: state colours, event pulses, progress,
  celebration. Stage the frame, then one `show()`. `clear()` + `show()` in
  `on_exit`. Lua LED indices are 1-6 and map to physical positions
  (1 upper-left, 2 upper-right, 3 mid-right, 4 bottom-right, 5 bottom-left,
  6 mid-left, viewed from the front).
- Keep `main.lua` under 64 KiB — and well under, since compilation memory,
  not the upload cap, is the real ceiling.

## 4. Check before replying

Run the validator on the single-file app:

```bash
python3 .claude/skills/badge-app/scripts/check_app.py <file.lua>
```

It checks the header delimiters, manifest keys and slug pattern, file size,
forbidden stdlib use, `api=1`-only factories, lifecycle callback shape, and
`show()`-less LED writes. It is a lint, not a compiler and not a device test.
Also re-read the app yourself for: every API name and `:` vs `.`, restart and
exit paths, text that fits on screen, and each expensive path (init, move,
reset, win, save) against its callback budget.

## 5. Deliver

1. Short prose: what it does, the button controls, what it saves and when,
   and what the LED colours/patterns mean.
2. **Exactly one fenced `lua` block** — manifest header + complete code:

   ```
   --[==[badge-app
   slug=my_app
   name=My App
   icon=MA
   api=2
   heap_kb=48
   ]==]

   -- code...
   ```

3. Install steps matching their IDE page. If you have not inspected the page,
   give both explicitly:
   - **With Import app**: paste the whole block into Import app, check the slug,
     Replace editor files, then badge off → USB in → on (not holding Start) →
     Connect → USB JTAG/serial debug unit → Push → open with **A**.
   - **Without Import app**: the `key=value` lines (no delimiters) go in
     `manifest.cfg`, everything after `]==]` goes in `main.lua`, then
     Connect → Push. A missing button is a page version difference, not a fault.
4. State plainly what you checked and that you did not run it on hardware.

On a later change request, return the **complete updated app again** with the
**same slug**, not a patch.

## Local files

If the user is keeping the app in this repo, mirror the two halves into
`manifest.cfg` and `main.lua` so the repo matches the IDE workspace. The single
code block in your reply is still the deliverable.
