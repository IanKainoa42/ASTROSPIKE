import Foundation
import simd
import Testing
@testable import ASTROSPIKECore

/// Build 116: bolts shove enemy hulls, and the beam reaches enemy ships and
/// enemy bolts. Never your own side's.
@Suite("Bolts and beams on ships")
struct BoltShipTests {
    private func playing(doubles: Bool = false, hit: BoltHit = .shove) -> SimulationEngine {
        var engine = SimulationEngine.testing()
        var configuration = engine.configuration
        configuration.boltHit = hit
        engine.updateConfiguration(configuration)
        if doubles { engine.configureRoster(Seat.doubles) }
        engine.beginPlay()
        // The ball well out of every test's way.
        engine.state.ball.position = .init(0, 0.45)
        engine.state.ball.velocity = .zero
        return engine
    }

    /// Cyan on its own half, nose turned toward orange `gap` ahead of it,
    /// both clear of the ball, the hump and the crossing line.
    private func facingOff(gap: Double) -> SimulationEngine {
        var engine = playing()
        engine.state.ball.position = .init(0.6, 0.45)
        engine.state.ships[.cyan]!.position = .init(-0.6, -0.2)
        engine.state.ships[.cyan]!.angle = 0
        engine.state.ships[.orange]!.position = .init(-0.6 + gap, -0.2)
        return engine
    }

    private func bolt(_ owner: Team, at position: SIMD2<Double>, heading: SIMD2<Double>) -> BoltState {
        BoltState(id: 900, owner: owner, position: position,
                  velocity: simd_normalize(heading) * 2.6, ticksRemaining: 60)
    }

    /// Steps both engines alike, the second with `tractor` held by cyan.
    private func run(_ engine: inout SimulationEngine, steps: Int, tractor: Bool = false) -> [SimulationEvent] {
        var events: [SimulationEvent] = []
        for tick in 0..<steps {
            engine.step(inputs: [.cyan: PlayerInput(tick: UInt64(tick), torque: 0, thrust: false, tractor: tractor)])
            events += engine.lastEvents
        }
        return events
    }

    private func zapped(_ events: [SimulationEvent], _ seat: Seat) -> Bool {
        events.contains { if case let .shipZapped(hit, _) = $0 { hit == seat } else { false } }
    }

    @Test("An enemy bolt shoves the hull down its line, and is not a touch")
    func boltKnocksEnemyHull() {
        var baseline = playing()
        var engine = baseline
        let ship = engine.state.ships[.cyan]!
        engine.state.bolts = [bolt(.orange, at: ship.position + .init(0.15, 0), heading: .init(-1, 0))]
        let events = run(&engine, steps: 10)
        _ = run(&baseline, steps: 10)
        #expect(zapped(events, .cyan))
        #expect(engine.state.bolts.isEmpty, "the bolt dies on the hull")
        let shove = engine.state.ships[.cyan]!.velocity - baseline.state.ships[.cyan]!.velocity
        #expect(shove.x < -0.3, "shoved \(shove)")
        #expect(abs(engine.state.ships[.cyan]!.angle - baseline.state.ships[.cyan]!.angle) < 1e-9, "aim untouched")
        #expect(engine.state.match.shipTouches[.cyan] == 0)
    }

    @Test("A bolt flies through its own side's hulls")
    func ownBoltPassesThrough() {
        var engine = playing(doubles: true)
        let wing = engine.state.ships[.wing(.cyan)]!
        engine.state.bolts = [bolt(.cyan, at: wing.position + .init(0.15, 0), heading: .init(-1, 0))]
        let events = run(&engine, steps: 10)
        #expect(!zapped(events, .wing(.cyan)))
        #expect(engine.state.bolts.count == 1, "still flying past the teammate")
    }

    /// A turned hull, so a sign slip in the world-to-ship transform shows.
    @Test("On a turned hull a bolt clipping the nose hits; one just wide misses")
    func noseClipOnTurnedHull() {
        for (offset, hits) in [(-0.005, true), (BoltState.radius + 0.01, false)] {
            var engine = playing()
            engine.state.ships[.cyan]!.angle = 0.3
            let ship = engine.state.ships[.cyan]!
            let axis = SIMD2(cos(ship.angle), sin(ship.angle))
            let left = SIMD2(-axis.y, axis.x)
            let reach = (engine.shipHitboxes[.cyan] ?? .shared).noseReach
            let mark = ship.position + axis * (reach + offset)
            engine.state.bolts = [bolt(.orange, at: mark + left * 0.15, heading: -left)]
            let events = run(&engine, steps: 12)
            #expect(zapped(events, .cyan) == hits, "offset \(offset)")
        }
    }

