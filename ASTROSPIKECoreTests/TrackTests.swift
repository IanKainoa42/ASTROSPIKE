import Testing
import simd
@testable import ASTROSPIKECore

@Suite("Track geometry")
struct TrackGeometryTests {
    @Test("The circuit closes on itself and every sample sits on the tarmac")
    func closedAndOnTheTarmac() {
        let track = TrackGeometry.circuit
        #expect(track.samples.count == track.controlPoints.count * TrackGeometry.samplesPerSegment)
        #expect(track.totalLength > 3)
        for sample in track.samples {
            // A point on the centreline is, by definition, no distance from it.
            #expect(abs(track.placement(of: sample.point).offset) < 0.01)
        }
    }

    @Test("No corner is tighter than the tarmac is wide")
    func cornersFitTheCorridor() {
        // A corner whose radius is smaller than the corridor the ship has to
        // stay in is not a corner, it is a wall with a gap in it. Measure the
        // turn per unit length round the whole lap and take the worst of it.
        // This is the rule that stops the lanes being widened past the point
        // where the inner rail folds through itself at an apex.
        let track = TrackGeometry.circuit
        let count = track.samples.count
        var tightest = Double.greatestFiniteMagnitude
        for index in 0 ..< count {
            let here = track.samples[index]
            let next = track.samples[(index + 4) % count]
            var turn = atan2(next.tangent.y, next.tangent.x) - atan2(here.tangent.y, here.tangent.x)
            while turn > .pi { turn -= 2 * .pi }
            while turn < -.pi { turn += 2 * .pi }
            let span = track.totalLength * 4 / Double(count)
            guard abs(turn) > 1e-9 else { continue }
            tightest = min(tightest, span / abs(turn))
        }
        #expect(tightest > track.halfWidth * 2)
    }

    @Test("The offset is signed, and the sign says which rail")
    func offsetIsSigned() {
        let track = TrackGeometry.circuit
        let sample = track.samples[10]
        let left = track.placement(of: sample.point + sample.normal * 0.04)
        let right = track.placement(of: sample.point - sample.normal * 0.04)
        #expect(left.offset > 0.03)
        #expect(right.offset < -0.03)
        #expect(track.rail(sign: 1).count == track.samples.count)
    }

    @Test("The corridor is wide enough to fly a hull down, not just to fit one")
    func corridorTakesAHull() {
        // Wider lanes was the ask. The number that matters is not the tarmac
        // but the daylight a hull actually has inside it, which is the tarmac
        // less the hull on both sides.
        let track = TrackGeometry.circuit
        let hull = TrackConfiguration().shipRadius
        #expect(track.halfWidth - hull > hull)
    }

    @Test("The whole circuit, rails included, fits inside the arena walls")
    func railsStayInTheArena() {
        // Same arena as a match: the corridor is laid inside the court box,
        // so nothing on the track is drawn through a wall.
        let track = TrackGeometry.circuit
        let arena = ArenaGeometry.standard
        for sign in [1.0, -1.0] {
            for point in track.rail(sign: sign) {
                #expect(abs(point.x) < arena.halfWidth)
                #expect(point.y > arena.floorY)
                #expect(point.y < arena.ceilingY)
            }
        }
    }

    @Test("The grid sits behind the line, so lap one ends at the line")
    func gridIsBehindTheLine() {
        let track = TrackGeometry.circuit
        let (point, _) = track.gridPosition(row: 0, offset: 0)
        // Behind the line means near the end of the lap, not the start of it.
        #expect(track.placement(of: point).progress > 0.95)
    }
}

@Suite("Track racing")
struct TrackEngineTests {
    private func afterTheLights() -> TrackEngine {
        var engine = TrackEngine()
        var tick: UInt64 = 0
        while engine.state.phase == .countdown, tick < 1_000 {
            engine.step(input: .idle(tick: tick))
            tick += 1
        }
        return engine
    }

    @Test("Nothing moves until the lights go out")
    func countdownHoldsTheField() {
        var engine = TrackEngine()
        let start = engine.state.cars[.player]!.position
        #expect(engine.state.phase == .countdown)
        #expect(engine.countdownSecondsRemaining > 0)
        for tick in 0 ..< 60 {
            engine.step(input: PlayerInput(
                tick: UInt64(tick), torque: 1, thrust: true, fire: false, tractor: false
            ))
        }
        #expect(engine.state.phase == .countdown)
        #expect(engine.state.cars[.player]!.position == start)
        #expect(engine.state.elapsed == 0)
    }

