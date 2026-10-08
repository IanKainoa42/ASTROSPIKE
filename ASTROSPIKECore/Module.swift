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

/// Turns a finger's position on the steering strip into a torque command.
///
/// The pad has no modes: a press and a drag are the same gesture. Touching
/// down places a *virtual centre* out past the finger, on the far side of
/// whichever half was touched, far enough that the first sample already reads
/// `initialTorque` -- half a turn, with `sharpenTravel` points of pad left
/// between the thumb and the stop to lean into a sharper one. Sliding back
/// toward that virtual centre eases the torque down continuously, through
/// zero, and on into the opposite turn.
public struct SteeringCurve: Sendable, Equatable {
    /// Torque a fresh press lands on, before the finger has moved at all.
    public let initialTorque: Double
    /// Travel left between a fresh press and full deflection -- the room to
    /// lean into a sharper turn.
    public let sharpenTravel: Double
    /// Shapes the ramp. 1 is linear; above 1 stretches the slow-turn end.
    public let gamma: Double

    public init(sharpenTravel: Double = 30, initialTorque: Double = 0.5, gamma: Double = 2) {
        self.sharpenTravel = sharpenTravel
        self.initialTorque = min(0.99, max(0.01, initialTorque))
        self.gamma = gamma
    }

    public static let standard = SteeringCurve()

    /// The pilot's turning-sensitivity preference, 0.5 ... 1.5, with 1 the
    /// standard curve exactly. It only reshapes the pad: a press lands on a
    /// harder turn and reaches full deflection in less travel. Full torque is
    /// the same at every setting, so it never changes how fast a ship can
    /// turn -- online, neither side gains anything by moving it.
    public static let sensitivityRange = 0.5 ... 1.5
    public static let sensitivityKey = "steeringSensitivity"

    public static func sensitivity(_ value: Double) -> SteeringCurve {
        let s = min(sensitivityRange.upperBound, max(sensitivityRange.lowerBound, value))
        return SteeringCurve(sharpenTravel: 30 / s, initialTorque: 0.5 * s)
    }

    /// Points of travel between neutral and full deflection. Derived rather
    /// than set, so `sharpenTravel` survives a change of `gamma`: a steeper
    /// gamma pushes the half-torque point further out, and the span grows to
    /// keep the same room past it.
    public var span: Double { sharpenTravel / (1 - pow(initialTorque, 1 / gamma)) }

    /// How far past the finger the virtual centre sits at touch-down.
    public var anchorOffset: Double { span - sharpenTravel }

    /// Where neutral sits for a touch that began at `anchorX` on a pad that is
    /// `width` points across.
    public func virtualCenter(anchorX: Double, width: Double) -> Double {
        // Positive torque is a left turn, and the left half of the pad turns
        // left, so neutral goes to the right of a left-half touch.
        if anchorX < width / 2 {
            // Never nearer the left edge than one span, or a thumb that landed
            // in the last few points of the pad could not reach full
            // deflection at all -- there is no travel outside the screen. Such
            // a press starts hotter than half instead, which is the only thing
            // left to give, and it is continuous: the further out you land,
            // the less room you had to begin with.
            return max(anchorX + anchorOffset, span)
        }
        return min(anchorX - anchorOffset, width - span)
    }

    /// Torque for a finger at `x`, given the neutral point fixed at touch-down.
    public func torque(x: Double, virtualCenter: Double) -> Double {
        let u = min(1, max(-1, (virtualCenter - x) / span))
        let magnitude = pow(abs(u), gamma)
        return u < 0 ? -magnitude : magnitude
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
    /// Ticks until this hull's next contact counts as a touch again. A ball
    /// pinned between a hull and a wall re-collides on every single step; the
    /// physics still fires each time, but only the first of a burst is
    /// scored, so a rattle costs one touch instead of the whole allowance.
    public var ballTouchCooldownTicks: UInt64
    /// Ticks left on an enemy bolt's stun: the controls are dead (no turn,
    /// no thrust, no trigger, no beam) and the hull drifts on what it had.
    public var stunTicks: UInt64
    /// Ticks until another bolt can stun this hull again. Set with the stun
    /// and longer than it, so a stream of bolts breaks a pilot's rhythm once
    /// and then shoves them like any other hit, never locks them out.
    public var stunGuardTicks: UInt64
    /// Yaw, in radians a second, an enemy bolt knocked into the hull. Rides
    /// on top of the pilot's own turn and bleeds away in a fraction of a
    /// second; the turn rate itself is set from input every step, so the
    /// knock has to live here or it would be gone the next tick.
    public var knockSpin: Double

    public init(
        position: SIMD2<Double>,
        velocity: SIMD2<Double> = .zero,
        angle: Double,
        angularVelocity: Double = 0,
        isDestroyed: Bool = false,
        thrustLevel: Double = 0,
        homeSide: Team? = nil,
        fireCooldownTicks: UInt64 = 0,
        tractorActive: Bool = false,
        ballTouchCooldownTicks: UInt64 = 0,
        stunTicks: UInt64 = 0,
        stunGuardTicks: UInt64 = 0,
        knockSpin: Double = 0
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
        self.ballTouchCooldownTicks = ballTouchCooldownTicks
        self.stunTicks = stunTicks
        self.stunGuardTicks = stunGuardTicks
        self.knockSpin = knockSpin
    }
}

/// What an enemy bolt does to the hull it hits, on top of the shove every
/// hit gives. A host match rule, so it rides the wire with the tuning.
public enum BoltHit: String, Codable, CaseIterable, Sendable {
    /// The shove alone (builds 116-124).
    case shove
    /// Controls dead for a moment: breaks the pilot's rhythm.
    case stun
    /// The hull is knocked round, so the hit redirects it.
    case spin

    public var title: String {
        switch self {
        case .shove: "Shove"
        case .stun: "Stun"
        case .spin: "Spin"
        }
    }
}

/// A bolt from a ship's nose. It flies the whole court and plays the ball;
/// since build 116 it also shoves an enemy hull it hits (its own side's
/// hulls fly through it), and an enemy beam bends it. The gate is on the
/// trigger, not the bolt: a ship can fire from anywhere short of the MAX
/// CROSS line on the far half.
public struct BoltState: Codable, Equatable, Sendable {
    /// Thin enough that a pilot can clip the edge of the ball on purpose.
    public static let radius = 0.007
    /// How far a hit off the ball's centre turns it off the bolt's line,
    /// toward the line through the two centres where they meet: 0 always
    /// punches straight down the bolt's line, 1 is a pure glancing blow.
    /// Halfway sends a hit on the very edge out at 45 degrees. A dead-centre
    /// hit is the plain punch whatever this is.
    public static let glance = 0.5
    /// The spin, in radians a second, that a hit on the very edge leaves on
    /// the ball. It falls away to nothing toward a dead-centre hit.
    public static let spinKick = 30.0

    public var id: UInt64
    public var owner: Team
    /// The ship that fired it. Drawing only: the bolt is drawn in that
    /// hull's look. Every rule reads `owner`.
    public var seat: Seat
    public var position: SIMD2<Double>
    public var velocity: SIMD2<Double>
    public var ticksRemaining: UInt64

    public init(
        id: UInt64,
        owner: Team,
        seat: Seat? = nil,
        position: SIMD2<Double>,
        velocity: SIMD2<Double>,
        ticksRemaining: UInt64
    ) {
        self.id = id
        self.owner = owner
        self.seat = seat ?? .lead(owner)
        self.position = position
        self.velocity = velocity
        self.ticksRemaining = ticksRemaining
    }
}

public struct WorldState: Codable, Equatable, Sendable {
    public var tick: UInt64
    public var ships: [Seat: ShipState]
    /// Every ball in play, never empty. Singles courts fly one; doubles
    /// flies two small ones. `ball` is the first, for the many places that
    /// only ever needed one.
    public var balls: [BallState]
    /// The first ball. Reads and writes go straight through to `balls[0]`.
    public var ball: BallState {
        get { balls[0] }
        set { balls[0] = newValue }
    }
    public var match: MatchRuleState
    public var serveTicksRemaining: UInt64
    /// Which way the next serve drifts: -1 to the left half, +1 to the right.
    /// The ball reappears dead centre under the goal, and the side that just
    /// conceded is the side it is handed to.
    public var serveDriftSign: Double
    /// The teams have changed ends: cyan flies the right half and orange the
    /// left. Flipped after every set but the last, so each team plays both
    /// halves in a match. Colours stay with the team, so anything that turns
    /// a half of the court into a team goes through `team(onHalfAt:)`.
    public var sidesSwapped: Bool
    /// The serve under way is the break between sets: longer than a rally's,
    /// and counted down on every board.
    public var setBreak: Bool
    /// Bolts in flight, oldest first.
    public var bolts: [BoltState]
    public var nextBoltID: UInt64
    /// Who touched the ball last -- by hull or by bolt, whichever came most
    /// recently. Basketball is decided on it: the bucket belongs to whoever
    /// put the ball through, not to whichever half it fell from. Cleared on
    /// every serve so a stale touch cannot claim a shot nobody took.
    public var lastBallToucher: Team?
    /// Where each of the layout's sprung pegs has been shoved to, one entry
    /// per arena obstacle. Empty on a court with nothing sprung.
    public var bumpers: [BumperState]
    /// The match's goals, slams, zaps and longest rally, per pilot. Kept by
    /// the rulebook's keeper and carried on every snapshot.
    public var stats: MatchStats
    /// The free-for-all book: bays, lives, winner. Nil on every other court,
    /// and nil is what keeps the duel and doubles exactly as they were.
    public var freeForAll: FreeForAllState?

    public init(
        tick: UInt64 = 0,
        ships: [Seat: ShipState],
        ball: BallState = BallState(position: SIMD2(0, 0.10)),
        extraBalls: [BallState] = [],
        match: MatchRuleState = MatchRuleState(),
        serveTicksRemaining: UInt64 = 0,
        serveDriftSign: Double = -1,
        sidesSwapped: Bool = false,
        setBreak: Bool = false,
        bolts: [BoltState] = [],
        nextBoltID: UInt64 = 0,
        lastBallToucher: Team? = nil,
        bumpers: [BumperState] = [],
        stats: MatchStats = MatchStats(),
        freeForAll: FreeForAllState? = nil
    ) {
        self.tick = tick
        self.ships = ships
        self.balls = [ball] + extraBalls
        self.match = match
        self.serveTicksRemaining = serveTicksRemaining
        self.serveDriftSign = serveDriftSign
        self.sidesSwapped = sidesSwapped
        self.setBreak = setBreak
        self.bolts = bolts
        self.nextBoltID = nextBoltID
        self.lastBallToucher = lastBallToucher
        self.bumpers = bumpers
        self.stats = stats
        self.freeForAll = freeForAll
    }

    /// The team whose half of the court `x` is on.
    public func team(onHalfAt x: Double) -> Team {
        let left: Team = sidesSwapped ? .orange : .cyan
        return x < 0 ? left : left.opponent
    }

    /// -1 if the team is on the left half, +1 if it is on the right.
    public func halfSign(of team: Team) -> Double {
        self.team(onHalfAt: -1) == team ? -1 : 1
    }

