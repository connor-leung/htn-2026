# Goose Duel - design

A Pokemon-style battler for the Hack the North 2026 Hacker Badge, themed on
Waterloo's geese. Pick a goose, fight a CPU goose solo, or duel a friend's
badge standing next to you.

This is the current design. `README.md` is the badge team's platform brief and
remains the authority on the hardware and API; where the two disagree, it wins.

## Goal and scope

| In | Out |
| --- | --- |
| 1v1 battles, one goose, four moves | Party switching, items, status effects |
| Duel a nearby badge over radio | Anything over USB (see below) |
| Solo practice vs a CPU goose | Online or multi-badge tournaments |
| Levels, XP, win/loss record | Trading, breeding, evolution |
| Six-LED battle feedback | Step-based levelling (deferred, see Open) |

## Why radio, not USB

The original ask was to link badges over USB. **There is no Lua USB API.** USB
on this badge is only the IDE's Push/console channel. The badge-to-badge link
is `badge.radio`: a restricted BLE broadcast channel, `LUA1`-prefixed, 44-byte
payloads, an 8-slot receive ring drained 4 frames per tick, and no delivery
acknowledgement.

The end experience is unchanged and arguably better - stand near your friend,
both open the app, duel with no cable.

## Constraints that shaped everything

| Constraint | Consequence |
| --- | --- |
| 44-byte lossy broadcast, no acks | Short ASCII protocol, session filtering, retransmit-until-confirmed |
| `send()` means queued, not delivered | Never show a hit on send; only on a confirmed exchange |
| Compile memory, not the 64 KiB upload cap, is the ceiling | Shipped file is stripped; see Memory |
| `on_tick` 250 ms shared cutoff | All animation and retransmission are timestamp-driven |
| No `pcall`/`os`/`coroutine`/`setmetatable` | Plain tables, explicit nil checks, no defensive wrappers |
| Widgets expose no Lua event handlers | All input through `on_button` |
| Store: 32 keys, strings <=128 B | Six integer keys |

## The core problem: lockstep over a lossy broadcast

Keeping two badges in agreement when frames drop, duplicate, and are visible to
every other badge in the room is the interesting part - not the battle maths.

**Neither badge ever transmits HP or damage.** Both send only the move they
chose and compute the identical result from a shared seed. Divergence is
impossible by construction and the payload stays tiny.

- Shared PRNG: `rng = (rng * 75 + 74) % 65537`, small enough to be exact in any
  number representation. `badge.sys.random` is used only for the session id and
  seed, never for battle rolls.
- Each turn, a badge rebroadcasts its move every 300 ms until the peer's move
  for that same turn arrives. Retransmission is the whole loss-recovery
  mechanism.
- A frame is ignored unless it carries the `GG1` prefix, the agreed session id,
  and a turn the badge is actually waiting on - handling duplicates, stale
  frames, and other people's games nearby.
- Neither side advances until both moves for the turn are known, so they cannot
  drift apart.

### Protocol

| Message | Form | Sent when |
| --- | --- | --- |
| Hello | `GG1:H:<id4>:<species>:<lvl>` | Seeking, every 500 ms |
| Pair | `GG1:P:<id4>:<peer4>:<seed>:<species>:<lvl>` | By the host until the peer's first move proves it arrived |
| Move | `GG1:M:<id4>:<turn>:<move>` | Every 300 ms until the peer's move for that turn arrives |
| Keepalive | `GG1:K:<id4>` | Every 2 s while a player is still choosing |
| Bye | `GG1:B:<id4>` | Only on a real forfeit or exit |

`id4` is a random 16-bit session id in hex. **The lower id hosts** - a tie-break
both badges compute identically, needing no negotiation. The host picks the
seed. Silence for 15 s ends the duel as "opponent left"; searching gives up
after 60 s.

### Two bugs this design still had

Both were found by driving the real `main.lua` against the mock runtime, and
both would have broken duels on hardware:

1. **Whoever paired first raced ahead.** The host broadcast its turn-1 move
   while the guest was still seeking and ignoring move frames, then only ever
   retransmitted the *current* turn - so the guest waited forever for a move
   nobody would send again. The same trap sprang on ordinary frame loss.
   **Fix:** a badge answers catch-up requests for the turn it just resolved
   (`prev_turn`/`prev_move`), from the result screen too.
