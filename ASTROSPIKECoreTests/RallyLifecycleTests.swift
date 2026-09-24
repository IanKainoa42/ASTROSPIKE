import Testing
@testable import ASTROSPIKECore

@Suite("Rally lifecycle")
struct RallyLifecycleTests {
    /// A ball pinned between a hull and the left wall, taken from a sweep of
    /// randomised near-wall situations: without the buffer this hull is struck
    /// three separate times inside a handful of ticks, which is the entire
    /// touch allowance gone in under 60ms. Re-swept when surfaces started
    /// gripping the ball, and again when hulls got their drawn-size hitbox.
    private func rattleAgainstTheWall(debounce: Double? = nil) -> SimulationEngine {
        var configuration = SimulationConfiguration()
        if let debounce { configuration.ballTouchDebounce = debounce }
        return SimulationEngine(
            state: WorldState(
                ships: [
                    .cyan: ShipState(
                        position: SIMD2(-0.858729, -0.421778),
                        velocity: SIMD2(0.377983, -0.791238),
                        angle: 2.181934
                    ),
                    .orange: ShipState(position: SIMD2(0.55, -0.45), angle: .pi / 2),
                ],
                ball: BallState(
                    position: SIMD2(-0.859656, -0.515194),
                    velocity: SIMD2(-0.763752, -0.259653)
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
                .cyan: PlayerInput(tick: engine.state.tick, torque: -0.701665, thrust: false)
            ])
            if engine.lastEvents.contains(where: {
                if case .collisionEffect = $0 { true } else { false }
            }) { collisions += 1 }
        }
        return collisions
    }

    @Test("A ball rattling on a hull tallies one touch, not three")
    func rattleCountsOnce() {
        var engine = rattleAgainstTheWall()
        let collisions = flyTheRattle(&engine, ticks: 20)

        // The hull is struck three times and still shoves the ball clear each
        // time -- the physics is untouched. Only the scoring collapses it.
        #expect(collisions == 3, "the scenario has to actually rattle to prove anything")
        #expect(engine.state.match.shipTouches[.cyan] == 1)
    }

    @Test("Without the buffer that same rattle tallies three")
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

    /// A ball dropped straight onto a cyan hull at `x`, with orange parked out
    /// of the way in its far corner.
    private func dropOntoCyan(atX x: Double) -> SimulationEngine {
        var engine = SimulationEngine.testing()
        engine.beginPlay()
        engine.state.ships[.cyan] = ShipState(position: SIMD2(x, -0.10), angle: .pi / 2, homeSide: .cyan)
        engine.state.ships[.orange] = ShipState(position: SIMD2(0.85, 0.30), angle: .pi / 2, homeSide: .orange)
        engine.state.ball = BallState(position: SIMD2(x, 0.05), velocity: SIMD2(0, -1.0))
        for tick in UInt64(0) ..< 30 {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
            if engine.state.lastBallToucher == .cyan { break }
        }
        return engine
    }

    @Test("A hull touch on your own half is tallied")
    func ownHalfTouchCounts() {
        let engine = dropOntoCyan(atX: -0.30)
        #expect(engine.state.lastBallToucher == .cyan, "the hull has to reach the ball")
        #expect(engine.state.match.shipTouches[.cyan] == 1)
    }

    @Test("A hull touch on the far half is not tallied")
    func farHalfTouchIsFree() {
        let engine = dropOntoCyan(atX: 0.30)
        #expect(engine.state.lastBallToucher == .cyan, "the hull has to reach the ball")
        #expect(engine.state.match.shipTouches[.cyan] == 0)
        #expect(engine.state.match.shipTouches[.orange] == 0)
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
        // The serve is jittered, but only in size: always toward the
        // receiving half, always down, within the tuned ranges.
        let drift = SimulationEngine.serveDriftSpeed
        let v = engine.state.ball.velocity
        #expect(v.x <= -drift * SimulationEngine.serveDriftRange.lowerBound)
        #expect(v.x >= -drift * SimulationEngine.serveDriftRange.upperBound)
        #expect(v.y <= -0.08 * SimulationEngine.serveDropRange.lowerBound)
        #expect(v.y >= -0.08 * SimulationEngine.serveDropRange.upperBound)
    }

    /// Just outside the cyan face at mouth height, so a 2/s drive goes through
    /// it on the next tick. Placed from the geometry, so it is still a goal
    /// whatever size the ball is.
    private static let besideTheCyanFace = SIMD2(
        -(ArenaGeometry.standard.netHalfWidth + BallState.nominalRadius + 0.004),
        0.30
    )

    // MARK: - Changing ends

    /// Orange a point from the first set, the ball about to go through the
    /// left face.
    private static func setPointForOrange(setsToWin: Int) -> SimulationEngine {
        SimulationEngine(state: WorldState(
            ships: [
                .cyan: ShipState(position: SIMD2(-0.55, -0.45), angle: .pi / 2),
                .orange: ShipState(position: SIMD2(0.55, -0.45), angle: .pi / 2),
            ],
            ball: BallState(position: besideTheCyanFace, velocity: SIMD2(2, 0)),
            match: MatchRuleState(score: Score(cyan: 0, orange: 6), phase: .playing, setsToWin: setsToWin)
        ))
    }

