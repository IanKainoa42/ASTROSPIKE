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

/// Why a car is being held up. Shown on the car itself, because a penalty the
/// driver cannot see is just the controls going wrong.
public enum PenaltyReason: String, Equatable, Sendable {
    case railing
}

public struct CarState: Equatable, Sendable {
    public var position: SIMD2<Double>
    /// Which way the nose points, radians.
    public var heading: Double
    /// Along the nose, arena units per second. Negative is reverse.
    public var speed: Double
    /// Ticks left on the stun. Throttle and steering are dead while it runs.
    public var stunTicksRemaining: UInt64
    public var penaltyReason: PenaltyReason?
    /// Seconds added to this lap for hitting the railing.
    public var penaltySeconds: Double
    /// Laps completed, as a real number. Counted from the distance actually
    /// driven round the loop, so reversing over the line does not add one and
    /// cutting back across it does not either.
    public var lapProgress: Double
    public var lapsCompleted: Int
    public var lapClock: Double
    public var bestLapSeconds: Double?
    /// Position round the lap on the previous tick, for the progress delta.
    public var lastProgress: Double
    /// How far off the centreline the car is, signed. Kept for the renderer.
    public var railOffset: Double

    public init(
        position: SIMD2<Double>,
        heading: Double,
        speed: Double = 0,
        stunTicksRemaining: UInt64 = 0,
        penaltyReason: PenaltyReason? = nil,
        penaltySeconds: Double = 0,
        lapProgress: Double = 0,
        lapsCompleted: Int = 0,
        lapClock: Double = 0,
        bestLapSeconds: Double? = nil,
        lastProgress: Double = 0,
        railOffset: Double = 0
    ) {
        self.position = position
        self.heading = heading
        self.speed = speed
        self.stunTicksRemaining = stunTicksRemaining
        self.penaltyReason = penaltyReason
        self.penaltySeconds = penaltySeconds
        self.lapProgress = lapProgress
        self.lapsCompleted = lapsCompleted
        self.lapClock = lapClock
        self.bestLapSeconds = bestLapSeconds
        self.lastProgress = lastProgress
        self.railOffset = railOffset
    }

    public var isStunned: Bool { stunTicksRemaining > 0 }
}

public struct TrackState: Equatable, Sendable {
    public var tick: UInt64
    public var cars: [TrackSeat: CarState]
    public var phase: RacePhase
    public var elapsed: Double
    public var winner: TrackSeat?
    public var lapsToWin: Int

    public init(
        tick: UInt64 = 0,
        cars: [TrackSeat: CarState],
        phase: RacePhase = .countdown,
        elapsed: Double = 0,
        winner: TrackSeat? = nil,
        lapsToWin: Int = 3
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
    /// A car scraped the railing. The position is where it touched.
    case railStrike(seat: TrackSeat, position: SIMD2<Double>, speed: Double)
    case lapCompleted(seat: TrackSeat, lap: Int, seconds: Double)
    case raceFinished(winner: TrackSeat)
}

public struct TrackConfiguration: Equatable, Sendable {
    public var stepDuration: Double
    /// Top speed under power, arena units per second.
    public var maximumSpeed: Double
    public var acceleration: Double
    /// How hard the brake pad pulls it up. Held past a stop it reverses.
    public var braking: Double
    public var reverseSpeed: Double
    /// Rolling resistance with the throttle shut.
    public var coastDrag: Double
    /// Radians per second at full lock, once the car is up to `steeringBite`.
    public var steeringRate: Double
    /// Below this speed the steering does nothing -- the same as a real car,
    /// and it stops a stunned car from pirouetting on the spot.
    public var steeringBite: Double
    /// How much of the car's speed survives a scrape along the railing.
    public var railSpeedKept: Double
    /// How long the controls stay dead after a scrape.
    public var railStunSeconds: Double
    /// What a scrape costs on the lap clock.
    public var railPenaltySeconds: Double
    /// The car's own radius. It touches the railing this far from it.
    public var carRadius: Double
    /// Seconds of lights before the flag drops.
    public var countdownSeconds: Double
    /// The rival's share of the player's top speed. Under one, so a clean
    /// lap beats it and a scrappy one does not.
    public var rivalPace: Double