2. **Winning could hand the opponent a win as well.** `finish()` sent a Bye,
   which the peer reads as "opponent quit, I win" - even when that peer had
   actually lost but had not yet resolved the final turn. **Fix:** Bye now means
   only a real forfeit; a finished badge keeps answering catch-up requests until
   the peer reaches the same verdict independently.

A third, caught by reasoning rather than testing: on a **speed tie** both badges
draw the same number, so the tie-break must resolve to a fixed player. Breaking
toward "me" made each badge think it went first - inconsistent on 100% of ties,
which happen whenever both players pick the same goose.

## Game design

Three types in a triangle: **Honk > Flap > Peck > Honk**, at 1.5x / 1.0x / 0.66x.

| Goose | Type | Character |
| --- | --- | --- |
| Campus Honker | Honk | Balanced starter |
| Ring Road Runner | Flap | Fast, fragile |
| Bread Baron | Peck | Tanky, slow |
| Alpha Gander | Honk | Glass cannon |

Twelve moves across the four geese, four each. Damage:

```
raw = (power * atk) // (def * 8) + 2      -- divisor 8 tuned by measurement
raw = raw * 3/2 (strong) or * 2/3 (weak)
raw = raw * (85 + rnd(16)) / 100          -- shared PRNG, so both agree
```

Stats scale with level: `hp +4`, `atk +2`, `def +2`, `spd +1` per level, cap 50.
XP is `10 + 2 * foe level` on a win, 3 on a loss; a level costs `20 * level`.

**Balance is measured, not guessed** (300 simulated battles per configuration):

- The damage divisor was swept 3..9. At 3 battles ended in 2.8 rounds; **8 gives
  6.3 rounds** (range 4-8), which is the target.
- Move choice swings the win rate from **17% to 44%** - a 2.6x spread. That is
  the whole game, so **both fighters' types and each move's type are shown on
  screen**; the matchup was unplayable while hidden.
- The CPU plays the optimal matchup **half** the time. Always-optimal made
  practice punishing rather than encouraging.

## Screens, controls, LEDs

State machine: `MENU -> PICK -> (SOLO | SEEK -> PAIRED) -> BATTLE -> RESULT`.

- **MENU** UP/DOWN choose, A select, **L/R set LED brightness**
- **PICK** arrows choose, A confirm, B back
- **SEEK** B cancels
- **BATTLE** arrows pick a move, A attack, B forfeit
- **RESULT** A rematch, B menu. HOME exits and saves throughout.

Only `KIND.PRESSED` is handled, so one press never fires twice. Default HOME
exit: `confirm_home=1` pauses ticks while `badge.sys.ms()` keeps running, which
would complicate the retransmit clock for no real gain.

LEDs use the documented front-view map - left column `{1,6,5}` is you, right
`{2,3,4}` is your opponent, matching the screen sides. Every frame is staged in
full, then one `show()`.

| State | Effect |
| --- | --- |
| Menu / pick | Breathing in the selected goose's type colour |
| Seeking | Chase around the perimeter |
| Battle | Each column fills as an HP bar, green -> amber -> red |
| Move lands | Brief flash on the struck side in the move's type colour |
| Win / loss | Gold chase / red fade |

## Battery

The six LEDs are the dominant draw, so every colour is scaled before reaching
the strip.

- Levels `{0, 60, 140, 255}` (Off/Low/Med/Full), **default Low**, persisted.
- **The strip blanks entirely after 20 s idle on a menu** and returns on any
  press. "Left in a pocket" was the expensive case.
- `wake_lock` is **not** in the manifest. It is held only from the start of a
  duel search until the radio stops, so the badge sleeps normally on menus and
  in solo play. The 60 s search cap bounds the hold.
- The radio gives up after 60 s with no peer and disables itself rather than
  advertising until flat.
- LED refresh is 90 ms, not 50 ms: same visual smoothness, ~45% fewer writes.

Measured over 10 minutes idle on the menu: **9,568,500 -> 72,492** energy units,
a 132x reduction. That proxy is the sum of channel values latched to the strip,
not milliamps - treat it as "the dominant draw fell by two orders of magnitude".

## Persistence

`badge.store` integers, cached in memory: `gsp` species, `glvl` level, `gxp` xp,
`gwin` wins, `gloss` losses, `gled` LED level.

