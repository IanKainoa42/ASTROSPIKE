import Testing
import simd
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

    @Test("Attitude control ignores the previous held rotation direction")
    func attitudeControlDoesNotCounterSteerReleasedInput() {
        var state = SimulationEngine.testing().state
        state.ships[.orange]!.position = SIMD2(0.55, -0.70)
        state.ships[.orange]!.angle = .pi / 2
        state.ships[.orange]!.angularVelocity = 1.5
        state.ball.position = SIMD2(-0.55, 0.25)
        var controller = AIController(difficulty: .pilot)

        let afterLeftRelease = controller.input(for: state, team: .orange, tick: 0)
        state.ships[.orange]!.angularVelocity = -1.5
        let afterRightRelease = controller.input(for: state, team: .orange, tick: 1)

        // The point is that a released rotation leaves no trace: the same state
        // with opposite residual spin must produce the same command.
        #expect(afterLeftRelease.torque == afterRightRelease.torque)
    }

    @Test("AI begins retreating before the opponent-side crossing limit")
    func avoidsThrustingPastOpponentCrossingLimit() {
        var state = SimulationEngine.testing().state
        state.ships[.orange] = ShipState(
            position: SIMD2(-0.37, 0.20),
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

    @Test("AI does not treat the center line as lethal")
    func centerLineIsSafeForAI() {
        var state = SimulationEngine.testing().state
        state.ships[.orange] = ShipState(
            position: SIMD2(0.05, 0.30),
            velocity: .zero,
            angle: 0.46,
            homeSide: .orange
        )
        state.ball.position = SIMD2(-0.30, 0.30)
        var controller = AIController(difficulty: .ace)

        let input = controller.input(for: state, team: .orange, tick: 0)

        #expect(input.thrust)
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

    @Test("Pilot does not wander deep past the crossing marker")
    func pilotStaysNearItsOwnHalf() {
        var engine = SimulationEngine.testing()
        var controller = AIController(difficulty: .pilot, configuration: engine.configuration)
        let limit = engine.arena.opponentCrossingLimit
        var deepest = 0.0

        for tick in UInt64(0) ..< 3_600 {
            let input = controller.input(for: engine.state, team: .orange, tick: tick)
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: input])
            if let ship = engine.state.ships[.orange] {
                deepest = max(deepest, -ship.position.x - limit)
            }
        }

        // Crossing is legal and merely resisted, so this is about judgement rather
        // than survival: the AI should not be living in the far half.
        #expect(deepest < 0.10)
    }

    @Test("The solo AI puts a served ball back over the net")
    func soloAIReturnsTheServe() {
        for difficulty in AIDifficulty.allCases {
            var engine = SimulationEngine.testing()
            var controller = AIController(
                difficulty: difficulty,
                configuration: engine.configuration
            )
            // Staged exactly as a conceded point stages it, above the AI's half.
            engine.state.ball = BallState(position: SIMD2(0.48, 0.60), velocity: SIMD2(0, -0.18))
            var returned = false

            for tick in UInt64(0) ..< 1_200 {
                let previousX = engine.state.ball.position.x
                engine.step(inputs: [
                    .cyan: Self.stationKeeping(for: engine.state, team: .cyan, tick: tick),
                    .orange: controller.input(for: engine.state, team: .orange, tick: tick),
                ])
                guard engine.state.match.phase == .playing else { break }
                if previousX > 0, engine.state.ball.position.x < 0 {
                    returned = true
                    break
                }
            }

            #expect(returned, "\(difficulty) never returned the serve")
        }
    }

    @Test("The solo AI keeps the ball moving instead of hovering with it")
    func soloAIDoesNotHoverWithTheBall() {
        var engine = SimulationEngine.testing()
        var controller = AIController(difficulty: .pilot, configuration: engine.configuration)
        var longestContact = 0
        var contact = 0

        for tick in UInt64(0) ..< 3_600 {
            engine.step(inputs: [
                .cyan: Self.stationKeeping(for: engine.state, team: .cyan, tick: tick),
                .orange: controller.input(for: engine.state, team: .orange, tick: tick),
            ])
            guard let ship = engine.state.ships[.orange] else { break }
            let riding = simd_distance(engine.state.ball.position, ship.position) < 0.17
            contact = riding ? contact + 1 : 0
            longestContact = max(longestContact, contact)
            if engine.state.match.phase == .finished { break }
        }

        // Half a second of unbroken contact is a strike; anything longer is a stall.
        #expect(longestContact < 60)
    }

    @Test("Solo rallies are real exchanges rather than a stalled ball")
    func soloRalliesProduceExchanges() {
        for difficulty in AIDifficulty.allCases {
            var engine = SimulationEngine.testing()
            var cyan = AIController(difficulty: difficulty, configuration: engine.configuration)
            var orange = AIController(difficulty: difficulty, configuration: engine.configuration)
            var crossings = 0
            var crashes = 0

            for tick in UInt64(0) ..< 3_600 {
                let previousX = engine.state.ball.position.x
                engine.step(inputs: [
                    .cyan: cyan.input(for: engine.state, team: .cyan, tick: tick),
                    .orange: orange.input(for: engine.state, team: .orange, tick: tick),
                ])
                if engine.state.match.phase == .playing,
                   previousX * engine.state.ball.position.x < 0 {
                    crossings += 1
                }
                crashes += engine.lastEvents.filter { event in
                    guard case let .point(_, reason) = event else { return false }
                    return reason == .crash
                }.count
                if engine.state.match.phase == .finished { break }
            }

            // The prototype AI never struck the ball at all: it managed one or two
            // crossings in thirty seconds, and only because the ball drifted over.
            #expect(crossings >= 4, "\(difficulty) barely put the ball back over")
            #expect(crashes == 0, "\(difficulty) flew itself into the ground")
        }
    }

    /// Opponent stand-in that holds altitude and never chases the ball, so the
    /// rally only continues if the AI under test actually plays it.
    private static func stationKeeping(
        for state: WorldState,
        team: Team,
        tick: UInt64
    ) -> PlayerInput {
        guard let ship = state.ships[team] else { return .idle(tick: tick) }
        let upright = Double.pi / 2 - ship.angle
        let error = atan2(sin(upright), cos(upright))
        let torque = abs(error) < 0.05 ? 0 : max(-1, min(1, error * 2.4))
        let thrust = ship.position.y < -0.30 || ship.velocity.y < -0.05
        return PlayerInput(tick: tick, torque: torque, thrust: thrust)
    }
}