    public init(
        stepDuration: Double = 1.0 / 120.0,
        maximumSpeed: Double = 1.05,
        acceleration: Double = 1.5,
        braking: Double = 2.2,
        reverseSpeed: Double = 0.32,
        coastDrag: Double = 0.55,
        steeringRate: Double = 4.6,
        steeringBite: Double = 0.12,
        railSpeedKept: Double = 0.22,
        railStunSeconds: Double = 0.6,
        railPenaltySeconds: Double = 1.0,
        carRadius: Double = 0.030,
        countdownSeconds: Double = 3,
        rivalPace: Double = 0.88
    ) {
        self.stepDuration = stepDuration
        self.maximumSpeed = maximumSpeed
        self.acceleration = acceleration
        self.braking = braking
        self.reverseSpeed = reverseSpeed
        self.coastDrag = coastDrag
        self.steeringRate = steeringRate
        self.steeringBite = steeringBite
        self.railSpeedKept = max(0, min(1, railSpeedKept))
        self.railStunSeconds = max(0, railStunSeconds)
        self.railPenaltySeconds = max(0, railPenaltySeconds)
        self.carRadius = carRadius
        self.countdownSeconds = max(0, countdownSeconds)
        self.rivalPace = max(0.1, min(1.4, rivalPace))
    }
}

/// The circuit's own engine. It shares nothing with `SimulationEngine` but the
/// fixed step and the input type: there is no ball, no net, no teams and no
/// rulebook here, and pretending otherwise would have meant threading a
/// nil ball through every method in the arena.
public struct TrackEngine: Sendable {
    public let track: TrackGeometry
    public private(set) var configuration: TrackConfiguration
    public private(set) var state: TrackState
    public private(set) var lastEvents: [TrackEvent] = []
    private var countdownRemaining: Double

    public init(
        track: TrackGeometry = .circuit,
        configuration: TrackConfiguration = TrackConfiguration(),
        lapsToWin: Int = 3
    ) {
        self.track = track
        self.configuration = configuration
        countdownRemaining = configuration.countdownSeconds
        let (playerPoint, playerHeading) = track.gridPosition(row: 0, offset: track.halfWidth * 0.42)
        let (rivalPoint, rivalHeading) = track.gridPosition(row: 1, offset: -track.halfWidth * 0.42)
        // The grid sits behind the line, so the lap counter starts negative by
        // exactly the run-up. Lap one then ends at the line rather than back
        // at the grid.
        func gridCar(_ point: SIMD2<Double>, _ heading: Double) -> CarState {
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
                .player: gridCar(playerPoint, playerHeading),
                .rival: gridCar(rivalPoint, rivalHeading),
            ],
            lapsToWin: max(1, lapsToWin)
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
            let topSpeed = seat == .player
                ? configuration.maximumSpeed
                : configuration.maximumSpeed * configuration.rivalPace
            advance(car: &car, seat: seat, control: control, topSpeed: topSpeed, events: &events)
            state.cars[seat] = car
        }

