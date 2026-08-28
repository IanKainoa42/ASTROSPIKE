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

public enum FlightControlDirection: Sendable {
    case left
    case right
}

public enum FlightControlMapping {
    public static func torque(for direction: FlightControlDirection) -> Double {
        switch direction {
        case .left: 1
        case .right: -1
        }
    }

    public static func input(
        tick: UInt64,
        leftPressed: Bool,
        rightPressed: Bool,
        thrustPressed: Bool
    ) -> PlayerInput {
        let torque = (leftPressed ? torque(for: .left) : 0)
            + (rightPressed ? torque(for: .right) : 0)
        return PlayerInput(tick: tick, torque: torque, thrust: thrustPressed)
    }
}

public struct ControlPressTracker<ID: Hashable & Sendable>: Sendable {
    private var activeIDs: Set<ID> = []

    public init() {}

    public var isPressed: Bool { !activeIDs.isEmpty }

    public mutating func began(_ id: ID) {
        activeIDs.insert(id)
    }

    public mutating func ended(_ id: ID) {
        activeIDs.remove(id)
    }

    public mutating func cancelled(_ id: ID) {
        activeIDs.remove(id)
    }

    public mutating func cancelAll() {
        activeIDs.removeAll()
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
    public var serveTicksRemaining: UInt64

    public init(
        tick: UInt64 = 0,
        ships: [Team: ShipState],
        ball: BallState = BallState(position: SIMD2(0, 0.60)),
        match: MatchRuleState = MatchRuleState(),
        serveTicksRemaining: UInt64 = 0
    ) {
        self.tick = tick
        self.ships = ships
        self.ball = ball
        self.match = match
        self.serveTicksRemaining = serveTicksRemaining
    }
}

public struct SimulationConfiguration: Equatable, Sendable {
    public var stepDuration: Double
    public var gravity: SIMD2<Double>
    public var initialThrustAcceleration: Double
    public var maximumThrustAcceleration: Double
    public var thrustRampRate: Double
    public var torqueAcceleration: Double
    public var ballGravityMultiplier: Double
    public var ballDropHeight: Double
    public var ballDropSpeed: Double
    public var serveDelay: Double
    public var allowedFloorBounces: Int

    public init(
        stepDuration: Double = 1.0 / 120.0,
        gravity: SIMD2<Double> = SIMD2(0, -2),
        initialThrustAcceleration: Double = 5.5,
        maximumThrustAcceleration: Double = 5.5,
        thrustRampRate: Double = 0,
        torqueAcceleration: Double = 3,
        ballGravityMultiplier: Double = 0.72,
        ballDropHeight: Double = 0.60,
        ballDropSpeed: Double = 0.18,
        serveDelay: Double = 1.35,
        allowedFloorBounces: Int = 2
    ) {
        self.stepDuration = stepDuration
        self.gravity = gravity
        self.initialThrustAcceleration = initialThrustAcceleration
        self.maximumThrustAcceleration = maximumThrustAcceleration
        self.thrustRampRate = thrustRampRate
        self.torqueAcceleration = torqueAcceleration
        self.ballGravityMultiplier = ballGravityMultiplier
        self.ballDropHeight = ballDropHeight
        self.ballDropSpeed = ballDropSpeed
        self.serveDelay = max(0, serveDelay)
        self.allowedFloorBounces = min(5, max(1, allowedFloorBounces))
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
        self.rules = MatchRules(
            state: state.match,
            allowedFloorBounces: configuration.allowedFloorBounces
        )
    }

    public static func testing() -> SimulationEngine {
        SimulationEngine(state: WorldState(ships: [
            .cyan: ShipState(position: SIMD2(-0.55, -0.55), angle: .pi / 2),
            .orange: ShipState(position: SIMD2(0.55, -0.55), angle: .pi / 2),
        ]))
    }

    public mutating func updateConfiguration(_ configuration: SimulationConfiguration) {
        self.configuration = configuration
        rules.updateAllowedFloorBounces(configuration.allowedFloorBounces)
    }

    public mutating func prepareNextRally(mirrored: Bool) {
        guard state.match.phase != .finished else { return }
        let direction = mirrored ? 1.0 : -1.0
        state.ships = [
            .cyan: ShipState(position: SIMD2(0.55 * direction, -0.55), angle: .pi / 2),
            .orange: ShipState(position: SIMD2(-0.55 * direction, -0.55), angle: .pi / 2),
        ]
        state.ball = BallState(
            position: SIMD2(0, configuration.ballDropHeight),
            velocity: SIMD2(0, -configuration.ballDropSpeed)
        )
        state.serveTicksRemaining = 0
        rules.prepareNextRally()
        state.match = rules.state
        lastEvents = [.rallyReset]
    }

