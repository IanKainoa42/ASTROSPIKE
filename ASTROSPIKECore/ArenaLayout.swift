import Foundation
import simd

/// A solid piece of the arena standing out from the walls or floating in the
/// court: a segment grown by a radius. With both ends on the same point it is
/// a round peg. The ball, the hulls and the bolts all meet it.
public struct ArenaObstacle: Equatable, Sendable {
    public var start: SIMD2<Double>
    public var end: SIMD2<Double>
    public var radius: Double
    /// Part of the floor rather than something standing on it: a ball that
    /// lands on top of it has bounced, exactly as the corner arcs count.
    /// Pegs and ledges are not ground -- a ball resting on one rolls off.
    public var isGround: Bool

    public init(start: SIMD2<Double>, end: SIMD2<Double>, radius: Double, isGround: Bool = false) {
        self.start = start
        self.end = end
        self.radius = radius
        self.isGround = isGround
    }

    public static func peg(_ center: SIMD2<Double>, radius: Double) -> ArenaObstacle {
        ArenaObstacle(start: center, end: center, radius: radius)
    }

    /// The same obstacle on the other half of the court.
    var mirrored: ArenaObstacle {
        ArenaObstacle(
            start: SIMD2(-start.x, start.y),
            end: SIMD2(-end.x, end.y),
            radius: radius,
            isGround: isGround
        )
    }

    /// Closest point on the spine to `point`.
    func closestPoint(to point: SIMD2<Double>) -> SIMD2<Double> {
        let edge = end - start
        let lengthSquared = simd_length_squared(edge)
        guard lengthSquared > 1e-12 else { return start }
        let t = min(1, max(0, simd_dot(point - start, edge) / lengthSquared))
        return start + edge * t
    }
}

/// Which court the match is played in. Every layout is the same game -- the
/// roof-hung goal, the same rules -- with different surfaces to bank the ball
/// off. Layouts are mirrored across the net so neither half is the lucky one,
/// and changing ends between sets changes nothing.
public enum ArenaLayout: String, Codable, CaseIterable, Sendable {
    /// The shipped court. No obstacles at all.
    case standard
    /// All four corners cut off flat at a steep angle: shots up the side wall
    /// are thrown in toward the goal, and floor rolls kick up early.
    case diamond
    /// Two round pegs a side, out of the way of the goal and the spawns.
    case bumpers
    /// A shelf out of each side wall, sloping down toward the net.
    case ledges

    public var title: String {
        switch self {
        case .standard: "Standard"
        case .diamond: "Diamond"
        case .bumpers: "Bumpers"
        case .ledges: "Ledges"
        }
    }

    /// The right half of the layout, in standard-court units. Mirrored onto
    /// the left and stretched with the court by `ArenaGeometry.laidOut`.
    var rightHalf: [ArenaObstacle] {
        switch self {
        case .standard:
            []
        case .diamond:
            // Both ends buried in the walls, so there is no pocket behind
            // either cut for a ball or a hull to get into.
            [
                ArenaObstacle(start: SIMD2(0.99, 0.22), end: SIMD2(0.58, 0.67), radius: 0.03),
                ArenaObstacle(start: SIMD2(0.99, -0.37), end: SIMD2(0.72, -0.67), radius: 0.03, isGround: true),
            ]
        case .bumpers:
            [
                .peg(SIMD2(0.60, 0.26), radius: 0.06),
                .peg(SIMD2(0.62, -0.18), radius: 0.06),
            ]
        case .ledges:
            [
                ArenaObstacle(start: SIMD2(0.99, 0.14), end: SIMD2(0.68, -0.01), radius: 0.022),
            ]
        }
    }
}

extension ArenaGeometry {
    /// This court with `layout`'s obstacles built into it, stretched with the
    /// court so the doubles arena keeps the same angles.
    public func laidOut(_ layout: ArenaLayout) -> ArenaGeometry {
        var court = self
        court.layout = layout
        let scale = SIMD2(widthScale, heightScale)
        let right = layout.rightHalf.map { obstacle in
            ArenaObstacle(
                start: obstacle.start * scale,
                end: obstacle.end * scale,
                radius: obstacle.radius * widthScale,
                isGround: obstacle.isGround
            )
        }
        court.obstacles = right + right.map(\.mirrored)
        return court
    }

    /// Pushes a body of `radius` off the obstacle it is deepest into, if any.
    /// A centre dead on the spine has no side; it is sent up, which for every
    /// shipped obstacle is back into the court.
    public func obstacleContact(
        position: SIMD2<Double>,
        radius: Double
    ) -> (position: SIMD2<Double>, normal: SIMD2<Double>, isGround: Bool)? {
        var best: (position: SIMD2<Double>, normal: SIMD2<Double>, isGround: Bool)?
        var deepest = 0.0
        for obstacle in obstacles {
            let closest = obstacle.closestPoint(to: position)
            let away = position - closest
            let distance = simd_length(away)
            let reach = radius + obstacle.radius
            let depth = reach - distance
            guard depth > 0, depth > deepest else { continue }
            let normal = distance > 1e-9 ? away / distance : SIMD2(0, 1)
            deepest = depth
            best = (closest + normal * reach, normal, obstacle.isGround)
        }
        return best
    }

    /// Swept in radius-sized slices, like the hump: an obstacle is convex and
    /// thin next to how far a driven ball travels in a tick.
    public func obstacleContact(
        from start: SIMD2<Double>,
        to end: SIMD2<Double>,
        radius: Double
    ) -> (position: SIMD2<Double>, normal: SIMD2<Double>, isGround: Bool)? {
        guard !obstacles.isEmpty else { return nil }
        let travel = simd_distance(start, end)
        let steps = max(1, min(32, Int((travel / max(radius * 0.5, 1e-4)).rounded(.up))))
        for step in 1 ... steps {
            let sample = start + (end - start) * (Double(step) / Double(steps))
            if let contact = obstacleContact(position: sample, radius: radius) {
                return contact
            }
        }
        return nil
    }
}
