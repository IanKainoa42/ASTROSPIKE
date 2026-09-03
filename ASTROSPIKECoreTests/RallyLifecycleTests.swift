import Testing
@testable import ASTROSPIKECore

@Suite("Rally lifecycle")
struct RallyLifecycleTests {
    @Test("A fresh rally stages the ball under the centre goal")
    func freshRallyUsesHigherDrop() {
        let engine = SimulationEngine.testing()

        #expect(engine.state.ball.position == .init(0, 0.10))
    }

    @Test("A tuned rally uses its configured ball height and drop speed")
    func tunedRallyUsesConfiguredDrop() {
        var engine = SimulationEngine.testing()
        var tuning = engine.configuration
        tuning.ballDropHeight = 0.02
        tuning.ballDropSpeed = 0.08
        engine.updateConfiguration(tuning)

        engine.prepareNextRally(mirrored: false)

        #expect(engine.state.ball.position == .init(0, 0.02))
        // Centre is directly under the goal, so a serve is released with a
        // sideways drift toward the receiving half.
        #expect(engine.state.ball.velocity == .init(-0.45, -0.08))
    }

    @Test("A point respawns only the ball, over the middle")
    func pointRespawnsOnlyBall() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan] = ShipState(
            position: .init(-0.42, 0.31),
            velocity: .init(0.7, -0.2),
            angle: 0.8,
            angularVelocity: 0,
            thrustLevel: 2.5
        )
        engine.state.ships[.orange] = ShipState(
            position: .init(0.61, 0.22),
            velocity: .init(-0.3, 0.5),
            angle: 1.9,
            angularVelocity: 0,
            thrustLevel: 1.5
        )
        engine.state.ball.position = .init(-0.06, 0.30)
        engine.state.ball.velocity = .init(2, 0)

        engine.step(inputs: [:])

        // Through the cyan face: cyan's goal, so orange's point.
        #expect(engine.state.match.score == Score(cyan: 0, orange: 1))
        #expect(engine.state.match.phase == .serve)
        #expect(engine.state.ball.position == .init(0, 0.06))
        #expect(engine.state.ball.velocity == .zero)
        #expect(engine.state.ships[.cyan]!.angle == 0.8)
        #expect(engine.state.ships[.cyan]!.position.x < 0)
        #expect(engine.state.ships[.orange]!.angle == 1.9)
        #expect(engine.state.ships[.orange]!.position.x > 0)
    }

    @Test("Ships keep flying under live input while the served ball waits")
    func shipsStayLiveDuringServe() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position = .init(-0.55, 0.25)
        engine.state.ships[.cyan]!.angle = .pi / 2
        engine.state.ball.position = .init(-0.06, 0.30)
        engine.state.ball.velocity = .init(2, 0)
        engine.step(inputs: [:])
        let heldBall = engine.state.ball
        let velocityBeforeInput = engine.state.ships[.cyan]!.velocity

        engine.step(inputs: [
            .cyan: PlayerInput(tick: engine.state.tick, torque: 1, thrust: true),
        ])

        #expect(engine.state.ball == heldBall)
        #expect(engine.state.ships[.cyan]!.velocity != velocityBeforeInput)
        #expect(engine.state.ships[.cyan]!.angularVelocity > 0)
        #expect(engine.lastEvents.contains { event in
            if case .point = event { return true }
            return false
        } == false)
    }

    @Test("The serve releases after the prototype delay without a countdown")
    func serveDropsAfterPrototypeDelay() {
        var engine = SimulationEngine.testing()
        engine.state.ball.position = .init(-0.06, 0.30)
        engine.state.ball.velocity = .init(2, 0)
        engine.step(inputs: [:])
        let heldPosition = engine.state.ball.position

        for _ in 0 ..< 161 {
            engine.step(inputs: [:])
        }

        #expect(engine.state.match.phase != .playing)
        #expect(engine.state.ball.position == heldPosition)

        engine.step(inputs: [:])

        #expect(engine.state.match.phase == .playing)
        #expect(engine.state.ball.position == heldPosition)
        // Orange took the point, so the serve drifts toward cyan, who conceded.
        #expect(engine.state.ball.velocity == .init(-0.45, -0.18))
    }

    @Test("Play no longer destroys a ship at all")
    func playNeverDestroysAShip() {
        var engine = SimulationEngine.testing()
        // Drive both ships into every former hazard at once: the floor, the net,
        // and deep past the marker.
        engine.state.ships[.cyan] = ShipState(
            position: .init(0.62, -0.70),
            velocity: .init(4, -6),
            angle: 0,
            homeSide: .cyan
        )
        engine.state.ships[.orange] = ShipState(
            position: .init(-0.04, -0.60),
            velocity: .init(-4, -6),
            angle: .pi,
            homeSide: .orange
        )

        for tick in UInt64(0) ..< 600 {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
            #expect(!engine.state.ships[.cyan]!.isDestroyed)
            #expect(!engine.state.ships[.orange]!.isDestroyed)
        }
    }
}