    /// -1 or +1: the goal face `team` scores in. The face on your own half is
    /// the one you defend, so the one to score in is always across the net.
    public func attackFaceSign(of team: Team) -> Double {
        halfSign(of: team.opponent)
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
    /// How big the ball is. Bigger than nominal because that is what makes
    /// spin aimable: bolts are 0.007 across, so at the nominal 0.042 a clip
    /// off the ball's edge is luck, and a bigger ball is a target you can
    /// deliberately hit off-centre. The arena's goal mouth is cut to match
    /// -- see `ArenaGeometry.portalCollar`.
    public var ballRadius: Double
    /// How many balls are in play at once: one on every court but doubles,
    /// which flies two. Every ball shares `ballRadius`.
    public var ballCount: Int
    /// Which court the match is played in. Rides the wire inside the host's
    /// tuning, so a guest builds the same walls it is simulating against.
    public var arenaLayout: ArenaLayout = .standard
    /// How hard the tractor beam hauls a Bumpers peg along its track, as a
    /// multiple of the baked pull. The host's choice, like the arena.
    public var pegPull: Double = 1.0
    /// Seconds a beam has to hold the ball before it locks on; zero never
    /// locks. Let go sooner and the ball just flies on in.
    public var beamLockTime: Double = 0
    /// How hard the stick swings a locked pair, times
    /// `SimulationEngine.beamSwingAcceleration`; zero never pumps.
    public var beamSwing: Double = 0
    public var ballDropHeight: Double
    public var ballDropSpeed: Double
    public var serveDelay: Double
    public var minimumBallSeparationSpeed: Double
    /// Seconds after a counted hull touch during which further contacts by the
    /// same hull are free. Sized off the measured gap between a rattle (the
    /// ball trapped on a wall, re-hitting within a handful of ticks) and a
    /// deliberate second hit, whose median gap is 20 ticks near the wall.
    public var ballTouchDebounce: Double
    /// Spring that pushes a ship back once it is past the halfway marker.
    /// 18 lets a flat-out run (about 2.7 at the marker, a full court's
    /// run-up with thrust held) just touch the far wall; 2.4 stops 0.03
    /// short and 2.0 stops 0.08 short. At 30 even a flat-out run stopped
    /// 0.07 short.
    public var crossingPushBack: Double
    /// Drag applied past the marker, ramping in with depth.
    public var crossingDrag: Double
    public var allowedFloorBounces: Int
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
    /// never award a point, and a goal re-serves to the pilot -- counted only
    /// if it went in the far face, as in a match. Flight is a match's.
    public var sandbox: Bool
    /// What an enemy bolt does to a hull besides shove it.
    public var boltHit: BoltHit = .stun
    /// Free-for-all ring only: how the ring flies and how hard its lines
    /// hold. The pilot's sliders offline; online the host's, which reach
    /// every board with the seating plan.
    public var ring = RingTuning()
    /// What the motor pushes a ring hull with.
    public var ringThrust: Double { maximumThrustAcceleration * ring.speed }
    /// The speed a ring hull settles at with the motor held.
    public var ringTopSpeed: Double { ringThrust / max(0.01, ring.hullDrag) }

    public init(
        stepDuration: Double = 1.0 / 120.0,
        gravity: SIMD2<Double> = SIMD2(0, -2),
        initialThrustAcceleration: Double = 5.5,
        maximumThrustAcceleration: Double = 5.5,
        thrustRampRate: Double = 0,
        torqueAcceleration: Double = 3,
        ballGravityMultiplier: Double = 0.95,
        ballRadius: Double = BallState.nominalRadius,
        ballCount: Int = 1,
        ballDropHeight: Double = 0.06,
        ballDropSpeed: Double = 0.18,
        serveDelay: Double = 1.35,
        minimumBallSeparationSpeed: Double = 0.45,
        ballTouchDebounce: Double = 0.1,
        crossingPushBack: Double = 18,
        crossingDrag: Double = 5.0,
        allowedFloorBounces: Int = 1,
        boltSpeed: Double = 2.6,
        boltLifetime: Double = 0.8,
        boltCooldown: Double = 0.45,
        boltPunch: Double = 1.15,
        exhaustWashStrength: Double = 0.85,
        exhaustWashRange: Double = 0.36,
        tractorStrength: Double = 2.6,
        tractorRange: Double = 0.82,
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
        self.ballRadius = min(
            BallState.nominalRadius * ArenaGeometry.maximumRadiusScale,
            max(BallState.nominalRadius, ballRadius)
        )
        self.ballCount = min(Self.maximumBallCount, max(1, ballCount))
        self.ballDropHeight = ballDropHeight
        self.ballDropSpeed = ballDropSpeed
        self.serveDelay = max(0, serveDelay)
        self.minimumBallSeparationSpeed = max(0, minimumBallSeparationSpeed)
        self.ballTouchDebounce = max(0, ballTouchDebounce)
        self.crossingPushBack = max(0, crossingPushBack)
        self.crossingDrag = max(0, crossingDrag)
        self.allowedFloorBounces = min(5, max(0, allowedFloorBounces))
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

    /// Two is doubles. Nothing is tuned for more.
    public static let maximumBallCount = 2

    /// Doubles: a wider, taller court with two small balls in it. The ball is
    /// pinned at nominal so the two of them stay small, and the crossing
    /// spring scales down with the longer half so a run still reaches the
    /// far wall and no further.
    public static func doubles(from base: SimulationConfiguration) -> SimulationConfiguration {
        var configuration = base
        configuration.ballRadius = BallState.nominalRadius
        configuration.ballCount = 2
        return configuration
    }

    /// The warm-up bay and practice: the pilot's own sliders, flown exactly
    /// as a match flies them -- MAX CROSS push-back and trigger line, serve
    /// timing. Only the rulebook differs: nothing is a fault. Until build 123
    /// the bay also switched off the push-back and let the trigger work
    /// anywhere, which made warming up a different game from the one waited for.
    public static func warmup(from base: SimulationConfiguration) -> SimulationConfiguration {
        var configuration = base
        configuration.sandbox = true
        return configuration
    }

    public static let warmup = warmup(from: online)

    /// Volleyball. The net is a wall now, so the ball is served from high
    /// above it, and the floor is live: the first touch of the ground ends
    /// the rally rather than the second.
    public static func volleyball(from base: SimulationConfiguration) -> SimulationConfiguration {
        var configuration = base
        configuration.ballDropHeight = 0.34
        configuration.allowedFloorBounces = 0
        return configuration
    }

    /// Basketball. The ball is put in play well under the rim so a serve can
    /// never drop through it on its own, and the bounce cap is moot -- the
    /// hoop court keeps its own book, where nothing is a fault.
    public static func basketball(from base: SimulationConfiguration) -> SimulationConfiguration {
        var configuration = base
        configuration.ballDropHeight = -0.20
        configuration.serveDelay = 1.1
        return configuration
    }

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
    /// Per-seat ball hitboxes. A seat missing here flies `ShipHitbox.shared`,
    /// so every hull meets the ball the same way unless one is set.
    public var shipHitboxes: [Seat: ShipHitbox] = [:]
    /// A guest's copy of an online board. It flies the physics between the
    /// host's snapshots but never keeps the book: no points, no serves, no
    /// phase changes of its own. Those arrive from the host, so a rally the
    /// guest thought it saw end cannot pull the ball out from under one the
    /// host is still playing.
    public var followsHost = false
    /// Which balls went into a goal this step, and whose goal it was, so a
    /// two-ball rally that plays on can put just those balls back up.
    private var goalsThisStep: [Int: Team] = [:]
    /// Free-for-all's goals this step: ball index to goal index.
    private var freeForAllGoalsThisStep: [Int: Int] = [:]
    /// What the physics saw this step that the stat book wants. Physics runs
    /// on every board, the guest's roll-forward and the warm-up bay
    /// included, so it only buffers here: the book is written on the
    /// rulebook's path alone, or a guest replaying ticks would count every
    /// hit twice.
    private var playsThisStep: [StatPlay] = []
    /// Each pilot's stick this step, for the beam lock: it picks the way a
    /// catch swings and pumps a locked pair.
    private var stickTorques: [Seat: Double] = [:]
    private enum StatPlay {
        case hit(Seat)
        case boltHit(Seat, slam: Bool)
        case zap(Seat, victim: Seat)
    }
    /// Every hull, bolt and beam grab that played a ball this step, in the
    /// order the physics saw them: the candidates for a save.
    private var defencePlays: [(ball: Int, seat: Seat, kind: SaveKind)] = []
    /// Saves waiting on the ball: booked once the moment the ghost said it
    /// would have gone in has passed with the ball still out. Host only, like
    /// the rest of the book.
    private var pendingSaves: [PendingSave] = []
    private struct PendingSave {
        var ball: Int
        var seat: Seat
        var kind: SaveKind
        var close: Bool
        var deadline: UInt64
    }
    /// No new save on a ball until this tick, so a ball pinned against a
    /// hull near the goal cannot farm them.
    private var saveGuardUntil: [Int: UInt64] = [:]
    /// A throwaway copy rolled forward to ask "would that have gone in?".
    /// It never looks for saves itself.
    private var isGhost = false

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

    /// How much speed the ball keeps off the walls, roof, hump, corners and
    /// collar. Below the old 0.94 so the ball feels like it has some weight
    /// to it instead of pinging around the arena.
    static let ballRestitution = 0.82
    /// Slowest hull-on-arena or hull-on-hull knock that counts as an impact.
    static let effectImpactSpeed = 0.25
    /// The floor takes a little more out of it than the walls do.
    static let floorRestitution = 0.78
    /// Speed the hoop court's ball always comes back off the deck with. It is
    /// a basketball there: it never lies down. Well short of the rim, so a
    /// loose ball can never bounce itself in.
    static let hoopDribbleSpeed = 1.35
    /// What a hull and the ball weigh against each other, and how lively the
    /// knock between them is.
    static let ballMass = 0.45
    static let shipMass = 1.60
    static let shipBallRestitution = 0.95
    /// A peg on its track: a little lighter than a hull, so a ship shoves it
    /// along but feels it, and much heavier than the ball, which it kicks.
    static let bumperMass = 1.20
    /// A peg slides on its own upright track, like a foosball goalie on its
    /// rod. Nothing pulls it back: it glides to a stop and stays wherever it
    /// was left. Drag bleeds speed off each second -- light enough that a
    /// good shove carries it a long way down a floor-to-roof track -- and a
    /// little dry friction brings a slow peg to a dead stop instead of
    /// creeping.
    static let bumperDrag = 1.5
    static let bumperFriction = 0.35
    /// A hull and a peg meet with a dull knock, not a bounce.
    static let shipBumperRestitution = 0.2
    /// How hard the tractor beam hauls a peg along its track, per unit of
    /// `tractorStrength`, before the host's peg-pull setting scales it. At
    /// the default a peg close and dead ahead crosses its whole track in a
    /// little over half a second; one at the edge of the cone barely creeps.
    /// Softer than build 105's, which had a spring to fight.
    static let bumperTractorGain = 1.2
    /// Speed a bolt knocks into a peg along its line: a bolt kicks the ball
    /// by `boltPunch`, and the peg is a little under three balls heavy. Only
    /// the part along the track moves it, so shoot from below to lift it.
    static let bumperBoltKick = 0.45
    /// Ball speed out of a nose-on strike, per unit of closing speed. Falls
    /// out of the impulse below; the guidance needs it to know how hard to
    /// drive through a ball to send it a given distance.
    static let strikeGain = (1 + shipBallRestitution) / (1 + ballMass / shipMass)

    public static func testing() -> SimulationEngine {
        SimulationEngine(state: WorldState(ships: [
            .cyan: ShipState(position: SIMD2(-0.55, -0.45), angle: .pi / 2),
            .orange: ShipState(position: SIMD2(0.55, -0.45), angle: .pi / 2),
        ]))
    }

    /// Swaps the court under a live engine. The arena is the whole of what
    /// makes a mode: the hump, the lips, the portal, the standing net and the
    /// hoop all live on it, and every collision routine reads it rather than
    /// a constant.
    public mutating func updateArena(_ arena: ArenaGeometry) {
        self.arena = arena
        seatBumpers()
    }

    /// Every sprung peg back on its anchor, at rest, one entry per obstacle.
    private mutating func seatBumpers() {
        let sprung = arena.obstacles.contains { $0.isSprung }
        state.bumpers = sprung ? Array(repeating: BumperState(), count: arena.obstacles.count) : []
    }

    public mutating func updateConfiguration(_ configuration: SimulationConfiguration) {
        self.configuration = configuration
        rules.updateAllowedFloorBounces(configuration.allowedFloorBounces)
        // The ball in play grows with the slider rather than waiting for the
        // next serve: the whole point of the knob is to see what the size
        // feels like while you are flying. A ball that ends up overlapping a
        // wall is pushed back out by the next step's contact resolve.
        for index in state.balls.indices { state.balls[index].radius = configuration.ballRadius }
        // The count follows the slider too: a court switched to doubles gets
        // its second ball on the next serve rather than mid-rally.
    }

    /// How many sets take the match: 1 for a single game, 2 for best of
    /// three, 3 for best of five. Part of the match state rather than the
    /// configuration, so an engine rebuilt from a host's snapshot keeps the
    /// host's format without being told again.
    public mutating func setMatchFormat(setsToWin: Int) {
        rules.updateSetsToWin(setsToWin)
        state.match = rules.state
    }

    /// Where a seat starts a rally on the standard court. Leads sit
    /// mid-court, wings sit behind them nearer the wall, so neither is under
    /// the ball when it drops.
    public static func spawnPosition(for seat: Seat, mirrored: Bool) -> SIMD2<Double> {
        spawnPosition(for: seat, mirrored: mirrored, arena: .standard)
    }

    /// The same spawn, stretched to fit `arena`: the doubles court is wider
    /// and taller, and a ship should start the same share of the way across
    /// it rather than the same distance from the middle.
    public static func spawnPosition(for seat: Seat, mirrored: Bool, arena: ArenaGeometry) -> SIMD2<Double> {
        let direction = mirrored ? 1.0 : -1.0
        let side = seat.team == .cyan ? direction : -direction
        return SIMD2(
            (seat.isWing ? 0.80 : 0.55) * side * arena.widthScale,
            -0.45 * arena.heightScale
        )
    }

    private func spawn(for seat: Seat, mirrored: Bool) -> SIMD2<Double> {
        if let ring = arena.ring, let bay = state.freeForAll?.bay(of: seat), ring.spokeAngles.indices.contains(bay) {
            return ring.spawnPoint(bay: bay)
        }
        if let bay = state.freeForAll?.bay(of: seat), arena.goalCentres.indices.contains(bay) {
            return Self.freeForAllSpawn(goalCentre: arena.goalCentres[bay])
        }
        return Self.spawnPosition(for: seat, mirrored: mirrored, arena: arena)
    }

    /// Where a free-for-all pilot starts: beside their own goal, on the side
    /// nearer the wall, clear of the ball that drops from under it.
    public static func freeForAllSpawn(goalCentre: Double) -> SIMD2<Double> {
        SIMD2(goalCentre + (goalCentre <= 0 ? -0.42 : 0.42), -0.45)
    }

    /// A fresh hull points up, away from the floor -- on the ring it starts
    /// beside its own net, pointing in at the middle.
    private func spawnAngle(for seat: Seat) -> Double {
        if let ring = arena.ring, let bay = state.freeForAll?.bay(of: seat), ring.spokeAngles.indices.contains(bay) {
            return ring.spokeAngles[bay] + .pi
        }
        return .pi / 2
    }

    /// True on the free-for-all field: no halves, no teams, the engine
    /// keeps the book.
    public var isFreeForAll: Bool { state.freeForAll != nil }

    /// On the ring, how a hull at `point` gets back short of `seat`'s MAX
    /// CROSS line, or nil when it is already there. A knocked-out pilot's
    /// ground is open to everyone.
    public func ringOffside(_ point: SIMD2<Double>, seat: Seat) -> SIMD2<Double>? {
        guard let ring = arena.ring, let field = state.freeForAll, let home = field.bay(of: seat) else { return nil }
        return ring.offside(point, home: home) { !field.isSolid(goal: $0) }
    }

    /// Whether `seat` is home in its own zone: on its own ground past the
    /// MAX CROSS line, where no rival may fly. Enemy bolts break on a hull
    /// there.
    public func ringInOwnZone(_ point: SIMD2<Double>, seat: Seat) -> Bool {
        guard let ring = arena.ring, let home = state.freeForAll?.bay(of: seat) else { return false }
        return simd_length(point) > ring.maxCrossRadius && ring.ground(at: point) == home
    }

    /// Whether two seats are on opposite sides. In free-for-all everyone
    /// else is.
    private func rivals(_ a: Seat, _ b: Seat) -> Bool {
        isFreeForAll ? a != b : a.team != b.team
    }

    /// Seats a free-for-all field: one pilot per bay, every one on full
    /// lives. The arena must already be `ArenaGeometry.freeForAll` with a
    /// goal per seat.
    public mutating func configureFreeForAll(_ seats: Set<Seat>) {
        state.freeForAll = FreeForAllState(seats: seats)
        configureRoster(seats)
    }

    /// Replaces every ship with a fresh one in each of the given seats and
    /// stages a rally. Seats not listed are simply empty.
    public mutating func configureRoster(_ seats: Set<Seat>, mirrored: Bool = false) {
        state.ships = Dictionary(uniqueKeysWithValues: seats.map { seat in
            (seat, ShipState(position: spawn(for: seat, mirrored: mirrored), angle: spawnAngle(for: seat)))
        })
        prepareNextRally(mirrored: mirrored)
    }

    /// Play Again after a finished match: love-all, same roster and format,
    /// ships reseated, clock at zero. `prepareNextRally` refuses a finished
    /// board, so the rulebook has to be cleared first.
    public mutating func restartMatch() {
        rules.resetMatch()
        state.match = rules.state
        state.tick = 0
        state.sidesSwapped = false
        state.setBreak = false
        state.bolts.removeAll()
        state.nextBoltID = 0
        state.lastBallToucher = nil
        state.stats = MatchStats()
        if let field = state.freeForAll {
            // Knocked-out pilots left the field; every one of them comes back.
            state.freeForAll = FreeForAllState(seats: Set(field.bays))
            configureRoster(Set(field.bays))
            return
        }
        configureRoster(Set(state.ships.keys))
    }

    public mutating func prepareNextRally(mirrored: Bool) {
        guard state.match.phase != .finished else { return }
        // Relative to the ends the teams are on now, so a restart in the
        // second set does not quietly swap them back.
        let mirrored = mirrored != state.sidesSwapped
        state.setBreak = false
        // Whoever is seated stays seated; only the positions reset.
        let seats = state.ships.isEmpty ? Seat.singles : Set(state.ships.keys)
        state.ships = Dictionary(uniqueKeysWithValues: seats.map { seat in
            (seat, ShipState(position: spawn(for: seat, mirrored: mirrored), angle: spawnAngle(for: seat)))
        })
        state.serveDriftSign = mirrored ? 1 : -1
        state.balls = stagedBalls(moving: true)
        state.serveTicksRemaining = 0
        state.bolts.removeAll()
        seatBumpers()
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
        playsThisStep.removeAll()
        stickTorques.removeAll()
        defencePlays.removeAll()
        let previousShipPositions = state.ships.mapValues(\.position)
        for seat in Seat.allCases {
            guard var ship = state.ships[seat], !ship.isDestroyed else { continue }
            // A stunned hull flies with its hands off the stick.
            let input = ship.stunTicks > 0 ? .idle(tick: state.tick) : inputs[seat] ?? .idle(tick: state.tick)
            if ship.stunTicks > 0 { ship.stunTicks -= 1 }
            if ship.stunGuardTicks > 0 { ship.stunGuardTicks -= 1 }
            stickTorques[seat] = input.torque
            if let locked = lockedBall(of: seat), let lock = state.balls[locked].beamLock {
                // Welded to a ball, the hull turns with the pair, not the stick.
                ship.angularVelocity = lock.spin
            } else {
                ship.angularVelocity = input.torque * configuration.torqueAcceleration + ship.knockSpin
            }
            ship.angle += ship.angularVelocity * dt
            if ship.knockSpin != 0 {
                ship.knockSpin *= exp(-dt / Self.knockSpinDecay)
                if abs(ship.knockSpin) < 0.05 { ship.knockSpin = 0 }
            }
            // On the ring, down is out: gravity pulls every hull to the rim,
            // harder the farther out it flies.
            var acceleration = arena.ring.map {
                $0.gravity(at: ship.position, rim: simd_length(configuration.gravity) * configuration.ring.gravity)
            } ?? configuration.gravity
            if input.thrust {
                ship.thrustLevel = ship.thrustLevel > 0
                    ? min(
                        configuration.maximumThrustAcceleration,
                        ship.thrustLevel + configuration.thrustRampRate * dt
                    )
                    : configuration.initialThrustAcceleration
                acceleration += SIMD2(cos(ship.angle), sin(ship.angle)) * ship.thrustLevel
                    * (arena.ring == nil ? 1 : configuration.ring.speed)
            } else {
                ship.thrustLevel = 0
            }
            if arena.ring != nil {
                acceleration -= ship.velocity * configuration.ring.hullDrag
            }
            // The halfway marker is a wall of treacle rather than a tripwire: the
            // deeper a pilot pushes into the far half, the harder the arena shoves
            // back and the more speed it steals. Nothing here is lethal.
            let intrusionSign = ship.homeSide == .cyan ? 1.0 : -1.0
            let depth = ship.position.x * intrusionSign - arena.opponentCrossingLimit
            if depth > 0, !isFreeForAll {
                acceleration.x -= intrusionSign * configuration.crossingPushBack * depth
                acceleration -= ship.velocity
                    * (configuration.crossingDrag * min(1, depth / 0.20))
            }
            // The ring's MAX CROSS: the same treacle, shoving back toward the
            // nearest ground the pilot may fly.
            if let back = ringOffside(ship.position, seat: seat) {
                let depth = simd_length(back)
                acceleration += back * configuration.ring.linePush
                acceleration -= ship.velocity
                    * (configuration.ring.lineBrake * min(1, depth / 0.20))
            }
            ship.velocity += acceleration * dt
            ship.position += ship.velocity * dt
            resolveArenaCollision(
                for: &ship,
                hitbox: shipHitboxes[seat] ?? .shared,
                from: previousShipPositions[seat] ?? ship.position,
                effects: &collisionEffects
            )
            if ship.fireCooldownTicks > 0 { ship.fireCooldownTicks -= 1 }
            if ship.ballTouchCooldownTicks > 0 { ship.ballTouchCooldownTicks -= 1 }
            // The trigger works anywhere short of the MAX CROSS line, the
            // same line the push-back starts at. Past it the nose is live
            // for ramming but the bolts stay holstered. (Until build 125 it
            // stopped at the base of the hump.)
            let homeSign = ship.homeSide == .cyan ? -1.0 : 1.0
            let shortOfTheLine = isFreeForAll
                ? ringOffside(ship.position, seat: seat) == nil
                : ship.position.x * homeSign >= -arena.opponentCrossingLimit
            if input.fire, shortOfTheLine, ship.fireCooldownTicks == 0, state.match.phase == .playing {
                fireBolt(from: &ship, seat: seat)
            }
            // Unlike the cannon, the beam works anywhere on the court — a
            // pilot can reach into the far half and reel the ball back out.
            ship.tractorActive = input.tractor && state.match.phase == .playing
            state.ships[seat] = ship
        }
        applyTractorToShips(dt: dt)
        resolveShipShipCollisions(
            previousPositions: previousShipPositions,
            effects: &collisionEffects
        )
        // Before the serve returns early: a peg shoved during the serve
        // still swings home rather than freezing where it was left.
        advanceBumpers(dt: dt)
        resolveShipBumperCollisions(effects: &collisionEffects)

        if state.match.phase == .serve {
            // The staged ball hangs still, but it is not a ghost: a hull that
            // flies into it stops against it rather than ending the countdown
            // parked inside the ball, where the first live step could not see it.
            for ballIndex in state.balls.indices { pushShipsOffBall(ballIndex) }
            advanceServe()
            lastEvents = collisionEffects
            state.tick += 1
            return
        }

        // The board as it stood before the ball moved, for the save ghost.
        // Only the rulebook's board keeps the book, so only it pays for one.
        let beforeBall: SimulationEngine? = isGhost || followsHost || configuration.sandbox || arena.hoop != nil
            || isFreeForAll ? nil : self
        let previousBallPositions = state.balls.map(\.position)
        goalsThisStep.removeAll()
        freeForAllGoalsThisStep.removeAll()
        for ballIndex in state.balls.indices {
            if let ring = arena.ring {
                state.balls[ballIndex].velocity += ring.gravity(
                    at: state.balls[ballIndex].position,
                    rim: simd_length(configuration.gravity) * configuration.ring.gravity
                        * configuration.ballGravityMultiplier
                ) * dt
            } else {
                state.balls[ballIndex].velocity += configuration.gravity * configuration.ballGravityMultiplier * dt
            }
            // A puck slides dead straight: its spin is only for show. A
            // locked ball turns with its hull, so it neither curves nor
            // winds down on its own.
            if !(arena.ring != nil && configuration.ring.puck), state.balls[ballIndex].beamLock == nil {
                (state.balls[ballIndex].velocity, state.balls[ballIndex].spin) = BallState.curved(
                    state.balls[ballIndex].velocity,
                    spin: state.balls[ballIndex].spin,
                    over: dt
                )
            }
            applyExhaustWash(dt: dt, ballIndex: ballIndex)
            applyTractorBeam(dt: dt, ballIndex: ballIndex)
            if arena.ring != nil {
                state.balls[ballIndex].velocity *= exp(-configuration.ring.ballDrag * dt)
            }
            state.balls[ballIndex].position += state.balls[ballIndex].velocity * dt
        }
        solveBeamLocks(effects: &collisionEffects)
        advanceBolts(previousShipPositions: previousShipPositions, effects: &collisionEffects)
        resolveBallBallCollisions(effects: &collisionEffects)
        for ballIndex in state.balls.indices {
            resolveBallShipCollisions(
                ballIndex: ballIndex,
                previousBallPosition: previousBallPositions[ballIndex],
                previousShipPositions: previousShipPositions,
                contacts: &contacts,
                effects: &collisionEffects
            )
            resolveBallCollision(
                ballIndex: ballIndex,
                previousPosition: previousBallPositions[ballIndex],
                contacts: &contacts
            )
            // A ball the hull just shoved into a wall comes back off the wall
            // into the hull. The wall wins: the ship gives way, or next step
            // starts overlapped and the hull passes straight through the ball.
            pushShipsOffBall(ballIndex)
        }

        // Whoever put a hand on it most recently owns whatever happens next.
        // Only the hoop court decides anything on it, but every court keeps
        // it so the board can name who touched last.
        for contact in contacts {
            if case let .ballTouchedShip(team, _) = contact { state.lastBallToucher = team }
        }

        if configuration.sandbox {
            resolveSandbox(contacts: contacts, effects: collisionEffects)
            state.tick += 1
            return
        }

        if arena.hoop != nil {
            resolveHoopCourt(contacts: contacts, effects: collisionEffects)
            state.tick += 1
            return
        }

        if followsHost {
            // The host keeps the book. The guest only flies the physics
            // until the next snapshot lands, and the effects are the one
            // thing it may show on its own.
            lastEvents = collisionEffects
            state.tick += 1
            return
        }

        if isFreeForAll {
            resolveFreeForAll(effects: collisionEffects)
            state.tick += 1
            return
        }

        let wasPlaying = rules.state.phase == .playing
        var ruleEvents = rules.resolve(contacts, goalsKeepPlaying: state.balls.count > 1)
        if wasPlaying { ruleEvents = bookStats(contacts: contacts, ruleEvents: ruleEvents, before: beforeBall) }
        lastEvents = ruleEvents + collisionEffects
        state.match = rules.state
        if state.match.phase == .playing {
            for (ballIndex, defending) in goalsThisStep.sorted(by: { $0.key < $1.key }) {
                redropBall(ballIndex, toward: defending)
            }
        }
        if state.match.phase == .serve {
            let concedingTeam = ruleEvents.compactMap { event -> Team? in
                guard case let .point(scoringTeam, _) = event else { return nil }
                return scoringTeam.opponent
            }.first
            let setEnded = ruleEvents.contains { if case .setEnded = $0 { true } else { false } }
            if setEnded { changeEnds() }
            stageServe(on: concedingTeam)
            if setEnded {
                state.setBreak = true
                state.serveTicksRemaining = UInt64((Self.setBreakDuration / configuration.stepDuration).rounded())
            }
        }
        state.tick += 1
    }

    /// Writes the step's plays into the stat book and credits each goal the
    /// rulebook actually awarded -- one ball only scores once a step, and a
    /// set point stops the second -- to the last play on that ball. Returns
    /// the rule events with a `goalScored` slotted in after each goal's
    /// point, so every board names the shot alongside the score.
    private mutating func bookStats(
        contacts: [RuleContact],
        ruleEvents: [SimulationEvent],
        before: SimulationEngine?
    ) -> [SimulationEvent] {
        var calls = bookPlays()
        calls += bookSaves(before: before)
        for contact in contacts {
            if case .ballCrossedCenter = contact { state.stats.ballCrossedCenter() }
        }
        // Read before anything re-drops or re-stages the ball.
        var goals = goalsThisStep.sorted { $0.key < $1.key }.makeIterator()
        var events: [SimulationEvent] = []
        for event in ruleEvents {
            events.append(event)
            switch event {
            case let .point(_, reason):
                if reason == .goal, let goal = goals.next(),
                   let credit = state.stats.creditGoal(
                       lastPlay: state.balls[goal.key].lastPlay,
                       pulledBy: beamPuller(of: goal.key),
                       defending: goal.value
                   ) {
                    events.append(.goalScored(seat: credit.seat, style: credit.style))
                }
                state.stats.pointEnded()
            case .rallyReset:
                state.stats.pointEnded()
            default:
                break
            }
        }
        if state.match.phase != .playing { pendingSaves.removeAll() }
        return calls + events
    }

    /// Writes the step's hits, bolt hits and zaps into the book and returns
    /// the calls worth naming (a slam, a zap). Shared by every court that
    /// keeps a book: the duel's rulebook and the free-for-all's.
    private mutating func bookPlays() -> [SimulationEvent] {
        var calls: [SimulationEvent] = []
        for play in playsThisStep {
            switch play {
            case let .hit(seat):
                state.stats[seat].hits += 1
            case let .boltHit(seat, slam):
                state.stats[seat].boltHits += 1
                if slam { calls.append(.play(seat: seat, call: .slam)) }
            case let .zap(seat, victim):
                state.stats[seat].zaps += 1
                calls.append(.play(seat: seat, call: .zap(victim: victim)))
            }
        }
        return calls
    }

    /// A save is a play by the defending side on a ball that, left alone,
    /// was going in. "Left alone" is asked of a ghost: the board from before
    /// the ball moved this step, with every ship and bolt lifted off it,
    /// rolled forward until the ball scores, bounces or runs out of time.
    /// The save is only booked once the ball has stayed out past the moment
    /// the ghost said it would go in -- a beam takes a while to turn a ball,
    /// and a touch that still lets it in was no save at all.
    private mutating func bookSaves(before: SimulationEngine?) -> [SimulationEvent] {
        var calls: [SimulationEvent] = []
        for (ballIndex, defending) in goalsThisStep {
            pendingSaves.removeAll { $0.ball == ballIndex && $0.seat.team == defending }
        }
        let due = pendingSaves.filter { $0.deadline <= state.tick }
        pendingSaves.removeAll { $0.deadline <= state.tick }
        for save in due {
            state.stats[save.seat].saves += 1
            if save.close { state.stats[save.seat].closeSaves += 1 }
            switch save.kind {
            case .hull: break
            case .bolt: state.stats[save.seat].boltSaves += 1
            case .beam: state.stats[save.seat].beamSaves += 1
            }
            calls.append(.play(seat: save.seat, call: .save(save.kind, close: save.close)))
        }
        guard let before else { return calls }
        let dt = configuration.stepDuration
        let horizon = Int((Self.saveHorizon / dt).rounded())
        var seen: Set<Int> = []
        for play in defencePlays where seen.insert(play.ball).inserted {
            guard play.ball < before.state.balls.count,
                  state.tick >= saveGuardUntil[play.ball] ?? 0,
                  !pendingSaves.contains(where: { $0.ball == play.ball }),
                  goalsThisStep[play.ball] == nil,
                  state.team(onHalfAt: before.state.balls[play.ball].position.x) == play.seat.team,
                  let ticks = before.ghostGoal(ball: play.ball, against: play.seat.team, horizon: horizon)
            else { continue }
            let deadline = state.tick + UInt64(ticks) + UInt64((Self.saveGrace / dt).rounded())
            pendingSaves.append(PendingSave(
                ball: play.ball,
                seat: play.seat,
                kind: play.kind,
                close: Double(ticks) * dt <= Self.closeSaveWindow,
                deadline: deadline
            ))
            saveGuardUntil[play.ball] = deadline + UInt64((Self.saveGrace / dt).rounded())
        }
        return calls
    }

    /// Steps the ball alone -- no ships, no bolts -- and returns how many
    /// steps until it goes into `team`'s goal. Nil if it goes in elsewhere,
    /// touches the floor first, or is still out at the horizon.
    private func ghostGoal(ball index: Int, against team: Team, horizon: Int) -> Int? {
        var ghost = self
        ghost.isGhost = true
        ghost.followsHost = false
        ghost.configuration.sandbox = true
        ghost.state.ships = [:]
        ghost.state.bolts = []
        ghost.state.balls = [state.balls[index]]
        ghost.state.match.phase = .playing
        ghost.pendingSaves = []
        let floor = ghost.state.match.floorContacts
        for step in 1 ... max(1, horizon) {
            ghost.step(inputs: [:])
            if let defending = ghost.goalsThisStep[0] { return defending == team ? step : nil }
            if ghost.state.match.floorContacts != floor { return nil }
        }
        return nil
    }

    /// How far ahead the ghost looks for the goal a save stopped.
    static let saveHorizon = 1.0
    /// A save the ghost had going in within this long is a close one.
    static let closeSaveWindow = 0.3
    /// How long past the ghost's goal the ball must stay out to book it.
    static let saveGrace = 0.3

    /// Seconds between the set point and the next set's serve: long enough
    /// to read the stat board and catch a breath while the ships settle on
    /// their new ends. Was 3 until build 121.
    public static let setBreakDuration = 6.0

    /// Between sets the teams change ends, colours and all, so each plays
    /// both halves in a match. Every hull starts the next set from its seat's
    /// spawn on the new half, and its `homeSide` follows the half.
    private mutating func changeEnds() {
        state.sidesSwapped.toggle()
        seatBumpers()
        for seat in state.ships.keys {
            state.ships[seat] = ShipState(
                position: spawn(for: seat, mirrored: state.sidesSwapped),
                angle: .pi / 2
            )
        }
    }

    /// Enough sideways drift that the ball lands well inside the receiving
    /// half rather than on the centre line.
    static let serveDriftSpeed = 0.45
    /// The ring's face-off drift out of the middle, between two nets.
    static let ringServeSpeed = 0.30
    /// How far off dead centre the face-off ball sits, toward its gap, so a
    /// staged serve that lets go with no push still drifts out the gap.
    static let ringServeOffset = 0.04
    /// How far the face-off drift is turned off the gap's centre line, as a
    /// share of half the gap between nets. Straight down the line, the rim
    /// sends the ball back through the middle along the same line -- and
    /// with three nets that line ends in a mouth, so every untouched serve
    /// scored. Anywhere from 0.05 to 0.3 of a half-gap off it, none did.
    static let ringServeSkew = 0.2
    /// How far a serve strays from the stock one, as fractions of it. The
    /// side it drifts to never changes; how hard, how fast it drops and how
    /// long the countdown hangs do, so a pilot parked on the landing spot
    /// has to read each serve instead of pre-flying it.
    static let serveDriftRange = 0.55 ... 1.45
    static let serveDropRange = 0.80 ... 1.25
    static let serveDelayRange = 0.75 ... 1.45

    /// A repeatable draw in `range`, keyed off the tick and the score. Both
    /// ends of an online game already share those, so host and guest pick
    /// the same serve without a word on the wire, and a test replays exactly.
    private func serveDraw(_ salt: UInt64, in range: ClosedRange<Double>) -> Double {
        var z = state.tick &* 0x9E37_79B9_7F4A_7C15
            &+ UInt64(truncatingIfNeeded: state.match.score.cyan) &* 0xBF58_476D_1CE4_E5B9
            &+ UInt64(truncatingIfNeeded: state.match.score.orange) &* 0x94D0_49BB_1331_11EB
            &+ salt &* 0xD6E8_FEB8_6659_FD93
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        let unit = Double(z >> 11) / Double(1 << 53)
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }

    /// Every ball a serve puts up, sitting under the cap of the goal. One
    /// ball drops dead centre and drifts to the side that conceded. Two sit
    /// a shoulder apart and drift opposite ways, so each side is handed one
    /// -- the first still goes to the conceding side. `moving` gives them
    /// their serve velocity straight away; a staged serve leaves them still
    /// until the countdown lets go.
    private func stagedBalls(moving: Bool) -> [BallState] {
        let count = configuration.ballCount
        return (0 ..< count).map { index in
            let sign = index == 0 ? state.serveDriftSign : -state.serveDriftSign
            let spread = count > 1 ? sign * (configuration.ballRadius + 0.012) : 0
            let salt = UInt64(index) * 2
            let velocity = SIMD2(
                sign * Self.serveDriftSpeed * serveDraw(salt + 1, in: Self.serveDriftRange),
                -configuration.ballDropSpeed * serveDraw(salt + 2, in: Self.serveDropRange)
            )
            // On the ring the serve is a face-off in the open middle,
            // drifting out through the gap beside the net that just conceded.
            // The centre bumper, when it is up, pushes the drop out past itself.
            if let ring = arena.ring, let bay = state.freeForAll?.serveBay, ring.gapBearings.indices.contains(bay) {
                let out = SIMD2(cos(ring.gapBearings[bay] - Self.ringServeSkew * .pi / Double(ring.spokeAngles.count)), sin(ring.gapBearings[bay] - Self.ringServeSkew * .pi / Double(ring.spokeAngles.count)))
                let across = SIMD2(-out.y, out.x)
                let drop = ring.centreBumper
                    ? RingField.centreBumperRadius + configuration.ballRadius + 0.03
                    : Self.ringServeOffset
                return BallState(
                    position: out * drop + across * spread,
                    velocity: moving ? out * Self.ringServeSpeed * serveDraw(salt + 2, in: Self.serveDropRange) : .zero,
                    radius: configuration.ballRadius
                )
            }
            return BallState(
                position: SIMD2(serveCentreX + spread, configuration.ballDropHeight),
                velocity: moving ? velocity : .zero,
                radius: configuration.ballRadius
            )
        }
    }

    /// Put a scored ball straight back into a live rally: dead centre under
    /// the goal, already falling, drifting to the side that just conceded --
    /// a serve for one ball that never stops the other.
    private mutating func redropBall(_ index: Int, toward team: Team) {
        guard state.balls.indices.contains(index) else { return }
        let sign = state.halfSign(of: team)
        let salt = 16 + UInt64(index) * 2
        state.balls[index] = BallState(
            position: SIMD2(0, configuration.ballDropHeight),
            velocity: SIMD2(
                sign * Self.serveDriftSpeed * serveDraw(salt, in: Self.serveDriftRange),
                -configuration.ballDropSpeed * serveDraw(salt + 1, in: Self.serveDropRange)
            ),
            radius: configuration.ballRadius
        )
    }

    /// True when the engine keeps its own book instead of handing contacts
    /// to `MatchRules`: the warm-up bay and the hoop court both do.
    private var usesEngineRules: Bool { configuration.sandbox || arena.hoop != nil || isFreeForAll }

    /// Where the serve drops from: under the goal, or in free-for-all under
    /// the goal that just conceded.
    private var serveCentreX: Double {
        guard let bay = state.freeForAll?.serveBay, arena.goalCentres.indices.contains(bay) else { return 0 }
        return arena.goalCentres[bay]
    }

    /// Free-for-all's rulebook. A goal costs its owner a life; the last life
    /// takes their ship off the field and closes their goal; one pilot left
    /// is the winner. Nothing else -- bounces, touches, crossings -- counts
    /// toward the result, but the book is kept as the duel keeps it: hits,
    /// bolt hits and zaps every step, and each goal credited to the last
    /// play on the ball (a slam dunk when a rival's beam pulled it in, an
    /// own goal when the net's owner put it there). There are no halves, so
    /// no rally is measured and no save is called.
    private mutating func resolveFreeForAll(effects: [SimulationEvent]) {
        var events = effects
        guard var field = state.freeForAll, state.match.phase == .playing else {
            lastEvents = events
            return
        }
        events = bookPlays() + events
        // One goal a step. With two balls up, one that went in on the same
        // tick bounces back out of the pocket and has to go in again.
        guard let (ballIndex, goal) = freeForAllGoalsThisStep.sorted(by: { $0.key < $1.key }).first,
              let owner = field.owner(ofGoal: goal), !field.isOut(owner) else {
            lastEvents = events
            return
        }
        let scorer = state.balls[ballIndex].lastPlay?.seat
        let credit = state.stats.creditGoal(
            lastPlay: state.balls[ballIndex].lastPlay,
            pulledBy: beamPuller(of: ballIndex),
            defendingSeat: owner
        )
        let left = max(0, (field.lives[owner] ?? 0) - 1)
        field.lives[owner] = left
        events.append(.lifeLost(seat: owner, by: scorer, livesLeft: left))
        if let credit { events.append(.goalScored(seat: credit.seat, style: credit.style)) }
        if left == 0 {
            events.append(.pilotOut(owner))
            state.ships[owner] = nil
        }
        let standing = field.standing
        if standing.count <= 1 {
            field.winner = standing.first
            state.freeForAll = field
            state.match.phase = .finished
            if let winner = standing.first { events.append(.lastPilotStanding(winner)) }
            lastEvents = events
            return
        }
        field.serveBay = field.nearestOpenBay(to: goal)
        state.freeForAll = field
        // Two balls up: only the one that went in comes back, already
        // moving off the face-off spot; the other never stops.
        if state.balls.count > 1, state.balls.count == configuration.ballCount {
            state.balls[ballIndex] = stagedBalls(moving: true)[0]
            lastEvents = events
            return
        }
        state.match.phase = .serve
        stageServe(on: nil)
        lastEvents = events
    }

    private mutating func stageServe(on team: Team?) {
        // The ball reappears dead centre, just under the cap of the goal, and
        // drifts out to the side that just conceded. It cannot score by
        // itself: the goal is above it, and it only ever falls.
        if let team {
            state.serveDriftSign = state.halfSign(of: team)
        } else {
            state.serveDriftSign = -state.serveDriftSign
        }
        state.balls = stagedBalls(moving: false)
        state.bolts.removeAll()
        // Every point starts from the same court: pegs back on the middle
        // of their tracks.
        seatBumpers()
        // A fresh ball has nobody's fingerprints on it -- and no hull is still
        // holding a debounce from the rally that just ended, which would eat
        // the first touch of this one.
        state.lastBallToucher = nil
        for seat in state.ships.keys { state.ships[seat]?.ballTouchCooldownTicks = 0 }
        let delay = configuration.serveDelay * serveDraw(0, in: Self.serveDelayRange)
        state.serveTicksRemaining = max(1, UInt64((delay / configuration.stepDuration).rounded()))
    }

    private mutating func advanceServe() {
        for index in state.balls.indices { state.balls[index].velocity = .zero }
        if state.serveTicksRemaining > 0 {
            state.serveTicksRemaining -= 1
        }
        guard state.serveTicksRemaining == 0 else { return }
        state.setBreak = false
        respawnDestroyedShips()
        // Let go of every ball that was staged, and only those: a ball
        // count that changed during the serve takes effect next serve.
        let released = stagedBalls(moving: true)
        for index in state.balls.indices where index < released.count {
            state.balls[index].velocity = released[index].velocity
        }
        if usesEngineRules {
            state.match.phase = .playing
            state.match.floorContacts = SideCounts()
            state.match.shipTouches = SideCounts()
            state.lastBallToucher = nil
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
            case let .ballTouchedShip(team, counted):
                if counted { state.match.shipTouches[team] += 1 }
            case let .ballTouchedFloor(side):
                state.match.floorContacts[side] += 1
                state.match.shipTouches = SideCounts()
            case .ballEnteredHoop:
                break
            case let .ballEnteredGoal(defending):
                // A match only pays for the far face. Either way the next
                // ball drifts back to the lone pilot's half.
                let pilot = state.ships.keys.min()?.team ?? .cyan
                if defending != pilot {
                    state.match.score[pilot] += 1
                    events.append(.point(scoringTeam: pilot, reason: .goal))
                }
                state.match.phase = .serve
                stageServe(on: pilot)
            case .ballCrossedCenter, .shipDestroyed:
                break
            }
        }
        lastEvents = events
    }

    /// The hoop court's rulebook, and it is nearly all absence: there is no
    /// ladder of points to climb and nothing is a fault. A bounce is just a
    /// bounce, a wrecked hull is a re-serve rather than a concession, and the
    /// first ball to drop through the rim ends the match on the spot -- for
    /// whoever touched it last, whichever half it fell from.
    private mutating func resolveHoopCourt(contacts: [RuleContact], effects: [SimulationEvent]) {
        var events = effects
        var destroyed: Set<Team> = []
        for contact in contacts {
            switch contact {
            case let .ballTouchedShip(team, counted):
                if counted { state.match.shipTouches[team] += 1 }
            case let .ballTouchedFloor(side):
                state.match.floorContacts[side] += 1
            case .ballEnteredHoop:
                guard state.match.phase == .playing,
                      let scorer = state.lastBallToucher else { continue }
                state.match.score[scorer] += 1
                state.match.phase = .finished
                state.match.winner = scorer
                events.append(.point(scoringTeam: scorer, reason: .goal))
                events.append(.matchEnded(winner: scorer))
            case let .shipDestroyed(team, _):
                destroyed.insert(team)
            case .ballCrossedCenter, .ballEnteredGoal:
                break
            }
        }
        if state.match.phase == .playing, !destroyed.isEmpty {
            events.append(.rallyReset)
            state.match.phase = .serve
            stageServe(on: nil)
        }
        lastEvents = events
    }

    private mutating func respawnDestroyedShips() {
        for seat in Seat.allCases {
            guard let destroyedShip = state.ships[seat], destroyedShip.isDestroyed else { continue }
            if arena.ring != nil {
                state.ships[seat] = ShipState(position: spawn(for: seat, mirrored: false), angle: spawnAngle(for: seat))
                continue
            }
            let homeSide = destroyedShip.homeSide
            let depth = (seat.isWing ? 0.80 : 0.55) * arena.widthScale
            state.ships[seat] = ShipState(
                position: SIMD2(homeSide == .cyan ? -depth : depth, -0.45 * arena.heightScale),
                angle: .pi / 2,
                homeSide: homeSide
            )
        }
    }

    private mutating func fireBolt(from ship: inout ShipState, seat: Seat) {
        let axis = SIMD2(cos(ship.angle), sin(ship.angle))
        let lifetime = UInt64((configuration.boltLifetime / configuration.stepDuration).rounded())
        guard lifetime > 0, configuration.boltSpeed > 0 else { return }
        state.bolts.append(BoltState(
            id: state.nextBoltID,
            owner: seat.team,
            seat: seat,
            // Leaves from just past the nose so it cannot spawn inside a ball
            // already resting against the hull.
            position: ship.position + axis * ((shipHitboxes[seat] ?? .shared).noseReach + 0.005),
            velocity: axis * configuration.boltSpeed,
            ticksRemaining: lifetime
        ))
        state.nextBoltID &+= 1
        // The ring keeps its own, much slower, fire rate.
        let cooldown = arena.ring == nil ? configuration.boltCooldown : configuration.ring.fireCooldown
        ship.fireCooldownTicks = UInt64((cooldown / configuration.stepDuration).rounded())
    }

    /// The exhaust is a real jet: a ball sitting in it gets shoved down the
    /// plume. Strongest at the nozzle, gone at `exhaustWashRange`, and only
    /// inside a cone behind the tail, so flying past the ball does nothing.
    /// It is not a touch -- nothing has hit anything -- so it never clears
    /// the bounce allowance the way a hull does: hovering under a ball to
    /// cushion it keeps it off the floor, it does not reset the count.
    /// Public so `ArenaScene` throws its blast spray over the same cone.
    public static let exhaustWashCone = 0.80

    private mutating func applyExhaustWash(dt: Double, ballIndex: Int) {
        let range = configuration.exhaustWashRange
        guard range > 0, configuration.exhaustWashStrength > 0 else { return }
        for seat in Seat.allCases {
            guard let ship = state.ships[seat], !ship.isDestroyed, ship.thrustLevel > 0 else { continue }
            let tail = SIMD2(-cos(ship.angle), -sin(ship.angle))
            let offset = state.balls[ballIndex].position - ship.position
            let distance = simd_length(offset)
            guard distance > 0.000_001, distance < range else { continue }
            let along = simd_dot(offset / distance, tail)
            guard along > Self.exhaustWashCone else { continue }
            let falloff = 1 - distance / range
            let centring = (along - Self.exhaustWashCone) / (1 - Self.exhaustWashCone)
            // On the ring the wash is the motor's: as soft as the push.
            let motor = ship.thrustLevel * (arena.ring == nil ? 1 : configuration.ring.speed)
            let push = motor * configuration.exhaustWashStrength * falloff * centring
            state.balls[ballIndex].velocity += tail * (push * dt)
        }
    }

    /// The tractor beam is the cannon's opposite: a cone ahead of the nose
    /// that draws the ball in and bleeds its speed off, strongest at the
    /// nose and gone at `tractorRange`. Like the wash it is not a touch, so
    /// reeling a ball in never clears the bounce allowance -- the touch
    /// comes when it lands on the hull.
    /// The cosine of the cone's half-angle: higher is narrower. 0.92 is
    /// about 23 degrees (build 115; was 0.86, 31 degrees, which Ian found too
    /// wide): a long thin reach rather than a fan, aimed with the nose.
    /// Public so `ArenaScene` draws the volume that actually grabs.
    public static let tractorCone = 0.92

    /// Every impulse the beam hands the ball comes back out of the hull at
    /// this ratio, which is what makes the grab conserve momentum.
    static let tractorMassRatio = ballMass / shipMass

    /// A beam has the ball, for a slam dunk, once its grip is at least this
    /// -- a ball grazing the edge of the cone is not being held.
    static let slamGrip = 0.15
    /// How long after the beam lets go a bolt still counts as a slam: long
    /// enough to release and fire, short enough that the ball is still
    /// sitting where the beam left it.
    public static let slamWindow = 0.6
    /// A goal still counts as beamed in for this long after the grip lapses:
    /// the ball leaving the cone on its way through the face is still the
    /// beam's goal.
    public static let slamPullGrace = 0.1

    /// The pilot whose beam has this ball right now, or had it a moment ago.
    private func beamPuller(of ballIndex: Int) -> Seat? {
        guard state.balls.indices.contains(ballIndex), let hold = state.balls[ballIndex].beamHold else { return nil }
        let grace = UInt64((Self.slamPullGrace / configuration.stepDuration).rounded())
        return state.tick &- hold.tick <= grace ? hold.seat : nil
    }

    private mutating func applyTractorBeam(dt: Double, ballIndex: Int) {
        let range = configuration.tractorRange
        guard range > 0, configuration.tractorStrength > 0 else { return }
        // A locked ball answers to the lock alone; no beam pulls it, its own
        // included, or the pull and the drag would fight the weld.
        guard state.balls[ballIndex].beamLock == nil else { return }
        for seat in Seat.allCases {
            guard var ship = state.ships[seat], !ship.isDestroyed, ship.tractorActive else { continue }
            let nose = SIMD2(cos(ship.angle), sin(ship.angle))
            let offset = state.balls[ballIndex].position - ship.position
            let distance = simd_length(offset)
            guard distance > 0.000_001, distance < range else { continue }
            let toward = offset / distance
            let along = simd_dot(toward, nose)
            guard along > Self.tractorCone else { continue }
            let falloff = 1 - distance / range
            let centring = (along - Self.tractorCone) / (1 - Self.tractorCone)
            let grip = falloff * centring
            // Newton's third law. Whatever the beam puts into the ball it
            // takes out of the hull, scaled by the mass ratio: reeling a ball
            // in drags you toward it, and a heavy ball moves you more than a
            // light one would. The beam is no longer a free hand.
            let pull = toward * (configuration.tractorStrength * grip * dt)
            state.balls[ballIndex].velocity -= pull
            ship.velocity += pull * Self.tractorMassRatio
            // The grab damps the ball against the SHIP's frame, not the
            // world's, and hands the momentum it removes to the hull. A
            // caught ball settles into the pocket and flies with you instead
            // of being dragged toward a standstill. Against a ship that is
            // holding still this is exactly the old behaviour.
            let damp = min(1, configuration.tractorDrag * grip * dt)
            let bleed = (state.balls[ballIndex].velocity - ship.velocity) * damp
            state.balls[ballIndex].velocity -= bleed
            ship.velocity += bleed * Self.tractorMassRatio
            if grip >= Self.slamGrip {
                let held = state.balls[ballIndex].beamHold
                let fresh = held?.seat != seat || state.tick &- (held?.tick ?? 0) > 1
                if fresh {
                    defencePlays.append((ballIndex, seat, .beam))
                }
                let since = fresh ? state.tick : held?.since ?? state.tick
                state.balls[ballIndex].beamHold = BeamHold(seat: seat, tick: state.tick, since: since)
                // The time can come off the wire: anything not a sane number
                // of seconds never locks rather than trapping the conversion.
                let lockTime = configuration.beamLockTime
                if lockTime > 0, lockTime <= Self.longestBeamLock,
                   state.tick &- since >= UInt64((lockTime / configuration.stepDuration).rounded()),
                   lockedBall(of: seat) == nil {
                    // Held long enough: the ball welds on where it is, never
                    // closer than just off the nose.
                    let reach = (shipHitboxes[seat] ?? .shared).noseReach + state.balls[ballIndex].radius + 0.005
                    let bearing = remainder(atan2(toward.y, toward.x) - ship.angle, 2 * .pi)
                    state.balls[ballIndex].beamLock = BeamLock(
                        seat: seat,
                        length: max(distance, reach),
                        bearing: bearing,
                        spin: ship.angularVelocity
                    )
                    // The catch keeps the ball's run: the speed it was closing
                    // at turns into swing instead of dying against the weld.
                    // Momentum and the pair's energy are kept; the swing goes
                    // the way the stick is held, else the way the ball was
                    // already drifting across the line, else the side it sits.
                    let ball = state.balls[ballIndex]
                    let mass = Self.shipMass + Self.ballMass
                    let drift = (ship.velocity * Self.shipMass + ball.velocity * Self.ballMass) / mass
                    let relative = ball.velocity - ship.velocity
                    let across = SIMD2(-toward.y, toward.x)
                    let sideways = simd_dot(relative, across)
                    let stick = stickTorques[seat] ?? 0
                    let way: Double = stick != 0 ? (stick > 0 ? 1 : -1)
                        : abs(sideways) > 0.02 ? (sideways > 0 ? 1 : -1)
                        : bearing < 0 ? -1 : 1
                    let swing = across * (way * simd_length(relative))
                    ship.velocity = drift - swing * (Self.ballMass / mass)
                    state.balls[ballIndex].velocity = drift + swing * (Self.shipMass / mass)
                    state.ships[seat] = ship
                    return
                }
            }
            state.ships[seat] = ship
        }
    }

    /// The ball `seat`'s beam has locked on, if any. A beam holds one ball.
    private func lockedBall(of seat: Seat) -> Int? {
        state.balls.indices.first { state.balls[$0].beamLock?.seat == seat }
    }

    /// Every lock flies its hull and ball as one rigid body. Whatever each
    /// felt this step on its own -- thrust, gravity, drag -- is pooled: the
    /// pair keeps the linear momentum and the angular momentum about its
    /// centre of mass the two had between them, the distance snaps back to
    /// the locked length, and the turn rate is whatever that angular
    /// momentum comes to over the pair's moment of inertia. Thrust along the
    /// line pushes the pair; anything off the line spins it. Letting go of
    /// the beam (or a stun, which lets go for you) drops the lock, and both
    /// fly on at the speeds the spin left them, the hull still turning.
    private mutating func solveBeamLocks(effects: inout [SimulationEvent]) {
        for ballIndex in state.balls.indices {
            guard var lock = state.balls[ballIndex].beamLock else { continue }
            guard var ship = state.ships[lock.seat], !ship.isDestroyed, ship.tractorActive else {
                state.balls[ballIndex].beamLock = nil
                if var ship = state.ships[lock.seat] {
                    // The hull's share of the spin winds down like a knock.
                    ship.knockSpin = lock.spin
                    state.ships[lock.seat] = ship
                }
                continue
            }
            var ball = state.balls[ballIndex]
            let shipMass = Self.shipMass
            let ballMass = Self.ballMass
            let mass = shipMass + ballMass
            let hitbox = shipHitboxes[lock.seat] ?? .shared
            let shipInertia = Self.lockedHullInertia * shipMass * hitbox.reach * hitbox.reach
            // The ball's own turn counts too, as the solid ball the grip
            // treats it as: whatever it was spinning at the lock goes into
            // the pair, and from then on it turns with the hull.
            let ballInertia = Self.lockedBallInertia * ballMass * ball.radius * ball.radius
            let centre = (ship.position * shipMass + ball.position * ballMass) / mass
            let drift = (ship.velocity * shipMass + ball.velocity * ballMass) / mass
            func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }
            let angularMomentum = shipMass * cross(ship.position - centre, ship.velocity - drift)
                + ballMass * cross(ball.position - centre, ball.velocity - drift)
                + shipInertia * lock.spin
                + ballInertia * ball.spin
            let line = ball.position - ship.position
            let span = simd_length(line)
            let axis = span > 0.000_001
                ? line / span
                : SIMD2(cos(ship.angle + lock.bearing), sin(ship.angle + lock.bearing))
            let shipArm = -axis * (lock.length * ballMass / mass)
            let ballArm = axis * (lock.length * shipMass / mass)
            let inertia = shipInertia + ballInertia + shipMass * simd_length_squared(shipArm) + ballMass * simd_length_squared(ballArm)
            var spin = angularMomentum / inertia
            // The stick pumps the swing, up to twice the hull's own turn;
            // against the swing it brakes. Let go of the beam at the top of
            // it to whip the ball off.
            if let stick = stickTorques[lock.seat], stick != 0, configuration.beamSwing > 0 {
                let top = Self.beamSwingTopRate * configuration.torqueAcceleration
                let push = stick * Self.beamSwingAcceleration * configuration.beamSwing * configuration.stepDuration
                if push > 0, spin < top {
                    spin = min(top, spin + push)
                } else if push < 0, spin > -top {
                    spin = max(-top, spin + push)
                }
            }
            let from = ship.position
            ship.position = centre + shipArm
            ship.velocity = drift + SIMD2(-shipArm.y, shipArm.x) * spin
            ball.position = centre + ballArm
            ball.velocity = drift + SIMD2(-ballArm.y, ballArm.x) * spin
            ball.spin = spin
            // Snapped without a wrap, so a hull swung past half a turn never
            // jumps a whole one for anything that smooths its angle.
            ship.angle += remainder(atan2(axis.y, axis.x) - lock.bearing - ship.angle, 2 * .pi)
            ship.angularVelocity = spin
            lock.spin = spin
            // The weld moved the hull; the walls still have the last word.
            resolveArenaCollision(for: &ship, hitbox: hitbox, from: from, effects: &effects)
            ball.beamLock = lock
            // Still the beam's ball, for a slam dunk or a beam-pull goal.
            ball.beamHold = BeamHold(seat: lock.seat, tick: state.tick, since: ball.beamHold?.since)
            state.balls[ballIndex] = ball
            state.ships[lock.seat] = ship
        }
    }

