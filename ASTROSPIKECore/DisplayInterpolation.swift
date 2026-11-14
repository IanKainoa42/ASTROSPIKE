import Foundation
import simd

/// Blends two authoritative ticks for display while physics stays on the fixed
/// step. Discrete book-keeping (`tick`, match phase, cooldowns) comes from the
/// newer state; only motion is eased between them.
public enum DisplayInterpolation {
    public static func between(_ earlier: WorldState, _ later: WorldState, alpha: Double) -> WorldState {
        let t = min(1, max(0, alpha))
        if t <= 0 { return earlier }
        if t >= 1 { return later }

        var shown = later
        let seats = Set(earlier.ships.keys).union(later.ships.keys)
        for seat in seats {
            guard var after = later.ships[seat], let before = earlier.ships[seat] else { continue }
            after.position = simd_mix(before.position, after.position, t)
            after.velocity = simd_mix(before.velocity, after.velocity, t)
            after.angle = interpolateAngle(from: before.angle, to: after.angle, t: t)
            after.angularVelocity = before.angularVelocity + (after.angularVelocity - before.angularVelocity) * t
            shown.ships[seat] = after
        }

        let ballCount = max(earlier.balls.count, later.balls.count)
        if ballCount > 0 {
            shown.balls = (0 ..< ballCount).map { index in
                guard index < earlier.balls.count, index < later.balls.count else {
                    return index < later.balls.count ? later.balls[index] : earlier.balls[index]
                }
                var ball = later.balls[index]
                let before = earlier.balls[index]
                ball.position = simd_mix(before.position, ball.position, t)
                ball.velocity = simd_mix(before.velocity, ball.velocity, t)
                ball.spin = before.spin + (ball.spin - before.spin) * t
                return ball
            }
        }

        shown.bolts = zip(earlier.bolts, later.bolts).enumerated().map { index, pair in
            var bolt = pair.1
            bolt.position = simd_mix(pair.0.position, bolt.position, t)
            bolt.velocity = simd_mix(pair.0.velocity, bolt.velocity, t)
            return bolt
        }
        if later.bolts.count > earlier.bolts.count {
            shown.bolts.append(contentsOf: later.bolts.suffix(later.bolts.count - earlier.bolts.count))
        }

        let bumperCount = max(earlier.bumpers.count, later.bumpers.count)
        if bumperCount > 0 {
            shown.bumpers = (0 ..< bumperCount).map { index in
                guard index < earlier.bumpers.count, index < later.bumpers.count else {
                    return index < later.bumpers.count ? later.bumpers[index] : earlier.bumpers[index]
                }
                var bumper = later.bumpers[index]
                let before = earlier.bumpers[index]
                bumper.offset = simd_mix(before.offset, bumper.offset, t)
                bumper.velocity = simd_mix(before.velocity, bumper.velocity, t)
                return bumper
            }
        }

        return shown
    }

    private static func interpolateAngle(from: Double, to: Double, t: Double) -> Double {
        var delta = to - from
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return from + delta * t
    }
}

private func simd_mix(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ t: Double) -> SIMD2<Double> {
    a + (b - a) * t
}