Writes happen **only on the first press at the result screen and in `on_exit`** -
never on a tick. `finish()` is reachable from `on_tick`, whose 250 ms budget is
shared with the radio drain, so the write is deferred to the button path
(1,000 ms). `on_exit` is not guaranteed on power loss, which is why the result
screen saves too.

## Memory

The hardest part of this project, and still the open risk.

The badge compiles the entire file before `on_enter` runs, holding **both** the
source text and a compiled tree with debug info:

```
source text                 19,446 B
compiled, with debug info   21,133 B   <- the badge holds this too
compiled, stripped          15,554 B
```

That is ~40 KB before transient parser allocations - which is why comment
stripping alone was never decisive, and why `on_enter`-time optimisations
(flattened data, gc_step) cannot help a failure in `main.lua`.

**What was done:**

- `tools/build.py` strips comments, blank lines and indentation from the shipped
  bundle. `main.lua` stays readable; the badge gets 28% less source.
- Data is ten flat arrays rather than 22 string-keyed tables. Measured at only
  ~0.6 KB on the host - the right shape, not the fix.
- One UI panel exists at a time, built on demand and deleted on transition:
  **8 live widgets versus ~29**, stable over 200 transition cycles.
- `badge.sys.gc_step()` once per tick and after parsing.

**The counter-intuitive finding:** `heap_kb` does not ration the app, it sets
how lazy the GC is. Raising it 48 -> 96 made things *worse* - `used` went
40,572 -> 61,068, because Lua paces collection against the limit. With
`free=76636` physical and Lua holding 61 KB, the allocator had ~15 KB left and
failed. So the app ships **`heap_kb=48`** deliberately, to keep the collector
aggressive.

If it still fails there with `used` near 40,000, the compile genuinely does not
fit and the next step is cutting the app - three geese, simpler LED effects, no
pick screen - which reduces compiled code and live data together.

## Repo layout and workflow

| Path | Purpose |
| --- | --- |
| `main.lua` | Source, commented and readable |
| `manifest.cfg` | `slug=goose_duel`, `api=2`, `heap_kb=48`, text icon `GG` |
| `goose_duel.lua` | **Build output** - the file to Import. Never hand-edit |
| `tools/` | `build.py`, `harness.lua`, `test_battle.lua`, `test_power.lua` |
| `README.md` | Badge team's platform brief |

```bash
python3 tools/build.py      # regenerate goose_duel.lua - required after any edit
lua tools/test_battle.lua   # 300 solo battles + 120 duels
lua tools/test_power.lua    # LED energy, idle blanking, wake lock, radio giveup
luac -p main.lua            # syntax check
python3 .claude/skills/badge-app/scripts/check_app.py goose_duel.lua
```

`tools/harness.lua` mocks the documented `badge.*` API - widgets, LEDs, store,
buttons, and a radio two instances talk over - so `main.lua` can be driven
through real battles with injected frame loss and duplication. It asserts the
documented limits (integer LED channels, 44-byte payloads, the 512-widget cap)
and raises on use of a deleted widget handle, so violations fail here instead of
on device.

## What is verified, and what is not

**Verified in simulation:** 300 solo battles always terminate and save. 60/60
duels on a clean link finish with one winner and mirrored HP. 60/60 duels at 35%
frame loss with 20% duplicates reach a terminal state with no contradictory
winners and no HP desync. No widget leak over 200 screen-transition cycles. Both
the source and the shipped body compile under `luac`.

**Not verified:** anything on hardware. The harness is a model of the badge, not
the badge - it cannot reproduce ESP32 timing, LVGL allocation, flash latency, or
real BLE. At time of writing the app has not yet booted on a badge.

## Open

- **Memory.** `heap_kb=48` on a clean push is the next test. Fallback is cutting
  the app down.
- **Push reliability.** Repeated transfer stalls - including one on a 5,304-byte
  `icon.bin`, which rules out file size - leave padded, corrupt files and produce
  spurious syntax errors. A push is only trustworthy with no `[push error]` line.
- **`mem_log()` diagnostics** are still in `main.lua` deliberately while the
  memory problem is open. Bounded, not per-tick. Remove when done.
- **Walking XP** (level up by moving around) is deferred. Design problem to solve
  first: apps run only in the foreground, so the badge cannot count steps while
  the app is closed.
- **Image icon.** `icon=GG` text icon ships today; a 42x42 `icon.bin` is optional
  and currently a liability given the transfer stalls.