    @Test("The beam draws an enemy ship in and the puller out, evenly")
    func beamPullsEnemyShip() {
        var baseline = facingOff(gap: 0.3)
        var engine = baseline
        _ = run(&baseline, steps: 1)
        _ = run(&engine, steps: 1, tractor: true)
        let target = engine.state.ships[.orange]!.velocity - baseline.state.ships[.orange]!.velocity
        let puller = engine.state.ships[.cyan]!.velocity - baseline.state.ships[.cyan]!.velocity
        #expect(target.x < 0, "the target is drawn toward the nose")
        #expect(puller.x > 0, "the puller is drawn toward the target")
        #expect(simd_length(target + puller) < 1e-9, "equal hulls, equal and opposite")
    }

    @Test("Held half a second, the beam closes a visible gap")
    func beamPullIsFelt() {
        var baseline = facingOff(gap: 0.35)
        var engine = baseline
        let steps = Int((0.5 / engine.configuration.stepDuration).rounded())
        _ = run(&baseline, steps: steps)
        _ = run(&engine, steps: steps, tractor: true)
        func gap(_ e: SimulationEngine) -> Double { e.state.ships[.orange]!.position.x - e.state.ships[.cyan]!.position.x }
        let closed = gap(baseline) - gap(engine)
        #expect(closed > 0.1, "closed \(closed) in half a second")
    }

    @Test("The beam leaves a teammate alone")
    func beamIgnoresTeammate() {
        var baseline = playing(doubles: true)
        baseline.state.ships[.cyan]!.position = .init(-0.6, -0.35)
        baseline.state.ships[.wing(.cyan)]!.position = .init(-0.6, -0.05)
        var engine = baseline
        _ = run(&baseline, steps: 1)
        _ = run(&engine, steps: 1, tractor: true)
        #expect(engine.state.ships[.wing(.cyan)]!.velocity == baseline.state.ships[.wing(.cyan)]!.velocity)
    }

    @Test("An enemy bolt through the cone hooks visibly and keeps its speed")
    func beamBendsEnemyBolt() {
        var engine = playing()
        engine.state.ships[.cyan]!.position = .init(-0.5, -0.4)
        let ship = engine.state.ships[.cyan]!
        let start = ship.position + .init(0.35, 0.3)
        engine.state.bolts = [bolt(.orange, at: start, heading: .init(-1, 0))]
        var deflection = 0.0
        for tick in 0..<40 {
            engine.step(inputs: [.cyan: PlayerInput(tick: UInt64(tick), torque: 0, thrust: false, tractor: true)])
            guard let flying = engine.state.bolts.first else { break }
            #expect(abs(simd_length(flying.velocity) - 2.6) < 1e-9)
            deflection = max(deflection, acos(min(1, simd_dot(simd_normalize(flying.velocity), SIMD2(-1, 0)))))
        }
        #expect(deflection > 12 * .pi / 180, "hooked \(deflection * 180 / .pi) degrees")
    }

    @Test("A pilot's own beam does not bend their own bolt")
    func ownBeamLeavesOwnBolt() {
        var engine = playing()
        let ship = engine.state.ships[.cyan]!
        engine.state.bolts = [bolt(.cyan, at: ship.position + .init(0.12, 0.3), heading: .init(-1, 0))]
        _ = run(&engine, steps: 5, tractor: true)
        #expect(engine.state.bolts.first?.velocity == SIMD2(-2.6, 0))
    }

    @Test("A bolt reeled onto the nose is caught, not a zap")
    func beamCatchesBolt() {
        var baseline = playing()
        let ship = baseline.state.ships[.cyan]!
        baseline.state.bolts = [bolt(.orange, at: ship.position + .init(0, 0.3), heading: .init(0, -1))]
        var engine = baseline
        let caught = run(&engine, steps: 20, tractor: true)
        #expect(!zapped(caught, .cyan))
        #expect(engine.state.bolts.isEmpty, "the bolt dies on the nose")
        let struck = run(&baseline, steps: 20)
        #expect(zapped(struck, .cyan), "with the beam off the same bolt zaps")
    }

