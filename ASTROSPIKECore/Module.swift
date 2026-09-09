import Foundation
import simd

public enum Team: String, Codable, CaseIterable, Sendable {
    case cyan
    case orange
}

/// A place on the court. Every match has the two leads; doubles adds a wing
/// on each side. Seats are what ships, inputs and hulls are keyed by, and
/// the team is what the rulebook keys by.
public enum Seat: Int, Codable, CaseIterable, Sendable, Hashable, Comparable {
    case cyan = 0
    case orange = 1
    case cyanWing = 2
    case orangeWing = 3

    public var team: Team {
        switch self {
        case .cyan, .cyanWing: .cyan
        case .orange, .orangeWing: .orange
        }
    }

    public var isWing: Bool { self == .cyanWing || self == .orangeWing }

    /// The other seat on the same side.
    public var partner: Seat {
        switch self {
        case .cyan: .cyanWing
        case .cyanWing: .cyan
        case .orange: .orangeWing
        case .orangeWing: .orange
        }
    }

    public static func lead(_ team: Team) -> Seat { team == .cyan ? .cyan : .orange }
    public static func wing(_ team: Team) -> Seat { team == .cyan ? .cyanWing : .orangeWing }

    /// The classic duel.
    public static let singles: Set<Seat> = [.cyan, .orange]
    /// Two a side.
    public static let doubles: Set<Seat> = Set(Seat.allCases)

    public var label: String {
        switch self {
        case .cyan: "CYAN"
        case .orange: "ORANGE"
        case .cyanWing: "CYAN WING"
        case .orangeWing: "ORANGE WING"
        }
    }

    public static func < (lhs: Seat, rhs: Seat) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension Dictionary where Key == Seat, Value == ShipState {
    /// The lead ship of a team, for code and tests that think in teams.
    public subscript(team team: Team) -> ShipState? {
        get { self[Seat.lead(team)] }
        set { self[Seat.lead(team)] = newValue }
    }
}

public struct PlayerInput: Codable, Equatable, Sendable {
    public var tick: UInt64
    public var torque: Double
    public var thrust: Bool
    /// Asks for a bolt. Held down it repeats at the cooldown rate, so a
    /// thumb mashing the pad and a thumb resting on it behave the same.
    public var fire: Bool
    /// Holds the tractor beam on: the ball ahead of the nose is drawn in
    /// toward the ship while this is held. Continuous, no cooldown.
    public var tractor: Bool

    public init(tick: UInt64, torque: Double, thrust: Bool, fire: Bool = false, tractor: Bool = false) {
        self.tick = tick
        self.torque = max(-1, min(1, torque))
        self.thrust = thrust
        self.fire = fire
        self.tractor = tractor
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
        thrustPressed: Bool,
        firePressed: Bool = false,
        tractorPressed: Bool = false
    ) -> PlayerInput {
        let torque = (leftPressed ? torque(for: .left) : 0)
            + (rightPressed ? torque(for: .right) : 0)
        return PlayerInput(tick: tick, torque: torque, thrust: thrustPressed, fire: firePressed, tractor: tractorPressed)
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
    /// Ticks until the cannon can fire again. Zero means ready.
    public var fireCooldownTicks: UInt64
    /// The tractor beam is on this tick, so every board can draw it.
    public var tractorActive: Bool

    public init(
        position: SIMD2<Double>,
        velocity: SIMD2<Double> = .zero,
        angle: Double,
        angularVelocity: Double = 0,
        isDestroyed: Bool = false,
        thrustLevel: Double = 0,
        homeSide: Team? = nil,
        fireCooldownTicks: UInt64 = 0,
        tractorActive: Bool = false
    ) {
        self.position = position
        self.velocity = velocity
        self.angle = angle
        self.angularVelocity = angularVelocity
        self.isDestroyed = isDestroyed
        self.thrustLevel = thrustLevel
        self.homeSide = homeSide ?? (position.x < 0 ? .cyan : .orange)
        self.fireCooldownTicks = fireCooldownTicks
        self.tractorActive = tractorActive
    }
}

/// A bolt from a ship's nose. It only ever talks to the ball: hulls fly
/// through it, and it flies the whole court. The gate is on the trigger,
/// not the bolt: a ship can only fire from its own half. Hitting the ball
/// is a touch by the owner, same as a hull would be.
public struct BoltState: Codable, Equatable, Sendable {
    public static let radius = 0.012

