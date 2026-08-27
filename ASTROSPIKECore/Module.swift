import Foundation
import simd

public enum Team: String, Codable, CaseIterable, Sendable {
    case cyan
    case orange
}

public struct PlayerInput: Codable, Equatable, Sendable {
    public var tick: UInt64
    public var torque: Double
    public var thrust: Bool

    public init(tick: UInt64, torque: Double, thrust: Bool) {
        self.tick = tick
        self.torque = max(-1, min(1, torque))
        self.thrust = thrust
    }

    public static func idle(tick: UInt64) -> PlayerInput {
        PlayerInput(tick: tick, torque: 0, thrust: false)
    }
}

public struct ShipState: Codable, Equatable, Sendable {
    public var position: SIMD2<Double>
    public var velocity: SIMD2<Double>
    public var angle: Double
    public var angularVelocity: Double
    public var isDestroyed: Bool
    public var thrustLevel: Double
    public var homeSide: Team

    public init(
        position: SIMD2<Double>,
        velocity: SIMD2<Double> = .zero,
        angle: Double,
        angularVelocity: Double = 0,
        isDestroyed: Bool = false,
        thrustLevel: Double = 0,
        homeSide: Team? = nil
    ) {
        self.position = position
        self.velocity = velocity
        self.angle = angle
        self.angularVelocity = angularVelocity
        self.isDestroyed = isDestroyed
        self.thrustLevel = thrustLevel
        self.homeSide = homeSide ?? (position.x < 0 ? .cyan : .orange)
    }
}

public struct WorldState: Codable, Equatable, Sendable {
    public var tick: UInt64
    public var ships: [Team: ShipState]
    public var ball: BallState
    public var match: MatchRuleState

    public init(
        tick: UInt64 = 0,
        ships: [Team: ShipState],
        ball: BallState = BallState(position: SIMD2(0, 0.28)),
        match: MatchRuleState = MatchRuleState()
    ) {
        self.tick = tick
        self.ships = ships
        self.ball = ball
        self.match = match
    }
}

public struct SimulationConfiguration: Equatable, Sendable {
    public var stepDuration: Double
    public var gravity: SIMD2<Double>
    public var initialThrustAcceleration: Double
    public var maximumThrustAcceleration: Double
    public var thrustRampRate: Double
    public var torqueAcceleration: Double

    public init(
        stepDuration: Double = 1.0 / 120.0,
        gravity: SIMD2<Double> = SIMD2(0, -1.2),
        initialThrustAcceleration: Double = 3,
        maximumThrustAcceleration: Double = 18,
        thrustRampRate: Double = 24,
        torqueAcceleration: Double = 5
    ) {
        self.stepDuration = stepDuration
        self.gravity = gravity
        self.initialThrustAcceleration = initialThrustAcceleration
        self.maximumThrustAcceleration = maximumThrustAcceleration
        self.thrustRampRate = thrustRampRate
        self.torqueAcceleration = torqueAcceleration
    }
}

public struct SimulationEngine: Sendable {
    public private(set) var configuration: SimulationConfiguration
    public var state: WorldState
    public private(set) var lastEvents: [SimulationEvent]
    public private(set) var arena: ArenaGeometry
    private var rules: MatchRules

    public init(
        state: WorldState,
        configuration: SimulationConfiguration = .init(),
        arena: ArenaGeometry = .standard
    ) {
        self.state = state
        self.configuration = configuration
        self.lastEvents = []
        self.arena = arena
        self.rules = MatchRules(state: state.match)
    }

    public static func testing() -> SimulationEngine {
        SimulationEngine(state: WorldState(ships: [
            .cyan: ShipState(position: SIMD2(-0.55, -0.55), angle: .pi / 2),
            .orange: ShipState(position: SIMD2(0.55, -0.55), angle: .pi / 2),
        ]))
    }

    public mutating func prepareNextRally(mirrored: Bool) {
        guard state.match.phase != .finished else { return }
        let direction = mirrored ? 1.0 : -1.0
        state.ships = [
            .cyan: ShipState(position: SIMD2(0.55 * direction, -0.55), angle: .pi / 2),
            .orange: ShipState(position: SIMD2(-0.55 * direction, -0.55), angle: .pi / 2),
        ]
        state.ball = BallState(position: SIMD2(0, 0.28), velocity: SIMD2(0, -0.18))
        rules.prepareNextRally()
        state.match = rules.state
        lastEvents = [.rallyReset]
    }

    public mutating func beginPlay() {
        rules.beginNextRally()
        state.match = rules.state
    }

    public mutating func finishByForfeit(winner: Team) {
        lastEvents = rules.forfeit(winner: winner)
        state.match = rules.state
    }

