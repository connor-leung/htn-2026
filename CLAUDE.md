# Hack the North 2026 Hacker Badge — app development

This repo is a workspace for writing **Lua apps for the 2026 Hacker Badge**.
`README.md` is the authoritative platform brief shipped by the badge team
(IDE workflow, full API reference, runtime limits, worked examples,
troubleshooting table). It is the source of truth — when this file and
`README.md` disagree, `README.md` wins. Do not invent APIs that are not in it.

## Workspace layout

| Path            | Purpose                                                        |
| --------------- | -------------------------------------------------------------- |
| `README.md`     | Platform brief from the badge team. Reference, not app code.    |
| `manifest.cfg`  | Current app's config (`key=value`). Mirrors the IDE file.       |
| `main.lua`      | Current app's code. Mirrors the IDE file.                       |
| `apps/<slug>/`  | Optional: keep other apps here so the IDE workspace stays clean.|

There is no build, test, or deploy step in this repo. The badge is programmed
through the [Badge IDE](https://badge.hackthenorth.com/ide/) in desktop Chrome
or Edge over USB. Nothing here compiles or runs Lua; the badge is the only
real test environment.

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
