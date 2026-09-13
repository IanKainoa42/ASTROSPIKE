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

        // The motor waits for the nose to come round before it fires, so
        // give it a moment to turn; what matters is that it does fire
        // rather than treating the centre line as something to flee.
        var thrusted = false
        for tick in UInt64(0) ..< 30 {
            let input = controller.input(for: state, team: .orange, tick: tick)
            if input.thrust { thrusted = true; break }
            state.ships[.orange]!.angle += input.torque * 3 / 120
        }

        #expect(thrusted)
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
        // Staged so the idle control is meaningful: left alone these balls drift
        // away from the net and die on the AI's own floor, so a crossing can only
        // come from the AI hitting it. A rally is chaotic, so one staging measured
        // the draw rather than the AI -- a change to how the ball bounces flipped
        // the old single staging while the AI's return rate held. A staging the
        // idle control returns on its own proves nothing and is skipped.
        var clean = 0
        var returned = 0
        for x in [0.40, 0.45, 0.50] {
            for y in [0.20, 0.25, 0.30] {
                for vx in [0.25, 0.35] {
                    let ball = BallState(position: SIMD2(x, y), velocity: SIMD2(vx, -0.15))
                    guard !Self.flyIncoming(ball, pilot: false).returned else { continue }
                    clean += 1
                    let flown = Self.flyIncoming(ball, pilot: true)
                    if flown.returned {
                        returned += 1
                        // Causation, not coincidence: the AI has to have been on the ball first.
                        #expect(flown.struck, "the ball from \(ball.position) went over without the AI ever reaching it")
                    }
                    #expect(!flown.destroyed)
                }
            }
        }

        // Measured 9 returns from 16 clean stagings, and 6 from 15 before
        // surfaces gripped the ball. The prototype AI returned none.
        #expect(clean >= 12, "the idle control crossed too often for this to prove anything")
        #expect(returned >= 4)
        #expect(returned * 4 >= clean, "the pilot returned \(returned) of \(clean)")
    }

    /// One ball drifting on the orange side, flown by the pilot AI or left to an
    /// idle ship: did it cross back, and had the AI reached it first?
    private static func flyIncoming(
        _ ball: BallState,
        pilot: Bool
    ) -> (returned: Bool, struck: Bool, destroyed: Bool) {
        var engine = SimulationEngine.testing()
        engine.state.ball = ball
        var controller = AIController(difficulty: .pilot, configuration: engine.configuration)
        var struck = false
        for tick in UInt64(0) ..< 1_200 {
            let previousX = engine.state.ball.position.x
            let input: PlayerInput = pilot
                ? controller.input(for: engine.state, team: .orange, tick: tick)
                : .idle(tick: tick)
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: input])
            if let ship = engine.state.ships[.orange],
               simd_distance(engine.state.ball.position, ship.position) < 0.14 {
                struck = true
            }
            if previousX > 0, engine.state.ball.position.x < 0 {
                return (true, struck, engine.state.ships[.orange]!.isDestroyed)
            }
            if engine.state.match.phase != .playing {
                break
            }
        }
        return (false, struck, engine.state.ships[.orange]!.isDestroyed)
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

    @Test("The solo AI puts a served ball back at the net")
    func soloAIReturnsTheServe() {
        // Staged as a conceded point stages it -- under the goal, drifting out
        // to the AI's half -- across a spread of drifts, because one serve is a
        // coin flip: a change to how the ball bounces flipped the pilot's single
        // staging while its return rate barely moved.
        var stagings: [BallState] = []
        for y in [0.04, 0.06, 0.08] {
            for vx in [0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60] {
                for vy in [-0.26, -0.22, -0.18, -0.14, -0.10] {
                    stagings.append(BallState(position: SIMD2(0, y), velocity: SIMD2(vx, vy)))
                }
            }
        }
        let idle = stagings.filter { Self.serveReturned($0, by: nil) }.count

        for difficulty in AIDifficulty.allCases {
            let returned = stagings.filter { Self.serveReturned($0, by: difficulty) }.count
            // Measured 56 rookie, 67 pilot, 67 ace of 105 against 1 idle; before
            // surfaces gripped the ball, 62, 77 and 61 against 2.
            #expect(returned >= 42, "\(difficulty) returned only \(returned) of \(stagings.count) serves")
            #expect(
                returned >= 10 * max(1, idle),
                "\(difficulty) returned \(returned), barely more than an idle ship's \(idle)"
            )
        }
    }

    /// One serve against a station-keeping opponent: did the AI -- or, with no
    /// difficulty, an idle ship -- put it back over?
    private static func serveReturned(_ ball: BallState, by difficulty: AIDifficulty?) -> Bool {
        var engine = SimulationEngine.testing()
        var controller = difficulty.map { AIController(difficulty: $0, configuration: engine.configuration) }
        engine.state.ball = ball
        for tick in UInt64(0) ..< 1_200 {
            let previousX = engine.state.ball.position.x
            engine.step(inputs: [
                .cyan: Self.stationKeeping(for: engine.state, team: .cyan, tick: tick),
                .orange: controller?.input(for: engine.state, team: .orange, tick: tick) ?? .idle(tick: tick),
            ])
            // The AI's own face is the goal it defends, so its shot goes
            // under the cap into the far half. Landing it on the far lip
            // is a goal; short of that it has still crossed.
            if engine.state.match.score.orange == 1 { return true }
            guard engine.state.match.phase == .playing else { return false }
            if previousX >= 0, engine.state.ball.position.x < 0 { return true }
        }
        return false
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

    /// Openings for the exchange test. A duel is chaotic, so a single thirty-second
    /// run is a coin flip rather than a measurement: sampled across varied openings
    /// every difficulty averages seven to nine crossings, but roughly one opening in
    /// eighteen dips below four for each of them. Judging the AI on one hard-coded
    /// opening measured the draw, not the AI.
    private static let rallyOpenings: [(x: Double, velocity: SIMD2<Double>)] = [
        (0.00, SIMD2(0.00, 0.00)),
        (-0.18, SIMD2(0.25, -0.10)),
        (0.18, SIMD2(-0.25, -0.10)),
        (0.00, SIMD2(0.25, 0.15)),
        (-0.18, SIMD2(-0.25, 0.15)),
    ]

    /// Thirty seconds from one opening: how often the ball changed sides and how
    /// many points were lost to a crash. With no difficulty both ships sit idle.
    private static func rally(
        from opening: (x: Double, velocity: SIMD2<Double>),
        difficulty: AIDifficulty?
    ) -> (crossings: Int, crashes: Int) {
        var engine = SimulationEngine.testing()
        var cyan = difficulty.map { AIController(difficulty: $0, configuration: engine.configuration) }
        var orange = difficulty.map { AIController(difficulty: $0, configuration: engine.configuration) }
        // Mid-court rather than up by the roof, which is where the
        // goal hangs now.
        engine.state.ball = BallState(
            position: SIMD2(opening.x, 0.0),
            velocity: opening.velocity
        )
        var crossings = 0
        var crashes = 0

        for tick in UInt64(0) ..< 3_600 {
            let previousX = engine.state.ball.position.x
            engine.step(inputs: [
                .cyan: cyan?.input(for: engine.state, team: .cyan, tick: tick) ?? .idle(tick: tick),
                .orange: orange?.input(for: engine.state, team: .orange, tick: tick) ?? .idle(tick: tick),
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
        return (crossings, crashes)
    }

    @Test("Solo rallies are real exchanges rather than a stalled ball")
    func soloRalliesProduceExchanges() {
        // Two idle ships still see the ball cross: 5 times across these
        // openings, with none at all from two of them. So a floor on every
        // opening measured the draw, not the AI; the idle total is the bar.
        let idleCrossings = Self.rallyOpenings.reduce(0) { total, opening in
            total + Self.rally(from: opening, difficulty: nil).crossings
        }

        for difficulty in AIDifficulty.allCases {
            var totalCrossings = 0
            var crashes = 0
            for opening in Self.rallyOpenings {
                let rally = Self.rally(from: opening, difficulty: difficulty)
                totalCrossings += rally.crossings
                crashes += rally.crashes
            }

            // The prototype AI never struck the ball at all: it managed one or two
            // crossings in thirty seconds, and only because the ball drifted over.
            // Measured totals across these five openings are 20 rookie, 21 pilot,
            // 22 ace against 5 idle, so twelve and twice idle leave headroom
            // without being meaningless.
            #expect(totalCrossings >= 12, "\(difficulty) barely put the ball back over")
            #expect(
                totalCrossings >= 2 * idleCrossings,
                "\(difficulty) managed \(totalCrossings), barely more than idle ships' \(idleCrossings)"
            )
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
        guard let ship = state.ships[team: team] else { return .idle(tick: tick) }
        let upright = Double.pi / 2 - ship.angle
        let error = atan2(sin(upright), cos(upright))
        let torque = abs(error) < 0.05 ? 0 : max(-1, min(1, error * 2.4))
        let thrust = ship.position.y < -0.30 || ship.velocity.y < -0.05
        return PlayerInput(tick: tick, torque: torque, thrust: thrust)
    }
}
