import Testing
@testable import ASTROSPIKECore

@Suite("Rally lifecycle")
struct RallyLifecycleTests {
    @Test("A fresh rally stages the ball high above the center net")
    func freshRallyUsesHigherDrop() {
        let engine = SimulationEngine.testing()

        #expect(engine.state.ball.position == .init(0, 0.60))
    }

    @Test("A tuned rally uses its configured ball height and drop speed")
    func tunedRallyUsesConfiguredDrop() {
        var engine = SimulationEngine.testing()
        var tuning = engine.configuration
        tuning.ballDropHeight = 0.72
        tuning.ballDropSpeed = 0.08
        engine.updateConfiguration(tuning)

        engine.prepareNextRally(mirrored: false)

        #expect(engine.state.ball.position == .init(0, 0.72))
        #expect(engine.state.ball.velocity == .init(0, -0.08))
    }

    @Test("A point freezes, then reset enters countdown without changing score")
    func freezeResetCountdown() {
        var engine = SimulationEngine.testing()
        engine.state.ball.position = .init(0.08, -0.72)
        engine.state.ball.velocity = .init(0.4, -2)

        engine.step(inputs: [:])
        let score = engine.state.match.score
        #expect(engine.state.match.phase == .pointFreeze)

        engine.prepareNextRally(mirrored: true)
        #expect(engine.state.match.phase == .countdown)
        #expect(engine.state.match.score == score)
        #expect(engine.state.ball.position == .init(0, 0.60))
        #expect(engine.state.ships[.cyan]!.position.x > 0)

        engine.beginPlay()
        #expect(engine.state.match.phase == .playing)
    }
}
