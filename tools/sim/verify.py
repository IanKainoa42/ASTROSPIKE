"""Self-check for the Python port, against RECORDED Swift behaviour.

Read this before trusting a pass. There is no Swift toolchain here, so this
cannot compare the port to the live simulation. It compares the port to facts
recorded by hand when the port was last synced — at commit f1f28cf, the singles
game before doubles, bolts and the lobby landed.

So a failure is conclusive: the port has broken and its output is fiction. A
pass is not. A pass means only "the port still behaves the way it did when these
numbers were written down"; the port and the recorded numbers can be stale
together, and as of this commit they are. See README.md for the gap.

Re-syncing means porting the Swift change, re-establishing these numbers against
it, and updating SYNCED_AT.

    python3 tools/sim/verify.py
"""

import sys

from ai import DIFF, NewAI
from sim import Arena, Ball, Config, Engine, V

SYNCED_AT = "f1f28cf"  # the ASTROSPIKE commit these numbers were recorded against

DIFFICULTIES = ("rookie", "pilot", "ace")

# Mirrors AIControllerTests.rallyOpenings.
OPENINGS = [
    (0.00, 0.00, 0.00),
    (-0.18, 0.25, -0.10),
    (0.18, -0.25, -0.10),
    (0.00, 0.25, 0.15),
    (-0.18, -0.25, 0.15),
]

failures = []


def check(name, ok, detail):
    print(f"  {'ok  ' if ok else 'FAIL'}  {name}: {detail}")
    if not ok:
        failures.append(name)


def engine():
    """A default engine must equal SimulationEngine.testing() with shipped defaults."""
    return Engine(arena=Arena(), config=Config())


def idle_crosses(pos, vel, limit=1200):
    e = engine()
    e.ball = Ball(V(*pos), V(*vel))
    for tick in range(limit):
        previous_x = e.ball.pos.x
        e.step({"cyan": (0.0, False), "orange": (0.0, False)})
        if previous_x > 0 and e.ball.pos.x < 0:
            return True, tick
        if e.phase != "playing":
            return False, tick
    return False, limit


def ai_returns(pos, vel, difficulty, limit=1200):
    e = engine()
    e.ball = Ball(V(*pos), V(*vel))
    ai = NewAI(difficulty, e.arena, e.config)
    strike_frames = 0
    for tick in range(limit):
        previous_x = e.ball.pos.x
        e.step({"cyan": (0.0, False), "orange": ai.input(e, "orange", tick)})
        if (e.ball.pos - e.ships["orange"].pos).length() < 0.14:
            strike_frames += 1
        if previous_x > 0 and e.ball.pos.x < 0:
            return True, strike_frames
        if e.phase != "playing":
            return False, strike_frames
    return False, strike_frames


def duel(difficulty, opening, ticks=3600):
    x, vx, vy = opening
    e = engine()
    e.ball = Ball(V(x, 0.60), V(vx, vy))
    cyan = NewAI(difficulty, e.arena, e.config)
    orange = NewAI(difficulty, e.arena, e.config)
    crossings = destroyed = 0
    for tick in range(ticks):
        previous_x = e.ball.pos.x
        e.step({
            "cyan": cyan.input(e, "cyan", tick),
            "orange": orange.input(e, "orange", tick),
        })
        if e.phase == "playing" and previous_x * e.ball.pos.x < 0:
            crossings += 1
        destroyed += sum(1 for s in e.ships.values() if s.isDestroyed)
        if e.phase == "finished":
            break
    return crossings, destroyed


print(f"Port self-check against behaviour recorded at {SYNCED_AT}\n")
print("Constants as of that commit")
arena, config = Arena(), Config()
check("net top", arena.netTopY == -0.46, f"{arena.netTopY} (ArenaGeometry.netTopY at {SYNCED_AT})")
check(
    "min ball separation",
    config.minimumBallSeparationSpeed == 0.45,
    f"{config.minimumBallSeparationSpeed} (SimulationConfiguration at {SYNCED_AT})",
)
check("crossing push back", config.crossingPushBack == 30.0, f"{config.crossingPushBack}")
check("crossing drag", config.crossingDrag == 5.0, f"{config.crossingDrag}")
check(
    "difficulty table",
    [DIFF[d]["strike"] for d in DIFFICULTIES] == [1.8, 2.5, 3.2],
    f"strike speeds {[DIFF[d]['strike'] for d in DIFFICULTIES]} (AIDifficulty at {SYNCED_AT})",
)

print("\nNothing in the arena is lethal")
for difficulty in DIFFICULTIES:
    _, destroyed = duel(difficulty, OPENINGS[0])
    check(f"{difficulty} duel has no deaths", destroyed == 0, f"{destroyed} destroyed frames")

print("\nAIControllerTests.pilotReturnsIncomingBall")
crossed, tick = idle_crosses((0.45, 0.25), (0.30, -0.15))
check("idle control does not cross", not crossed, f"crossed={crossed}, left play at tick {tick}")
for difficulty in DIFFICULTIES:
    returned, strikes = ai_returns((0.45, 0.25), (0.30, -0.15), difficulty)
    check(
        f"{difficulty} returns it after striking it",
        returned and strikes > 0,
        f"returned={returned}, strike frames={strikes}",
    )

# Why the old staging was replaced: with the net at -0.46 this one crosses by
# itself, so it could never prove the AI did anything.
crossed, tick = idle_crosses((0.58, 0.32), (-0.10, -0.20))
check(
    "retired staging still crosses unaided",
    crossed,
    f"crossed={crossed} at tick {tick} ({tick / 120:.2f}s)",
)

print("\nAIControllerTests.soloRalliesProduceExchanges")
for difficulty in DIFFICULTIES:
    results = [duel(difficulty, opening) for opening in OPENINGS]
    total = sum(c for c, _ in results)
    quietest = min(c for c, _ in results)
    check(
        f"{difficulty} totals >= 12 and every opening rallies",
        total >= 12 and quietest >= 1,
        f"total={total}, per opening={[c for c, _ in results]}",
    )

if failures:
    print(f"\n{len(failures)} check(s) failed — the port has drifted from the Swift.")
    print("Re-sync it against ASTROSPIKECore before believing any number it gives you.")
    sys.exit(1)
print(f"\nAll checks passed: the port still matches what was recorded at {SYNCED_AT}.")
print("This says nothing about whether the Swift has moved since. Check that too.")
