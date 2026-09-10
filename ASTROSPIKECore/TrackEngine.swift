import Foundation
import simd

public enum TrackSeat: String, CaseIterable, Equatable, Sendable {
    case player
    case rival
}

public enum RacePhase: String, Equatable, Sendable {
    case countdown
    case racing
    case finished
}

/// Why a ship is hurt. Shown on the ship itself, because damage the pilot
/// cannot see is just the controls going wrong.
public enum PenaltyReason: String, Equatable, Sendable {
    case railing
}

/// One racer. It is a hull, not a car: it flies the same model the match
/// does -- a velocity vector under constant gravity, turned by torque and
/// pushed along the nose by thrust -- and the tarmac underneath it is a
/// corridor rather than a road surface. Nothing here grips.
public struct CarState: Equatable, Sendable {
    public var position: SIMD2<Double>
    /// Which way the nose points, radians. Turns at the match's torque rate.
    public var heading: Double
    /// Where the ship is actually going, arena units per second. A ship does
    /// not travel along its nose -- it travels along whatever the last burn
    /// left it with, and gravity is pulling on that the whole way round.
    public var velocity: SIMD2<Double>
    /// The burn currently coming out of the nose, so a ramped thrust curve
    /// behaves here exactly as it does in a match.
    public var thrustLevel: Double
    /// Ticks left on the damage. The ship still answers the pads while this
    /// runs -- it just answers weakly, because the engine and the attitude
    /// thrusters are arcing. Nothing is taken away from the pilot.
    public var damageTicksRemaining: UInt64
    public var penaltyReason: PenaltyReason?
    /// Laps completed, as a real number. Counted from the distance actually
    /// flown round the loop, so drifting back over the line does not add one
    /// and cutting back across it does not either.
    public var lapProgress: Double
    public var lapsCompleted: Int
    public var lapClock: Double
    public var bestLapSeconds: Double?
    /// Position round the lap on the previous tick, for the progress delta.
    public var lastProgress: Double
    /// How far off the centreline the ship is, signed. Kept for the renderer.
    public var railOffset: Double

    public init(
        position: SIMD2<Double>,
        heading: Double,
        velocity: SIMD2<Double> = .zero,
        thrustLevel: Double = 0,
        damageTicksRemaining: UInt64 = 0,
        penaltyReason: PenaltyReason? = nil,
        lapProgress: Double = 0,
        lapsCompleted: Int = 0,
        lapClock: Double = 0,
        bestLapSeconds: Double? = nil,
        lastProgress: Double = 0,
        railOffset: Double = 0
    ) {
        self.position = position
        self.heading = heading
        self.velocity = velocity
        self.thrustLevel = thrustLevel
        self.damageTicksRemaining = damageTicksRemaining
        self.penaltyReason = penaltyReason
        self.lapProgress = lapProgress
        self.lapsCompleted = lapsCompleted
        self.lapClock = lapClock
        self.bestLapSeconds = bestLapSeconds
        self.lastProgress = lastProgress
        self.railOffset = railOffset
    }

    /// How fast it is going, whichever way it happens to be pointing.
    public var speed: Double { simd_length(velocity) }

    /// Arcing, and down on power. Not frozen: see `damageTicksRemaining`.
    public var isDamaged: Bool { damageTicksRemaining > 0 }
}

public struct TrackState: Equatable, Sendable {
    public var tick: UInt64
    public var cars: [TrackSeat: CarState]
    public var phase: RacePhase
    public var elapsed: Double
    public var winner: TrackSeat?
    /// Laps to take the flag, or zero for a loop that never ends.
    public var lapsToWin: Int

    /// Nothing to reach, so nothing to lose: the pilot laps until they leave.
    public var isEndless: Bool { lapsToWin <= 0 }

