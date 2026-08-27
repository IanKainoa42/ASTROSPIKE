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
    private var cachedTargetPosition: SIMD2<Double>?
    private var cachedAimError = 0.0
    private var cachedHomeSide: Team?

    public init(difficulty: AIDifficulty) {
        self.difficulty = difficulty
    }

    public mutating func input(for state: WorldState, team: Team, tick: UInt64) -> PlayerInput {
        guard let ship = state.ships[team] else { return .idle(tick: tick) }
        let homeSign = ship.homeSide == .cyan ? -1.0 : 1.0
        let projectedHomeDistance = (ship.position.x + ship.velocity.x * 1.20) * homeSign
        let centerDanger = projectedHomeDistance < 0.32
        let nearFloor = ship.position.y < -0.52
        let recovering = nearFloor
        let needsDecision = cachedTargetPosition == nil
            || cachedHomeSide != ship.homeSide
            || lastDecisionTick.map { tick - $0 >= difficulty.reactionIntervalTicks } != false

        if needsDecision {
            let ballIsHome = state.ball.position.x * homeSign > 0
            let lookAhead: Double = difficulty == .rookie ? 0.10 : difficulty == .pilot ? 0.22 : 0.34
            if ballIsHome {
                let predictedBall = state.ball.position + state.ball.velocity * lookAhead
                let safeX = homeSign * max(0.34, min(0.84, abs(predictedBall.x) + 0.10))
                cachedTargetPosition = SIMD2(
                    safeX,
                    max(-0.55, min(0.55, predictedBall.y - 0.10))
                )
            } else {
                cachedTargetPosition = SIMD2(homeSign * 0.52, -0.18)
            }
            cachedAimError = sin(Double(tick &+ (team == .cyan ? 17 : 43)) * 0.17)
                * difficulty.aimErrorRadians
            cachedHomeSide = ship.homeSide
            lastDecisionTick = tick
        }

        let targetPosition = cachedTargetPosition ?? SIMD2(homeSign * 0.52, -0.18)
        let positionError = targetPosition - ship.position
        let desiredVelocity = SIMD2(
            max(-1.6, min(1.6, positionError.x * 1.8)),
            max(-1.3, min(1.3, positionError.y * 1.8))
        )
        var desiredAcceleration = (desiredVelocity - ship.velocity) * 2.5
            + SIMD2(0, 3.2)
        if centerDanger {
            desiredAcceleration.x = homeSign * (6 + abs(ship.velocity.x) * 2)
        }

        let desiredAngle: Double
        if centerDanger {
            desiredAngle = atan2(desiredAcceleration.y, desiredAcceleration.x)
        } else if recovering {
            desiredAngle = .pi / 2
        } else {
            desiredAngle = atan2(desiredAcceleration.y, desiredAcceleration.x)
                + cachedAimError
        }

        let angleError = normalizedAngle(desiredAngle - ship.angle)
        let turnDemand = angleError * 2.4 - ship.angularVelocity * 1.35
        let torque = abs(turnDemand) < 0.08 ? 0 : max(-1, min(1, turnDemand))
        let thrust: Bool
        if centerDanger {
            thrust = cos(ship.angle) * homeSign > 0.25
        } else {
            thrust = simd_length(desiredAcceleration) > 0.8
                && abs(angleError) < (recovering ? 0.30 : 0.48)
                && abs(ship.angularVelocity) < 1.1
        }
        return PlayerInput(tick: tick, torque: torque, thrust: thrust)
    }

    private func normalizedAngle(_ angle: Double) -> Double {
        var value = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if value > .pi { value -= 2 * .pi }
        if value < -.pi { value += 2 * .pi }
        return value
    }
}
