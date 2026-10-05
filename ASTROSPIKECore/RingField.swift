import Foundation
import simd

/// The free-for-all field: a round arena with gravity pulling out to the
/// rim, and a hub in the middle that every goal hangs from. Nobody has an end
/// wall at their back, so nobody's goal is the corner the ball rolls into.
///
/// Each goal is the duel court's goal turned to point outward. Its own frame
/// -- the goal at x = 0 hanging down from y = `spoke.humpUndersideY`, the rim
/// directly below at `spoke.floorY` -- is exactly the duel court around its
/// net, so the swept face, cap and lip tests run there unchanged. Only the
/// hub and the rim are new, and they are circles.
public struct RingField: Equatable, Sendable {
    /// Room the goals hang from. Sized so four goals and their lips leave a
    /// hull's width of open hub between them, and no bigger: every unit on
    /// the radius makes the whole field smaller on screen.
    public static let hubRadius = 0.40

    public var hubRadius: Double
    /// Hub to rim is the duel court's hump underside to floor, so the drop
    /// under every goal is the duel's.
    public var rimRadius: Double
    /// The way each goal points, out from the centre. Goal 0 points straight
    /// down, so the bottom of the screen looks like a duel.
    public var spokeAngles: [Double]
    public var ballRadius: Double

    public init(pilots: Int, ballRadius: Double) {
        let count = max(2, pilots)
        self.ballRadius = ballRadius
        hubRadius = Self.hubRadius
        let court = ArenaGeometry.standard(ballRadius: ballRadius)
        rimRadius = Self.hubRadius + (court.humpUndersideY - court.floorY)
        spokeAngles = (0 ..< count).map { -.pi / 2 + Double($0) * 2 * .pi / Double(count) }
    }

    /// The duel court every goal is a copy of, in that goal's own frame.
    public var spoke: ArenaGeometry { .standard(ballRadius: ballRadius) }

    /// Where the hub's centre sits in a goal's own frame.
    public var hubCentreY: Double { spoke.humpUndersideY + hubRadius }

    private func turn(_ v: SIMD2<Double>, by angle: Double) -> SIMD2<Double> {
        let (c, s) = (cos(angle), sin(angle))
        return SIMD2(v.x * c - v.y * s, v.x * s + v.y * c)
    }

    /// How far goal `index`'s frame is turned from the world's.
    public func frameAngle(_ index: Int) -> Double { spokeAngles[index] + .pi / 2 }

    public func toLocal(_ point: SIMD2<Double>, spoke index: Int) -> SIMD2<Double> {
        turn(point, by: -frameAngle(index)) + SIMD2(0, hubCentreY)
    }

    public func toWorld(_ point: SIMD2<Double>, spoke index: Int) -> SIMD2<Double> {
        turn(point - SIMD2(0, hubCentreY), by: frameAngle(index))
    }

    public func vectorToLocal(_ vector: SIMD2<Double>, spoke index: Int) -> SIMD2<Double> {
        turn(vector, by: -frameAngle(index))
    }

    public func vectorToWorld(_ vector: SIMD2<Double>, spoke index: Int) -> SIMD2<Double> {
        turn(vector, by: frameAngle(index))
    }

    /// The goal whose direction is nearest `point`'s.
    public func spokeIndex(nearest point: SIMD2<Double>) -> Int {
        let bearing = atan2(point.y, point.x)
        func gap(_ index: Int) -> Double { abs(remainder(bearing - spokeAngles[index], 2 * .pi)) }
        return spokeAngles.indices.min { gap($0) < gap($1) } ?? 0
    }

    /// Straight out from the centre: the way gravity pulls at `point`.
    public func outward(at point: SIMD2<Double>) -> SIMD2<Double> {
        let distance = simd_length(point)
        return distance > 0.000_001 ? point / distance : SIMD2(0, -1)
    }

    /// Spin gravity at `point`: straight out, nothing at the centre, growing
    /// in step with the distance to `rim` at the rim itself. The goals on the
    /// hub sit in light air and only the rim pulls with full weight.
    public func gravity(at point: SIMD2<Double>, rim strength: Double) -> SIMD2<Double> {
        point * (strength / rimRadius)
    }

    /// The middle of goal `index`'s mouth, in the world.
    public func mouthCentre(_ index: Int) -> SIMD2<Double> {
        let court = spoke
        return toWorld(SIMD2(0, (court.portalMouthTopY + court.netBottomY) / 2), spoke: index)
    }
}