        if let winner = state.cars.first(where: { $0.value.lapsCompleted >= state.lapsToWin })?.key {
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
        topSpeed: Double,
        events: inout [TrackEvent]
    ) {
        let dt = configuration.stepDuration
        car.lapClock += dt

        if car.stunTicksRemaining > 0 {
            car.stunTicksRemaining -= 1
            if car.stunTicksRemaining == 0 { car.penaltyReason = nil }
        }

        // A stunned car keeps rolling but answers nothing: no throttle, no
        // brake, no steering. That is the penalty -- you are a passenger for
        // six tenths of a second, in whatever direction you were pointing.
        if !car.isStunned {
            if control.thrust {
                car.speed = min(topSpeed, car.speed + configuration.acceleration * dt)
            } else if control.tractor {
                car.speed = max(
                    -configuration.reverseSpeed,
                    car.speed - configuration.braking * dt
                )
            } else {
                let drag = configuration.coastDrag * dt
                car.speed = car.speed > 0
                    ? max(0, car.speed - drag)
                    : min(0, car.speed + drag)
            }

            // Steering scales with speed, so the car turns in and not on the
            // spot. Reversing steers the other way, as it does in a car park.
            // With power on it keeps some authority at a standstill: a car
            // pinned nose-first against the railing has to be able to get its
            // front round, or the penalty is a dead end rather than a cost.
            let motionBite = min(1, abs(car.speed) / max(configuration.steeringBite, 1e-6))
            let poweredBite = (control.thrust || control.tractor) ? 0.5 : 0
            let bite = max(motionBite, poweredBite)
            let direction: Double = car.speed < 0 ? -1 : 1
            car.heading += control.torque * configuration.steeringRate * bite * direction * dt
        } else {
            let drag = configuration.coastDrag * dt
            car.speed = car.speed > 0 ? max(0, car.speed - drag) : min(0, car.speed + drag)
        }

        let axis = SIMD2(cos(car.heading), sin(car.heading))
        car.position += axis * (car.speed * dt)

        // The railing. The tarmac is a tube round the centreline, so being off
        // the track is one comparison, and putting the car back on it is one
        // clamp -- true through the chicane and the hairpin alike.
        var placement = track.placement(of: car.position)
        let limit = track.halfWidth - configuration.carRadius
        if abs(placement.offset) > limit {
            let sign: Double = placement.offset < 0 ? -1 : 1
            let struckAt = placement.closest + placement.normal * (sign * track.halfWidth)
            // Back onto the tarmac with a little daylight, not flush against
            // the rail: a car left exactly on the line re-triggers next tick.
            car.position = placement.closest + placement.normal * (sign * limit * 0.94)
            // One strike per contact. A car already serving a stun is sliding
            // along the railing, and charging it again for every tick of that
            // slide is what turns a penalty into a pin.
            if !car.isStunned {
                let impactSpeed = abs(car.speed)
                car.speed *= configuration.railSpeedKept
                car.stunTicksRemaining = UInt64(
                    (configuration.railStunSeconds / configuration.stepDuration).rounded()
                )
                car.penaltyReason = .railing
                car.penaltySeconds += configuration.railPenaltySeconds
                events.append(.railStrike(seat: seat, position: struckAt, speed: impactSpeed))
            }
            placement = track.placement(of: car.position)
        }
        car.railOffset = placement.offset

        // Lap counting off the distance actually driven, wrapped short. A car
        // that reverses over the line unwinds its own progress instead of
        // banking a lap.
        var delta = placement.progress - car.lastProgress
        if delta > 0.5 { delta -= 1 }
        if delta < -0.5 { delta += 1 }
        let wasBeforeLine = car.lapProgress < 0
        car.lapProgress += delta
        car.lastProgress = placement.progress
        if wasBeforeLine, car.lapProgress >= 0 {
            car.lapClock = 0
            car.penaltySeconds = 0
        }
        while car.lapProgress >= Double(car.lapsCompleted + 1) {
            car.lapsCompleted += 1
            let lapTime = car.lapClock + car.penaltySeconds
            if car.bestLapSeconds == nil || lapTime < car.bestLapSeconds! {
                car.bestLapSeconds = lapTime
            }
            events.append(.lapCompleted(seat: seat, lap: car.lapsCompleted, seconds: lapTime))
            car.lapClock = 0
            car.penaltySeconds = 0
        }
    }

    /// The rival drives the line: it aims at a point up the road and holds
    /// the throttle open, lifting only when the corner ahead is sharper than
    /// it can take. It is on the same railing rules as the player.
    private func rivalInput(for car: CarState) -> PlayerInput {
        Self.paceCommand(
            track: track,
            car: car,
            configuration: configuration,
            topSpeed: configuration.maximumSpeed * configuration.rivalPace,
            tick: state.tick
        )
    }