    /// A hull's own moment of inertia as a share of mass times reach
    /// squared: a uniform disc the size of the hull.
    static let lockedHullInertia = 0.5
    /// A solid ball's moment of inertia as a share of mass times radius
    /// squared -- the 2/5 the contact grip's 2/7 roll assumes.
    static let lockedBallInertia = 0.4
    /// The longest hold the engine will honour; past it the beam never locks.
    static let longestBeamLock = 60.0
    /// Radians a second, each second, a full stick adds to a locked pair's
    /// swing at Beam swing 1.
    static let beamSwingAcceleration = 12.0
    /// A pumped swing tops out at this many times the hull's own turn rate.
    static let beamSwingTopRate = 2.0

    /// How hard `ship`'s beam holds whatever sits at `point`, and the unit
    /// direction from the ship out to it. Nil with the beam off, or outside
    /// its cone or range. The same grade the ball feels.
    private func tractorGrip(of ship: ShipState, at point: SIMD2<Double>) -> (grip: Double, toward: SIMD2<Double>)? {
        let range = configuration.tractorRange
        guard ship.tractorActive, !ship.isDestroyed, range > 0, configuration.tractorStrength > 0 else { return nil }
        let offset = point - ship.position
        let distance = simd_length(offset)
        guard distance > 0.000_001, distance < range else { return nil }
        let toward = offset / distance
        let along = simd_dot(toward, SIMD2(cos(ship.angle), sin(ship.angle)))
        guard along > Self.tractorCone else { return nil }
        return ((1 - distance / range) * (along - Self.tractorCone) / (1 - Self.tractorCone), toward)
    }