    public mutating func step(inputs: [Team: PlayerInput]) {
        let dt = configuration.stepDuration
        var contacts: [RuleContact] = []
        let previousShipPositions = state.ships.mapValues(\.position)
        for team in Team.allCases {
            guard var ship = state.ships[team], !ship.isDestroyed else { continue }
            let input = inputs[team] ?? .idle(tick: state.tick)
            ship.angularVelocity += input.torque * configuration.torqueAcceleration * dt
            ship.angle += ship.angularVelocity * dt
            var acceleration = configuration.gravity
            if input.thrust {
                ship.thrustLevel = ship.thrustLevel > 0
                    ? min(
                        configuration.maximumThrustAcceleration,
                        ship.thrustLevel + configuration.thrustRampRate * dt
                    )
                    : configuration.initialThrustAcceleration
                acceleration += SIMD2(cos(ship.angle), sin(ship.angle)) * ship.thrustLevel
            } else {
                ship.thrustLevel = 0
            }
            ship.velocity += acceleration * dt
            ship.position += ship.velocity * dt
            resolveArenaCollision(for: &ship, team: team, contacts: &contacts)
            state.ships[team] = ship
        }
        resolveShipShipCollision(previousPositions: previousShipPositions, contacts: &contacts)

        let previousBallPosition = state.ball.position
        state.ball.velocity += configuration.gravity * 0.72 * dt
        state.ball.position += state.ball.velocity * dt
        resolveBallShipCollisions(
            previousBallPosition: previousBallPosition,
            previousShipPositions: previousShipPositions
        )
        resolveBallCollision(previousPosition: previousBallPosition, contacts: &contacts)

        lastEvents = rules.resolve(contacts)
        state.match = rules.state
        state.tick += 1
    }

    private mutating func resolveShipShipCollision(
        previousPositions: [Team: SIMD2<Double>],
        contacts: inout [RuleContact]
    ) {
        guard var cyan = state.ships[.cyan], var orange = state.ships[.orange],
              !cyan.isDestroyed, !orange.isDestroyed,
              let previousCyan = previousPositions[.cyan],
              let previousOrange = previousPositions[.orange] else { return }

        let relativeStart = previousCyan - previousOrange
        let relativeEnd = cyan.position - orange.position
        guard let hitTime = sweptCircleTime(
            from: relativeStart,
            to: relativeEnd,
            center: .zero,
            radius: 0.13
        ) else { return }

        var normal = relativeStart + (relativeEnd - relativeStart) * hitTime
        let length = simd_length(normal)
        normal = length > 0.000_001 ? normal / length : SIMD2(-1, 0)
        let closingSpeed = max(0, -simd_dot(cyan.velocity - orange.velocity, normal))
        if closingSpeed > 0 {
            let impulse = normal * (closingSpeed * 0.82)
            cyan.velocity += impulse
            orange.velocity -= impulse
        }
        state.ships[.cyan] = cyan
        state.ships[.orange] = orange
    }

    private mutating func resolveArenaCollision(
        for ship: inout ShipState,
        team: Team,
        contacts: inout [RuleContact]
    ) {
        let radius = 0.065
        let enteredEnemyTerritory = ship.homeSide == .cyan
            ? ship.position.x + radius > 0
            : ship.position.x - radius < 0
        if enteredEnemyTerritory {
            ship.isDestroyed = true
            ship.thrustLevel = 0
            contacts.append(.shipDestroyed(team: team, reason: .netContact))
            return
        }

        if ship.position.y - radius <= arena.floorY {
            ship.position.y = arena.floorY + radius
            ship.velocity.y = max(0, -ship.velocity.y * 0.12)
        }
        if ship.position.y + radius >= arena.ceilingY {
            ship.position.y = arena.ceilingY - radius
            ship.velocity.y = min(0, -ship.velocity.y * 0.3)
        }
        if ship.position.x - radius <= -arena.halfWidth {
            ship.position.x = -arena.halfWidth + radius
            ship.velocity.x = max(0, -ship.velocity.x * 0.3)
        }
        if ship.position.x + radius >= arena.halfWidth {
            ship.position.x = arena.halfWidth - radius
            ship.velocity.x = min(0, -ship.velocity.x * 0.3)
        }
    }

    private mutating func resolveBallCollision(
        previousPosition: SIMD2<Double>,
        contacts: inout [RuleContact]
    ) {
        if let defending = arena.goalDefender(for: state.ball) {
            contacts.append(.ballEnteredGoal(defending: defending))
            return
        }

        let r = state.ball.radius
        if let netHit = sweptNetHit(from: previousPosition, to: state.ball.position, radius: r) {
            state.ball.position = netHit.position
            state.ball.velocity.x = netHit.fromLeft
                ? -abs(state.ball.velocity.x) * 0.94
                : abs(state.ball.velocity.x) * 0.94
        } else if previousPosition.x.sign != state.ball.position.x.sign {
            contacts.append(.ballCrossedCenter(into: state.ball.position.x < 0 ? .cyan : .orange))
        }

        if state.ball.position.y - r <= arena.floorY {
            state.ball.position.y = arena.floorY + r
            state.ball.velocity.y = abs(state.ball.velocity.y) * 0.90
            contacts.append(.ballTouchedFloor(side: state.ball.position.x < 0 ? .cyan : .orange))
        }
        if state.ball.position.y + r >= arena.ceilingY {
            state.ball.position.y = arena.ceilingY - r
            state.ball.velocity.y = -abs(state.ball.velocity.y) * 0.94
        }
        if state.ball.position.x - r <= -arena.halfWidth {
            state.ball.position.x = -arena.halfWidth + r
            state.ball.velocity.x = abs(state.ball.velocity.x) * 0.94
        }
        if state.ball.position.x + r >= arena.halfWidth {
            state.ball.position.x = arena.halfWidth - r
            state.ball.velocity.x = -abs(state.ball.velocity.x) * 0.94
        }
    }

