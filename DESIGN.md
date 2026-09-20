# Goose Duel - design

A Pokemon-style battler for the Hack the North 2026 Hacker Badge, themed on
Waterloo's geese. Pick a goose, fight a CPU goose solo, or duel a friend's
badge standing next to you.

This is the current design. `badge-app-guide.md` is the badge team's platform brief and
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

- **MENU** UP/DOWN choose, A select
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

- Every colour constant in the file is **pre-scaled to ~24%** (60/255).
  Scaling on the way to the strip cost two prototypes and three multiplies per
  LED per frame; pre-scaling the constants is free at runtime and, with memory
  this tight, that mattered. To rebrighten, multiply every RGB literal by the
  same factor.
- **The strip blanks entirely after 20 s idle on a menu** and returns on any
  press. "Left in a pocket" was the expensive case.
- `wake_lock` is **not** in the manifest - and this was the battery bug. With
  `wake_lock=1` set there, the badge never sleeps for the whole session,
  menus included. It is now taken with `badge.sys.wake_lock(true)` at the start
  of a duel search and released in `radio_stop()`, so the badge sleeps normally
  on menus and in solo play. The 60 s search cap bounds the hold. **Removing it
  from the manifest needs a Reboot to take effect.**
- The radio gives up after 60 s with no peer and disables itself rather than
  advertising until flat.
- LED refresh is 90 ms, not 50 ms: same visual smoothness, ~45% fewer writes.

Measured over 10 minutes idle on the menu: **9,568,500 -> 72,492** energy units,
a 132x reduction. That proxy is the sum of channel values latched to the strip,
not milliamps - treat it as "the dominant draw fell by two orders of magnitude".

## Persistence

`badge.store` integers, cached in memory: `gsp` species, `glvl` level, `gxp` xp,
`gwin` wins, `gloss` losses.

Writes happen **only on the first press at the result screen and in `on_exit`** -
never on a tick. `finish()` is reachable from `on_tick`, whose 250 ms budget is
shared with the radio drain, so the write is deferred to the button path
(1,000 ms). `on_exit` is not guaranteed on power loss, which is why the result
screen saves too.

## Memory

The hardest part of this project. The badge compiles the entire file before
`on_enter` runs, holding both the source text and a compiled tree with debug
info, and that compile is what fails.

**The ceiling is now calibrated against the badge**, by measuring what each
commit costs with `tools/mem_report.lua` (which `load()`s a chunk without
running it and weighs the heap either side):

| commit | retained | on the badge |
| --- | --- | --- |
| `a996e29` | **47.0 KB** | **boots at `heap_kb=48`** |
| `43333a1` desync fixes | **48.0 KB** | the failure `fea9e5a` was written to fix |
| `8e6bab5` battery work | 50.2 KB | fails |
| `7f7e712` | 53.5 KB | fails, `peak 45,489 / limit 49,152` |
| **current** | **47.2 KB** | to be tested |

The cliff sits in the 1 KB between 47.0 and 48.0. `tools/mem_report.lua`
defaults to a 47.5 KB ceiling and fails the build above it.

**Three things that were believed and are false:**

- *Comment stripping helps.* It removes 30% of the source and **zero**
  compiled bytes - measured identical to 16 bytes. It shrinks only the
  transient buffer the lexer reads. It is still worth doing for that, but it
  is not a memory fix.
- *Cutting the app fixes the compile failure.* A 2.5 KB source-level cut moved
  the badge by **46 bytes** of peak and 218 bytes of `used`. At that exchange
  rate the two largest remaining feature cuts are worth ~50 bytes between them.
- *`heap_kb=96` buys room.* It reserves no RAM; it only makes the GC lazier.
  At 96 the collector idled until the *system* allocator ran out of a
  contiguous block (peak 63,636 against largest 63,488 - a miss by 148 bytes).
  At 48 the quota rejected the compile instead.

### The measurement that explains all of it

Removing multiplayer entirely - 25% of the program - and launching the result:

| | `used` | `peak` | bytecode |
| --- | --- | --- | --- |
| `goose_duel` | 39,197 | 45,489 | 19,822 B |
| `goose_solo` | **39,217** | 41,529 | 14,844 B |

**`used` differs by 20 bytes.** `peak` tracks program size faithfully (-3,960
for -4,978 bytes of bytecode); `used` does not move at all. So roughly 39.2 KB
of the 48 KiB quota is consumed independently of the app, leaving under 10 KB
for it. That is why a 2.5 KB cut moved `peak` by 46 bytes, and why deleting the
entire radio stack moved `used` by 20: **the app was never what filled the
quota.**

The second tell: `goose_solo` peaked 7,623 bytes *below* the limit and still
failed. The allocation being refused is a single block of at least 7.6 KB, and
no amount of feature-trimming gets under that.

The only lever that acts on a fixed floor is the quota itself, so the app ships
**`heap_kb=96`**. At 96 the constraint stops being the quota and becomes
physical contiguous RAM, where the 53.5 KB build missed by 148 bytes; today's
builds peak lower and the largest block reads 65,536.

**This is the fix, and it is confirmed on hardware.** `goose_solo` at
`heap_kb=96` runs on USB *and* on battery - the first configuration in this
project to do either. The whole memory effort before it, three rounds of
cutting the app down, was aimed at the wrong variable.

