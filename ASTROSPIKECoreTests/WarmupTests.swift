import Testing
import simd
@testable import ASTROSPIKECore

@Suite("Warm-up bay")
struct WarmupTests {
    private func bay() -> SimulationEngine {
        var engine = SimulationEngine.testing()
        engine.updateConfiguration(.warmup)
        engine.state.ships[.orange] = nil
        engine.beginPlay()
        return engine
    }

    @Test("A lone pilot can fly for a long time with nobody to defend against")
    func loneShipNeverCrashesTheEngine() {
        var engine = bay()
        for tick in 0 ..< 600 {
            engine.step(inputs: [.cyan: PlayerInput(tick: UInt64(tick), torque: 0.4, thrust: tick % 7 == 0)])
        }
        #expect(engine.state.ships[.cyan] != nil)
        #expect(engine.state.ships[.orange] == nil)
        #expect(engine.state.match.phase == .playing || engine.state.match.phase == .serve)
    }

    @Test("Floor bounces reset the keep-up streak but never award a point")
    func floorIsNotAFault() {
        var engine = bay()
        // Over open floor, clear of the idle ship's spawn column: a drop onto
        // the ship counts as a touch, which resets the bounce tally.
        engine.state.ball.position = .init(-0.25, -0.2)
        engine.state.ball.velocity = .zero
        engine.state.match.shipTouches.cyan = 4
        for tick in 0 ..< 900 {
            engine.step(inputs: [.cyan: .idle(tick: UInt64(tick))])
        }
        #expect(engine.state.match.floorContacts.cyan >= 1)
        #expect(engine.state.match.shipTouches.cyan == 0)
        #expect(engine.state.match.score == Score())
        #expect(engine.state.match.phase == .playing)
    }

    @Test("Touches pile up past the match cap without anyone scoring")
    func touchesAreOnlyAStreak() {
        var engine = bay()
        engine.state.match.shipTouches.cyan = 5
        engine.state.ball.position = .init(-0.55, -0.25)
        engine.state.ball.velocity = .zero
        engine.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0, thrust: false, fire: true)])
        for tick in 1 ..< 12 {
            engine.step(inputs: [.cyan: .idle(tick: UInt64(tick))])
        }
        #expect(engine.state.match.shipTouches.cyan == 6)
        #expect(engine.state.match.score == Score())
        #expect(engine.state.match.phase == .playing)
    }

    @Test("Bolts fly the whole court in the bay")
    func boltsCrossTheCentre() {
        var engine = bay()
        engine.state.ball.position = .init(0.6, 0.4)
        engine.state.ships[.cyan]!.position = .init(-0.1, 0)
        engine.state.ships[.cyan]!.angle = 0
        engine.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0, thrust: false, fire: true)])
        for tick in 1 ..< 10 {
            engine.step(inputs: [.cyan: .idle(tick: UInt64(tick))])
        }
        #expect(engine.state.bolts.count == 1)
        #expect(engine.state.bolts.first!.position.x > 0)
    }

    @Test("The ball pops a hoop, which comes back somewhere else")
    func ballPopsHoop() {
        var rings = WarmupRings()
        let target = rings.rings[0]
        var state = SimulationEngine.testing().state
        state.ball.position = target.position
        let burst = rings.observe(state)
        #expect(burst == [target])
        #expect(rings.popped == 1)
        #expect(rings.rings.count == 3)
        #expect(!rings.rings.contains(where: { $0.id == target.id }))
        for ring in rings.rings {
            #expect(simd_length(ring.position - state.ball.position) >= 0.3)
        }
    }

    @Test("A bolt through a hoop pops it too")
    func boltPopsHoop() {
        var rings = WarmupRings()
        let target = rings.rings[1]
        var state = SimulationEngine.testing().state
        state.ball.position = .init(0.8, -0.5)
        state.bolts = [BoltState(id: 0, owner: .cyan, position: target.position, velocity: .zero, ticksRemaining: 10)]
        #expect(rings.observe(state).count == 1)
        #expect(rings.observe(state).isEmpty, "a fresh hoop is not under the same bolt")
    }

    @Test("Hoops keep clear of the goal and each other")
    func hoopsAvoidTheGoal() {
        var rings = WarmupRings()
        let arena = ArenaGeometry.standard
        var state = SimulationEngine.testing().state
        for _ in 0 ..< 40 {
            state.ball.position = rings.rings[0].position
            _ = rings.observe(state)
            for ring in rings.rings {
                let underGoal = abs(ring.position.x) < arena.humpBaseX + ring.radius
                    && ring.position.y > arena.netBottomY - 0.16
                #expect(!underGoal)
                #expect(abs(ring.position.x) < arena.halfWidth - ring.radius)
                #expect(ring.position.y > arena.floorY + ring.radius)
                #expect(ring.position.y < arena.ceilingY - ring.radius)
            }
        }
    }
}