    public init(
        tick: UInt64 = 0,
        cars: [TrackSeat: CarState],
        phase: RacePhase = .countdown,
        elapsed: Double = 0,
        winner: TrackSeat? = nil,
        lapsToWin: Int = 0
    ) {
        self.tick = tick
        self.cars = cars
        self.phase = phase
        self.elapsed = elapsed
        self.winner = winner
        self.lapsToWin = lapsToWin
    }
}

public enum TrackEvent: Equatable, Sendable {
    /// A ship scraped the railing. The position is where it touched.
    case railStrike(seat: TrackSeat, position: SIMD2<Double>, speed: Double)
    case lapCompleted(seat: TrackSeat, lap: Int, seconds: Double)
    case raceFinished(winner: TrackSeat)
}

public struct TrackConfiguration: Equatable, Sendable {
    public var stepDuration: Double
    /// The same pull the match runs under, and it never lets up: there is no
    /// floor here, only the rail the ship falls onto if it stops flying.
    public var gravity: SIMD2<Double>
    public var initialThrustAcceleration: Double
    public var maximumThrustAcceleration: Double
    public var thrustRampRate: Double
    /// Radians per second at full lock. The match's rotation rate.
    public var torqueAcceleration: Double
    /// The burn out of the tail. A ship has no brake, and a corridor race
    /// with no way to shed speed is a race nobody finishes, so the pad that
    /// works the tractor beam in a match works a retro burn here.
    public var retroAcceleration: Double
    /// How much of the ship's speed survives a scrape along the railing.
    public var railSpeedKept: Double
    /// How long the hull stays damaged after a scrape.
    public var damageSeconds: Double
    /// The share of engine power a damaged hull still has. Thrust and retro
    /// only -- steering is deliberately untouched. The rail costs power,
    /// never control: a ship that cannot turn out of the wall it just hit
    /// grinds along it and strikes again the tick its damage clears, which is
    /// being grabbed and stuck by another name.
    public var damagePowerKept: Double
    /// The hull's own radius, the same 0.048 the arena collides against. It
    /// touches the railing this far from it.
    public var shipRadius: Double
    /// Seconds of lights before the flag drops.
    public var countdownSeconds: Double
    /// The pace ship's own ceiling on the straights, arena units per second.
    /// The player has no ceiling, exactly as in a match.
    public var paceTopSpeed: Double
    /// The share of the cornering limit the pace ship actually uses. Under
    /// one, so a clean lap beats it and a scrappy one does not.
    public var rivalPace: Double

    public init(
        stepDuration: Double = 1.0 / 120.0,
        gravity: SIMD2<Double> = SIMD2(0, -0.5),
        initialThrustAcceleration: Double = 2.75,
        maximumThrustAcceleration: Double = 2.75,
        thrustRampRate: Double = 0,
        torqueAcceleration: Double = 5.5,
        retroAcceleration: Double = 1.8,
        railSpeedKept: Double = 0.55,
        damageSeconds: Double = 2.5,
        damagePowerKept: Double = 0.45,
        shipRadius: Double = 0.048,
        countdownSeconds: Double = 3,
        paceTopSpeed: Double = 1.30,
        rivalPace: Double = 0.88
    ) {
        self.stepDuration = stepDuration
        self.gravity = gravity
        self.initialThrustAcceleration = initialThrustAcceleration
        self.maximumThrustAcceleration = maximumThrustAcceleration
        self.thrustRampRate = thrustRampRate
        self.torqueAcceleration = torqueAcceleration
        self.retroAcceleration = retroAcceleration
        self.railSpeedKept = max(0, min(1, railSpeedKept))
        self.damageSeconds = max(0, damageSeconds)
        self.damagePowerKept = max(0.05, min(1, damagePowerKept))
        self.shipRadius = shipRadius
        self.countdownSeconds = max(0, countdownSeconds)
        self.paceTopSpeed = max(0.2, paceTopSpeed)
        self.rivalPace = max(0.1, min(1.4, rivalPace))
    }