    /// The line the pace car drives, as a pure function of the road and the
    /// car on it. Public so it can be flown against the track on its own,
    /// without a race around it.
    public static func paceCommand(
        track: TrackGeometry,
        car: CarState,
        configuration: TrackConfiguration,
        topSpeed: Double,
        tick: UInt64
    ) -> PlayerInput {
        let placement = track.placement(of: car.position)
        let top = topSpeed
        let pace = abs(car.speed) / max(top, 1e-6)

        // Two terms, not one, and the first of them looks at the road *here*
        // rather than up ahead. Aiming the nose at a point further round the
        // bend turns the car in early, and turning in early on a curve whose
        // centreline is itself curving means the car is always heading inside
        // of where the centreline will be -- it walks itself onto the inner
        // rail and stays there. Anticipation belongs in the speed target, not
        // the steering one. So: line the nose up with the road under the car,
        // then crab back toward the middle by however far off it is.
        let roadAngle = atan2(placement.tangent.y, placement.tangent.x)
        var headingError = roadAngle - car.heading
        while headingError > .pi { headingError -= 2 * .pi }
        while headingError < -.pi { headingError += 2 * .pi }
        // Offset is positive to the left of travel, so a positive offset asks
        // for right lock, which is negative torque. Divided by speed because
        // the same sideways error needs less lock the faster the car is going.
        let recentre = atan(2.2 * placement.offset / max(abs(car.speed), 0.25))
        // Feed-forward. On a corner of constant curvature a purely corrective
        // driver is always a beat late -- it can only steer once it is already
        // off the line, so it spends the whole corner catching up and arrives
        // at the exit against the outside rail. So hand it the corner before
        // it happens: holding curvature k at speed v needs exactly k * v
        // radians per second of yaw, which is that fraction of full lock.
        // Read the corner a little way in front of the nose, not under it: the
        // car takes a moment to take up the lock, and a corner it starts
        // turning for on arrival is a corner it turns into late.
        let bendHere = 0.5 * (
            signedCurvature(track: track, alongFrom: placement.progress, distance: 0.02)
                + signedCurvature(track: track, alongFrom: placement.progress, distance: 0.08)
        )
        let holdTheCorner = bendHere * car.speed / max(configuration.steeringRate, 1e-6)
        let torque = max(-1, min(1, holdTheCorner + (headingError - recentre) * 4.0))

        // Brake for the corner, not for the mistake. Walk up the road ahead,
        // and for every point on it ask two questions: how fast could the car
        // get round the bend that is there, and -- given it still has that
        // much road to slow down in -- how fast is it allowed to be going
        // *now* to arrive at that speed. The lowest answer wins. That is why
        // it lifts before a corner it cannot yet see the far side of.
        var wanted = top
        var ahead = 0.0
        while ahead < 0.70 {
            let bend = abs(signedCurvature(track: track, alongFrom: placement.progress, distance: ahead))
            // A car turning at full lock carves a circle of radius v / ω, so
            // the tightest bend it can hold at speed v has curvature ω / v.
            // Read backwards: the fastest it can take this bend is ω / κ.
            let corner = bend > 1e-6
                ? min(top, configuration.steeringRate / bend * Self.cornerMargin)
                : top
            wanted = min(wanted, (corner * corner + 2 * configuration.braking * ahead).squareRoot())
            ahead += 0.05
        }
        wanted = max(wanted, top * 0.22)
        // Pace scales it: a car that is meant to be beatable does not have to
        // be the one that finds the limit of the corner every time.
        _ = pace
        let thrust = abs(car.speed) < wanted
        let brake = abs(car.speed) > wanted * 1.08
        return PlayerInput(
            tick: tick,
            torque: torque,
            thrust: thrust,
            fire: false,
            tractor: brake
        )
    }

    /// How much of the theoretical cornering limit the pace car actually uses.
    /// Under one because tyres are not the only thing between it and the rail:
    /// the steering is discrete, the line is not perfect, and a car that takes
    /// every corner at exactly its limit spends the race in the barriers.
    private static let cornerMargin = 0.75

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
        let along = progress + distance / max(track.totalLength, 1e-6)
        let wrapped = along - floor(along)
        let index = Int(wrapped * Double(track.samples.count)) % track.samples.count
        let tangent = track.samples[index].tangent
        return atan2(tangent.y, tangent.x)
    }

}