    /// Share of `tractorStrength` an enemy hull in the beam feels. Two hulls
    /// weigh the same, so the pull is split evenly: the target is drawn in
    /// and the puller is drawn out to meet it. Half the ball's pull at the
    /// nose is about half of full thrust -- strong up close, and a pilot
    /// who thrusts away still gets out.
    static let tractorShipPull = 0.5

    /// The beam reaches enemy ships the way it reaches the ball: it draws
    /// the hull toward the nose and damps the two ships' closing speed, and
    /// every bit of it comes back out of the puller. Never a teammate.
    private mutating func applyTractorToShips(dt: Double) {
        for seat in Seat.allCases {
            guard var puller = state.ships[seat], puller.tractorActive, !puller.isDestroyed else { continue }
            for target in Seat.allCases where rivals(target, seat) {
                guard var ship = state.ships[target], !ship.isDestroyed,
                      let hold = tractorGrip(of: puller, at: ship.position) else { continue }
                let pull = hold.toward * (configuration.tractorStrength * Self.tractorShipPull * hold.grip * dt)
                ship.velocity -= pull
                puller.velocity += pull
                let damp = min(1, configuration.tractorDrag * hold.grip * dt) / 2
                let bleed = (ship.velocity - puller.velocity) * damp
                ship.velocity -= bleed
                puller.velocity += bleed
                state.ships[target] = ship
            }
            state.ships[seat] = puller
        }
    }

