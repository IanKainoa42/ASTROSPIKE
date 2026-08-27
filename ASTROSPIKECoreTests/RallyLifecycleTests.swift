import Testing
@testable import ASTROSPIKECore

@Suite("Rally lifecycle")
struct RallyLifecycleTests {
    @Test("A point freezes, then reset enters countdown without changing score")
    func freezeResetCountdown() {
        var engine = SimulationEngine.testing()
        engine.state.ball.position = .init(0.82, -0.62)
        engine.state.ball.velocity = .init(-0.4, -2)

        engine.step(inputs: [:])
        let score = engine.state.match.score
        #expect(engine.state.match.phase == .pointFreeze)

        engine.prepareNextRally(mirrored: true)
        #expect(engine.state.match.phase == .countdown)
        #expect(engine.state.match.score == score)
        #expect(engine.state.ball.position == .init(0, 0.28))
        #expect(engine.state.ships[.cyan]!.position.x > 0)

        engine.beginPlay()
        #expect(engine.state.match.phase == .playing)
    }
}
