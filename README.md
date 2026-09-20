# Goose Duel — Hack the North 2026 Hacker Badge

A Pokémon-style goose battler for the 2026 Hacker Badge, themed on Waterloo's
geese. Pick a goose, fight a CPU goose, or duel a friend's badge over the
radio.

- **[`badge-app-guide.md`](badge-app-guide.md) is the single source of truth**
  for the platform: IDE workflow, the full `badge.*` API, runtime limits,
  worked examples and the troubleshooting table. It is a vendor document —
  read it, don't edit it.
- **[`DESIGN.md`](DESIGN.md)** is this project: what it does, why it is built
  this way, what is measured, and what is still open.

## The two builds

| App | Slug | Compile cost | What it is |
| --- | --- | --- | --- |
| Goose Duel | `goose_duel` | 47.2 KB | Full game, radio duels between badges |
| Goose Solo | `goose_solo` | 36.6 KB | Solo play **and hot-seat duels**. Runs on hardware, wired and on battery |

Both ship `heap_kb=96`. That setting, not the size of the app, is what made
them launch — see DESIGN.md's Memory section.

Both install side by side. `goose_duel.lua` and
`apps/goose_solo/goose_solo.lua` are the files you Import — they are build
output, so edit `main.lua` and rebuild rather than touching them.

## Build and test

```bash
python3 tools/build.py                  # main.lua + manifest.cfg -> goose_duel.lua
python3 tools/build.py apps/goose_solo  # any app dir; the slug names the output
lua tools/mem_report.lua                # compile cost vs the measured ceiling
lua tools/test_battle.lua               # 300 solo battles + 120 duels
lua tools/test_solo.lua                 # the no-radio build
lua tools/test_power.lua                # LED energy, idle blanking, wake lock
luac -p main.lua                        # syntax only (brew install lua)
```

`tools/harness.lua` mocks the documented `badge.*` API so `main.lua` can be
driven through real battles, including duels with injected frame loss and
duplication. It is a model of the badge, not the badge: only hardware proves
an app works.

## Installing

Import the bundle in the [Badge IDE](https://badge.hackthenorth.com/ide/),
**Replace editor files**, Connect, Push. A push is only trustworthy with no
`[push error]` line. Changing a runtime manifest option (`api`, `heap_kb`,
`wake_lock`, `home_button`, `confirm_home`) on an already-installed slug needs
a **Reboot** — a Push alone refreshes the name and icon and nothing else.
