## Inspiration

Waterloo geese are a campus institution: territorial, fearless, and completely
unbothered by the humans they outrank. Hack the North handed every hacker an
ESP32 badge with six RGB LEDs, a 320x240 screen, and a radio — and the obvious
thing to build for a room full of people wearing the same hardware is a reason
to walk up to a stranger and fight them. So: a Pokemon-style battler where your
goose levels up over the weekend and you duel the badge standing next to you.

## What it does

**Goose Duel** is a 1v1 turn-based battler that runs on the Hacker Badge.

- Pick one of four geese — Campus Honker, Ring Road Runner, Bread Baron, Alpha
  Gander — each with its own type, stats, and four moves.
- Three types in a triangle: **Honk > Flap > Peck > Honk**, at 1.5x / 1.0x /
  0.66x. Both fighters' types and every move's type are shown on screen,
  because the matchup is the whole game.
- **Solo mode** fights a CPU goose for practice. **Duel mode** finds another
  badge over the radio and plays a real lockstep match against it — no cable,
  no server, just stand next to each other.
- Your goose persists: level, XP, wins and losses are saved to the badge store
  and carried between sessions. Stats scale per level to a cap of 50.
- All six LEDs are part of the game. The left column is your HP bar, the right
  is your opponent's, green to amber to red as the fight goes; hits flash the
  struck side in the move's type colour; seeking chases around the perimeter;
  a win is a gold chase, a loss a red fade.

## How we built it

Lua, one file, on the badge's sandboxed `badge.*` API — no `os`, no `io`, no
`coroutine`, no `pcall`, physical buttons only, and hard callback deadlines
(3000 ms to enter, 250 ms shared across `on_tick` and `on_recv`). The app is a
state machine: `MENU -> PICK -> (SOLO | SEEK -> PAIRED) -> BATTLE -> RESULT`,
with every animation and timeout driven off timestamps rather than sleeping.

The interesting engineering is the badge-to-badge link. The original plan was
USB, until we established there is no Lua USB API at all — USB is only the
IDE's push channel. So the duel runs over `badge.radio`: a BLE broadcast
channel with 44-byte payloads, an 8-slot receive ring, and **no delivery
acknowledgement**. Frames drop, duplicate, and are visible to every other badge
in the room.

Our answer was to make desync impossible by construction: **neither badge ever
transmits HP or damage.** Each sends only the move it chose, and both compute
the identical outcome from a seed agreed at pairing, using a shared PRNG
(`rng = (rng * 75 + 74) % 65537`) small enough to be exact in any number
representation. On top of that:

- A five-message ASCII protocol (Hello / Pair / Move / Keepalive / Bye).
- The **lower session id hosts** — a tie-break both badges compute identically,
  so pairing needs no negotiation round.
- Each badge rebroadcasts its move every 300 ms until the peer's move for that
  turn arrives. Retransmission *is* the loss-recovery mechanism.
- A frame is ignored unless it carries the right prefix, the agreed session id,
  and a turn this badge is actually waiting on — which handles duplicates,
  stale frames, and the six other games happening nearby.

Because only hardware proves an app works, we wrote `tools/harness.lua`: a mock
of the documented badge API — widgets, LEDs, store, buttons, and a radio two
instances can talk over — so the real `main.lua` can be driven through full
battles with injected frame loss and duplication. It asserts the documented
limits (integer LED channels, 44-byte payloads, the 512-widget cap) and raises
on use of a deleted widget handle, so violations fail in CI instead of on a
badge in front of a judge.

## Challenges we ran into

**The memory ceiling, which was not what we thought.** The badge compiles the
entire file before `on_enter` runs, and that compile kept failing. We spent
three rounds cutting the app down. Then we measured: deleting multiplayer
entirely — 25% of the program, 5 KB of bytecode — moved reported `used` by
**20 bytes**. Roughly 39 KB of the 48 KiB quota is consumed before our app
exists, and the allocation actually being refused is a single contiguous block
of 7.6 KB or more. Comment stripping removed 30% of the source and *zero*
compiled bytes. The fix was the one knob that acts on a fixed floor:
`heap_kb=96`, confirmed booting on hardware on USB and on battery.

