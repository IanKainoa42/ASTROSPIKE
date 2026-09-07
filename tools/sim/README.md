# Python port of the ASTROSPIKE simulation

> **This port is stale. It models the singles game as of commit `f1f28cf`.**
> It is committed as a working starting point, not as a current mirror. Re-sync
> it before its numbers mean anything about today's game — see *The gap* below.

A port of `ASTROSPIKECore`'s deterministic simulation and solo AI: the fixed
120 Hz step, swept-circle collision, the net and crossing spring, the scoring
rules, and `AIController`'s prediction and guidance law.

It exists because tuning the AI means running the rally hundreds of times and
comparing outcomes, and a Swift toolchain is not always at hand — an agent
container has none at all. This runs anywhere Python 3 does, in seconds, with no
dependencies.

## Use it

```sh
cd tools/sim
python3 verify.py     # self-check; read what a pass does and does not mean
python3 measure.py    # sample AI behaviour across 18 openings
```

## The gap

Everything below landed after this port was synced and is **not** modelled:

| area | on `main` | here |
|---|---|---|
| `strikeStandoff` | 0.107 | 0.145 |
| `strikeRunup` | 0.18 | 0.24 |
| `driveWindow` | 0.55 | 0.40 |
| `floorY` | −0.64 | −0.78 |
| `aimDepthUnderCap`, `turnLatency`, `thrustAlignment`, `fireAlignment` | present | absent |
| doubles and the `Seat` model | present | singles `Team` only |
| bolts, exhaust wash, hulls | present | absent |

Re-syncing means porting those into `sim.py` and `ai.py`, re-establishing the
recorded numbers in `verify.py` against the new Swift, and updating `SYNCED_AT`.

## What `verify.py` can and cannot tell you

There is no Swift toolchain in an agent container, so `verify.py` cannot compare
the port to the live simulation. It compares the port to facts recorded by hand
at `SYNCED_AT`.

- **A failure is conclusive.** The port has broken; its output is fiction.
- **A pass is not.** It means only that the port behaves the way it did when
  those numbers were written down. The port and the recorded numbers go stale
  together — which is exactly the state it is in now.

So a pass is necessary, never sufficient. Also check whether the Swift has moved.

## Keeping it honest

When you change `ASTROSPIKECore`, port the change here in the same session and
re-run `verify.py`. Change tuning constants in both places or in neither. Resist
adding knobs with no Swift counterpart: an experimental `SPEED_CAP` lived here
briefly and had to be removed, because a port that can do things the game cannot
is no longer evidence about the game.

This drifts easily, and quietly. It has already done so three times:

- The `Arena` and `Config` defaults kept the old net height (`-0.26`) and no
  minimum ball separation, so anything run without explicit overrides silently
  modelled a game that no longer existed.
- The lethal collision paths survived here for a session after `no-crashing`
  removed them from the Swift, so idle ships "died" where the real game lands
  them safely.
- Doubles, bolts and the new AI constants landed while this was being committed.

The first two were caught only because a result looked wrong and got checked by
hand. `verify.py` exists so that class of drift is caught by one command instead.

## What it is good for, and what it is not

Good for: comparing tunings, sampling behaviour across many openings, testing
whether a hunch about the AI survives contact with numbers, and reproducing a CI
failure when there is no compiler. It earned its keep once already — it
reproduced two CI failures exactly and showed that an `ace` that looked broken on
one opening was averaging the same as every other difficulty across eighteen.

Not good for: anything above the simulation. No SpriteKit, SwiftUI, GameKit,
touch handling or rendering. It cannot tell you whether the game *feels* right,
only what the physics and the AI do. Agreement here is evidence, never proof —
the tests on a real simulator are what gate a change.

## Layout

| file | what it is |
|---|---|
| `sim.py` | the simulation: arena, ball, ships, collisions, scoring |
| `ai.py` | the solo AI, mirroring `AIController.swift` |
| `verify.py` | self-check against behaviour recorded at `SYNCED_AT` |
| `measure.py` | samples crossings and ball touches across 18 openings |
