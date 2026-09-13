import Testing
@testable import ASTROSPIKECore

@Suite("Rally lifecycle")
struct RallyLifecycleTests {
    /// A ball pinned between a hull and the left wall, taken from a sweep of
    /// randomised near-wall situations: on the old engine this hull is struck
    /// three separate times inside seven ticks, which is the entire touch
    /// allowance gone in under 60ms.
    private func rattleAgainstTheWall(debounce: Double? = nil) -> SimulationEngine {
        var configuration = SimulationConfiguration()
        if let debounce { configuration.ballTouchDebounce = debounce }
        return SimulationEngine(
            state: WorldState(
                ships: [
                    .cyan: ShipState(
                        position: SIMD2(-0.849872, -0.460041),
                        velocity: SIMD2(1.125247, -0.726516),
                        angle: 0.507198
                    ),
                    .orange: ShipState(position: SIMD2(0.55, -0.45), angle: .pi / 2),
                ],
                ball: BallState(
                    position: SIMD2(-0.925343, -0.544544),
                    velocity: SIMD2(1.871315, -0.579135)
                ),
                match: MatchRuleState(phase: .playing)
            ),
            configuration: configuration
        )
    }

    private func flyTheRattle(_ engine: inout SimulationEngine, ticks: Int) -> Int {
        var collisions = 0
        for _ in 0 ..< ticks {
            engine.step(inputs: [
                .cyan: PlayerInput(tick: engine.state.tick, torque: 0.83083, thrust: false)
            ])
            if engine.lastEvents.contains(where: {
                if case .collisionEffect = $0 { true } else { false }
            }) { collisions += 1 }
        }
        return collisions
    }

    @Test("A ball rattling on a hull spends one touch, not three")
    func rattleCountsOnce() {
        var engine = rattleAgainstTheWall()
        let collisions = flyTheRattle(&engine, ticks: 20)

        // The hull is struck three times and still shoves the ball clear each
        // time -- the physics is untouched. Only the scoring collapses it.
        #expect(collisions == 3, "the scenario has to actually rattle to prove anything")
        #expect(engine.state.match.shipTouches[.cyan] == 1)
    }

    @Test("Without the buffer that same rattle burns the whole allowance")
    func rattleWithoutTheBufferCostsThree() {
        var engine = rattleAgainstTheWall(debounce: 0)
        _ = flyTheRattle(&engine, ticks: 20)

        #expect(engine.state.match.shipTouches[.cyan] == 3)
    }

    @Test("The buffer expires, so a real second hit still counts")
    func debounceExpires() {
        var engine = rattleAgainstTheWall()
        // Fly until the first strike arms the buffer. Which tick that is
        // depends on the size of the ball; how long the buffer runs does not.
        var flown = 0
        while engine.state.ships[.cyan]!.ballTouchCooldownTicks == 0, flown < 20 {
            _ = flyTheRattle(&engine, ticks: 1)
            flown += 1
        }
        let armed = engine.state.ships[.cyan]!.ballTouchCooldownTicks
        #expect(armed == 12, "0.1s at the 120Hz fixed step")

        _ = flyTheRattle(&engine, ticks: Int(armed))

        #expect(engine.state.ships[.cyan]!.ballTouchCooldownTicks == 0)
    }

    @Test("A conceded point never leaves a touch owed on the next rally")
    func serveClearsTheDebounce() {
        // A point leaves the hulls where they are and only re-stages the ball,
        // so a live buffer would ride into the next rally and swallow its
        // first touch. A long buffer guarantees one is still running when the
        // rally ends, which is the case the reset exists for.
        var engine = rattleAgainstTheWall()
        var tuning = engine.configuration
        tuning.ballTouchDebounce = 1.0
        engine.updateConfiguration(tuning)

        var armed = false
        var conceded = false
        for _ in 0 ..< 120 {
            _ = flyTheRattle(&engine, ticks: 1)
            if engine.state.ships[.cyan]!.ballTouchCooldownTicks > 0 { armed = true }
            if engine.lastEvents.contains(where: {
                if case .point = $0 { true } else { false }
            }) { conceded = true; break }
        }

        #expect(armed, "the hull has to arm a buffer for this to prove anything")
        #expect(conceded, "the rally has to actually end for this to prove anything")
        #expect(engine.state.ships[.cyan]!.ballTouchCooldownTicks == 0)
    }

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

    /// Just outside the cyan face at mouth height, so a 2/s drive goes through
    /// it on the next tick. Placed from the geometry, so it is still a goal
    /// whatever size the ball is.
    private static let besideTheCyanFace = SIMD2(
        -(ArenaGeometry.standard.netHalfWidth + BallState.nominalRadius + 0.004),
        0.30
    )

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
        engine.state.ball.position = Self.besideTheCyanFace
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
        engine.state.ball.position = Self.besideTheCyanFace
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
        engine.state.ball.position = Self.besideTheCyanFace
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