    /// How fast, in radians a second at full grip, an enemy beam turns a
    /// bolt toward its nose. Bolts are massless and keep their speed: the
    /// beam only bends their line. Strong enough that a shot passing
    /// through the cone visibly hooks, and a shot down the beam is reeled
    /// onto the nose, where it is caught.
    static let tractorBoltTurn = 9.0

    private func bendBolt(_ bolt: inout BoltState, dt: Double) {
        for seat in Seat.allCases where isFreeForAll ? seat != bolt.seat : seat.team != bolt.owner {
            guard let ship = state.ships[seat], let hold = tractorGrip(of: ship, at: bolt.position) else { continue }
            let speed = simd_length(bolt.velocity)
            guard speed > 0.000_001 else { continue }
            let heading = bolt.velocity / speed
            let home = -hold.toward
            let off = atan2(heading.x * home.y - heading.y * home.x, simd_dot(heading, home))
            let limit = Self.tractorBoltTurn * hold.grip * dt
            let turn = min(limit, max(-limit, off))
            bolt.velocity = SIMD2(
                heading.x * cos(turn) - heading.y * sin(turn),
                heading.x * sin(turn) + heading.y * cos(turn)
            ) * speed
        }
    }

    /// What an enemy bolt does to a hull: a shove down the bolt's line, in
    /// world units a second, plus whatever `BoltHit` the host picked. No
    /// touch, no point. A ship holding the bolt in its own beam catches it
    /// instead: the bolt dies on the nose.
    static let boltShipKick = 0.45
    /// `BoltHit.stun`: how long the controls are dead, and how long after a
    /// stun starts before another one can land (stun plus a clear window).
    static let stunSeconds = 0.75
    static let stunGuardSeconds = 1.6
    /// `BoltHit.spin`: the yaw a hit on the very tip of the hull knocks in,
    /// radians a second, and how fast it bleeds away. The total turn is
    /// about kick x decay: ~40 degrees off the tip, half that dead centre.
    static let knockSpinKick = 5.0
    static let knockSpinDecay = 0.14

