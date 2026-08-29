import Foundation
import simd

public struct BallState: Codable, Equatable, Sendable {
    public var position: SIMD2<Double>
    public var velocity: SIMD2<Double>
    public var radius: Double

    public init(
        position: SIMD2<Double>,
        velocity: SIMD2<Double> = .zero,
        radius: Double = 0.045
    ) {
        self.position = position
        self.velocity = velocity
        self.radius = radius
    }
}

public struct ArenaGeometry: Equatable, Sendable {
    public var halfWidth: Double
    public var floorY: Double
    public var ceilingY: Double
    public var netHalfWidth: Double
    public var netTopY: Double
    public var goalInnerX: Double
    public var goalOuterX: Double
    public var goalMinimumDownwardSpeed: Double

    public init(
        halfWidth: Double = 0.96,
        floorY: Double = -0.78,
        ceilingY: Double = 0.78,
        netHalfWidth: Double = 0.018,
        netTopY: Double = -0.46,
        goalInnerX: Double = 0.018,
        goalOuterX: Double = 0.128,
        goalMinimumDownwardSpeed: Double = 0.25
    ) {
        self.halfWidth = halfWidth
        self.floorY = floorY
        self.ceilingY = ceilingY
        self.netHalfWidth = netHalfWidth
        self.netTopY = netTopY
        self.goalInnerX = goalInnerX
        self.goalOuterX = goalOuterX
        self.goalMinimumDownwardSpeed = goalMinimumDownwardSpeed
    }

    public static let standard = ArenaGeometry()

    public var opponentCrossingLimit: Double { halfWidth / 2 }

    public func goalDefender(for ball: BallState) -> Team? {
        guard ball.velocity.y < -goalMinimumDownwardSpeed else { return nil }
        let absoluteX = abs(ball.position.x)
        guard absoluteX >= goalInnerX, absoluteX <= goalOuterX else { return nil }
        let sideSign = ball.position.x < 0 ? -1.0 : 1.0
        guard ball.velocity.x * sideSign > 0.05 else { return nil }
        let diagonalRoofY = floorY + (absoluteX - goalInnerX)
        guard ball.position.y <= diagonalRoofY + ball.radius else { return nil }
        return ball.position.x < 0 ? .cyan : .orange
    }
}
