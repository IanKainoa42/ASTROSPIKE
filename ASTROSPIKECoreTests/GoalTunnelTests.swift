import Testing
import simd
@testable import ASTROSPIKECore

/// A ball that gets into the goal slot without crossing a face used to
/// drift through it and out the other side with nothing scored. Seen most
/// with the beam lock: the shut face bounced a locked ball onto the face
/// line, and the weld pushed it on in from there.
struct GoalTunnelTests {
    private func weightless() -> SimulationEngine {
        var engine = SimulationEngine.testing()
        engine.beginPlay()
        var configuration = engine.configuration
        configuration.gravity = .zero
        engine.updateConfiguration(configuration)
        // Out of the way of everything at the goal.
        engine.state.ships[.cyan]!.position = .init(-1.2, -0.5)
        engine.state.ships[.orange]!.position = .init(1.2, -0.5)
        return engine
    }

    private func mouthY(_ arena: ArenaGeometry, _ fraction: Double) -> Double {
        arena.netBottomY + (arena.portalMouthTopY - arena.netBottomY) * fraction
    }

    @Test("A ball sitting on a goal face and moving in is a goal", arguments: [1.0, -1.0])
    func ballOnTheFaceGoesIn(side: Double) {
        for fraction in [0.25, 0.5, 0.75] {
            var engine = weightless()
            let arena = engine.arena
            let limit = arena.netHalfWidth + engine.state.ball.radius
            engine.state.ball.position = SIMD2(side * limit, mouthY(arena, fraction))
            engine.state.ball.velocity = SIMD2(-side * 0.5, 0)
            let before = engine.state.match.score
            engine.step(inputs: [:])
            #expect(engine.state.match.score != before, "side \(side), mouth \(fraction): a ball driven in off the face did not score")
        }
    }

    @Test("A ball found inside the slot is put back out at its nearer face, no goal", arguments: [1.0, -1.0])
    func ballInsideTheSlotComesBackOut(side: Double) {
        var engine = weightless()
        let arena = engine.arena
        let limit = arena.netHalfWidth + engine.state.ball.radius
        // Inside the slot on `side`'s half, heading for the far face.
        engine.state.ball.position = SIMD2(side * limit * 0.5, mouthY(arena, 0.5))
        engine.state.ball.velocity = SIMD2(-side * 0.5, 0)
        let before = engine.state.match.score
        for _ in 0 ..< 60 {
            engine.step(inputs: [:])
        }
        #expect(engine.state.match.score == before, "side \(side): a ball inside the slot scored")
        #expect(engine.state.ball.position.x * side >= limit - 1e-9, "side \(side): the ball went on through, x \(engine.state.ball.position.x)")
    }
}