    /// The race flown on the match's own numbers. Move the gravity or thrust
    /// slider and the circuit moves with it, because the pilot asked for the
    /// same ship in the same arena and a race tuned separately would not be
    /// that.
    public init(flight: FlightTuningSnapshot, track: TrackTuningSnapshot = .defaults) {
        self.init(
            gravity: SIMD2(0, -flight.gravityMagnitude),
            initialThrustAcceleration: flight.thrustAcceleration,
            maximumThrustAcceleration: flight.thrustAcceleration,
            torqueAcceleration: flight.rotationAcceleration,
            retroAcceleration: flight.thrustAcceleration * 0.65,
            railSpeedKept: track.railSpeedKept,
            damageSeconds: track.damageSeconds,
            damagePowerKept: track.damagePowerKept,
            rivalPace: track.rivalPace
        )
    }
}

/// The circuit's own engine. It shares the fixed step, the input type and now
/// the flight model with `SimulationEngine`: a ship here answers the pads
/// exactly as it does in a match, under the same gravity, inside the same
/// arena box. What it does not share is any of the match: no ball, no net, no
/// teams and no rulebook -- only a corridor, a railing and a lap counter.
public struct TrackEngine: Sendable {
    public let track: TrackGeometry
    public private(set) var configuration: TrackConfiguration
    public private(set) var state: TrackState
    public private(set) var lastEvents: [TrackEvent] = []
    private var countdownRemaining: Double

    public init(
        track: TrackGeometry = .circuit,
        configuration: TrackConfiguration = TrackConfiguration(),
        lapsToWin: Int = 0
    ) {
        self.track = track
        self.configuration = configuration
        countdownRemaining = configuration.countdownSeconds
        let (playerPoint, playerHeading) = track.gridPosition(row: 0, offset: track.halfWidth * 0.42)
        let (rivalPoint, rivalHeading) = track.gridPosition(row: 1, offset: -track.halfWidth * 0.42)
        // The grid sits behind the line, so the lap counter starts negative by
        // exactly the run-up. Lap one then ends at the line rather than back
        // at the grid.
        func gridShip(_ point: SIMD2<Double>, _ heading: Double) -> CarState {
            let progress = track.placement(of: point).progress
            return CarState(
                position: point,
                heading: heading,
                lapProgress: progress > 0.5 ? progress - 1 : progress,
                lastProgress: progress
            )
        }
        state = TrackState(
            cars: [
                .player: gridShip(playerPoint, playerHeading),
                .rival: gridShip(rivalPoint, rivalHeading),
            ],
            lapsToWin: max(0, lapsToWin)
        )
    }

    /// Seconds left on the lights. Zero once the flag has dropped.
    public var countdownSecondsRemaining: Double { max(0, countdownRemaining) }

    public mutating func step(input: PlayerInput) {
        var events: [TrackEvent] = []
        let dt = configuration.stepDuration

        switch state.phase {
        case .countdown:
            countdownRemaining -= dt
            if countdownRemaining <= 0 {
                countdownRemaining = 0
                state.phase = .racing
            }
            state.tick &+= 1
            lastEvents = []
            return
        case .finished:
            state.tick &+= 1
            lastEvents = []
            return
        case .racing:
            break
        }

        state.elapsed += dt
        for seat in TrackSeat.allCases {
            guard var car = state.cars[seat] else { continue }
            let control = seat == .player ? input : rivalInput(for: car)
            advance(car: &car, seat: seat, control: control, events: &events)
            state.cars[seat] = car
        }

        // An endless loop has no flag to take, so nothing here ever ends it.
        // The pilot leaves when they are done, which is the whole point of it.
        if !state.isEndless,
           let winner = state.cars.first(where: { $0.value.lapsCompleted >= state.lapsToWin })?.key {
            state.phase = .finished
            state.winner = winner
            events.append(.raceFinished(winner: winner))
        }
        state.tick &+= 1
        lastEvents = events
    }