    // MARK: Build 125: what a hit does besides the shove

    /// An orange bolt fired straight at cyan's hull from its right, `lift`
    /// above its middle (the hull is nose-up, so lift is toward the nose).
    private func struck(_ hit: BoltHit, lift: Double = 0) -> SimulationEngine {
        var engine = playing(hit: hit)
        let ship = engine.state.ships[.cyan]!
        engine.state.bolts = [bolt(.orange, at: ship.position + .init(0.12, lift), heading: .init(-1, 0))]
        return engine
    }

    @Test("Spin: a hit knocks the hull round, then the knock bleeds away")
    func spinRedirects() {
        var engine = struck(.spin, lift: 0.02)
        var baseline = playing(hit: .spin)
        let events = run(&engine, steps: 100)
        _ = run(&baseline, steps: 100)
        #expect(zapped(events, .cyan))
        let turned = abs(engine.state.ships[.cyan]!.angle - baseline.state.ships[.cyan]!.angle)
        #expect(turned > 15 * .pi / 180 && turned < 60 * .pi / 180, "turned \(turned * 180 / .pi) degrees")
        #expect(engine.state.ships[.cyan]!.knockSpin == 0, "the knock is spent inside a second")
    }

    @Test("Spin: a hit either side of the middle turns the hull opposite ways")
    func spinFollowsTheLever() {
        var above = struck(.spin, lift: 0.02)
        var below = struck(.spin, lift: -0.02)
        _ = run(&above, steps: 30)
        _ = run(&below, steps: 30)
        let up = above.state.ships[.cyan]!.angle - .pi / 2
        let down = below.state.ships[.cyan]!.angle - .pi / 2
        #expect(up * down < 0, "above \(up), below \(down)")
    }

    @Test("Stun: the stick is dead for a moment, then the pilot has it back")
    func stunBreaksRhythm() {
        var engine = struck(.stun)
        // Run the bolt in with no input, then hold thrust.
        while engine.state.ships[.cyan]!.stunTicks == 0, engine.state.tick < 30 {
            engine.step(inputs: [.cyan: .idle(tick: engine.state.tick)])
        }
        let stun = engine.state.ships[.cyan]!.stunTicks
        #expect(stun > 30, "stunned \(stun) ticks")
        for _ in 0 ..< 10 {
            engine.step(inputs: [.cyan: PlayerInput(tick: engine.state.tick, torque: 1, thrust: true, fire: true)])
        }
        #expect(engine.state.ships[.cyan]!.thrustLevel == 0, "no thrust while stunned")
        #expect(engine.state.bolts.isEmpty, "no trigger while stunned")
        for _ in 0 ..< Int(stun) {
            engine.step(inputs: [.cyan: PlayerInput(tick: engine.state.tick, torque: 0, thrust: true)])
        }
        #expect(engine.state.ships[.cyan]!.thrustLevel > 0, "thrust back once the stun lifts")
    }

    @Test("Stun: a stream of bolts cannot hold a pilot down")
    func stunCannotChain() {
        var engine = playing(hit: .stun)
        var stunnedTicks = 0
        let total = 360
        for tick in 0 ..< total {
            // A fresh bolt every cooldown, from both enemy seats' worth of fire.
            if tick % 27 == 0 {
                let ship = engine.state.ships[.cyan]!
                engine.state.bolts.append(BoltState(id: UInt64(1000 + tick), owner: .orange,
                                                    position: ship.position + .init(0.08, 0),
                                                    velocity: .init(-2.6, 0), ticksRemaining: 60))
            }
            engine.step(inputs: [.cyan: .idle(tick: UInt64(tick))])
            if engine.state.ships[.cyan]!.stunTicks > 0 { stunnedTicks += 1 }
        }
        #expect(stunnedTicks < total / 2, "stunned \(stunnedTicks) of \(total) ticks")
    }

    @Test("Shove alone leaves the stick live and the nose where it was")
    func shoveOnly() {
        var engine = struck(.shove, lift: 0.02)
        _ = run(&engine, steps: 30)
        #expect(engine.state.ships[.cyan]!.stunTicks == 0)
        #expect(engine.state.ships[.cyan]!.knockSpin == 0)
        #expect(abs(engine.state.ships[.cyan]!.angle - .pi / 2) < 1e-9)
    }
}
