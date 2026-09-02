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
    /// Which way the next serve drifts: -1 toward cyan, +1 toward orange. The
    /// ball reappears dead centre, so it needs somewhere to go -- straight down
    /// from there lands in a void and hands out a free point.
    public var serveDriftSign: Double

    public init(
        tick: UInt64 = 0,
        ships: [Team: ShipState],
        ball: BallState = BallState(position: SIMD2(0, 0.60)),
        match: MatchRuleState = MatchRuleState(),
        serveTicksRemaining: UInt64 = 0,
        serveDriftSign: Double = -1
    ) {
        self.tick = tick
        self.ships = ships
        self.ball = ball
        self.match = match
        self.serveTicksRemaining = serveTicksRemaining
        self.serveDriftSign = serveDriftSign
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
    public var minimumBallSeparationSpeed: Double
    /// Spring that pushes a ship back once it is past the halfway marker.
    public var crossingPushBack: Double
    /// Drag applied past the marker, ramping in with depth.
    public var crossingDrag: Double
    public var allowedFloorBounces: Int
    public var allowedShipTouches: Int

    public init(
        stepDuration: Double = 1.0 / 120.0,
        gravity: SIMD2<Double> = SIMD2(0, -2),
        initialThrustAcceleration: Double = 5.5,
        maximumThrustAcceleration: Double = 5.5,
        thrustRampRate: Double = 0,
        torqueAcceleration: Double = 3,
        ballGravityMultiplier: Double = 0.72,
        ballDropHeight: Double = 0.50,
        ballDropSpeed: Double = 0.18,
        serveDelay: Double = 1.35,
        minimumBallSeparationSpeed: Double = 0.45,
        crossingPushBack: Double = 30,
        crossingDrag: Double = 5.0,
        allowedFloorBounces: Int = 1,
        allowedShipTouches: Int = 3
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
        self.minimumBallSeparationSpeed = max(0, minimumBallSeparationSpeed)
        self.crossingPushBack = max(0, crossingPushBack)
        self.crossingDrag = max(0, crossingDrag)
        self.allowedFloorBounces = min(5, max(1, allowedFloorBounces))
        self.allowedShipTouches = min(6, max(1, allowedShipTouches))
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
            allowedFloorBounces: configuration.allowedFloorBounces,
            allowedShipTouches: configuration.allowedShipTouches
        )
    }

    public static func testing() -> SimulationEngine {
        SimulationEngine(state: WorldState(ships: [
            .cyan: ShipState(position: SIMD2(-0.55, -0.45), angle: .pi / 2),
            .orange: ShipState(position: SIMD2(0.55, -0.45), angle: .pi / 2),
        ]))
    }

    public mutating func updateConfiguration(_ configuration: SimulationConfiguration) {
        self.configuration = configuration
        rules.updateAllowedFloorBounces(configuration.allowedFloorBounces)
        rules.updateAllowedShipTouches(configuration.allowedShipTouches)
    }

    public mutating func prepareNextRally(mirrored: Bool) {
        guard state.match.phase != .finished else { return }
        let direction = mirrored ? 1.0 : -1.0
        state.ships = [
            .cyan: ShipState(position: SIMD2(0.55 * direction, -0.45), angle: .pi / 2),
            .orange: ShipState(position: SIMD2(-0.55 * direction, -0.45), angle: .pi / 2),
        ]
        state.serveDriftSign = mirrored ? 1 : -1
        state.ball = BallState(
            position: SIMD2(0, configuration.ballDropHeight),
            velocity: serveVelocity
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
            // The halfway marker is a wall of treacle rather than a tripwire: the
            // deeper a pilot pushes into the far half, the harder the arena shoves
            // back and the more speed it steals. Nothing here is lethal.
            let intrusionSign = ship.homeSide == .cyan ? 1.0 : -1.0
            let depth = ship.position.x * intrusionSign - arena.opponentCrossingLimit
            if depth > 0 {
                acceleration.x -= intrusionSign * configuration.crossingPushBack * depth
                acceleration -= ship.velocity
                    * (configuration.crossingDrag * min(1, depth / 0.20))
            }
            ship.velocity += acceleration * dt
            ship.position += ship.velocity * dt
            resolveArenaCollision(
                for: &ship,
                from: previousShipPositions[team] ?? ship.position,
                effects: &collisionEffects
            )
            state.ships[team] = ship
        }
        resolveShipShipCollision(
            previousPositions: previousShipPositions,
            effects: &collisionEffects
        )

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
            contacts: &contacts,
            effects: &collisionEffects
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

    /// Enough sideways speed that the ball is past the outer post before it
    /// falls to net height, whatever it does after that.
    private var serveVelocity: SIMD2<Double> {
        SIMD2(state.serveDriftSign * 0.45, -configuration.ballDropSpeed)
    }

    private mutating func stageServe(on team: Team?) {
        // The ball reappears dead centre, above the solid post, and drifts out
        // to the side that just conceded -- far enough to clear the voids, so
        // an untouched serve lands in play instead of scoring by itself.
        switch team {
        case .cyan: state.serveDriftSign = -1
        case .orange: state.serveDriftSign = 1
        case nil: state.serveDriftSign = -state.serveDriftSign
        }
        state.ball = BallState(
            position: SIMD2(0, configuration.ballDropHeight),
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
        respawnDestroyedShips()
        state.ball.velocity = serveVelocity
        rules.beginNextRally()
        state.match = rules.state
    }

    private mutating func respawnDestroyedShips() {
        for team in Team.allCases {
            guard let destroyedShip = state.ships[team], destroyedShip.isDestroyed else { continue }
            let homeSide = destroyedShip.homeSide
            state.ships[team] = ShipState(
                position: SIMD2(homeSide == .cyan ? -0.55 : 0.55, -0.45),
                angle: .pi / 2,
                homeSide: homeSide
            )
        }
    }

    private mutating func resolveShipShipCollision(
        previousPositions: [Team: SIMD2<Double>],
        effects: inout [SimulationEvent]
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
            radius: 0.096
        ) else { return }

        let impactSpeed = simd_length(cyan.velocity - orange.velocity)
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
        effects.append(.collisionEffect(
            position: (cyan.position + orange.position) / 2,
            intensity: impactSpeed
        ))
    }

    private mutating func resolveArenaCollision(
        for ship: inout ShipState,
        from previousPosition: SIMD2<Double>,
        effects: inout [SimulationEvent]
    ) {
        let radius = 0.048

        // The net is a portal for the ball only. A hull hits it like a wall,
        // so the low route through the middle stays closed exactly as it was.
        if let netContact = sweptNetContact(
            from: previousPosition,
            to: ship.position,
            radius: radius,
            postCenterX: 0
        ) {
            ship.position = netContact.position
            let inwardSpeed = simd_dot(ship.velocity, netContact.normal)
            if inwardSpeed < 0 {
                ship.velocity -= netContact.normal * ((1 + 0.45) * inwardSpeed)
            }
            effects.append(.collisionEffect(
                position: ship.position,
                intensity: abs(inwardSpeed)
            ))
        }

        if let corner = arena.cornerContact(position: ship.position, radius: radius) {
            ship.position = corner.position
            let inwardSpeed = simd_dot(ship.velocity, corner.normal)
            if inwardSpeed < 0 {
                ship.velocity -= corner.normal * ((1 + 0.3) * inwardSpeed)
            }
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

    private func sweptNetContact(
        from start: SIMD2<Double>,
        to end: SIMD2<Double>,
        radius: Double,
        postCenterX: Double
    ) -> (position: SIMD2<Double>, normal: SIMD2<Double>)? {
        let capCenter = SIMD2(postCenterX, arena.netTopY)
        let combinedRadius = radius + arena.netHalfWidth
        let capHitTime = sweptCircleTime(
            from: start,
            to: end,
            center: capCenter,
            radius: combinedRadius
        )
        let endOverlapsCap = simd_distance(end, capCenter) <= combinedRadius
        if let hitTime = capHitTime ?? (endOverlapsCap ? 1 : nil) {
            let contactCenter = start + (end - start) * hitTime
            var normal = contactCenter - capCenter
            let length = simd_length(normal)
            if length <= 0.000_001 {
                normal = SIMD2(start.x <= postCenterX ? -1 : 1, 0)
            } else {
                normal /= length
            }
            return (capCenter + normal * combinedRadius, normal)
        }

        guard let bodyHit = sweptNetHit(
            from: start,
            to: end,
            radius: radius,
            postCenterX: postCenterX
        ) else {
            return nil
        }
        let normal = SIMD2(bodyHit.fromLeft ? -1.0 : 1.0, 0)
        return (bodyHit.position, normal)
    }

    private mutating func resolveBallCollision(
        previousPosition: SIMD2<Double>,
        contacts: inout [RuleContact]
    ) {
        let r = state.ball.radius
        var struckNet = false
        // Cap first: the crown of the net is hard and neutral, so clipping the
        // top is a rebound rather than a score. Only the two faces below it are
        // the portal, and a ball that reaches one is gone -- whoever drove it
        // in takes the point.
        if let capHit = sweptNetCapHit(
            from: previousPosition,
            to: state.ball.position,
            radius: r,
            postCenterX: 0
        ) {
            state.ball.position = capHit.position
            let inwardSpeed = simd_dot(state.ball.velocity, capHit.normal)
            if inwardSpeed < 0 {
                state.ball.velocity -= capHit.normal * (2 * inwardSpeed)
            }
            struckNet = true
        } else if let netHit = sweptNetHit(
            from: previousPosition,
            to: state.ball.position,
            radius: r,
            postCenterX: 0
        ) {
            state.ball.position = netHit.position
            contacts.append(.ballEnteredGoal(
                defending: arena.portalScorer(enteredFromLeft: netHit.fromLeft).opponent
            ))
            return
        }

        if !struckNet, previousPosition.x.sign != state.ball.position.x.sign {
            contacts.append(.ballCrossedCenter(into: state.ball.position.x < 0 ? .cyan : .orange))
        }

        // The arc runs first so that in a corner it, not the flat wall, sets the
        // final position -- and so the floor clamp below cannot double-count a
        // touch the arc has already reported.
        var floorRegistered = false
        if let corner = arena.cornerContact(position: state.ball.position, radius: r) {
            state.ball.position = corner.position
            let inwardSpeed = simd_dot(state.ball.velocity, corner.normal)
            if inwardSpeed < 0 {
                state.ball.velocity -= corner.normal * ((1 + 0.94) * inwardSpeed)
            }
            if corner.normal.y > 0.5 {
                floorRegistered = true
                contacts.append(.ballTouchedFloor(side: state.ball.position.x < 0 ? .cyan : .orange))
            }
        }

        if state.ball.position.y - r <= arena.floorY {
            state.ball.position.y = arena.floorY + r
            state.ball.velocity.y = abs(state.ball.velocity.y) * 0.90
            if !floorRegistered {
                contacts.append(.ballTouchedFloor(side: state.ball.position.x < 0 ? .cyan : .orange))
            }
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
        radius: Double,
        postCenterX: Double
    ) -> (position: SIMD2<Double>, normal: SIMD2<Double>)? {
        let center = SIMD2(postCenterX, arena.netTopY)
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
        // The cap is hard and neutral: it rebounds, it never scores, and it
        // favours neither half. A ball landing dead on top has no side to
        // fall to, so alternate the nudge by rally -- symmetric across a
        // match, and it keeps the ball from settling on the crown.
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
        radius: Double,
        postCenterX: Double
    ) -> (position: SIMD2<Double>, fromLeft: Bool)? {
        let limit = arena.netHalfWidth + radius
        let delta = end - start
        let startOffset = start.x - postCenterX
        if abs(startOffset) <= limit, start.y - radius <= arena.netTopY {
            let fromLeft = startOffset <= 0
            let penetration = limit - abs(startOffset)
            let movingTowardNet = fromLeft ? delta.x > 0 : delta.x < 0
            if penetration > 0.000_000_1 || movingTowardNet {
                return (SIMD2(postCenterX + (fromLeft ? -limit : limit), start.y), fromLeft)
            }
        }
        guard abs(delta.x) > 0.000_000_1 else {
            if abs(end.x - postCenterX) <= limit, end.y - radius <= arena.netTopY {
                let fromLeft = startOffset < 0
                return (SIMD2(postCenterX + (fromLeft ? -limit : limit), end.y), fromLeft)
            }
            return nil
        }

        let fromLeft = startOffset < 0
        let boundary = postCenterX + (fromLeft ? -limit : limit)
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
        contacts: inout [RuleContact],
        effects: inout [SimulationEvent]
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
                    previousCenter: previousShipPosition - axis * 0.033,
                    center: ship.position - axis * 0.033,
                    radius: 0.035
                ),
                Fixture(
                    previousCenter: previousShipPosition,
                    center: ship.position,
                    radius: 0.041
                ),
                Fixture(
                    previousCenter: previousShipPosition + axis * 0.044,
                    center: ship.position + axis * 0.044,
                    radius: 0.026
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
        // Every contact pops the ball clear of the hull. Without this a ship can
        // park under a slow ball and ride it, which stalls the rally outright.
        let separationSpeed = simd_dot(state.ball.velocity - ship.velocity, normal)
        if separationSpeed < configuration.minimumBallSeparationSpeed {
            state.ball.velocity += normal
                * (configuration.minimumBallSeparationSpeed - separationSpeed)
        }
        state.ships[hit.team] = ship
        contacts.append(.ballTouchedShip(team: hit.team))
        effects.append(.collisionEffect(
            position: state.ball.position,
            intensity: abs(inwardSpeed)
        ))
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
