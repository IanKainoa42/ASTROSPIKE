"""Sample AI behaviour across many openings instead of one.

A duel is chaotic: one thirty-second run tells you about that run, not about the
AI. This is the harness that settled it — judged on a single opening the ace
looked broken at one crossing; sampled across eighteen it averaged 7.5, the same
as every other difficulty, and the opening was simply a bad draw.

    python3 tools/sim/measure.py            # all difficulties
    python3 tools/sim/measure.py ace        # one of them
"""

import statistics
import sys

from ai import NewAI
from sim import Arena, Ball, Config, Engine, V

DIFFICULTIES = ("rookie", "pilot", "ace")

# Eighteen openings: three release points, three lateral speeds, two vertical.
SEEDS = [
    (x, vx, vy)
    for x in (0.0, -0.18, 0.18)
    for vx in (-0.25, 0.0, 0.25)
    for vy in (-0.1, 0.15)
]


def duel(difficulty, seed, ticks=3600):
    """One AI-vs-AI rally. Returns (net crossings, ball-on-hull contacts)."""
    x, vx, vy = seed
    engine = Engine(arena=Arena(), config=Config())
    engine.ball = Ball(V(x, 0.60), V(vx, vy))
    cyan = NewAI(difficulty, engine.arena, engine.config)
    orange = NewAI(difficulty, engine.arena, engine.config)
    crossings = touches = 0
    for tick in range(ticks):
        previous_x = engine.ball.pos.x
        engine.step({
            "cyan": cyan.input(engine, "cyan", tick),
            "orange": orange.input(engine, "orange", tick),
        })
        if engine.phase == "playing" and previous_x * engine.ball.pos.x < 0:
            crossings += 1
        touches += sum(1 for c in engine.contacts if c[0] == "ship")
        if engine.phase == "finished":
            break
    return crossings, touches


def main(difficulties):
    print(f"{len(SEEDS)} openings per difficulty, 30s each\n")
    print(f"{'difficulty':<10} {'crossings':>10} {'touches':>9} {'worst':>6} {'under 4':>9}")
    for difficulty in difficulties:
        results = [duel(difficulty, seed) for seed in SEEDS]
        crossings = [c for c, _ in results]
        touches = [t for _, t in results]
        print(
            f"{difficulty:<10} {statistics.mean(crossings):>10.1f} "
            f"{statistics.mean(touches):>9.1f} {min(crossings):>6d} "
            f"{sum(1 for c in crossings if c < 4):>6d}/{len(SEEDS)}"
        )
    print("\nA single run is noise. Compare means, and treat a lone bad opening"
          "\nas a draw rather than a defect until the mean moves with it.")


if __name__ == "__main__":
    requested = sys.argv[1:] or list(DIFFICULTIES)
    unknown = [d for d in requested if d not in DIFFICULTIES]
    if unknown:
        sys.exit(f"unknown difficulty {unknown[0]!r}; choose from {', '.join(DIFFICULTIES)}")
    main(requested)