**And one trap worth its own line:** runtime manifest options (`api`,
`heap_kb`, `wake_lock`, `home_button`, `confirm_home`) on an already-installed
slug take effect only after a **Reboot**. Push and `reload` refresh the name
and icon and nothing else. A `heap_kb=48` that had been in the repo for four
commits had never once run on the badge, and every measurement taken in that
window was taken under the old value.

One more asymmetry in the current build's favour: it ships **17.5 KB of
stripped source against the known-good version's 23.1 KB**, so on source bytes
it is 5.5 KB lighter than a version that boots, while being within 0.2 KB of it
on retained memory.

## The single-badge build

`apps/goose_solo/` is Goose Duel with the radio multiplayer removed - the
pairing protocol, the retransmit/catch-up machinery, the seek screen and the
wake lock. Everything else is the same game: the same four geese, twelve moves,
type triangle, damage maths, levelling, save keys and LED effects.

**It has multiplayer again, without a radio.** "Duel a friend" is a hot-seat
duel: two players share one badge. Player 2 picks a goose, then each turn
player 1 chooses a move, a hand-over screen blanks the move list, and player 2
takes the badge and chooses theirs. Both moves resolve together, exactly as
they would have over the air - the battle engine is unchanged, because the
lockstep protocol only ever exchanged a move index anyway.

A friend's duel does not touch the badge owner's record or XP, and player 2
fights at player 1's level so the duel is about the matchup rather than who has
played more. Verified over 60 simulated hot-seat duels: every one reaches a
winner, the hand-over screen never leaks the other player's move list, and the
stored win/loss record is untouched.

| | retained | source shipped |
| --- | --- | --- |
| `goose_duel` (duelling) | 47.2 KB | 17.5 KB |
| `goose_solo` (this) | **36.6 KB** | 14.2 KB |

It ships `heap_kb=96` where the duelling build ships 48 - see Memory for why
that is the only knob that moves this failure.

It exists because the duelling build sits within 0.2 KB of a memory cliff
measured between 47.0 and 48.0 KB, and that margin held on a freshly rebooted
badge but not on a fragmented one - the app booted over USB after a reboot and
failed the same day on battery. 34.2 KB is ~13 KB below the known-good
version, which is margin rather than a coin flip.

It is a separate slug (`goose_solo`, icon `G1`), so it installs alongside the
duelling build rather than replacing it. `tools/test_solo.lua` drives it and
asserts the radio is genuinely gone: nothing transmits, `badge.radio.enable`
is never called, and the badge is never held awake.

## Repo layout and workflow

| Path | Purpose |
| --- | --- |
| `main.lua` | Source, commented and readable |
| `manifest.cfg` | `slug=goose_duel`, `api=2`, `heap_kb=48`, text icon `GG` |
| `goose_duel.lua` | **Build output** - the file to Import. Never hand-edit |
| `tools/` | `build.py`, `mem_report.lua`, `harness.lua`, `test_battle.lua`, `test_power.lua` |
| `badge-app-guide.md` | Badge team's platform brief - the source of truth |
| `README.md` | What this repo is; points at the guide |

```bash
python3 tools/build.py      # regenerate goose_duel.lua - required after any edit
lua tools/mem_report.lua    # compile cost against the 47.5 KB ceiling
lua tools/test_battle.lua   # 300 solo battles + 120 duels
lua tools/test_solo.lua     # the no-radio build in apps/goose_solo/
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

**Verified on hardware:** `goose_solo` at `heap_kb=96` launches and runs, on
USB power and on battery. Nothing else in this document has been confirmed on a
badge.

**Verified in simulation:** 300 solo battles always terminate and save. 60/60
duels on a clean link finish with one winner and mirrored HP. 60/60 duels at 35%
frame loss with 20% duplicates reach a terminal state with no contradictory
winners and no HP desync. No widget leak over 200 screen-transition cycles. Both
the source and the shipped body compile under `luac`.

**Not verified:** a two-badge duel on real radios, and the duelling build's
memory at `heap_kb=96`. The harness is a model of the badge, not the badge - it
cannot reproduce ESP32 timing, LVGL allocation, flash latency, or real BLE.

## Open

- **Radio.** Badge-to-badge multiplayer is **not available to Lua apps** on
  this hardware. `badge.radio.enable()` needs ~47 KB of system heap; on a badge
  with a Lua app resident it either fails or, when it does allocate, leaves
  2,968 bytes free - and no Lua app runs in 3 KB. The badge team confirmed it:
  Share works because it is custom C. `badge.nfc` is reader-only and
  `badge.contacts` is read-only, so neither is an alternative channel. See
  `RADIO-ISSUE.md`. Hot-seat multiplayer is the answer, and it is shipped.
- **Memory.** Solved for `goose_solo`: `heap_kb=96`, confirmed on hardware,
  wired and on battery. `goose_duel` now carries the same setting but has not
  been launched with it; its peak at 96 was the one that missed a contiguous
  block by 148 bytes, back when the app was 6 KB larger than it is now. That is
  the open test. The 47.0/48.0 host-side cliff recorded above turned out to be
  a coincidence of two builds, not a real threshold - `used` is flat across a
  25% change in program size - so treat `tools/mem_report.lua` as a regression
  guard, not as a predictor of whether the badge will launch an app.
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
