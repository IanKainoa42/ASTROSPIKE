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
        // A corner whose radius is smaller than the corridor the car has to
        // stay in is not a corner, it is a wall with a gap in it. Measure the
        // turn per unit length round the whole lap and take the worst of it.
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

        // Full lock with the throttle open puts the car into the rail well
        // inside a second, whichever way the road happens to be going.
        var struck: (before: CarState, after: CarState)?
        for tick in 0 ..< 600 {
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
        #expect(abs(hit.after.railOffset) < TrackGeometry.circuit.halfWidth - configuration.carRadius)
    }

    @Test("A stunned car answers nothing")
    func stunIgnoresTheControls() {
        var engine = afterTheLights()
        for tick in 0 ..< 600 {
            engine.step(input: PlayerInput(
                tick: UInt64(tick), torque: 1, thrust: true, fire: false, tractor: false
            ))
            if engine.state.cars[.player]!.isStunned { break }
        }
        let stunned = engine.state.cars[.player]!
        #expect(stunned.isStunned)
        let heading = stunned.heading
        // Full lock, engine open: a car that is listening would turn.
        engine.step(input: PlayerInput(tick: 999, torque: 1, thrust: true, fire: false, tractor: false))
        let after = engine.state.cars[.player]!
        #expect(after.heading == heading)
        #expect(after.speed <= stunned.speed)
    }

    @Test("One strike per contact, not one per tick of the slide")
    func strikesAreEdgeTriggered() {
        var engine = afterTheLights()
        var strikes = 0
        var stunTicksSeen = 0
        for tick in 0 ..< 200 {
            engine.step(input: PlayerInput(
                tick: UInt64(tick), torque: 1, thrust: true, fire: false, tractor: false
            ))
            strikes += engine.lastEvents.filter {
                if case .railStrike(.player, _, _) = $0 { true } else { false }
            }.count
            if engine.state.cars[.player]!.isStunned { stunTicksSeen += 1 }
        }
        // A car pinned against the railing for tens of ticks must not be
        // charged for every one of them.
        #expect(strikes >= 1)
        #expect(stunTicksSeen > strikes)
        #expect(strikes < 8)
    }

    @Test("The pace car drives three clean laps and takes the flag")
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
        // A parked player banks nothing, so lap counting is not just a timer.
        #expect(engine.state.cars[.player]!.lapsCompleted == 0)
        #expect(engine.state.elapsed < 40)
        #expect(engine.state.cars[.rival]!.bestLapSeconds != nil)
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