    /// The second set: cyan on the right half, orange on the left.
    private static func secondSet(ball: BallState) -> SimulationEngine {
        SimulationEngine(state: WorldState(
            ships: [
                .cyan: ShipState(position: SIMD2(0.55, -0.45), angle: .pi / 2),
                .orange: ShipState(position: SIMD2(-0.55, -0.45), angle: .pi / 2),
            ],
            ball: ball,
            match: MatchRuleState(phase: .playing, sets: Score(cyan: 0, orange: 1), setsToWin: 2),
            sidesSwapped: true
        ))
    }

    @Test("Winning a set changes ends, keeps colours, and counts down the next serve")
    func setPointChangesEnds() {
        var engine = Self.setPointForOrange(setsToWin: 2)

        engine.step(inputs: [:])

        #expect(engine.lastEvents.contains(.setEnded(winner: .orange, sets: Score(cyan: 0, orange: 1))))
        #expect(engine.state.sidesSwapped)
        #expect(engine.state.setBreak)
        #expect(engine.state.ships[.cyan]?.position == SIMD2(0.55, -0.45))
        #expect(engine.state.ships[.cyan]?.homeSide == .orange, "cyan now flies the right half")
        #expect(engine.state.ships[.orange]?.position == SIMD2(-0.55, -0.45))
        // Cyan conceded the set point, and cyan is on the right now.
        #expect(engine.state.serveDriftSign == 1)

        let breakTicks = Int((SimulationEngine.setBreakDuration / engine.configuration.stepDuration).rounded())
        for _ in 0 ..< breakTicks - 1 { engine.step(inputs: [:]) }

        #expect(engine.state.match.phase == .serve)
        #expect(engine.state.setBreak)

        engine.step(inputs: [:])

        #expect(engine.state.match.phase == .playing)
        #expect(!engine.state.setBreak)
        #expect(engine.state.ball.velocity.x > 0)
    }

    @Test("The set that wins the match does not change ends")
    func matchPointKeepsEnds() {
        var engine = Self.setPointForOrange(setsToWin: 1)

        engine.step(inputs: [:])

        #expect(engine.state.match.phase == .finished)
        #expect(!engine.state.sidesSwapped)
        #expect(!engine.state.setBreak)
    }

    @Test("After changing ends a bounce on the right half is cyan's bounce")
    func swappedFloorBelongsToTheTeamOnIt() {
        var engine = Self.secondSet(ball: BallState(position: SIMD2(0.25, -0.2)))

        for _ in 0 ..< 240 where engine.state.match.floorContacts == SideCounts() {
            engine.step(inputs: [:])
        }

        #expect(engine.state.match.floorContacts.cyan == 1)
        #expect(engine.state.match.floorContacts.orange == 0)
    }

    @Test("After changing ends the left face is orange's to defend")
    func swappedGoalFaceBelongsToTheTeamOnIt() {
        var engine = Self.secondSet(ball: BallState(position: Self.besideTheCyanFace, velocity: SIMD2(2, 0)))

        engine.step(inputs: [:])

        #expect(engine.state.match.score == Score(cyan: 1, orange: 0))
        // Orange conceded, and orange is on the left now.
        #expect(engine.state.serveDriftSign == -1)
    }

    @Test("Restarting a rally in the second set keeps the teams on their new ends")
    func restartKeepsChangedEnds() {
        var engine = Self.secondSet(ball: BallState(position: SIMD2(0, 0.10)))

        engine.prepareNextRally(mirrored: false)

        #expect(engine.state.ships[.cyan]?.position.x == 0.55)
        #expect(engine.state.ships[.orange]?.homeSide == .cyan, "orange still flies the left half")
        #expect(engine.state.ball.velocity.x > 0, "the opening drift still goes to cyan")
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

    @Test("The serve releases after its jittered delay without a countdown")
    func serveDropsAfterPrototypeDelay() {
        var engine = SimulationEngine.testing()
        engine.state.ball.position = Self.besideTheCyanFace
        engine.state.ball.velocity = .init(2, 0)
        engine.step(inputs: [:])
        let heldPosition = engine.state.ball.position
        let ticks = Int(engine.state.serveTicksRemaining)
        let stock = engine.configuration.serveDelay / engine.configuration.stepDuration
        #expect(Double(ticks) >= (stock * SimulationEngine.serveDelayRange.lowerBound).rounded(.down))
        #expect(Double(ticks) <= (stock * SimulationEngine.serveDelayRange.upperBound).rounded(.up))

        for _ in 0 ..< ticks - 1 {
            engine.step(inputs: [:])
        }

        #expect(engine.state.match.phase != .playing)
        #expect(engine.state.ball.position == heldPosition)

        engine.step(inputs: [:])

        #expect(engine.state.match.phase == .playing)
        #expect(engine.state.ball.position == heldPosition)
        // Orange took the point, so the serve drifts toward cyan, who conceded.
        #expect(engine.state.ball.velocity.x < 0)
        #expect(engine.state.ball.velocity.y < 0)
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