    private mutating func advance(
        car: inout CarState,
        seat: TrackSeat,
        control: PlayerInput,
        events: inout [TrackEvent]
    ) {
        let dt = configuration.stepDuration
        car.lapClock += dt

        if car.damageTicksRemaining > 0 {
            car.damageTicksRemaining -= 1
            if car.damageTicksRemaining == 0 { car.penaltyReason = nil }
        }

        // Damage costs power, not control. A hurt ship burns weaker for a few
        // seconds and steers exactly as well as it always did -- steering is
        // how you get off the wall, and taking it away is what makes a
        // penalty feel like the game breaking in your hands.
        let power = car.isDamaged ? configuration.damagePowerKept : 1

        // The match's flight model, line for line: torque sets the turn rate,
        // gravity is always on, and thrust pushes along the nose.
        car.heading += control.torque * configuration.torqueAcceleration * dt
        var acceleration = configuration.gravity
        let nose = SIMD2(cos(car.heading), sin(car.heading))
        if control.thrust {
            car.thrustLevel = car.thrustLevel > 0
                ? min(
                    configuration.maximumThrustAcceleration,
                    car.thrustLevel + configuration.thrustRampRate * dt
                )
                : configuration.initialThrustAcceleration
            acceleration += nose * car.thrustLevel * power
        } else {
            car.thrustLevel = 0
        }
        if control.tractor {
            acceleration -= nose * configuration.retroAcceleration * power
        }
        car.velocity += acceleration * dt
        car.position += car.velocity * dt

        // The railing. The tarmac is a tube round the centreline, so being off
        // the track is one comparison, and putting the ship back on it is one
        // clamp -- true through the sweeper and the hairpin alike.
        var placement = track.placement(of: car.position)
        let limit = track.halfWidth - configuration.shipRadius
        if abs(placement.offset) > limit {
            let sign: Double = placement.offset < 0 ? -1 : 1
            let outward = placement.normal * sign
            let struckAt = placement.closest + outward * track.halfWidth
            // Back onto the tarmac with a little daylight, not flush against
            // the rail: a ship left exactly on the line re-triggers next tick.
            car.position = placement.closest + outward * (limit * 0.94)
            let impactSpeed = simd_length(car.velocity)
            // The rail is solid every tick it is being leaned on: whatever is
            // heading into it stops there. Without this the ship keeps its
            // velocity pointed at the wall and drives straight back into it
            // the instant the stun lifts, which turns a penalty into a pin.
            let into = simd_dot(car.velocity, outward)
            if into > 0 { car.velocity -= outward * into }
            // One strike per contact, and the damage is dealt once. A ship
            // already arcing is sliding along the railing; billing it for
            // every tick of that slide is a pin by another route.
            if !car.isDamaged {
                car.velocity *= configuration.railSpeedKept
                car.damageTicksRemaining = UInt64(
                    (configuration.damageSeconds / configuration.stepDuration).rounded()
                )
                car.penaltyReason = .railing
                events.append(.railStrike(seat: seat, position: struckAt, speed: impactSpeed))
            }
            placement = track.placement(of: car.position)
        }
        car.railOffset = placement.offset

        // Lap counting off the distance actually flown, wrapped short. A ship
        // that drifts back over the line unwinds its own progress instead of
        // banking a lap.
        var delta = placement.progress - car.lastProgress
        if delta > 0.5 { delta -= 1 }
        if delta < -0.5 { delta += 1 }
        let wasBeforeLine = car.lapProgress < 0
        car.lapProgress += delta
        car.lastProgress = placement.progress
        if wasBeforeLine, car.lapProgress >= 0 {
            car.lapClock = 0
        }
        // The clock is the whole penalty now. A scrape costs the seconds it
        // costs, because a slow ship takes longer round -- nothing is added
        // to the lap on top of that.
        while car.lapProgress >= Double(car.lapsCompleted + 1) {
            car.lapsCompleted += 1
            let lapTime = car.lapClock
            if car.bestLapSeconds == nil || lapTime < car.bestLapSeconds! {
                car.bestLapSeconds = lapTime
            }
            events.append(.lapCompleted(seat: seat, lap: car.lapsCompleted, seconds: lapTime))
            car.lapClock = 0
        }
    }

