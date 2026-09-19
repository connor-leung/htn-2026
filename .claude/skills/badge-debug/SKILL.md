---
name: badge-debug
description: Diagnose a Hack the North badge app failure - IDE console errors, Lua tracebacks, on-screen error cards, execution deadline or memory limit messages, Push/Connect/USB problems, an app missing from the launcher, dark or wrong LEDs, lost saves, or NFC/radio not working. Use when the user reports that their badge app does not work rather than asking for new code.
---

# Badge troubleshooting

Stay inside the IDE and the generated app. The user does not need a repo
checkout, terminal, or firmware flashing workflow.

## 1. Classify the failure before fixing anything

Four distinct stages fail in different ways — name which one you are in:

| Stage | Evidence |
| --- | --- |
| Import validation | IDE rejects the header/config. Lua is *not* compiled here. |
| USB transfer | Connect/device picker/Push status. `[push] reload confirmed` means uploaded and rescanned — **not** that the app initialized. |
| Launcher discovery | App missing from the launcher; `apps` console command. |
| Running on the badge | Error card with traceback, `script_app` console lines, wrong behaviour. |

`app_reg: launched` can appear *after* a Lua startup error — read the preceding
`script_app` error and what is on the badge screen.

## 2. Gather only what is missing

Do not ask the user to repeat anything they already sent. Ask for:

- The exact error text and full traceback from the IDE console.
- Which action triggered it: opening, a move, a win, a reset, or exiting.
- The complete single-file app they actually pushed.

Read-only console commands to request, one at a time, when relevant:
`apps` (installed apps), `heap` (system + LVGL memory), `uitree` (visible
widgets and text), `cat /littlefs/apps/THEIR_SLUG/main.lua` (what is really
installed — substitute their slug). Never request a full device snapshot or
provisioning credentials.

## 3. Read the traceback correctly

- The callback name comes first: `main.lua`, `on_enter`, `on_tick`, `on_recv`,
  `on_button`, `on_exit`. Follow the whole call path, not just the top frame.
- Line numbers refer to the extracted `main.lua`, **excluding the bundle
  header**. Offset accordingly when reading a single-file bundle.
- For a deadline error, the reported line is where the check fired, not
  necessarily where the time went.

## 4. Match the fix to the symptom

`README.md` at the repo root ends with a symptom -> fix table covering every
documented failure. Read it before answering:

```bash
sed -n '/^### Match the fix to the failure/,$p' README.md
```

The cases that get misdiagnosed most often:

- **`Lua memory limit exceeded` with `used < limit`** — one message covers both
  the quota rejection and a system `realloc` failure. `heap_kb` reserves no RAM
  and the failed allocation is not in `used`/`peak`. A failure in `main.lua` is
  compile-time memory pressure: shrink the app's code and live state; spreading
  widgets across ticks does not help a failure that happens before `on_enter`.
  Never tell the user to delete installed apps to free RAM, and never promise
  96 KiB is available.
- **Deadline exceeded** — current firmware allows 3,000 ms for the main chunk
  and `on_enter`, 250 ms shared for `on_tick`/`on_recv`, 1,000 ms for
  `on_button`, 1,000 ms for `on_exit`. Firmware before 2026-09-16 allows
  500 / 250 / 6 / 20 / 100 ms. `api=2` does not tell you which is installed —
  have the user log `badge.sys.version()`. Fix by splitting work across ticks,
  not by asking for more budget: no manifest option grants execution time.
- **New manifest options ignored** — Reboot, not just Push, after changing
  `api`, `heap_kb`, `wake_lock`, `home_button`, or `confirm_home` on an
  installed slug.
- **One press acts twice** — handle only `badge.input.KIND.PRESSED`.
- **`root widget is read-only`** — style a child box, never `root`.
- **`widget has been deleted`** — a deleted parent takes its children with it;
  clear retained handles and pending per-tick work.
- **LEDs dark or on the wrong side** — one `show()` after staging the frame,
  integer channels 0-255, Lua indices 1-6 in the documented front-view layout,
  not C++ zero-based indices.
- **Missing button in the IDE** — a page version difference, not a badge or USB
  fault. Fall back to editing `manifest.cfg` and `main.lua` directly.

## 5. Add temporary instrumentation when you need data

Put brief logs in the full app you return, between phases (a timeout stops the
final log from running). Never log per cell or every tick.

```lua
badge.sys.log("firmware=" .. badge.sys.version())
local s = badge.sys.stats()
badge.sys.log("lua=" .. s.lua_used .. "/" .. s.lua_limit ..
  " peak=" .. s.lua_peak .. " widgets=" .. s.widgets ..
  " free_heap=" .. s.free_heap)
```

Bracket a suspect section with `badge.sys.ms()` to measure it. Remove or
rate-limit the logging in the final version.

## 6. Reply

Re-run the lint before sending a fix:

```bash
python3 .claude/skills/badge-app/scripts/check_app.py <file.lua>
```

Then say: what failed and why, what you changed, what you actually verified,
and that host-side checks cannot reproduce ESP32 timing, LVGL allocation, or
flash latency. Return the **entire app with the same slug** plus the install
steps for their IDE, and ask them to retry the failing action *and* startup,
repeated reset, a win/draw if applicable, and exit/reopen.

Do not recommend erasing the badge, deleting unrelated apps, or calling an
ordinary Lua error a hardware fault.
