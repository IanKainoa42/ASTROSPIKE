import Foundation
import simd
import Testing
@testable import ASTROSPIKECore

/// Build 116: bolts shove enemy hulls, and the beam reaches enemy ships and
/// enemy bolts. Never your own side's.
@Suite("Bolts and beams on ships")
struct BoltShipTests {
    private func playing(doubles: Bool = false) -> SimulationEngine {
        var engine = SimulationEngine.testing()
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
}