    public mutating func beginPlay() {
        state.serveTicksRemaining = 0
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
        var collisionEffects: [SimulationEvent] = []
        let previousShipPositions = state.ships.mapValues(\.position)
        for team in Team.allCases {
            guard var ship = state.ships[team], !ship.isDestroyed else { continue }
            let input = inputs[team] ?? .idle(tick: state.tick)
            ship.angularVelocity = input.torque * configuration.torqueAcceleration
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
            resolveArenaCollision(for: &ship, team: team, effects: &collisionEffects)
            state.ships[team] = ship
        }
        resolveShipShipCollision(previousPositions: previousShipPositions, contacts: &contacts)

        if state.match.phase == .serve {
            advanceServe()
            lastEvents = collisionEffects
            state.tick += 1
            return
        }

        let previousBallPosition = state.ball.position
        state.ball.velocity += configuration.gravity * configuration.ballGravityMultiplier * dt
        state.ball.position += state.ball.velocity * dt
        resolveBallShipCollisions(
            previousBallPosition: previousBallPosition,
            previousShipPositions: previousShipPositions,
            contacts: &contacts
        )
        resolveBallCollision(previousPosition: previousBallPosition, contacts: &contacts)

        let ruleEvents = rules.resolve(contacts)
        lastEvents = ruleEvents + collisionEffects
        state.match = rules.state
        if state.match.phase == .serve {
            let concedingTeam = ruleEvents.compactMap { event -> Team? in
                guard case let .point(scoringTeam, _) = event else { return nil }
                return scoringTeam.opponent
            }.first
            stageServe(on: concedingTeam)
        }
        state.tick += 1
    }

    private mutating func stageServe(on team: Team?) {
        let x: Double
        switch team {
        case .cyan: x = -arena.halfWidth / 2
        case .orange: x = arena.halfWidth / 2
        case nil: x = 0
        }
        state.ball = BallState(
            position: SIMD2(x, configuration.ballDropHeight),
            velocity: .zero,
            radius: state.ball.radius
        )
        state.serveTicksRemaining = max(
            1,
            UInt64((configuration.serveDelay / configuration.stepDuration).rounded())
        )
    }

    private mutating func advanceServe() {
        state.ball.velocity = .zero
        if state.serveTicksRemaining > 0 {
            state.serveTicksRemaining -= 1
        }
        guard state.serveTicksRemaining == 0 else { return }
        state.ball.velocity = SIMD2(0, -configuration.ballDropSpeed)
        rules.beginNextRally()
        state.match = rules.state
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
        effects: inout [SimulationEvent]
    ) {
        let radius = 0.065
        let enteredEnemyTerritory = ship.homeSide == .cyan
            ? ship.position.x + radius > 0
            : ship.position.x - radius < 0
        if enteredEnemyTerritory {
            let impactSpeed = abs(ship.velocity.x)
            if ship.homeSide == .cyan {
                ship.position.x = -radius
                if ship.velocity.x > 0 { ship.velocity.x = -ship.velocity.x * 0.45 }
            } else {
                ship.position.x = radius
                if ship.velocity.x < 0 { ship.velocity.x = -ship.velocity.x * 0.45 }
            }
            effects.append(.collisionEffect(position: ship.position, intensity: impactSpeed))
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
        if let capHit = sweptNetCapHit(
            from: previousPosition,
            to: state.ball.position,
            radius: r
        ) {
            state.ball.position = capHit.position
            let inwardSpeed = simd_dot(state.ball.velocity, capHit.normal)
            if inwardSpeed < 0 {
                state.ball.velocity -= capHit.normal * ((1 + 0.94) * inwardSpeed)
            }
        } else if let netHit = sweptNetHit(from: previousPosition, to: state.ball.position, radius: r) {
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

    private func sweptNetCapHit(
        from start: SIMD2<Double>,
        to end: SIMD2<Double>,
        radius: Double
    ) -> (position: SIMD2<Double>, normal: SIMD2<Double>)? {
        let center = SIMD2(0.0, arena.netTopY)
        let combinedRadius = radius + arena.netHalfWidth
        guard let hitTime = sweptCircleTime(
            from: start,
            to: end,
            center: center,
            radius: combinedRadius
        ) else { return nil }

        let contact = start + (end - start) * hitTime
        var normal = contact - center
        let length = simd_length(normal)
        guard length > 0.000_001 else { return nil }
        normal /= length
        if abs(normal.x) < 0.02, normal.y > 0 {
            let rallyIndex = state.match.score.cyan + state.match.score.orange
            normal = simd_normalize(SIMD2(rallyIndex.isMultiple(of: 2) ? -0.18 : 0.18, 1))
        }
        guard simd_dot(state.ball.velocity, normal) < 0 else { return nil }
        return (center + normal * combinedRadius, normal)
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
            let penetration = limit - abs(start.x)
            let movingTowardNet = fromLeft ? delta.x > 0 : delta.x < 0
            if penetration > 0.000_000_1 || movingTowardNet {
                return (SIMD2(fromLeft ? -limit : limit, start.y), fromLeft)
            }
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
        previousShipPositions: [Team: SIMD2<Double>],
        contacts: inout [RuleContact]
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
        contacts.append(.ballTouchedShip(team: hit.team))
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