    private func sweptNetHit(
        from start: SIMD2<Double>,
        to end: SIMD2<Double>,
        radius: Double
    ) -> (position: SIMD2<Double>, fromLeft: Bool)? {
        let limit = arena.netHalfWidth + radius
        let delta = end - start
        if abs(start.x) <= limit, start.y - radius <= arena.netTopY {
            let fromLeft = start.x <= 0
            return (SIMD2(fromLeft ? -limit : limit, start.y), fromLeft)
        }
        guard abs(delta.x) > 0.000_000_1 else {
            if abs(end.x) <= limit, end.y - radius <= arena.netTopY {
                return (SIMD2(start.x < 0 ? -limit : limit, end.y), start.x < 0)
            }
            return nil
        }

        let fromLeft = start.x < 0
        let boundary = fromLeft ? -limit : limit
        let crossed = fromLeft ? end.x >= boundary : end.x <= boundary
        guard crossed else { return nil }
        let t = (boundary - start.x) / delta.x
        guard (0 ... 1).contains(t) else { return nil }
        let hitY = start.y + delta.y * t
        guard hitY - radius <= arena.netTopY else { return nil }
        return (SIMD2(boundary, hitY), fromLeft)
    }

    private mutating func resolveBallShipCollisions(
        previousBallPosition: SIMD2<Double>,
        previousShipPositions: [Team: SIMD2<Double>]
    ) {
        struct Fixture {
            var previousCenter: SIMD2<Double>
            var center: SIMD2<Double>
            var radius: Double
        }

        let ballEnd = state.ball.position
        var earliest: (team: Team, fixture: Fixture, t: Double)?
        for team in Team.allCases {
            guard let ship = state.ships[team], !ship.isDestroyed,
                  let previousShipPosition = previousShipPositions[team] else { continue }
            let axis = SIMD2(cos(ship.angle), sin(ship.angle))
            let fixtures = [
                Fixture(
                    previousCenter: previousShipPosition - axis * 0.045,
                    center: ship.position - axis * 0.045,
                    radius: 0.048
                ),
                Fixture(
                    previousCenter: previousShipPosition,
                    center: ship.position,
                    radius: 0.055
                ),
                Fixture(
                    previousCenter: previousShipPosition + axis * 0.060,
                    center: ship.position + axis * 0.060,
                    radius: 0.035
                ),
            ]
            for fixture in fixtures {
                guard let t = sweptCircleTime(
                    from: previousBallPosition - fixture.previousCenter,
                    to: ballEnd - fixture.center,
                    center: .zero,
                    radius: state.ball.radius + fixture.radius
                ) else { continue }
                if earliest == nil || t < earliest!.t {
                    earliest = (team, fixture, t)
                }
            }
        }

        guard let hit = earliest, var ship = state.ships[hit.team] else { return }
        let ballContact = previousBallPosition + (ballEnd - previousBallPosition) * hit.t
        let fixtureContact = hit.fixture.previousCenter
            + (hit.fixture.center - hit.fixture.previousCenter) * hit.t
        var normal = ballContact - fixtureContact
        let normalLength = simd_length(normal)
        normal = normalLength > 0.000_001 ? normal / normalLength : SIMD2(-1, 0)
        state.ball.position = hit.fixture.center + normal * (state.ball.radius + hit.fixture.radius)

        let relativeVelocity = state.ball.velocity - ship.velocity
        let inwardSpeed = simd_dot(relativeVelocity, normal)
        guard inwardSpeed < 0 else { return }
        let inverseBallMass = 1.0 / 0.45
        let inverseShipMass = 1.0 / 1.60
        let impulse = -(1 + 0.95) * inwardSpeed / (inverseBallMass + inverseShipMass)
        state.ball.velocity += normal * impulse * inverseBallMass
        ship.velocity -= normal * impulse * inverseShipMass
        state.ships[hit.team] = ship
    }

    private func sweptCircleTime(
        from start: SIMD2<Double>,
        to end: SIMD2<Double>,
        center: SIMD2<Double>,
        radius: Double
    ) -> Double? {
        let delta = end - start
        let offset = start - center
        let a = simd_dot(delta, delta)
        guard a > 0.000_000_1 else { return nil }
        let b = 2 * simd_dot(offset, delta)
        let c = simd_dot(offset, offset) - radius * radius
        let discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else { return nil }
        let root = sqrt(discriminant)
        let t = (-b - root) / (2 * a)
        return (0 ... 1).contains(t) ? t : nil
    }
}
