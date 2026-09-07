import Testing
@testable import ASTROSPIKECore

@Suite("Bolts and exhaust wash")
struct BoltAndWashTests {
    private func playing() -> SimulationEngine {
        var engine = SimulationEngine.testing()
        engine.beginPlay()
        return engine
    }

    @Test("Firing spawns one bolt from the nose and starts the cooldown")
    func fireSpawnsBoltAndCooldown() {
        var engine = playing()
        engine.state.ball.position = .init(0.5, 0.3)
        engine.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0, thrust: false, fire: true)])
        #expect(engine.state.bolts.count == 1)
        #expect(engine.state.bolts.first?.owner == .cyan)
        #expect(engine.state.ships[.cyan]!.fireCooldownTicks > 0)
        // Ahead of the ship along its nose, which points up.
        #expect(engine.state.bolts.first!.position.y > engine.state.ships[.cyan]!.position.y)
        #expect(engine.state.bolts.first!.velocity.y > 2)
    }

    @Test("A held trigger auto-repeats only once the cooldown has elapsed")
    func heldTriggerRepeatsAtCooldown() {
        var engine = playing()
        engine.state.ball.position = .init(0.5, 0.3)
        for tick in 0 ..< 20 {
            engine.step(inputs: [.cyan: PlayerInput(tick: UInt64(tick), torque: 0, thrust: false, fire: true)])
        }
        #expect(engine.state.nextBoltID == 1)
        for tick in 20 ..< 70 {
            engine.step(inputs: [.cyan: PlayerInput(tick: UInt64(tick), torque: 0, thrust: false, fire: true)])
        }
        #expect(engine.state.nextBoltID == 2)
    }

    @Test("A bolt that reaches the ball knocks it along the nose and counts as a touch")
    func boltPunchesBallAndCountsTouch() {
        var engine = playing()
        engine.state.ball.position = .init(-0.55, -0.25)
        engine.state.ball.velocity = .zero
        engine.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0, thrust: false, fire: true)])
        var hit = false
        for tick in 1 ..< 12 {
            engine.step(inputs: [.cyan: PlayerInput(tick: UInt64(tick), torque: 0, thrust: false, fire: false)])
            if engine.state.match.shipTouches[.cyan] == 1 { hit = true; break }
        }
        #expect(hit, "the bolt never reached the ball")
        #expect(engine.state.ball.velocity.y > 0.9)
        #expect(engine.state.bolts.isEmpty, "a spent bolt is removed")
    }

    @Test("A bolt crosses the centre line and can hit a ball on the far half")
    func boltCrossesCentreLine() {
        var engine = playing()
        engine.state.ball.position = .init(0.4, 0)
        engine.state.ball.velocity = .zero
        engine.state.ships[.cyan]!.position = .init(-0.1, 0)
        engine.state.ships[.cyan]!.angle = 0 // nose toward +x
        engine.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0, thrust: false, fire: true)])
        #expect(engine.state.bolts.count == 1)
        var hit = false
        for tick in 1 ..< 60 {
            engine.step(inputs: [.cyan: PlayerInput(tick: UInt64(tick), torque: 0, thrust: false, fire: false)])
            if engine.state.match.shipTouches[.cyan] == 1 { hit = true; break }
        }
        #expect(hit, "the bolt fizzled before the far half")
        #expect(engine.state.ball.velocity.x > 0.9)
    }

    @Test("A bolt from the back wall reaches the far wall before it fizzles")
    func boltReachesTheFarWall() {
        let configuration = SimulationConfiguration()
        let arena = ArenaGeometry()
        #expect(configuration.boltSpeed * configuration.boltLifetime >= 2 * arena.halfWidth)
    }

    @Test("The trigger is dead while the ship is over the centre line")
    func noFiringFromTheOpponentsHalf() {
        var engine = playing()
        engine.state.ball.position = .init(0.8, 0.4)
        engine.state.ships[.cyan]!.position = .init(0.2, 0)
        engine.state.ships[.cyan]!.angle = 0
        engine.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0, thrust: false, fire: true)])
        #expect(engine.state.bolts.isEmpty)
        #expect(engine.state.nextBoltID == 0)
        engine.state.ships[.cyan]!.position = .init(-0.2, 0)
        engine.step(inputs: [.cyan: PlayerInput(tick: 1, torque: 0, thrust: false, fire: true)])
        #expect(engine.state.bolts.count == 1)
    }

    @Test("Exhaust shoves a ball sitting behind a thrusting ship, and it is not a touch")
    func washPushesBallDownThePlume() {
        var thrusting = playing()
        var coasting = playing()
        for engine in [0, 1] {
            var e = engine == 0 ? thrusting : coasting
            e.state.ships[.cyan]!.position = .init(-0.3, 0.1)
            e.state.ships[.cyan]!.angle = .pi / 2
            e.state.ball.position = .init(-0.3, -0.1)
            e.state.ball.velocity = .zero
            if engine == 0 { thrusting = e } else { coasting = e }
        }
        for tick in 0 ..< 30 {
            thrusting.step(inputs: [.cyan: PlayerInput(tick: UInt64(tick), torque: 0, thrust: true)])
            coasting.step(inputs: [.cyan: .idle(tick: UInt64(tick))])
        }
        #expect(thrusting.state.ball.velocity.y < coasting.state.ball.velocity.y - 0.01)
        #expect(thrusting.state.match.shipTouches[.cyan] == 0)
    }

    @Test("A ball beside the ship, outside the exhaust cone, feels nothing")
    func washIgnoresBallOutsideCone() {
        var engine = playing()
        engine.state.ships[.cyan]!.position = .init(-0.3, 0.1)
        engine.state.ships[.cyan]!.angle = .pi / 2
        engine.state.ball.position = .init(-0.1, 0.1)
        engine.state.ball.velocity = .zero
        for tick in 0 ..< 30 {
            engine.step(inputs: [.cyan: PlayerInput(tick: UInt64(tick), torque: 0, thrust: true)])
        }
        #expect(abs(engine.state.ball.velocity.x) < 0.000_1)
    }

    @Test("Space held on the keyboard reaches the engine as fire")
    func keyboardFireReachesInput() {
        #expect(KeyboardControlMapping.input(tick: 3, held: [.fire]).fire)
        #expect(!KeyboardControlMapping.input(tick: 3, held: [.thrust]).fire)
    }
}
