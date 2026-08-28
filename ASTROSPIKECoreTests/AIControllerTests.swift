import Testing
@testable import ASTROSPIKECore

@Suite("Solo AI")
struct AIControllerTests {
    @Test("Every difficulty emits only legal player input")
    func inputsStayLegal() {
        let state = SimulationEngine.testing().state

        for difficulty in AIDifficulty.allCases {
            var controller = AIController(difficulty: difficulty)
            for tick in UInt64(0) ..< 240 {
                let input = controller.input(for: state, team: .orange, tick: tick)
                #expect((-1.0 ... 1.0).contains(input.torque))
                #expect(input.tick == tick)
            }
        }
    }

    @Test("Higher difficulties react more frequently without changing physics")
    func difficultyChangesDecisionCadenceOnly() {
        #expect(AIDifficulty.rookie.reactionIntervalTicks > AIDifficulty.pilot.reactionIntervalTicks)
        #expect(AIDifficulty.pilot.reactionIntervalTicks > AIDifficulty.ace.reactionIntervalTicks)
        #expect(AIDifficulty.rookie.physicsMultiplier == 1)
        #expect(AIDifficulty.pilot.physicsMultiplier == 1)
        #expect(AIDifficulty.ace.physicsMultiplier == 1)
    }

    @Test("A falling AI near the floor prioritizes recovery")
    func recoveryOverridesShotPlanning() {
        var state = SimulationEngine.testing().state
        state.ships[.orange]!.position = SIMD2(0.5, -0.62)
        state.ships[.orange]!.velocity = SIMD2(0, -3)
        state.ships[.orange]!.angle = -.pi / 2
        var controller = AIController(difficulty: .ace)

        let input = controller.input(for: state, team: .orange, tick: 0)

        #expect(!input.thrust)
        #expect(input.torque != 0)
    }

    @Test("Attitude control counter-steers current spin every simulation tick")
    func attitudeControlDoesNotReplayStaleTorque() {
        var state = SimulationEngine.testing().state
        state.ships[.orange]!.position = SIMD2(0.55, -0.70)
        state.ships[.orange]!.angle = .pi / 2
        state.ships[.orange]!.angularVelocity = 1.5
        state.ball.position = SIMD2(-0.55, 0.25)
        var controller = AIController(difficulty: .pilot)

        let clockwiseCorrection = controller.input(for: state, team: .orange, tick: 0)
        state.ships[.orange]!.angularVelocity = -1.5
        let counterclockwiseCorrection = controller.input(for: state, team: .orange, tick: 1)

        #expect(clockwiseCorrection.torque < 0)
        #expect(counterclockwiseCorrection.torque > 0)
    }

    @Test("AI begins retreating before it reaches the lethal center line")
    func avoidsThrustingIntoEnemyTerritory() {
        var state = SimulationEngine.testing().state
        state.ships[.orange] = ShipState(
            position: SIMD2(0.30, 0.20),
            velocity: .zero,
            angle: .pi,
            homeSide: .orange
        )
        state.ball.position = SIMD2(-0.40, 0.20)
        var controller = AIController(difficulty: .ace)

        let input = controller.input(for: state, team: .orange, tick: 0)

        #expect(!input.thrust)
        #expect(input.torque != 0)
    }

    @Test("Pilot survives ten seconds while the ball remains across the net")
    func pilotSurvivesSustainedEnemySideBait() {
        var engine = SimulationEngine.testing()
        var controller = AIController(difficulty: .pilot)

        for tick in UInt64(0) ..< 1_200 {
            engine.state.ball = BallState(
                position: SIMD2(-0.55, 0.25),
                velocity: .zero
            )
            let input = controller.input(
                for: engine.state,
                team: .orange,
                tick: tick
            )
            engine.step(inputs: [
                .cyan: .idle(tick: tick),
                .orange: input,
            ])
        }

        #expect(!engine.state.ships[.orange]!.isDestroyed)
    }

    @Test("Pilot returns an incoming ball instead of merely surviving beside it")
    func pilotReturnsIncomingBall() {
        let incomingBall = BallState(
            position: SIMD2(0.58, 0.32),
            velocity: SIMD2(-0.10, -0.20)
        )
        var idleEngine = SimulationEngine.testing()
        idleEngine.state.ball = incomingBall
        var idleBallCrossed = false
        for tick in UInt64(0) ..< 1_200 {
            let previousX = idleEngine.state.ball.position.x
            idleEngine.step(inputs: [
                .cyan: .idle(tick: tick),
                .orange: .idle(tick: tick),
            ])
            if previousX > 0, idleEngine.state.ball.position.x < 0 {
                idleBallCrossed = true
                break
            }
            if idleEngine.state.match.phase != .playing {
                break
            }
        }

        var engine = SimulationEngine.testing()
        engine.state.ball = incomingBall
        var controller = AIController(difficulty: .pilot)
        var returnedBall = false

        for tick in UInt64(0) ..< 1_200 {
            let previousX = engine.state.ball.position.x
            let input = controller.input(for: engine.state, team: .orange, tick: tick)
            engine.step(inputs: [
                .cyan: .idle(tick: tick),
                .orange: input,
            ])
            if previousX > 0, engine.state.ball.position.x < 0 {
                returnedBall = true
                break
            }
            if engine.state.match.phase != .playing {
                break
            }
        }

        #expect(!idleBallCrossed)
        #expect(returnedBall)
        #expect(!engine.state.ships[.orange]!.isDestroyed)
    }

    @Test("Pilot concedes no net deaths during thirty seconds of solo rallies")
    func pilotAvoidsNetDeathsAcrossRallies() {
        var engine = SimulationEngine.testing()
        var controller = AIController(difficulty: .pilot)
        var netDeaths = 0

        for tick in UInt64(0) ..< 3_600 {
            let input = controller.input(
                for: engine.state,
                team: .orange,
                tick: tick
            )
            engine.step(inputs: [
                .cyan: .idle(tick: tick),
                .orange: input,
            ])
            if engine.lastEvents.contains(
                .point(scoringTeam: .cyan, reason: .netContact)
            ) {
                netDeaths += 1
            }
        }

        #expect(netDeaths == 0)
    }
}