    private mutating func advanceBolts(
        previousShipPositions: [Seat: SIMD2<Double>],
        effects: inout [SimulationEvent]
    ) {
        guard !state.bolts.isEmpty else { return }
        let dt = configuration.stepDuration
        let field = arena.displaced(by: state.bumpers)
        var survivors: [BoltState] = []
        survivors.reserveCapacity(state.bolts.count)
        // Each ball takes at most one bolt a step, so a burst cannot land
        // three punches in a single tick.
        var struckBalls = Set<Int>()
        for var bolt in state.bolts {
            bendBolt(&bolt, dt: dt)
            let previous = bolt.position
            bolt.position += bolt.velocity * dt
            bolt.ticksRemaining -= 1

            // A bolt already overlapping the ball at the start of the step is
            // a hit at once: the ball moves too, so a bolt can finish one step
            // a hair outside it and start the next inside, where the sweep
            // alone would let it pass straight through. With two balls up the
            // bolt takes whichever it reaches first.
            var earliest: (ballIndex: Int, contact: Double)?
            for ballIndex in state.balls.indices where !struckBalls.contains(ballIndex) {
                let reach = state.balls[ballIndex].radius + BoltState.radius
                let contact: Double? = simd_length(previous - state.balls[ballIndex].position) <= reach
                    ? 0
                    : sweptCircleTime(
                        from: previous - state.balls[ballIndex].position,
                        to: bolt.position - state.balls[ballIndex].position,
                        center: .zero,
                        radius: reach
                    )
                if let contact, earliest == nil || contact < earliest!.contact {
                    earliest = (ballIndex, contact)
                }
            }
            // Enemy hulls stand in a bolt's way; its own side's do not. The
            // sweep runs in each ship's moving frame, like the ball's, so a
            // thin nose cannot slip between two steps.
            var shipHit: (seat: Seat, contact: Double)?
            for seat in Seat.allCases where isFreeForAll ? seat != bolt.seat : seat.team != bolt.owner {
                guard let ship = state.ships[seat], !ship.isDestroyed else { continue }
                let hitbox = shipHitboxes[seat] ?? .shared
                let axis = SIMD2(cos(ship.angle), sin(ship.angle))
                let left = SIMD2(-axis.y, axis.x)
                func local(_ offset: SIMD2<Double>) -> SIMD2<Double> {
                    SIMD2(simd_dot(offset, axis), simd_dot(offset, left))
                }
                let reach = BoltState.radius + ShipHitbox.skin
                let start = local(previous - (previousShipPositions[seat] ?? ship.position))
                let contact: Double? = hitbox.contains(start) || hitbox.distance(from: start) <= reach
                    ? 0
                    : hitbox.sweepTime(from: start, to: local(bolt.position - ship.position), radius: reach)
                if let contact, shipHit == nil || contact < shipHit!.contact {
                    shipHit = (seat, contact)
                }
            }
            if let shipHit, earliest.map({ shipHit.contact <= $0.contact }) ?? true,
               var ship = state.ships[shipHit.seat] {
                let touch = previous + (bolt.position - previous) * shipHit.contact
                if tractorGrip(of: ship, at: previous) != nil || ringInOwnZone(ship.position, seat: shipHit.seat) {
                    effects.append(.collisionEffect(position: touch, intensity: configuration.boltPunch))
                } else {
                    let speed = simd_length(bolt.velocity)
                    let travel = speed > 0.000_001 ? bolt.velocity / speed : SIMD2(0, 1)
                    ship.velocity += travel * Self.boltShipKick
                    switch configuration.boltHit {
                    case .shove:
                        break
                    case .stun:
                        if ship.stunGuardTicks == 0 {
                            ship.stunTicks = UInt64((Self.stunSeconds / dt).rounded())
                            ship.stunGuardTicks = UInt64((Self.stunGuardSeconds / dt).rounded())
                        }
                    case .spin:
                        // Turned the way the bolt's line pushes the point it
                        // struck: a hit forward of the middle swings the nose
                        // away from the shooter's side. Dead centre still
                        // turns, half as hard, the way the owner's side
                        // decides -- never a coin toss, or two boards differ.
                        let arm = touch - ship.position
                        let cross = arm.x * travel.y - arm.y * travel.x
                        let tip = max(0.000_001, ShipHitbox.shared.reach)
                        let lever = min(1, abs(cross) / tip)
                        let sign = abs(cross) > 0.000_001 ? (cross > 0 ? 1.0 : -1.0) : (bolt.owner == .cyan ? 1.0 : -1.0)
                        ship.knockSpin = sign * Self.knockSpinKick * (0.5 + 0.5 * lever)
                    }
                    state.ships[shipHit.seat] = ship
                    effects.append(.shipZapped(seat: shipHit.seat, position: touch))
                    playsThisStep.append(.zap(bolt.seat, victim: shipHit.seat))
                }
                continue
            }
            if let earliest {
                let ballIndex = earliest.ballIndex
                let contact = earliest.contact
                struckBalls.insert(ballIndex)
                let speed = simd_length(bolt.velocity)
                let travel = speed > 0.000_001 ? bolt.velocity / speed : SIMD2(0, 1)
                // Off the centre the hit glances: the ball is knocked partway
                // round from the bolt's line toward the line from where the
                // bolt touched it through its middle. Clip it underneath and it
                // lifts; clip the top and it is driven down.
                let touch = previous + (bolt.position - previous) * contact
                let throughCentre = simd_normalize(state.balls[ballIndex].position - touch)
                let direction = simd_normalize(
                    travel * (1 - BoltState.glance) + throughCentre * BoltState.glance
                )
                state.balls[ballIndex].velocity += direction * configuration.boltPunch
                // The same clip that turns the ball sets it spinning: the bolt
                // drags the side it touched along its own line. Underneath is
                // backspin, which holds the shot up; over the top is topspin,
                // which dips it. Dead centre there is nothing to drag, and a
                // new hit replaces whatever spin was already on it.
                let lever = (touch - state.balls[ballIndex].position) / (state.balls[ballIndex].radius + BoltState.radius)
                state.balls[ballIndex].spin = BoltState.spinKick * (lever.x * travel.y - lever.y * travel.x)
                // A bolt plays the ball but is not a touch: it neither spends
                // one nor refreshes the bounce allowance, or a cannon on your
                // own half could keep a rally alive forever. It still marks who
                // played the ball last.
                state.lastBallToucher = bolt.owner
                let windowTicks = UInt64((Self.slamWindow / configuration.stepDuration).rounded())
                let slam = state.balls[ballIndex].beamHold.map {
                    (isFreeForAll ? $0.seat == bolt.seat : $0.seat.team == bolt.owner)
                        && state.tick &- $0.tick <= windowTicks
                } ?? false
                state.balls[ballIndex].lastPlay = BallPlay(seat: bolt.seat, kind: slam ? .slamDunk : .bolt)
                playsThisStep.append(.boltHit(bolt.seat, slam: slam))
                defencePlays.append((ballIndex, bolt.seat, .bolt))
                effects.append(.collisionEffect(
                    position: state.balls[ballIndex].position,
                    intensity: configuration.boltPunch
                ))
                continue
            }

            let outside = arena.ring.map {
                let distance = simd_length(bolt.position)
                return distance > $0.rimRadius
            } ?? (abs(bolt.position.x) > arena.halfWidth
                || bolt.position.y < arena.floorY
                || bolt.position.y > arena.ceilingY)
            // Whatever stands in the middle of this court eats a bolt: the
            // roof hump, the standing net, or a rim post.
            let struckMiddle = arena.humpContact(
                position: bolt.position,
                radius: BoltState.radius
            ) != nil || arena.floorNetContact(
                position: bolt.position,
                radius: BoltState.radius,
                preferredSide: bolt.velocity.x
            ) != nil || arena.hoopRimContact(
                position: bolt.position,
                radius: BoltState.radius
            ) != nil
            // A bolt into a peg knocks it along its track before it dies:
            // off centre it glances, like the ball, so a shot clipping the
            // underside lifts the peg and one over the top drives it down.
            if let peg = field.obstacleContact(position: bolt.position, radius: BoltState.radius) {
                if arena.obstacles[peg.index].isSprung, peg.index < state.bumpers.count {
                    let speed = simd_length(bolt.velocity)
                    let travel = speed > 0.000_001 ? bolt.velocity / speed : SIMD2(0, 1)
                    let direction = travel * (1 - BoltState.glance) - peg.normal * BoltState.glance
                    state.bumpers[peg.index].velocity.y += direction.y * Self.bumperBoltKick
                    clampTravel(&state.bumpers[peg.index])
                    effects.append(.collisionEffect(position: bolt.position, intensity: Self.bumperBoltKick))
                }
                continue
            }
            if bolt.ticksRemaining == 0 || outside || struckMiddle { continue }
            survivors.append(bolt)
        }
        state.bolts = survivors
    }

    /// Two balls up meet each other like any other surface: an equal-mass
    /// knock with the ball's own bounce, and each grips the other so a
    /// glancing clash leaves both turning.
    private mutating func resolveBallBallCollisions(effects: inout [SimulationEvent]) {
        guard state.balls.count > 1 else { return }
        for first in state.balls.indices {
            for second in state.balls.indices where second > first {
                let offset = state.balls[second].position - state.balls[first].position
                let distance = simd_length(offset)
                let reach = state.balls[first].radius + state.balls[second].radius
                guard distance < reach else { continue }
                let normal = distance > 0.000_001 ? offset / distance : SIMD2(1, 0)
                // Push them apart evenly so neither is left inside the other.
                let overlap = reach - distance
                state.balls[first].position -= normal * (overlap / 2)
                state.balls[second].position += normal * (overlap / 2)
                let relative = state.balls[second].velocity - state.balls[first].velocity
                let closing = simd_dot(relative, normal)
                guard closing < 0 else { continue }
                let impulse = -(1 + Self.ballRestitution) * closing / 2
                let incomingFirst = state.balls[first].velocity
                let incomingSecond = state.balls[second].velocity
                state.balls[first].velocity -= normal * impulse
                state.balls[second].velocity += normal * impulse
                grip(-normal, from: incomingFirst, ballIndex: first)
                grip(normal, from: incomingSecond, ballIndex: second)
                if abs(closing) > Self.effectImpactSpeed {
                    effects.append(.collisionEffect(
                        position: (state.balls[first].position + state.balls[second].position) / 2,
                        intensity: abs(closing)
                    ))
                }
            }
        }
    }

    /// Slides every peg along its track, pulled by any beam on it, and
    /// lets it glide to a stop. Nothing brings it home: it stays where it
    /// was left until something moves it again.
    private mutating func advanceBumpers(dt: Double) {
        let sprung = arena.obstacles.contains { $0.isSprung }
        // A board rebuilt from a snapshot, or a court swapped under it, may
        // not have one entry per obstacle yet.
        if state.bumpers.count != (sprung ? arena.obstacles.count : 0) { seatBumpers() }
        guard sprung else { return }
        for index in state.bumpers.indices where arena.obstacles[index].isSprung {
            var bumper = state.bumpers[index]
            bumper.velocity.y += tractorPull(onPegAt: arena.obstacles[index].start + bumper.offset, dt: dt)
            bumper.velocity.y -= bumper.velocity.y * min(1, Self.bumperDrag * dt)
            let stop = Self.bumperFriction * dt
            bumper.velocity.y = abs(bumper.velocity.y) <= stop ? 0 : bumper.velocity.y - stop * (bumper.velocity.y > 0 ? 1 : -1)
            bumper.offset.y += bumper.velocity.y * dt
            clampTravel(&bumper)
            state.bumpers[index] = bumper
        }
    }

    /// Every beam that has a peg in its cone hauls it along the track toward
    /// the nose, graded exactly like the ball's grab. The hull takes back
    /// only what a ball grab would give it: the peg is on a rod, and a beam
    /// that yanked the ship across the court at every peg would be no fun.
    private mutating func tractorPull(onPegAt centre: SIMD2<Double>, dt: Double) -> Double {
        var pull = 0.0
        let range = configuration.tractorRange
        guard range > 0, configuration.tractorStrength > 0, configuration.pegPull > 0 else { return pull }
        for seat in Seat.allCases {
            guard var ship = state.ships[seat], !ship.isDestroyed, ship.tractorActive else { continue }
            let offset = centre - ship.position
            let distance = simd_length(offset)
            guard distance > 0.000_001, distance < range else { continue }
            let toward = offset / distance
            let along = simd_dot(toward, SIMD2(cos(ship.angle), sin(ship.angle)))
            guard along > Self.tractorCone else { continue }
            let grip = (1 - distance / range) * (along - Self.tractorCone) / (1 - Self.tractorCone)
            let tug = configuration.tractorStrength * grip * dt
            pull -= toward.y * (tug * Self.bumperTractorGain * configuration.pegPull)
            ship.velocity += toward * (tug * Self.tractorMassRatio)
            state.ships[seat] = ship
        }
        return pull
    }

    /// Holds a peg on its track: no sideways give at all, and a hard stop at
    /// each end.
    private func clampTravel(_ bumper: inout BumperState) {
        let travel = arena.bumperTravel
        bumper.offset.x = 0
        bumper.velocity.x = 0
        if bumper.offset.y > travel {
            bumper.offset.y = travel
            bumper.velocity.y = min(0, bumper.velocity.y)
        } else if bumper.offset.y < -travel {
            bumper.offset.y = -travel
            bumper.velocity.y = max(0, bumper.velocity.y)
        }
    }

    /// A hull meets a peg as two bodies, except the peg only gives along its
    /// track: the overlap and the knock are shared by weight in that one
    /// direction, so a ship driving up or down into a peg shoves it along,
    /// and a ship flying square into its side meets a post. Once the peg is
    /// at the end of its track it stands like a wall.
    private mutating func resolveShipBumperCollisions(effects: inout [SimulationEvent]) {
        guard !state.bumpers.isEmpty else { return }
        for seat in Seat.allCases {
            guard var ship = state.ships[seat], !ship.isDestroyed else { continue }
            let reach = (shipHitboxes[seat] ?? .shared).reach
            for index in state.bumpers.indices where arena.obstacles[index].isSprung {
                var bumper = state.bumpers[index]
                let peg = arena.obstacles[index].shifted(by: bumper.offset)
                let away = ship.position - peg.closestPoint(to: ship.position)
                let distance = simd_length(away)
                let depth = reach + peg.radius - distance
                guard depth > 0 else { continue }
                let normal = distance > 1e-9 ? away / distance : SIMD2(0, 1)
                // The peg's give along this normal: only the part of it that
                // lies along the track.
                let shipGive = 1 / Self.shipMass
                let pegGive = normal.y * normal.y / Self.bumperMass
                let share = depth / (shipGive + pegGive)
                ship.position += normal * (share * shipGive)
                bumper.offset.y -= normal.y * share / Self.bumperMass
                let closing = simd_dot(ship.velocity - bumper.velocity, normal)
                if closing < 0 {
                    let impulse = -(1 + Self.shipBumperRestitution) * closing / (shipGive + pegGive)
                    ship.velocity += normal * (impulse / Self.shipMass)
                    bumper.velocity.y -= normal.y * impulse / Self.bumperMass
                    if closing < -Self.effectImpactSpeed {
                        effects.append(.collisionEffect(position: ship.position, intensity: abs(closing)))
                    }
                }
                clampTravel(&bumper)
                // A peg already at its stop gives no more: whatever overlap
                // is left is the hull's to lose.
                let stopped = arena.obstacles[index].shifted(by: bumper.offset)
                let left = ship.position - stopped.closestPoint(to: ship.position)
                let gap = simd_length(left)
                if gap < reach + stopped.radius {
                    let out = gap > 1e-9 ? left / gap : normal
                    ship.position += out * (reach + stopped.radius - gap)
                    let inward = simd_dot(ship.velocity - bumper.velocity, out)
                    if inward < 0 { ship.velocity -= out * inward }
                }
                state.bumpers[index] = bumper
            }
            state.ships[seat] = ship
        }
    }