**Two lockstep bugs the harness caught**, both of which would have broken real
duels. First, whoever paired first raced ahead: the host broadcast its turn-1
move while the guest was still seeking, then only ever retransmitted the
*current* turn — so the guest waited forever for a move nobody would send
again. Fix: badges answer catch-up requests for the turn they just resolved,
from the result screen too. Second, winning could hand your opponent a win as
well, because `finish()` sent a Bye and a Bye reads as "opponent quit, I win".
Fix: Bye now means only a real forfeit. A third we caught by reasoning: on a
speed tie both badges draw the same number, so breaking the tie toward "me"
desyncs 100% of ties — which happen every time both players pick the same
goose.

**Battery.** The LEDs dominate draw, so every colour constant in the file is
pre-scaled to ~24% (free at runtime, unlike scaling on the way to the strip),
the strip blanks entirely after 20 s idle, the LED refresh is 90 ms instead of
50, and `wake_lock` is taken only for the duel search and released after,
instead of being set in the manifest where it would hold the badge awake for
the entire session. Ten minutes idle on the menu went from 9,568,500 to 72,492
energy units — two orders of magnitude.

**And the one we could not fix ourselves:** `badge.radio.enable()` returns
false on our firmware in every app we tried, down to a 1.2 KB app that does
nothing else (`E BLE_INIT: nimble host init failed`). We tested app size,
allocation order, GC, `heap_kb`, `wake_lock`, and USB versus battery; the
built-in Share app uses Bluetooth fine on the same badge. We wrote it up with a
minimal reproduction for the badge team rather than guessing.

## Accomplishments that we're proud of

- **Balance that was measured, not guessed.** 300 simulated battles per
  configuration. We swept the damage divisor 3..9 — at 3, fights ended in 2.8
  rounds; 8 gives 6.3 rounds, which was the target. Move choice swings win rate
  from 17% to 44%, a 2.6x spread, which is why both fighters' types are on
  screen at all times; the matchup was unplayable while hidden. The CPU plays
  the optimal move half the time, because always-optimal made practice
  punishing instead of encouraging.
- **A duel protocol that cannot desync**, verified at 35% frame loss with 20%
  duplicates: 60/60 duels reach a terminal state with no contradictory winners
  and no HP drift.
- **A 132x reduction in idle LED energy** without the game looking any dimmer
  in use.
- **A shipped single-badge build.** `apps/goose_solo/` is the same game with
  the radio removed, 34.2 KB against 47.2 KB, installable alongside the
  duelling build — so the game is playable regardless of how the radio question
  resolves.
- Being honest about the line: `goose_solo` at `heap_kb=96` is confirmed on
  hardware. Everything else is verified in simulation, and we say so.

## What we learned

- **Measure the thing you think is the constraint before optimizing it.** Three
  rounds of feature-cutting moved the real number by 46 bytes. One manifest
  line fixed it.
- **Runtime manifest options need a Reboot, not a Push.** A `heap_kb` value sat
  in our repo for four commits having never once run on the badge — every
  measurement taken in that window was taken under the old value.
- **"Sent" is not "delivered."** Designing around a lossy broadcast with no
  acks means never showing a hit on send, only on a confirmed exchange, and
  treating retransmission as the mechanism rather than the fallback.
- **Determinism beats synchronization.** Sending the input and recomputing the
  result on both sides is smaller, simpler, and impossible to desync compared
  to sending state.
- An emulator is a model of the device, not the device. Ours caught two
  protocol bugs and could not have caught a single one of the memory or BLE
  problems.

## What's next for Goose battle

- **Confirm the duelling build on hardware** at `heap_kb=96`, and get an answer
  from the badge team on `badge.radio.enable()` — the protocol is written,
  tested under loss, and waiting on a working radio.
- **A real two-badge duel on real radios**, which is the one thing simulation
  fundamentally cannot prove.
- **Walking XP**: level up your goose by moving around the venue. The design
  problem to solve first is that apps only run in the foreground, so the badge
  cannot count steps while the app is closed.
- **More geese and a fourth type**, now that we have the measurement harness to
  balance them properly.
- **Tournaments**: a bracket across more than two badges, which needs
  addressing and ordering on top of the broadcast channel we already have.
- A 42x42 image icon, once pushes stop stalling.
