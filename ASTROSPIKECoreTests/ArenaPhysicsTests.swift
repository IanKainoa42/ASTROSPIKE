import Testing
@testable import ASTROSPIKECore

@Suite("Arena physics")
struct ArenaPhysicsTests {
    @Test("A straight ground roll is rejected by the goal lip")
    func straightRollDoesNotScore() {
        let ball = BallState(
            position: SIMD2(0.84, -0.70),
            velocity: SIMD2(2, 0),
            radius: 0.05
        )

        #expect(ArenaGeometry.standard.goalDefender(for: ball) == nil)
    }

    @Test("A downward backboard return enters the recessed goal")
    func downwardBankScores() {
        let ball = BallState(
            position: SIMD2(0.84, -0.70),
            velocity: SIMD2(-0.4, -1.2),
            radius: 0.05
        )

        #expect(ArenaGeometry.standard.goalDefender(for: ball) == .orange)
    }

    @Test("The net rebounds the ball")
    func netReboundsBall() {
        var engine = SimulationEngine.testing()
        engine.state.ball = BallState(
            position: SIMD2(-0.051, -0.20),
            velocity: SIMD2(2, 0),
            radius: 0.04
        )

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        #expect(engine.state.ball.velocity.x < 0)
    }

    @Test("A maximum speed ball cannot tunnel through the net")
    func fastBallCannotTunnelThroughNet() {
        var engine = SimulationEngine.testing()
        engine.state.ball = BallState(
            position: SIMD2(-0.40, -0.20),
            velocity: SIMD2(60, 0),
            radius: 0.04
        )

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        #expect(engine.state.ball.position.x < 0)
        #expect(engine.state.ball.velocity.x < 0)
    }

    @Test("A maximum speed ball cannot tunnel through a ship")
    func fastBallCannotTunnelThroughShip() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position = SIMD2(-0.40, 0.30)
        engine.state.ships[.cyan]!.velocity = .zero
        engine.state.ball = BallState(
            position: SIMD2(-0.80, 0.30),
            velocity: SIMD2(60, 0),
            radius: 0.04
        )

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        #expect(engine.state.ball.velocity.x < 0)
        #expect(engine.state.ships[.cyan]!.velocity.x > 0)
    }

    @Test("A ship strike launches a stationary ball with arcade energy")
    func movingShipLaunchesStationaryBall() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan] = ShipState(
            position: SIMD2(-0.55, 0.30),
            velocity: SIMD2(12, 0),
            angle: 0
        )
        engine.state.ball = BallState(
            position: SIMD2(-0.40, 0.30),
            velocity: .zero,
            radius: 0.045
        )

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        #expect(engine.state.ball.velocity.x > 12)
    }

    @Test("Arena rebounds preserve Rocket League style ball speed")
    func wallReboundPreservesBallSpeed() {
        var engine = SimulationEngine.testing()
        engine.state.ball = BallState(
            position: SIMD2(0.90, 0.30),
            velocity: SIMD2(6, 0),
            radius: 0.04
        )

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        #expect(engine.state.ball.velocity.x < -5.5)
    }

    @Test("Touching the net destroys a ship and awards the opponent")
    func netDestroysShip() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position = SIMD2(-0.025, -0.45)
        engine.state.ships[.cyan]!.velocity = SIMD2(1, 0)

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        #expect(engine.state.ships[.cyan]!.isDestroyed)
        #expect(engine.lastEvents.contains(.point(scoringTeam: .orange, reason: .netContact)))
    }

    @Test("Even high speed outer arena impacts never destroy ships")
    func outerArenaImpactsAreForgiving() {
        var safe = SimulationEngine.testing()
        safe.state.ships[.cyan]!.position = SIMD2(-0.5, -0.70)
        safe.state.ships[.cyan]!.velocity = SIMD2(0, -0.2)
        safe.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])
        #expect(!safe.state.ships[.cyan]!.isDestroyed)

        var crash = SimulationEngine.testing()
        crash.state.ships[.cyan]!.position = SIMD2(-0.5, -0.70)
        crash.state.ships[.cyan]!.velocity = SIMD2(0, -8)
        crash.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])
        #expect(!crash.state.ships[.cyan]!.isDestroyed)
        #expect(!crash.lastEvents.contains(.point(scoringTeam: .orange, reason: .crash)))
    }

    @Test("Ship-to-ship impacts never destroy either player")
    func shipImpactsAreForgiving() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan] = ShipState(
            position: SIMD2(-0.39, 0.40),
            velocity: SIMD2(8, 0),
            angle: 0,
            homeSide: .cyan
        )
        engine.state.ships[.orange] = ShipState(
            position: SIMD2(-0.21, 0.40),
            velocity: SIMD2(-8, 0),
            angle: .pi,
            homeSide: .cyan
        )

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        #expect(!engine.state.ships[.cyan]!.isDestroyed)
        #expect(!engine.state.ships[.orange]!.isDestroyed)
        #expect(engine.state.match.score == Score())
    }

    @Test("Any part of a ship entering enemy territory destroys it")
    func enemyTerritoryIsLethalAboveTheNet() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan] = ShipState(
            position: SIMD2(-0.06, 0.45),
            velocity: .zero,
            angle: .pi / 2
        )

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        #expect(engine.state.ships[.cyan]!.isDestroyed)
        #expect(engine.lastEvents.contains(.point(scoringTeam: .orange, reason: .netContact)))
    }
}