    /// The ball off a peg. The bounce is on the ball's speed relative to the
    /// peg, so a peg sliding along its track into a ball kicks it -- the
    /// foosball goalie -- and the ball knocks the peg along a little in
    /// return.
    private mutating func resolveBallBumperCollision(ballIndex: Int, previousPosition: SIMD2<Double>) {
        guard !state.bumpers.isEmpty else { return }
        guard let contact = arena.displaced(by: state.bumpers).obstacleContact(
            from: previousPosition,
            to: state.balls[ballIndex].position,
            radius: state.balls[ballIndex].radius,
            where: \.isSprung
        ) else { return }
        var bumper = state.bumpers[contact.index]
        state.balls[ballIndex].position = contact.position
        let closing = simd_dot(state.balls[ballIndex].velocity - bumper.velocity, contact.normal)
        guard closing < 0 else { return }
        let pegGive = contact.normal.y * contact.normal.y / Self.bumperMass
        let impulse = -(1 + Self.ballRestitution) * closing / (1 / Self.ballMass + pegGive)
        let incoming = state.balls[ballIndex].velocity
        state.balls[ballIndex].velocity += contact.normal * (impulse / Self.ballMass)
        bumper.velocity.y -= contact.normal.y * impulse / Self.bumperMass
        clampTravel(&bumper)
        state.bumpers[contact.index] = bumper
        grip(contact.normal, from: incoming, ballIndex: ballIndex)
    }

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
        // Each hull is a circle out to its farthest drawn point, so two ships
        // bump where their art meets rather than a hull-length apart.
        let radius = (shipHitboxes[firstSeat] ?? .shared).reach
            + (shipHitboxes[secondSeat] ?? .shared).reach
        guard let hitTime = sweptCircleTime(
            from: relativeStart,
            to: relativeEnd,
            center: .zero,
            radius: radius
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
        hitbox: ShipHitbox,
        from previousPosition: SIMD2<Double>,
        effects: inout [SimulationEvent]
    ) {
        if let ring = arena.ring {
            resolveRingCollision(for: &ship, hitbox: hitbox, from: previousPosition, ring: ring, effects: &effects)
            return
        }
        // Curved parts meet the hull's bounding circle; the flat walls meet
        // whatever part of the drawn hull points at them.
        let radius = hitbox.reach

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

        // The standing net is solid for hulls too -- unlike the portal goal,
        // which you are meant to be able to fly into and defend.
        if let wall = arena.floorNetContact(
            from: previousPosition,
            to: ship.position,
            radius: radius
        ) {
            ship.position = wall.position
            let inwardSpeed = simd_dot(ship.velocity, wall.normal)
            if inwardSpeed < 0 {
                ship.velocity -= wall.normal * ((1 + 0.12) * inwardSpeed)
                if inwardSpeed < -Self.effectImpactSpeed {
                    effects.append(.collisionEffect(
                        position: ship.position,
                        intensity: abs(inwardSpeed)
                    ))
                }
            }
        }

        // The layout's walls and fixed pegs are solid to hulls, the same
        // give as the hump. Sprung pegs give way: see
        // `resolveShipBumperCollisions`.
        if let obstacle = arena.obstacleContact(
            from: previousPosition,
            to: ship.position,
            radius: radius,
            where: { !$0.isSprung }
        ) {
            ship.position = obstacle.position
            let inwardSpeed = simd_dot(ship.velocity, obstacle.normal)
            if inwardSpeed < 0 {
                ship.velocity -= obstacle.normal * ((1 + 0.12) * inwardSpeed)
            }
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

        let below = hitbox.extent(along: SIMD2(0, -1), angle: ship.angle)
        let above = hitbox.extent(along: SIMD2(0, 1), angle: ship.angle)
        let left = hitbox.extent(along: SIMD2(-1, 0), angle: ship.angle)
        let right = hitbox.extent(along: SIMD2(1, 0), angle: ship.angle)
        if ship.position.y - below <= arena.floorY {
            ship.position.y = arena.floorY + below
            ship.velocity.y = max(0, -ship.velocity.y * 0.12)
        }
        if ship.position.y + above >= arena.ceilingY {
            ship.position.y = arena.ceilingY - above
            ship.velocity.y = min(0, -ship.velocity.y * 0.3)
        }
        if ship.position.x - left <= -arena.halfWidth {
            ship.position.x = -arena.halfWidth + left
            ship.velocity.x = max(0, -ship.velocity.x * 0.3)
        }
        if ship.position.x + right >= arena.halfWidth {
            ship.position.x = arena.halfWidth - right
            ship.velocity.x = min(0, -ship.velocity.x * 0.3)
        }
    }

    /// The ring's rim meets a hull like the duel's floor, dead: whatever part
    /// of the drawn hull points at it. The fins are solid; a live net is not.
    private func resolveRingCollision(
        for ship: inout ShipState,
        hitbox: ShipHitbox,
        from previousPosition: SIMD2<Double>,
        ring: RingField,
        effects: inout [SimulationEvent]
    ) {
        // A hull meets every net shut, live or not: it can fly up to a
        // mouth and keep it, but never park behind a goal line.
        var solid = arena
        solid.obstacles += ring.closedNets { _ in true }
        if let wall = solid.obstacleContact(from: previousPosition, to: ship.position, radius: hitbox.reach) {
            ship.position = wall.position
            let inwardSpeed = simd_dot(ship.velocity, wall.normal)
            if inwardSpeed < 0 {
                ship.velocity -= wall.normal * ((1 + 0.12) * inwardSpeed)
            }
            if inwardSpeed < -Self.effectImpactSpeed {
                effects.append(.collisionEffect(position: ship.position, intensity: abs(inwardSpeed)))
            }
        }
        let out = ring.outward(at: ship.position)
        let towardRim = hitbox.extent(along: out, angle: ship.angle)
        if simd_length(ship.position) + towardRim >= ring.rimRadius {
            ship.position = out * (ring.rimRadius - towardRim)
            let speed = simd_dot(ship.velocity, out)
            if speed > 0 { ship.velocity -= out * ((1 + 0.12) * speed) }
        }
    }

    /// The ball on the ring: the nets' frames, the bump flanks, the
    /// centre bumper and the rim. The rim opens through a live mouth, so
    /// the ball can leave the circle into the pocket. A net whose pilot is
    /// out has a bar across its mouth and the rim stays shut there. A ball
    /// whose centre crosses a net's goal line -- all of it over -- is in.
    ///
    /// A bump flank meets the rim and a post, and a net's frame has inside corners,
    /// so a ball can be touching two surfaces at once; resolving one can push
    /// it into the other. A few passes settle it.
    private mutating func resolveRingBallCollision(
        ballIndex: Int,
        previousPosition: SIMD2<Double>,
        ring: RingField
    ) {
        var solid = arena
        let field = state.freeForAll
        solid.obstacles = ring.ballWalls { field?.isSolid(goal: $0) ?? false }
        let r = state.balls[ballIndex].radius
        var from = previousPosition
        for _ in 0 ..< 3 {
            var touched = false
            if let wall = solid.obstacleContact(from: from, to: state.balls[ballIndex].position, radius: r) {
                touched = true
                state.balls[ballIndex].position = wall.position
                let inwardSpeed = simd_dot(state.balls[ballIndex].velocity, wall.normal)
                if inwardSpeed < 0 {
                    let incoming = state.balls[ballIndex].velocity
                    state.balls[ballIndex].velocity -= wall.normal * ((1 + Self.ballRestitution) * inwardSpeed)
                    grip(wall.normal, from: incoming, ballIndex: ballIndex)
                }
            }
            let out = ring.outward(at: state.balls[ballIndex].position)
            let openMouth = ring.admitsThroughRim(state.balls[ballIndex].position) { !(field?.isSolid(goal: $0) ?? true) }
            if !openMouth, simd_length(state.balls[ballIndex].position) + r >= ring.rimRadius {
                touched = true
                state.balls[ballIndex].position = out * (ring.rimRadius - r)
                let outwardSpeed = simd_dot(state.balls[ballIndex].velocity, out)
                if outwardSpeed > 0 {
                    let incoming = state.balls[ballIndex].velocity
                    state.balls[ballIndex].velocity -= out * ((1 + Self.floorRestitution) * outwardSpeed)
                    grip(-out, from: incoming, ballIndex: ballIndex)
                }
            }
            if !touched { break }
            from = state.balls[ballIndex].position
        }

        // A live net's frame is open to the ball; only crossing the goal
        // line coming back in from the mouth counts.
        if let goal = ring.goalCrossing(from: previousPosition, to: state.balls[ballIndex].position),
           !(field?.isSolid(goal: goal) ?? false) {
            freeForAllGoalsThisStep[ballIndex] = goal
        }
    }

    private mutating func resolveBallCollision(
        ballIndex: Int,
        previousPosition: SIMD2<Double>,
        contacts: inout [RuleContact]
    ) {
        if let ring = arena.ring {
            resolveRingBallCollision(ballIndex: ballIndex, previousPosition: previousPosition, ring: ring)
            return
        }
        let r = state.balls[ballIndex].radius
        var struckNet = false

        // The floor-mounted net: one solid slab standing up out of the middle
        // of the court, capped with a half-round. Nothing goes through it, so
        // there is no scoring here at all -- it is simply in the way, and the
        // only route to the other half is over the top.
        if let wall = arena.floorNetContact(
            from: previousPosition,
            to: state.balls[ballIndex].position,
            radius: r
        ) {
            state.balls[ballIndex].position = wall.position
            let inwardSpeed = simd_dot(state.balls[ballIndex].velocity, wall.normal)
            if inwardSpeed < 0 {
                let incoming = state.balls[ballIndex].velocity
                state.balls[ballIndex].velocity -= wall.normal * ((1 + Self.ballRestitution) * inwardSpeed)
                grip(wall.normal, from: incoming, ballIndex: ballIndex)
            }
            struckNet = true
        }

        // The hoop. The bucket is judged before the rim, because a ball that
        // dropped cleanly through the window never touched a post -- and a
        // ball that clipped one on the way in still counts, same as the real
        // game.
        if arena.hoopScored(from: previousPosition, to: state.balls[ballIndex].position) {
            contacts.append(.ballEnteredHoop)
        }
        if let rim = arena.hoopRimContact(
            from: previousPosition,
            to: state.balls[ballIndex].position,
            radius: r
        ) {
            state.balls[ballIndex].position = rim.position
            let inwardSpeed = simd_dot(state.balls[ballIndex].velocity, rim.normal)
            if inwardSpeed < 0 {
                let incoming = state.balls[ballIndex].velocity
                state.balls[ballIndex].velocity -= rim.normal * ((1 + Self.ballRestitution) * inwardSpeed)
                grip(rim.normal, from: incoming, ballIndex: ballIndex)
            }
        }

        // The lip is the bottom bar of the goal, and from underneath it is
        // solid. A ball driven up into it is stopped there -- it must not be
        // handed the goal just because its one-tick sweep carried it past the
        // face on the far side of a ledge it never got through. Seen from on
        // top the lip is still the funnel it always was, so that contact is
        // left where it has always been: after the goal, further down.
        var blockedByLip = false
        if let lip = arena.lipContact(
            from: previousPosition,
            to: state.balls[ballIndex].position,
            radius: r
        ), lip.normal.y < 0 {
            let inwardSpeed = simd_dot(state.balls[ballIndex].velocity, lip.normal)
            if inwardSpeed < 0 {
                state.balls[ballIndex].position = lip.position
                let incoming = state.balls[ballIndex].velocity
                state.balls[ballIndex].velocity -= lip.normal * ((1 + 0.55) * inwardSpeed)
                grip(lip.normal, from: incoming, ballIndex: ballIndex)
                blockedByLip = true
            }
        }

        // Cap first: the rounded bottom of the net is hard and neutral, so
        // clipping it from below is a rebound rather than a score. Only the two
        // faces above it are the portal, and a ball that reaches one is gone --
        // whoever drove it in takes the point.
        if arena.netStyle == .roofPortal, let capHit = sweptNetCapHit(
            ballIndex: ballIndex,
            from: previousPosition,
            to: state.balls[ballIndex].position,
            radius: r,
            postCenterX: arena.goalCentre(nearest: previousPosition.x)
        ) {
            state.balls[ballIndex].position = capHit.position
            let inwardSpeed = simd_dot(state.balls[ballIndex].velocity, capHit.normal)
            if inwardSpeed < 0 {
                let incoming = state.balls[ballIndex].velocity
                state.balls[ballIndex].velocity -= capHit.normal * (2 * inwardSpeed)
                grip(capHit.normal, from: incoming, ballIndex: ballIndex)
            }
            struckNet = true
        } else if arena.netStyle == .roofPortal, let netHit = sweptNetHit(
            ballIndex: ballIndex,
            from: previousPosition,
            to: state.balls[ballIndex].position,
            radius: r,
            postCenterX: arena.goalCentre(nearest: previousPosition.x)
        ) {
            let goal = arena.goalIndex(nearest: previousPosition.x)
            // A knocked-out pilot's goal is closed: the mouth is as solid as
            // the collar above it.
            let closed = state.freeForAll?.isSolid(goal: goal) ?? false
            if netHit.crossedFace, !blockedByLip, !closed, netHit.position.y <= arena.portalMouthTopY,
               isFreeForAll {
                state.balls[ballIndex].position = netHit.position
                freeForAllGoalsThisStep[ballIndex] = goal
                return
            }
            if netHit.crossedFace, !blockedByLip, !closed, netHit.position.y <= arena.portalMouthTopY {
                state.balls[ballIndex].position = netHit.position
                // The face on your half is the one you defend.
                let defending = state.team(onHalfAt: netHit.fromLeft ? -1 : 1)
                contacts.append(.ballEnteredGoal(defending: defending))
                goalsThisStep[ballIndex] = defending
                return
            }
            if netHit.position.y > arena.portalMouthTopY || (closed && netHit.crossedFace) {
                // Above the mouth the slab is a solid collar hanging from the
                // hump. A ball that has ridden the roof down the slope arrives
                // here, and it bounces off rather than sneaking in over the top.
                state.balls[ballIndex].position = netHit.position
                let normal = SIMD2(netHit.fromLeft ? -1.0 : 1.0, 0)
                let inwardSpeed = simd_dot(state.balls[ballIndex].velocity, normal)
                if inwardSpeed < 0 {
                    let incoming = state.balls[ballIndex].velocity
                    state.balls[ballIndex].velocity -= normal * ((1 + Self.ballRestitution) * inwardSpeed)
                    grip(normal, from: incoming, ballIndex: ballIndex)
                }
                struckNet = true
            }
            // Otherwise the ball is inside the open mouth without having been
            // driven at either face. The mouth is a window, so it falls back
            // out and the rally goes on.
        }

        if !struckNet, previousPosition.x.sign != state.balls[ballIndex].position.x.sign {
            contacts.append(.ballCrossedCenter(into: state.team(onHalfAt: state.balls[ballIndex].position.x)))
        }

        // The lips are the one soft surface in the arena: a ball that lands
        // on one is meant to settle and roll down into the mouth, not spring
        // back off. They never count as a bounce -- they are part of the goal.
        if !blockedByLip, let lip = arena.lipContact(
            from: previousPosition,
            to: state.balls[ballIndex].position,
            radius: r
        ) {
            state.balls[ballIndex].position = lip.position
            let inwardSpeed = simd_dot(state.balls[ballIndex].velocity, lip.normal)
            if inwardSpeed < 0 {
                let incoming = state.balls[ballIndex].velocity
                state.balls[ballIndex].velocity -= lip.normal * ((1 + 0.55) * inwardSpeed)
                grip(lip.normal, from: incoming, ballIndex: ballIndex)
            }
        }

        // The hump and the corner arcs run before the flat clamps so that where
        // one of them is in play it, not the wall, sets the final position --
        // and so the floor clamp cannot double-count a touch the arc has
        // already reported.
        var floorRegistered = false
        if let hump = arena.humpContact(
            from: previousPosition,
            to: state.balls[ballIndex].position,
            radius: r
        ) {
            state.balls[ballIndex].position = hump.position
            let inwardSpeed = simd_dot(state.balls[ballIndex].velocity, hump.normal)
            if inwardSpeed < 0 {
                let incoming = state.balls[ballIndex].velocity
                state.balls[ballIndex].velocity -= hump.normal * ((1 + Self.ballRestitution) * inwardSpeed)
                grip(hump.normal, from: incoming, ballIndex: ballIndex)
            }
            // Never a floor contact: the hump is a structure hanging from the
            // roof, not the ground. The corners register because they *are*
            // the floor curving up at the ends of the court.
        }

        resolveBallBumperCollision(ballIndex: ballIndex, previousPosition: previousPosition)

        // The layout's cuts and fixed pegs. A cut at the floor is floor, like
        // the corner arcs; anything standing in the court is just a surface.
        if let obstacle = arena.obstacleContact(
            from: previousPosition,
            to: state.balls[ballIndex].position,
            radius: r,
            where: { !$0.isSprung }
        ) {
            state.balls[ballIndex].position = obstacle.position
            let inwardSpeed = simd_dot(state.balls[ballIndex].velocity, obstacle.normal)
            if inwardSpeed < 0 {
                let incoming = state.balls[ballIndex].velocity
                state.balls[ballIndex].velocity -= obstacle.normal * ((1 + Self.ballRestitution) * inwardSpeed)
                grip(obstacle.normal, from: incoming, ballIndex: ballIndex)
            }
            if obstacle.isGround, obstacle.normal.y > 0.5, !floorRegistered {
                floorRegistered = true
                contacts.append(.ballTouchedFloor(side: state.team(onHalfAt: state.balls[ballIndex].position.x)))
            }
        }

        if let corner = arena.cornerContact(position: state.balls[ballIndex].position, radius: r) {
            state.balls[ballIndex].position = corner.position
            let inwardSpeed = simd_dot(state.balls[ballIndex].velocity, corner.normal)
            if inwardSpeed < 0 {
                let incoming = state.balls[ballIndex].velocity
                state.balls[ballIndex].velocity -= corner.normal * ((1 + Self.ballRestitution) * inwardSpeed)
                grip(corner.normal, from: incoming, ballIndex: ballIndex)
            }
            if corner.normal.y > 0.5, !floorRegistered {
                floorRegistered = true
                contacts.append(.ballTouchedFloor(side: state.team(onHalfAt: state.balls[ballIndex].position.x)))
            }
        }

        if state.balls[ballIndex].position.y - r <= arena.floorY {
            let incoming = state.balls[ballIndex].velocity
            state.balls[ballIndex].position.y = arena.floorY + r
            state.balls[ballIndex].velocity.y = abs(state.balls[ballIndex].velocity.y) * Self.floorRestitution
            grip(SIMD2(0, 1), from: incoming, ballIndex: ballIndex)
            if !floorRegistered {
                contacts.append(.ballTouchedFloor(side: state.team(onHalfAt: state.balls[ballIndex].position.x)))
                floorRegistered = true
            }
        }
        // Nothing on the hoop court ends a rally except the rim, so a ball
        // that runs out of bounce just lies there and the match never
        // finishes. It comes off the deck live instead.
        if floorRegistered, arena.hoop != nil {
            state.balls[ballIndex].velocity.y = max(state.balls[ballIndex].velocity.y, Self.hoopDribbleSpeed)
        }
        if state.balls[ballIndex].position.y + r >= arena.ceilingY {
            let incoming = state.balls[ballIndex].velocity
            state.balls[ballIndex].position.y = arena.ceilingY - r
            state.balls[ballIndex].velocity.y = -abs(state.balls[ballIndex].velocity.y) * Self.ballRestitution
            grip(SIMD2(0, -1), from: incoming, ballIndex: ballIndex)
        }
        if state.balls[ballIndex].position.x - r <= -arena.halfWidth {
            let incoming = state.balls[ballIndex].velocity
            state.balls[ballIndex].position.x = -arena.halfWidth + r
            state.balls[ballIndex].velocity.x = abs(state.balls[ballIndex].velocity.x) * Self.ballRestitution
            grip(SIMD2(1, 0), from: incoming, ballIndex: ballIndex)
        }
        if state.balls[ballIndex].position.x + r >= arena.halfWidth {
            let incoming = state.balls[ballIndex].velocity
            state.balls[ballIndex].position.x = arena.halfWidth - r
            state.balls[ballIndex].velocity.x = -abs(state.balls[ballIndex].velocity.x) * Self.ballRestitution
            grip(SIMD2(-1, 0), from: incoming, ballIndex: ballIndex)
        }
    }

    /// The surface with outward `normal` has just pushed the ball off
    /// `incoming`; let it grip, trading the ball's slide for spin.
    private mutating func grip(
        _ normal: SIMD2<Double>,
        from incoming: SIMD2<Double>,
        ballIndex: Int
    ) {
        (state.balls[ballIndex].velocity, state.balls[ballIndex].spin) = BallState.gripped(
            state.balls[ballIndex].velocity,
            from: incoming,
            spin: state.balls[ballIndex].spin,
            radius: state.balls[ballIndex].radius,
            normal: normal
        )
    }

    private func sweptNetCapHit(
        ballIndex: Int,
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
        guard simd_dot(state.balls[ballIndex].velocity, normal) < 0 else { return nil }
        return (center + normal * combinedRadius, normal)
    }

    private func sweptNetHit(
        ballIndex: Int,
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
        // The face stops where the cap begins. Below netBottomY the edge of the
        // slab is the rounded cap, which the caller has already swept, so a
        // crossing down here is in the open pocket beside the cap and under the
        // root of the lip -- it has touched nothing, and it is not the mouth.
        guard hitY >= arena.netBottomY else { return nil }
        return (SIMD2(boundary, hitY), fromLeft, true)
    }

    private mutating func resolveBallShipCollisions(
        ballIndex: Int,
        previousBallPosition: SIMD2<Double>,
        previousShipPositions: [Seat: SIMD2<Double>],
        contacts: inout [RuleContact],
        effects: inout [SimulationEvent]
    ) {
        let ballEnd = state.balls[ballIndex].position
        var earliest: (seat: Seat, t: Double)?
        for seat in Seat.allCases {
            guard let ship = state.ships[seat], !ship.isDestroyed,
                  let previousShipPosition = previousShipPositions[seat] else { continue }
            let hitbox = shipHitboxes[seat] ?? .shared
            let axis = SIMD2(cos(ship.angle), sin(ship.angle))
            let left = SIMD2(-axis.y, axis.x)
            func local(_ offset: SIMD2<Double>) -> SIMD2<Double> {
                SIMD2(simd_dot(offset, axis), simd_dot(offset, left))
            }
            guard let t = hitbox.sweepTime(
                from: local(previousBallPosition - previousShipPosition),
                to: local(ballEnd - ship.position),
                radius: state.balls[ballIndex].radius + ShipHitbox.skin
            ) else { continue }
            if earliest == nil || t < earliest!.t {
                earliest = (seat, t)
            }
        }
        // The sweep cannot see a ball that starts the step already touching
        // the hull -- a nose swung onto it, a shove from another ship. Take
        // the deepest overlap as a contact at the end of the step instead of
        // letting the hull slide through.
        if earliest == nil {
            earliest = Seat.allCases
                .compactMap { seat in hullPenetration(of: state.balls[ballIndex], into: seat).map { (seat, $0.depth) } }
                .max { $0.1 < $1.1 }
                .map { (seat: $0.0, t: 1.0) }
        }

        guard let hit = earliest, var ship = state.ships[hit.seat],
              let previousShipPosition = previousShipPositions[hit.seat] else { return }
        let hitbox = shipHitboxes[hit.seat] ?? .shared
        let axis = SIMD2(cos(ship.angle), sin(ship.angle))
        let left = SIMD2(-axis.y, axis.x)
        let ballContact = previousBallPosition + (ballEnd - previousBallPosition) * hit.t
        let shipAtContact = previousShipPosition + (ship.position - previousShipPosition) * hit.t
        let offset = ballContact - shipAtContact
        let localBall = SIMD2(simd_dot(offset, axis), simd_dot(offset, left))
        let localSurface = hitbox.closestPoint(to: localBall)
        let surface = axis * localSurface.x + left * localSurface.y
        var normal = offset - surface
        let normalLength = simd_length(normal)
        normal = normalLength > 0.000_001 ? normal / normalLength : SIMD2(-1, 0)
        // A centre already inside the outline points the wrong way out.
        if hitbox.contains(localBall) { normal = -normal }
        state.balls[ballIndex].position = ship.position + surface + normal * (state.balls[ballIndex].radius + ShipHitbox.skin)

        let relativeVelocity = state.balls[ballIndex].velocity - ship.velocity
        let inwardSpeed = simd_dot(relativeVelocity, normal)
        guard inwardSpeed < 0 else { return }
        let inverseBallMass = 1.0 / Self.ballMass
        let inverseShipMass = 1.0 / Self.shipMass
        let impulse = -(1 + Self.shipBallRestitution) * inwardSpeed
            / (inverseBallMass + inverseShipMass)
        let incoming = state.balls[ballIndex].velocity
        state.balls[ballIndex].velocity += normal * impulse * inverseBallMass
        ship.velocity -= normal * impulse * inverseShipMass
        // A hull grips like any other surface, except the surface is moving:
        // the ball slides against the hull where they touch, so a glance, or a
        // nose swung through the ball, sends it off turning. The hull takes
        // the other end of that kick.
        let lever = state.balls[ballIndex].position - normal * state.balls[ballIndex].radius - ship.position
        let hullSurface = ship.velocity + ship.angularVelocity * SIMD2(-lever.y, lever.x)
        let sliding = state.balls[ballIndex].velocity
        (state.balls[ballIndex].velocity, state.balls[ballIndex].spin) = BallState.gripped(
            state.balls[ballIndex].velocity,
            from: incoming,
            spin: state.balls[ballIndex].spin,
            radius: state.balls[ballIndex].radius,
            normal: normal,
            surfaceVelocity: hullSurface
        )
        ship.velocity -= (state.balls[ballIndex].velocity - sliding) * (Self.ballMass / Self.shipMass)
        // Every contact pops the ball clear of the hull. Without this a ship can
        // park under a slow ball and ride it, which stalls the rally outright.
        let separationSpeed = simd_dot(state.balls[ballIndex].velocity - ship.velocity, normal)
        if separationSpeed < configuration.minimumBallSeparationSpeed {
            state.balls[ballIndex].velocity += normal
                * (configuration.minimumBallSeparationSpeed - separationSpeed)
        }
        // The physics above always runs -- a rattling ball still gets shoved
        // clear every step. Only the scoring counts a burst as one hit, and
        // only a hit on your own half spends a touch: a hull pushed into the
        // far half can still play the ball there, it just costs nothing. The
        // warm-up bay and the hoop court have no halves to keep.
        let fresh = ship.ballTouchCooldownTicks == 0
        if fresh {
            ship.ballTouchCooldownTicks = UInt64(
                (configuration.ballTouchDebounce / configuration.stepDuration).rounded()
            )
        }
        let ballSide: Team = ballContact.x < 0 ? .cyan : .orange
        let counted = fresh && (usesEngineRules || ballSide == ship.homeSide)
        state.ships[hit.seat] = ship
        contacts.append(.ballTouchedShip(team: hit.seat.team, counted: counted))
        // Any hull contact played the ball, counted or not: a deflection off
        // the far half still sends it where it goes.
        state.balls[ballIndex].lastPlay = BallPlay(seat: hit.seat, kind: .hull)
        if counted { playsThisStep.append(.hit(hit.seat)) }
        if fresh { defencePlays.append((ballIndex, hit.seat, .hull)) }
        effects.append(.collisionEffect(
            position: state.balls[ballIndex].position,
            intensity: abs(inwardSpeed)
        ))
    }

    /// How far `ball` sits inside `seat`'s hull, skin included, and the way
    /// out for the ball. Nil when the two are clear.
    private func hullPenetration(of ball: BallState, into seat: Seat) -> (normal: SIMD2<Double>, depth: Double)? {
        guard let ship = state.ships[seat], !ship.isDestroyed else { return nil }
        let hitbox = shipHitboxes[seat] ?? .shared
        let axis = SIMD2(cos(ship.angle), sin(ship.angle))
        let left = SIMD2(-axis.y, axis.x)
        let offset = ball.position - ship.position
        let local = SIMD2(simd_dot(offset, axis), simd_dot(offset, left))
        let inside = hitbox.contains(local)
        var away = local - hitbox.closestPoint(to: local)
        let gap = simd_length(away)
        let clearance = inside ? -gap : gap
        let reach = ball.radius + ShipHitbox.skin
        guard clearance < reach - 0.000_001 else { return nil }
        away = gap > 0.000_001 ? away / gap * (inside ? -1 : 1) : SIMD2(1, 0)
        return (axis * away.x + left * away.y, reach - clearance)
    }

    /// Moves every hull overlapping the ball back out of it and takes away
    /// the speed it was carrying into it, with a soft knock back. For a ball
    /// that is not free to move: staged for a serve, or pinned to a wall.
    private mutating func pushShipsOffBall(_ ballIndex: Int) {
        let ball = state.balls[ballIndex]
        for seat in Seat.allCases {
            guard let overlap = hullPenetration(of: ball, into: seat),
                  var ship = state.ships[seat] else { continue }
            ship.position -= overlap.normal * overlap.depth
            let closing = simd_dot(ship.velocity - ball.velocity, overlap.normal)
            if closing > 0 { ship.velocity -= overlap.normal * closing * 1.3 }
            state.ships[seat] = ship
        }
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