    /// The pace ship flies the line: it decides where it wants to be going,
    /// works out the burn that would get it there, and points the nose at
    /// that burn. It is on the same railing rules as the player.
    private func rivalInput(for car: CarState) -> PlayerInput {
        Self.paceCommand(
            track: track,
            car: car,
            configuration: configuration,
            pace: configuration.rivalPace,
            tick: state.tick
        )
    }

    /// The line the pace ship flies, as a pure function of the corridor and
    /// the ship in it. Public so it can be flown against the track on its
    /// own, without a race around it.
    ///
    /// A car planned in heading space: point the nose down the road and open
    /// the throttle. A ship cannot, because the nose is not where it is
    /// going and gravity is pulling it off the line the whole time. So the
    /// plan is made in acceleration space instead. Ask for a velocity -- down
    /// the road, at whatever the corner ahead allows, crabbing back toward
    /// the middle of the corridor -- subtract the velocity it has, subtract
    /// gravity, and what is left is the burn. Point at the burn, and light it
    /// when the nose is close enough to be pushing the right way.
    public static func paceCommand(
        track: TrackGeometry,
        car: CarState,
        configuration: TrackConfiguration,
        pace: Double,
        tick: UInt64
    ) -> PlayerInput {
        let placement = track.placement(of: car.position)
        let thrust = configuration.maximumThrustAcceleration
        // Pace has to reach the corners, not just the straights. Nearly all
        // of this lap is corner, so a pace ship throttled only on the straight
        // is barely slower at all -- and a pace ship nobody can beat, or one
        // nobody can lose to, is not a race either way. Cornering speed goes
        // as the root of the sideways push, so squaring the pace here makes
        // the corner exactly `pace` times slower too.
        let topSpeed = configuration.paceTopSpeed * pace

        // How fast it is allowed to be here. Walk the road ahead, and for
        // every point on it ask two questions: how fast could the ship hold
        // the bend that is there, and -- given it still has that much road to
        // slow down in -- how fast is it allowed to be going *now* to arrive
        // at that speed. The lowest answer wins, which is why it lifts before
        // a corner it cannot yet see the far side of.
        //
        // A ship holding a bend of radius r at speed v needs v * v / r of
        // sideways push, and everything it has to push with is the thrust. It
        // cannot spend all of it: some is holding the ship up against gravity
        // and some is the margin between a fast line and the rail.
        let lateral = max(0.1, thrust * Self.corneringShare - simd_length(configuration.gravity))
            * pace * pace
        // Shedding speed is the retro burn plus whatever gravity happens to
        // be doing, and gravity is as often against as for, so it is left out.
        let shedding = max(0.1, configuration.retroAcceleration)
        var wanted = topSpeed
        var ahead = 0.0
        while ahead < 0.85 {
            let bend = abs(signedCurvature(track: track, alongFrom: placement.progress, distance: ahead))
            let corner = bend > 1e-6 ? min(topSpeed, (lateral / bend).squareRoot()) : topSpeed
            wanted = min(wanted, (corner * corner + 2 * shedding * ahead).squareRoot())
            ahead += 0.05
        }
        wanted = max(wanted, topSpeed * 0.25)

        // Where it wants to be going: down the road, far enough ahead that it
        // is aiming at the corridor rather than at the point under its nose,
        // and pulled back toward the centreline by however far off it is.
        let lookahead = 0.10 + 0.28 * (wanted / max(topSpeed, 1e-6))
        let target = centreline(track: track, alongFrom: placement.progress, distance: lookahead)
        var toward = target - car.position
        let reach = simd_length(toward)
        toward = reach > 1e-9 ? toward / reach : placement.tangent
        let wantedVelocity = toward * wanted

        // The burn: close the gap to that velocity inside a couple of tenths,
        // and carry gravity on top so the ship holds its height as well as
        // its line.
        var burn = (wantedVelocity - car.velocity) * Self.velocityGain - configuration.gravity
        let magnitude = simd_length(burn)
        if magnitude < 1e-9 { burn = SIMD2(cos(car.heading), sin(car.heading)) }

        let wantHeading = atan2(burn.y, burn.x)
        var headingError = wantHeading - car.heading
        while headingError > .pi { headingError -= 2 * .pi }
        while headingError < -.pi { headingError += 2 * .pi }
        // Heading integrates straight off the torque, so the exact lock that
        // lands the nose on the burn this tick is arithmetic, not a guess.
        let perTick = configuration.torqueAcceleration * configuration.stepDuration
        let torque = max(-1, min(1, headingError / max(perTick, 1e-9)))

        // Thrust is on or off, never half, so it duty-cycles: light it when
        // the nose is pushing the right way and the burn asked for is worth
        // more than the fixed shove it will get.
        let nose = SIMD2(cos(car.heading), sin(car.heading))
        let along = simd_dot(nose, burn)
        let lit = along > thrust * Self.thrustDeadband && abs(headingError) < 1.0
        // The retro pad, for the case the plan cannot fix by pointing: badly
        // over the speed it wants, with the nose already turned away.
        let retro = !lit
            && simd_length(car.velocity) > wanted * 1.25
            && simd_dot(nose, car.velocity) < 0

        return PlayerInput(
            tick: tick,
            torque: torque,
            thrust: lit,
            fire: false,
            tractor: retro
        )
    }

