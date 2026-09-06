import Foundation
import simd

/// A floating hoop in the warm-up bay. Fly the ball through it, or put a bolt
/// through it, and it pops and turns up somewhere else.
public struct WarmupRing: Codable, Equatable, Sendable, Identifiable {
    public let id: UInt64
    public var position: SIMD2<Double>
    public var radius: Double

    public init(id: UInt64, position: SIMD2<Double>, radius: Double) {
        self.id = id
        self.position = position
        self.radius = radius
    }
}

/// The hoops are the bay's only scoreboard that is not the ball, so they
/// live in Core where the pop test is deterministic and testable.
public struct WarmupRings: Equatable, Sendable {
    public static let ringRadius = 0.075
    public private(set) var rings: [WarmupRing]
    public private(set) var popped = 0
    private var seed: UInt64
    private var nextID: UInt64 = 0

    public init(count: Int = 3, seed: UInt64 = 7, arena: ArenaGeometry = .standard) {
        self.seed = seed
        rings = []
        for _ in 0 ..< max(0, count) {
            rings.append(spawn(avoiding: nil, arena: arena))
        }
    }

    /// Pops every ring the ball or a bolt is inside, respawns it clear of the
    /// ball, and returns the rings that popped so the scene can burst them.
    public mutating func observe(_ state: WorldState, arena: ArenaGeometry = .standard) -> [WarmupRing] {
        var burst: [WarmupRing] = []
        for index in rings.indices {
            let ring = rings[index]
            let ballInside = simd_length(state.ball.position - ring.position) <= ring.radius
            let boltInside = state.bolts.contains { simd_length($0.position - ring.position) <= ring.radius }
            guard ballInside || boltInside else { continue }
            burst.append(ring)
            popped += 1
            rings[index] = spawn(avoiding: state.ball.position, arena: arena)
        }
        return burst
    }

    private mutating func next() -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(seed >> 11) / Double(1 << 53)
    }

    private mutating func spawn(avoiding ball: SIMD2<Double>?, arena: ArenaGeometry) -> WarmupRing {
        let radius = Self.ringRadius
        var position = SIMD2<Double>(0, 0)
        for _ in 0 ..< 24 {
            position = SIMD2(
                (next() * 2 - 1) * (arena.halfWidth - radius - 0.12),
                arena.floorY + radius + 0.10 + next() * (arena.ceilingY - arena.floorY - radius * 2 - 0.42)
            )
            // Keep out of the roof-hung goal and its lips.
            let underTheGoal = abs(position.x) < arena.humpBaseX + radius && position.y > arena.netBottomY - 0.16
            if underTheGoal { continue }
            if let ball, simd_length(ball - position) < 0.30 { continue }
            if rings.contains(where: { simd_length($0.position - position) < radius * 3 }) { continue }
            break
        }
        nextID += 1
        return WarmupRing(id: nextID, position: position, radius: radius)
    }
}