    @Test("Hitting the railing costs speed, control and a second on the clock")
    func railingIsAPenalty() throws {
        var engine = afterTheLights()
        #expect(engine.state.phase == .racing)

        // Full lock with the throttle open puts the ship into a rail inside a
        // few seconds, whichever way the corridor happens to be going.
        var struck: (before: CarState, after: CarState)?
        for tick in 0 ..< 1_200 {
            let before = engine.state.cars[.player]!
            engine.step(input: PlayerInput(
                tick: UInt64(tick), torque: 1, thrust: true, fire: false, tractor: false
            ))
            let hit = engine.lastEvents.contains {
                if case .railStrike(.player, _, _) = $0 { true } else { false }
            }
            if hit {
                struck = (before, engine.state.cars[.player]!)
                break
            }
        }

        let hit = try #require(struck)
        let configuration = TrackConfiguration()
        // Speed is clamped to a fraction of what arrived at the rail.
        #expect(hit.after.speed <= hit.before.speed * configuration.railSpeedKept + 0.01)
        // Stunned for the full penalty, and paying a second on the lap.
        #expect(hit.after.isStunned)
        #expect(hit.after.penaltyReason == .railing)
        #expect(hit.after.stunTicksRemaining == UInt64(
            (configuration.railStunSeconds / configuration.stepDuration).rounded()
        ))
        #expect(hit.after.penaltySeconds >= configuration.railPenaltySeconds)
        // And put back on the tarmac, with daylight, so it does not re-trigger.
        #expect(abs(hit.after.railOffset) < TrackGeometry.circuit.halfWidth - configuration.shipRadius)
    }

    @Test("A stunned ship answers nothing, but gravity still has hold of it")
    func stunIgnoresTheControls() {
        var engine = afterTheLights()
        for tick in 0 ..< 1_200 {
            engine.step(input: PlayerInput(
                tick: UInt64(tick), torque: 1, thrust: true, fire: false, tractor: false
            ))
            if engine.state.cars[.player]!.isStunned { break }
        }
        let stunned = engine.state.cars[.player]!
        #expect(stunned.isStunned)
        let heading = stunned.heading
        // Full lock, throttle open: a ship that is listening would turn and
        // would light its engine.
        engine.step(input: PlayerInput(tick: 999, torque: 1, thrust: true, fire: false, tractor: false))
        let after = engine.state.cars[.player]!
        #expect(after.heading == heading)
        #expect(after.thrustLevel == 0)
        // Not frozen, though: the penalty takes the controls away, not the
        // physics. Six tenths of a second as a passenger under gravity.
        #expect(after.velocity != stunned.velocity)
    }

    @Test("One strike per contact, not one per tick of the slide")
    func strikesAreEdgeTriggered() {
        var engine = afterTheLights()
        var strikes = 0
        var stunTicksSeen = 0
        for tick in 0 ..< 1_400 {
            engine.step(input: PlayerInput(
                tick: UInt64(tick), torque: 1, thrust: true, fire: false, tractor: false
            ))
            strikes += engine.lastEvents.filter {
                if case .railStrike(.player, _, _) = $0 { true } else { false }
            }.count
            if engine.state.cars[.player]!.isStunned { stunTicksSeen += 1 }
        }
        // A ship pinned against the railing for tens of ticks must not be
        // charged for every one of them. The hard invariant is one strike per
        // stun window and no more: full lock into a rail, over and over, can
        // only bill as often as the stun expires.
        let configuration = TrackConfiguration()
        let stunLength = Int((configuration.railStunSeconds / configuration.stepDuration).rounded())
        #expect(strikes >= 1)
        #expect(stunTicksSeen > strikes)
        #expect(strikes <= stunTicksSeen / stunLength + 1)
    }

    @Test("The pace ship flies three clean laps and takes the flag")
    func paceCarFinishes() {
        var engine = TrackEngine()
        var railStrikes = 0
        var lapTimes: [Double] = []
        var winner: TrackSeat?
        for tick in 0 ..< 20_000 {
            engine.step(input: .idle(tick: UInt64(tick)))
            for event in engine.lastEvents {
                switch event {
                case let .railStrike(seat, _, _) where seat == .rival: railStrikes += 1
                case let .lapCompleted(seat, _, seconds) where seat == .rival:
                    lapTimes.append(seconds)
                case let .raceFinished(who): winner = who
                default: break
                }
            }
            if engine.state.phase == .finished { break }
        }
        #expect(winner == .rival)
        #expect(railStrikes == 0)
        #expect(lapTimes.count == 3)
        #expect(engine.state.cars[.rival]!.lapsCompleted == 3)
        // A parked player banks nothing -- it falls onto the rail and stays
        // there -- so lap counting is not just a timer.
        #expect(engine.state.cars[.player]!.lapsCompleted == 0)
        #expect(engine.state.elapsed < 40)
        #expect(engine.state.cars[.rival]!.bestLapSeconds != nil)
    }

    @Test("A ship left alone falls, and thrust pushes it along its nose")
    func flightModelIsTheMatchModel() {
        var engine = afterTheLights()
        let before = engine.state.cars[.player]!
        // Hands off: nothing but gravity, and gravity is down.
        for tick in 0 ..< 30 {
            engine.step(input: .idle(tick: UInt64(tick)))
        }
        let fell = engine.state.cars[.player]!
        #expect(fell.velocity.y < before.velocity.y)
        #expect(fell.position.y < before.position.y)

        // The grid points down the bottom straight, so a burn with no lock
        // has to show up as speed along it -- and gravity has to keep pulling
        // the whole time it does, which a scalar speed along a heading could
        // never express.
        var burning = afterTheLights()
        let start = burning.state.cars[.player]!
        for tick in 0 ..< 60 {
            burning.step(input: PlayerInput(
                tick: UInt64(tick), torque: 0, thrust: true, fire: false, tractor: false
            ))
        }
        let ship = burning.state.cars[.player]!
        let configuration = TrackConfiguration()
        #expect(ship.thrustLevel == configuration.maximumThrustAcceleration)
        // Half a second of full thrust along a nose that is pointing down the
        // straight, less nothing: the arithmetic is the match's arithmetic.
        #expect(ship.velocity.x - start.velocity.x > configuration.maximumThrustAcceleration * 0.4)
        // And still falling, because thrust forward does not hold a ship up.
        #expect(ship.velocity.y < start.velocity.y)
    }

    @Test("The race is flown on the match's own tuning")
    func configurationFollowsTheSliders() {
        var snapshot = FlightTuningSnapshot.defaults
        snapshot.gravityMagnitude = 2.4
        snapshot.thrustAcceleration = 4.0
        snapshot.rotationAcceleration = 6.5
        let configuration = TrackConfiguration(flight: snapshot)
        #expect(configuration.gravity == SIMD2(0, -2.4))
        #expect(configuration.maximumThrustAcceleration == 4.0)
        #expect(configuration.initialThrustAcceleration == 4.0)
        #expect(configuration.torqueAcceleration == 6.5)
        // Nothing is bolted to a default: turn the gravity up and the race
        // flies under it.
        var engine = TrackEngine(configuration: configuration)
        #expect(engine.configuration.gravity.y == -2.4)
        var tick: UInt64 = 0
        while engine.state.phase == .countdown { engine.step(input: .idle(tick: tick)); tick &+= 1 }
        let before = engine.state.cars[.player]!.velocity.y
        engine.step(input: .idle(tick: tick))
        let after = engine.state.cars[.player]!.velocity.y
        #expect(abs((after - before) - -2.4 / 120) < 1e-9)
    }

    @Test("The race stops at the flag")
    func finishedRaceIsFrozen() {
        var engine = TrackEngine()
        for tick in 0 ..< 20_000 {
            engine.step(input: .idle(tick: UInt64(tick)))
            if engine.state.phase == .finished { break }
        }
        #expect(engine.state.phase == .finished)
        let frozen = engine.state.cars
        let elapsed = engine.state.elapsed
        for tick in 0 ..< 120 {
            engine.step(input: PlayerInput(
                tick: UInt64(tick), torque: 1, thrust: true, fire: false, tractor: false
            ))
        }
        #expect(engine.state.cars == frozen)
        #expect(engine.state.elapsed == elapsed)
        #expect(engine.lastEvents.isEmpty)
    }
}