    /// How much of the thrust the pace ship is willing to spend on turning.
    /// Under one because holding the ship up is not free and because a ship
    /// that takes every corner at exactly its limit spends the race in the
    /// barriers.
    private static let corneringShare = 0.62

    /// How hard the pace ship closes on the velocity it wants, per second.
    /// High enough to hold a line, low enough that it does not chatter the
    /// nose back and forth on a straight.
    private static let velocityGain = 3.2

    /// The share of full thrust a burn has to be worth before the pace ship
    /// lights it. This is what turns an on/off engine into a throttle.
    private static let thrustDeadband = 0.34

    /// How sharply the road bends `distance` further round the lap, in radians
    /// per arena unit. The magnitude's reciprocal is the corner's radius; the
    /// sign says which way it goes, positive for a left-hander.
    private static func signedCurvature(
        track: TrackGeometry,
        alongFrom progress: Double,
        distance: Double
    ) -> Double {
        let span = 0.06
        let here = tangentAngle(track: track, alongFrom: progress, distance: distance)
        let next = tangentAngle(track: track, alongFrom: progress, distance: distance + span)
        var delta = next - here
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return delta / span
    }

    /// Which way the road points, `distance` further round the lap.
    private static func tangentAngle(
        track: TrackGeometry,
        alongFrom progress: Double,
        distance: Double
    ) -> Double {
        let tangent = track.samples[sampleIndex(track: track, alongFrom: progress, distance: distance)].tangent
        return atan2(tangent.y, tangent.x)
    }

    /// The point on the centreline `distance` further round the lap.
    private static func centreline(
        track: TrackGeometry,
        alongFrom progress: Double,
        distance: Double
    ) -> SIMD2<Double> {
        track.samples[sampleIndex(track: track, alongFrom: progress, distance: distance)].point
    }

    private static func sampleIndex(
        track: TrackGeometry,
        alongFrom progress: Double,
        distance: Double
    ) -> Int {
        let along = progress + distance / max(track.totalLength, 1e-6)
        let wrapped = along - floor(along)
        return Int(wrapped * Double(track.samples.count)) % track.samples.count
    }
}