    public var id: UInt64
    public var owner: Team
    public var position: SIMD2<Double>
    public var velocity: SIMD2<Double>
    public var ticksRemaining: UInt64

    public init(
        id: UInt64,
        owner: Team,
        position: SIMD2<Double>,
        velocity: SIMD2<Double>,
        ticksRemaining: UInt64
    ) {
        self.id = id
        self.owner = owner
        self.position = position
        self.velocity = velocity
        self.ticksRemaining = ticksRemaining
    }
}

public struct WorldState: Codable, Equatable, Sendable {
    public var tick: UInt64
    public var ships: [Seat: ShipState]
    public var ball: BallState
    public var match: MatchRuleState
    public var serveTicksRemaining: UInt64
    /// Which way the next serve drifts: -1 toward cyan, +1 toward orange. The
    /// ball reappears dead centre under the goal, and the side that just
    /// conceded is the side it is handed to.
    public var serveDriftSign: Double
    /// Bolts in flight, oldest first.
    public var bolts: [BoltState]
    public var nextBoltID: UInt64

    public init(
        tick: UInt64 = 0,
        ships: [Seat: ShipState],
        ball: BallState = BallState(position: SIMD2(0, 0.10)),
        match: MatchRuleState = MatchRuleState(),
        serveTicksRemaining: UInt64 = 0,
        serveDriftSign: Double = -1,
        bolts: [BoltState] = [],
        nextBoltID: UInt64 = 0
    ) {
        self.tick = tick
        self.ships = ships
        self.ball = ball
        self.match = match
        self.serveTicksRemaining = serveTicksRemaining
        self.serveDriftSign = serveDriftSign
        self.bolts = bolts
        self.nextBoltID = nextBoltID
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
    /// Bolt muzzle speed, arena units per second.
    public var boltSpeed: Double
    /// Seconds a bolt flies before it fizzles. Long enough at `boltSpeed`
    /// to cross the whole court from a ship's own back wall.
    public var boltLifetime: Double
    /// Seconds between shots.
    public var boltCooldown: Double
    /// Speed a bolt adds to the ball along its line of flight.
    public var boltPunch: Double
    /// How hard the exhaust shoves a ball sitting in it, as a fraction of the
    /// ship's own thrust acceleration at the nozzle.
    public var exhaustWashStrength: Double
    /// How far behind the ship the exhaust still reaches the ball.
    public var exhaustWashRange: Double
    /// How hard the tractor beam draws the ball in, at the nose. Fades to
    /// nothing at `tractorRange`.
    public var tractorStrength: Double
    /// How far ahead of the nose the beam reaches.
    public var tractorRange: Double
    /// Velocity bled off the ball each second while it is in the beam, so
    /// it settles toward the ship instead of slingshotting past.
    public var tractorDrag: Double
    /// Warm-up bay: nothing is a fault. Touches and bounces are tallied but
    /// never award a point, a goal simply re-serves, and the trigger works
    /// anywhere. There is no opponent, so there is nothing to defend.
    public var sandbox: Bool

    public init(
        stepDuration: Double = 1.0 / 120.0,
        gravity: SIMD2<Double> = SIMD2(0, -2),
        initialThrustAcceleration: Double = 5.5,
        maximumThrustAcceleration: Double = 5.5,
        thrustRampRate: Double = 0,
        torqueAcceleration: Double = 3,
        ballGravityMultiplier: Double = 0.95,
        ballDropHeight: Double = 0.06,
        ballDropSpeed: Double = 0.18,
        serveDelay: Double = 1.35,
        minimumBallSeparationSpeed: Double = 0.45,
        crossingPushBack: Double = 30,
        crossingDrag: Double = 5.0,
        allowedFloorBounces: Int = 1,
        allowedShipTouches: Int = 3,
        boltSpeed: Double = 2.6,
        boltLifetime: Double = 0.8,
        boltCooldown: Double = 0.45,
        boltPunch: Double = 1.15,
        exhaustWashStrength: Double = 0.65,
        exhaustWashRange: Double = 0.36,
        tractorStrength: Double = 1.6,
        tractorRange: Double = 0.55,
        tractorDrag: Double = 2.0,
        sandbox: Bool = false
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
        self.boltSpeed = max(0, boltSpeed)
        self.boltLifetime = max(0, boltLifetime)
        self.boltCooldown = max(0, boltCooldown)
        self.boltPunch = max(0, boltPunch)
        self.exhaustWashStrength = max(0, exhaustWashStrength)
        self.exhaustWashRange = max(0, exhaustWashRange)
        self.tractorStrength = max(0, tractorStrength)
        self.tractorRange = max(0, tractorRange)
        self.tractorDrag = max(0, tractorDrag)
        self.sandbox = sandbox
    }

    /// The warm-up bay: the pilot's own sliders with the halfway treacle
    /// switched off and nothing counted as a fault, so a lone pilot can roam
    /// the whole court while the invite is out.
    public static func warmup(from base: SimulationConfiguration) -> SimulationConfiguration {
        var configuration = base
        configuration.serveDelay = 0.9
        configuration.crossingPushBack = 0
        configuration.crossingDrag = 0
        configuration.sandbox = true
        return configuration
    }

    public static let warmup = warmup(from: online)

    /// The baked baseline. In a Game Center match every board runs the
    /// host's sliders, which arrive with the seating plan; this is what a
    /// fresh install flies until a slider moves.
    public static let online = FlightTuningSnapshot.defaults.configuration
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

    /// How much speed the ball keeps off the walls, roof, hump, corners and
    /// collar. Below the old 0.94 so the ball feels like it has some weight
    /// to it instead of pinging around the arena.
    static let ballRestitution = 0.82
    /// Slowest hull-on-arena or hull-on-hull knock that counts as an impact.
    static let effectImpactSpeed = 0.25
    /// The floor takes a little more out of it than the walls do.
    static let floorRestitution = 0.78

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

    /// How many sets take the match: 1 for a single game, 2 for best of
    /// three, 3 for best of five. Part of the match state rather than the
    /// configuration, so an engine rebuilt from a host's snapshot keeps the
    /// host's format without being told again.
    public mutating func setMatchFormat(setsToWin: Int) {
        rules.updateSetsToWin(setsToWin)
        state.match = rules.state
    }

    /// Where a seat starts a rally. Leads sit mid-court, wings sit behind
    /// them nearer the wall, so neither is under the ball when it drops.
    public static func spawnPosition(for seat: Seat, mirrored: Bool) -> SIMD2<Double> {
        let direction = mirrored ? 1.0 : -1.0
        let side = seat.team == .cyan ? direction : -direction
        return SIMD2((seat.isWing ? 0.80 : 0.55) * side, -0.45)
    }

    /// Replaces every ship with a fresh one in each of the given seats and
    /// stages a rally. Seats not listed are simply empty.
    public mutating func configureRoster(_ seats: Set<Seat>, mirrored: Bool = false) {
        state.ships = Dictionary(uniqueKeysWithValues: seats.map { seat in
            (seat, ShipState(position: Self.spawnPosition(for: seat, mirrored: mirrored), angle: .pi / 2))
        })
        prepareNextRally(mirrored: mirrored)
    }

    public mutating func prepareNextRally(mirrored: Bool) {
        guard state.match.phase != .finished else { return }
        // Whoever is seated stays seated; only the positions reset.
        let seats = state.ships.isEmpty ? Seat.singles : Set(state.ships.keys)
        state.ships = Dictionary(uniqueKeysWithValues: seats.map { seat in
            (seat, ShipState(position: Self.spawnPosition(for: seat, mirrored: mirrored), angle: .pi / 2))
        })
        state.serveDriftSign = mirrored ? 1 : -1
        state.ball = BallState(
            position: SIMD2(0, configuration.ballDropHeight),
            velocity: serveVelocity
        )
        state.serveTicksRemaining = 0
        state.bolts.removeAll()
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

    public mutating func step(inputs: [Seat: PlayerInput]) {
        let dt = configuration.stepDuration
        var contacts: [RuleContact] = []
        var collisionEffects: [SimulationEvent] = []
        let previousShipPositions = state.ships.mapValues(\.position)
        for seat in Seat.allCases {
            guard var ship = state.ships[seat], !ship.isDestroyed else { continue }
            let input = inputs[seat] ?? .idle(tick: state.tick)
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
                from: previousShipPositions[seat] ?? ship.position,
                effects: &collisionEffects
            )
            if ship.fireCooldownTicks > 0 { ship.fireCooldownTicks -= 1 }
            // The trigger works from a ship's own half plus a short reach past
            // center, out to the base of the hump — past that the nose is
            // live for ramming but the bolts stay holstered.
            let homeSign = ship.homeSide == .cyan ? -1.0 : 1.0
            let onOwnHalf = configuration.sandbox
                || ship.position.x * homeSign >= -arena.humpBaseX
            if input.fire, onOwnHalf, ship.fireCooldownTicks == 0, state.match.phase == .playing {
                fireBolt(from: &ship, owner: seat.team)
            }
            // Same holster rule as the cannon: the beam only works from home.
            ship.tractorActive = input.tractor && onOwnHalf
                && (state.match.phase == .playing || configuration.sandbox)
            state.ships[seat] = ship
        }
        resolveShipShipCollisions(
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
        applyExhaustWash(dt: dt)
        applyTractorBeam(dt: dt)
        state.ball.position += state.ball.velocity * dt
        advanceBolts(contacts: &contacts, effects: &collisionEffects)
        resolveBallShipCollisions(
            previousBallPosition: previousBallPosition,
            previousShipPositions: previousShipPositions,
            contacts: &contacts,
            effects: &collisionEffects
        )
        resolveBallCollision(previousPosition: previousBallPosition, contacts: &contacts)

        if configuration.sandbox {
            resolveSandbox(contacts: contacts, effects: collisionEffects)
            state.tick += 1
            return
        }

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

    /// Enough sideways drift that the ball lands well inside the receiving
    /// half rather than on the centre line.
    private var serveVelocity: SIMD2<Double> {
        SIMD2(state.serveDriftSign * 0.45, -configuration.ballDropSpeed)
    }

    private mutating func stageServe(on team: Team?) {
        // The ball reappears dead centre, just under the cap of the goal, and
        // drifts out to the side that just conceded. It cannot score by
        // itself: the goal is above it, and it only ever falls.
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
        state.bolts.removeAll()
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
        if configuration.sandbox {
            state.match.phase = .playing
            state.match.floorContacts = SideCounts()
            state.match.shipTouches = SideCounts()
            return
        }
        rules.beginNextRally()
        state.match = rules.state
    }

    /// The warm-up bay's stand-in for the rulebook. Touches count up as a
    /// keep-up streak that a floor bounce resets, a goal is a point for
    /// whoever is flying and a fresh serve, and nothing else is a fault.
    private mutating func resolveSandbox(contacts: [RuleContact], effects: [SimulationEvent]) {
        var events = effects
        for contact in contacts {
            switch contact {
            case let .ballTouchedShip(team):
                state.match.shipTouches[team] += 1
            case let .ballTouchedFloor(side):
                state.match.floorContacts[side] += 1
                state.match.shipTouches = SideCounts()
            case .ballEnteredGoal:
                let pilot = state.ships.keys.min()?.team ?? .cyan
                if pilot == .cyan { state.match.score.cyan += 1 } else { state.match.score.orange += 1 }
                events.append(.point(scoringTeam: pilot, reason: .goal))
                state.match.phase = .serve
                stageServe(on: nil)
            case .ballCrossedCenter, .shipDestroyed:
                break
            }
        }
        lastEvents = events
    }

    private mutating func respawnDestroyedShips() {
        for seat in Seat.allCases {
            guard let destroyedShip = state.ships[seat], destroyedShip.isDestroyed else { continue }
            let homeSide = destroyedShip.homeSide
            let depth = seat.isWing ? 0.80 : 0.55
            state.ships[seat] = ShipState(
                position: SIMD2(homeSide == .cyan ? -depth : depth, -0.45),
                angle: .pi / 2,
                homeSide: homeSide
            )
        }
    }

    private mutating func fireBolt(from ship: inout ShipState, owner: Team) {
        let axis = SIMD2(cos(ship.angle), sin(ship.angle))
        let lifetime = UInt64((configuration.boltLifetime / configuration.stepDuration).rounded())
        guard lifetime > 0, configuration.boltSpeed > 0 else { return }
        state.bolts.append(BoltState(
            id: state.nextBoltID,
            owner: owner,
            // Leaves from just past the nose so it cannot spawn inside a ball
            // already resting against the hull.
            position: ship.position + axis * 0.075,
            velocity: axis * configuration.boltSpeed,
            ticksRemaining: lifetime
        ))
        state.nextBoltID &+= 1
        ship.fireCooldownTicks = UInt64((configuration.boltCooldown / configuration.stepDuration).rounded())
    }

    /// The exhaust is a real jet: a ball sitting in it gets shoved down the
    /// plume. Strongest at the nozzle, gone at `exhaustWashRange`, and only
    /// inside a cone behind the tail, so flying past the ball does nothing.
    /// It is not a touch -- nothing has hit anything -- so it never counts
    /// against the touch limit, which is what makes hovering under a ball to
    /// cushion it a real option rather than a foul.
    private static let exhaustWashCone = 0.80

    private mutating func applyExhaustWash(dt: Double) {
        let range = configuration.exhaustWashRange
        guard range > 0, configuration.exhaustWashStrength > 0 else { return }
        for seat in Seat.allCases {
            guard let ship = state.ships[seat], !ship.isDestroyed, ship.thrustLevel > 0 else { continue }
            let tail = SIMD2(-cos(ship.angle), -sin(ship.angle))
            let offset = state.ball.position - ship.position
            let distance = simd_length(offset)
            guard distance > 0.000_001, distance < range else { continue }
            let along = simd_dot(offset / distance, tail)
            guard along > Self.exhaustWashCone else { continue }
            let falloff = 1 - distance / range
            let centring = (along - Self.exhaustWashCone) / (1 - Self.exhaustWashCone)
            let push = ship.thrustLevel * configuration.exhaustWashStrength * falloff * centring
            state.ball.velocity += tail * (push * dt)
        }
    }

    /// The tractor beam is the cannon's opposite: a cone ahead of the nose
    /// that draws the ball in and bleeds its speed off, strongest at the
    /// nose and gone at `tractorRange`. Like the wash it is not a touch, so
    /// reeling a ball in never counts against the touch limit -- the touch
    /// comes when it lands on the hull.
    private static let tractorCone = 0.45

    private mutating func applyTractorBeam(dt: Double) {
        let range = configuration.tractorRange
        guard range > 0, configuration.tractorStrength > 0 else { return }
        for seat in Seat.allCases {
            guard let ship = state.ships[seat], !ship.isDestroyed, ship.tractorActive else { continue }
            let nose = SIMD2(cos(ship.angle), sin(ship.angle))
            let offset = state.ball.position - ship.position
            let distance = simd_length(offset)
            guard distance > 0.000_001, distance < range else { continue }
            let toward = offset / distance
            let along = simd_dot(toward, nose)
            guard along > Self.tractorCone else { continue }
            let falloff = 1 - distance / range
            let centring = (along - Self.tractorCone) / (1 - Self.tractorCone)
            let grip = falloff * centring
            let pull = configuration.tractorStrength * grip
            state.ball.velocity -= toward * (pull * dt)
            state.ball.velocity *= max(0, 1 - configuration.tractorDrag * grip * dt)
        }
    }

    private mutating func advanceBolts(
        contacts: inout [RuleContact],
        effects: inout [SimulationEvent]
    ) {
        guard !state.bolts.isEmpty else { return }
        let dt = configuration.stepDuration
        var survivors: [BoltState] = []
        survivors.reserveCapacity(state.bolts.count)
        var ballStruck = false
        for var bolt in state.bolts {
            let previous = bolt.position
            bolt.position += bolt.velocity * dt
            bolt.ticksRemaining -= 1

            if !ballStruck, let _ = sweptCircleTime(
                from: previous - state.ball.position,
                to: bolt.position - state.ball.position,
                center: .zero,
                radius: state.ball.radius + BoltState.radius
            ) {
                ballStruck = true
                let speed = simd_length(bolt.velocity)
                let direction = speed > 0.000_001 ? bolt.velocity / speed : SIMD2(0, 1)
                state.ball.velocity += direction * configuration.boltPunch
                contacts.append(.ballTouchedShip(team: bolt.owner))
                effects.append(.collisionEffect(
                    position: state.ball.position,
                    intensity: configuration.boltPunch
                ))
                continue
            }

            let outside = abs(bolt.position.x) > arena.halfWidth
                || bolt.position.y < arena.floorY
                || bolt.position.y > arena.ceilingY
            let struckHump = arena.humpContact(position: bolt.position, radius: BoltState.radius) != nil
            if bolt.ticksRemaining == 0 || outside || struckHump { continue }
            survivors.append(bolt)
        }
        state.bolts = survivors
    }

    /// Every seated hull can knock every other one, teammates included.
    private mutating func resolveShipShipCollisions(
        previousPositions: [Seat: SIMD2<Double>],
        effects: inout [SimulationEvent]
    ) {
        let seats = Seat.allCases.filter { state.ships[$0] != nil }
        guard seats.count > 1 else { return }
        for (index, first) in seats.enumerated() {
            for second in seats[(index + 1)...] {
                resolveShipShipCollision(
                    between: first,
                    and: second,
                    previousPositions: previousPositions,
                    effects: &effects
                )
            }
        }
    }

    private mutating func resolveShipShipCollision(
        between firstSeat: Seat,
        and secondSeat: Seat,
        previousPositions: [Seat: SIMD2<Double>],
        effects: inout [SimulationEvent]
    ) {
        guard var first = state.ships[firstSeat], var second = state.ships[secondSeat],
              !first.isDestroyed, !second.isDestroyed,
              let previousFirst = previousPositions[firstSeat],
              let previousSecond = previousPositions[secondSeat] else { return }

        let relativeStart = previousFirst - previousSecond
        let relativeEnd = first.position - second.position
        guard let hitTime = sweptCircleTime(
            from: relativeStart,
            to: relativeEnd,
            center: .zero,
            radius: 0.096
        ) else { return }

        let impactSpeed = simd_length(first.velocity - second.velocity)
        var normal = relativeStart + (relativeEnd - relativeStart) * hitTime
        let length = simd_length(normal)
        normal = length > 0.000_001 ? normal / length : SIMD2(-1, 0)
        let closingSpeed = max(0, -simd_dot(first.velocity - second.velocity, normal))
        if closingSpeed > 0 {
            let impulse = normal * (closingSpeed * 0.82)
            first.velocity += impulse
            second.velocity -= impulse
        }
        state.ships[firstSeat] = first
        state.ships[secondSeat] = second
        // Same rule as the hump: two hulls resting against each other are
        // not colliding every tick.
        if closingSpeed > Self.effectImpactSpeed {
            effects.append(.collisionEffect(
                position: (first.position + second.position) / 2,
                intensity: impactSpeed
            ))
        }
    }

    private mutating func resolveArenaCollision(
        for ship: inout ShipState,
        from previousPosition: SIMD2<Double>,
        effects: inout [SimulationEvent]
    ) {
        let radius = 0.048

        // Nothing about the net stops a hull: it is a goal, and defending a
        // goal means being able to fly into it. The lips are part of the net,
        // so they let a hull through too. What is still solid in the middle
        // is the hump the net hangs from.
        if let hump = arena.humpContact(
            from: previousPosition,
            to: ship.position,
            radius: radius
        ) {
            ship.position = hump.position
            let inwardSpeed = simd_dot(ship.velocity, hump.normal)
            if inwardSpeed < 0 {
                ship.velocity -= hump.normal * ((1 + 0.12) * inwardSpeed)
            }
            // A hull skidding along the hump touches it every tick. Only a
            // real knock is an event; the rest would be sparks and haptics
            // at 120 Hz, and every one of them sent over the wire online.
            if inwardSpeed < -Self.effectImpactSpeed {
                effects.append(.collisionEffect(
                    position: ship.position,
                    intensity: abs(inwardSpeed)
                ))
            }
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

    private mutating func resolveBallCollision(
        previousPosition: SIMD2<Double>,
        contacts: inout [RuleContact]
    ) {
        let r = state.ball.radius
        var struckNet = false
        // Cap first: the rounded bottom of the net is hard and neutral, so
        // clipping it from below is a rebound rather than a score. Only the two
        // faces above it are the portal, and a ball that reaches one is gone --
        // whoever drove it in takes the point.
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
            if netHit.crossedFace, netHit.position.y <= arena.portalMouthTopY {
                state.ball.position = netHit.position
                contacts.append(.ballEnteredGoal(
                    defending: arena.portalScorer(enteredFromLeft: netHit.fromLeft).opponent
                ))
                return
            }
            if netHit.position.y > arena.portalMouthTopY {
                // Above the mouth the slab is a solid collar hanging from the
                // hump. A ball that has ridden the roof down the slope arrives
                // here, and it bounces off rather than sneaking in over the top.
                state.ball.position = netHit.position
                let normal = SIMD2(netHit.fromLeft ? -1.0 : 1.0, 0)
                let inwardSpeed = simd_dot(state.ball.velocity, normal)
                if inwardSpeed < 0 {
                    state.ball.velocity -= normal * ((1 + Self.ballRestitution) * inwardSpeed)
                }
                struckNet = true
            }
            // Otherwise the ball is inside the open mouth without having been
            // driven at either face. The mouth is a window, so it falls back
            // out and the rally goes on.
        }

        if !struckNet, previousPosition.x.sign != state.ball.position.x.sign {
            contacts.append(.ballCrossedCenter(into: state.ball.position.x < 0 ? .cyan : .orange))
        }

        // The lips are the one soft surface in the arena: a ball that lands
        // on one is meant to settle and roll down into the mouth, not spring
        // back off. They never count as a bounce -- they are part of the goal.
        if let lip = arena.lipContact(
            from: previousPosition,
            to: state.ball.position,
            radius: r
        ) {
            state.ball.position = lip.position
            let inwardSpeed = simd_dot(state.ball.velocity, lip.normal)
            if inwardSpeed < 0 {
                state.ball.velocity -= lip.normal * ((1 + 0.55) * inwardSpeed)
            }
        }

        // The hump and the corner arcs run before the flat clamps so that where
        // one of them is in play it, not the wall, sets the final position --
        // and so the floor clamp cannot double-count a touch the arc has
        // already reported.
        var floorRegistered = false
        if let hump = arena.humpContact(
            from: previousPosition,
            to: state.ball.position,
            radius: r
        ) {
            state.ball.position = hump.position
            let inwardSpeed = simd_dot(state.ball.velocity, hump.normal)
            if inwardSpeed < 0 {
                state.ball.velocity -= hump.normal * ((1 + Self.ballRestitution) * inwardSpeed)
            }
            // Never a floor contact: the hump is a structure hanging from the
            // roof, not the ground. The corners register because they *are*
            // the floor curving up at the ends of the court.
        }

        if let corner = arena.cornerContact(position: state.ball.position, radius: r) {
            state.ball.position = corner.position
            let inwardSpeed = simd_dot(state.ball.velocity, corner.normal)
            if inwardSpeed < 0 {
                state.ball.velocity -= corner.normal * ((1 + Self.ballRestitution) * inwardSpeed)
            }
            if corner.normal.y > 0.5 {
                floorRegistered = true
                contacts.append(.ballTouchedFloor(side: state.ball.position.x < 0 ? .cyan : .orange))
            }
        }

        if state.ball.position.y - r <= arena.floorY {
            state.ball.position.y = arena.floorY + r
            state.ball.velocity.y = abs(state.ball.velocity.y) * Self.floorRestitution
            if !floorRegistered {
                contacts.append(.ballTouchedFloor(side: state.ball.position.x < 0 ? .cyan : .orange))
            }
        }
        if state.ball.position.y + r >= arena.ceilingY {
            state.ball.position.y = arena.ceilingY - r
            state.ball.velocity.y = -abs(state.ball.velocity.y) * Self.ballRestitution
        }
        if state.ball.position.x - r <= -arena.halfWidth {
            state.ball.position.x = -arena.halfWidth + r
            state.ball.velocity.x = abs(state.ball.velocity.x) * Self.ballRestitution
        }
        if state.ball.position.x + r >= arena.halfWidth {
            state.ball.position.x = arena.halfWidth - r
            state.ball.velocity.x = -abs(state.ball.velocity.x) * Self.ballRestitution
        }
    }

    private func sweptNetCapHit(
        from start: SIMD2<Double>,
        to end: SIMD2<Double>,
        radius: Double,
        postCenterX: Double
    ) -> (position: SIMD2<Double>, normal: SIMD2<Double>)? {
        let center = SIMD2(postCenterX, arena.netBottomY)
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
        // favours neither half. A ball tossed dead underneath it has no side
        // to fall to, so alternate the nudge by rally -- symmetric across a
        // match, and it keeps the ball from pogoing under the cap.
        if abs(normal.x) < 0.02, normal.y < 0 {
            let rallyIndex = state.match.score.cyan + state.match.score.orange
            normal = simd_normalize(SIMD2(rallyIndex.isMultiple(of: 2) ? -0.18 : 0.18, -1))
        }
        guard simd_dot(state.ball.velocity, normal) < 0 else { return nil }
        return (center + normal * combinedRadius, normal)
    }

    private func sweptNetHit(
        from start: SIMD2<Double>,
        to end: SIMD2<Double>,
        radius: Double,
        postCenterX: Double
    ) -> (position: SIMD2<Double>, fromLeft: Bool, crossedFace: Bool)? {
        let limit = arena.netHalfWidth + radius
        let delta = end - start
        let startOffset = start.x - postCenterX
        // Already inside the slot. That is not a shot at a face, so it is
        // reported without a crossing and the caller decides what the slab is
        // at that height: solid collar above the mouth, open mouth below it.
        if abs(startOffset) <= limit, start.y + radius >= arena.netBottomY {
            let fromLeft = startOffset <= 0
            let penetration = limit - abs(startOffset)
            let movingTowardNet = fromLeft ? delta.x > 0 : delta.x < 0
            if penetration > 0.000_000_1 || movingTowardNet {
                return (
                    SIMD2(postCenterX + (fromLeft ? -limit : limit), start.y),
                    fromLeft,
                    false
                )
            }
        }
        guard abs(delta.x) > 0.000_000_1 else {
            if abs(end.x - postCenterX) <= limit, end.y + radius >= arena.netBottomY {
                let fromLeft = startOffset < 0
                return (
                    SIMD2(postCenterX + (fromLeft ? -limit : limit), end.y),
                    fromLeft,
                    false
                )
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
        guard hitY + radius >= arena.netBottomY else { return nil }
        return (SIMD2(boundary, hitY), fromLeft, true)
    }

    private mutating func resolveBallShipCollisions(
        previousBallPosition: SIMD2<Double>,
        previousShipPositions: [Seat: SIMD2<Double>],
        contacts: inout [RuleContact],
        effects: inout [SimulationEvent]
    ) {
        struct Fixture {
            var previousCenter: SIMD2<Double>
            var center: SIMD2<Double>
            var radius: Double
        }

        let ballEnd = state.ball.position
        var earliest: (seat: Seat, fixture: Fixture, t: Double)?
        for seat in Seat.allCases {
            guard let ship = state.ships[seat], !ship.isDestroyed,
                  let previousShipPosition = previousShipPositions[seat] else { continue }
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
                    earliest = (seat, fixture, t)
                }
            }
        }

        guard let hit = earliest, var ship = state.ships[hit.seat] else { return }
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
        state.ships[hit.seat] = ship
        contacts.append(.ballTouchedShip(team: hit.seat.team))
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
