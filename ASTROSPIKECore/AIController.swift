import Foundation
import simd

public protocol InputSource {
    mutating func input(for state: WorldState, team: Team, tick: UInt64) -> PlayerInput
}

public enum AIDifficulty: String, Codable, CaseIterable, Sendable {
    case rookie
    case pilot
    case ace

    public var reactionIntervalTicks: UInt64 {
        switch self {
        case .rookie: 24
        case .pilot: 12
        case .ace: 6
        }
    }

    public var aimErrorRadians: Double {
        switch self {
        case .rookie: 0.30
        case .pilot: 0.14
        case .ace: 0.04
        }
    }

    public var physicsMultiplier: Double { 1 }
}

public struct AIController: InputSource, Sendable {
    public let difficulty: AIDifficulty
    private var lastDecisionTick: UInt64?
    private var cachedTorque = 0.0
    private var cachedThrust = false

    public init(difficulty: AIDifficulty) {
        self.difficulty = difficulty
    }

    public mutating func input(for state: WorldState, team: Team, tick: UInt64) -> PlayerInput {
        if let lastDecisionTick,
           tick - lastDecisionTick < difficulty.reactionIntervalTicks {
            return PlayerInput(tick: tick, torque: cachedTorque, thrust: cachedThrust)
        }

        guard let ship = state.ships[team] else { return .idle(tick: tick) }
        let nearFloor = ship.position.y < -0.52
        let fallingFast = ship.velocity.y < -1.1
        let recovering = nearFloor && fallingFast
        let nearCenter = abs(ship.position.x) < 0.38
        let facingEnemy = ship.homeSide == .cyan
            ? cos(ship.angle) > 0
            : cos(ship.angle) < 0
        let movingTowardEnemy = ship.homeSide == .cyan
            ? ship.velocity.x > 0.1
            : ship.velocity.x < -0.1

        let desiredAngle: Double
        if recovering {
            desiredAngle = .pi / 2
        } else if nearCenter && (facingEnemy || movingTowardEnemy) {
            desiredAngle = ship.homeSide == .cyan ? .pi : 0
        } else {
            let leadTime: Double = difficulty == .rookie ? 0.10 : difficulty == .pilot ? 0.22 : 0.34
            let predictedBall = state.ball.position + state.ball.velocity * leadTime
            let target = predictedBall - ship.position
            let deterministicError = sin(Double(tick &+ (team == .cyan ? 17 : 43)) * 0.17)
                * difficulty.aimErrorRadians
            desiredAngle = atan2(target.y, target.x) + deterministicError
        }

        let delta = normalizedAngle(desiredAngle - ship.angle)
        cachedTorque = abs(delta) < 0.035 ? 0 : (delta > 0 ? 1 : -1)
        cachedThrust = abs(delta) < (recovering ? 0.30 : 0.58)
            && !(nearCenter && facingEnemy)
        lastDecisionTick = tick
        return PlayerInput(tick: tick, torque: cachedTorque, thrust: cachedThrust)
    }

    private func normalizedAngle(_ angle: Double) -> Double {
        var value = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if value > .pi { value -= 2 * .pi }
        if value < -.pi { value += 2 * .pi }
        return value
    }
}
