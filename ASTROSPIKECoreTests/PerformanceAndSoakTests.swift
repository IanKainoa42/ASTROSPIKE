import Foundation
import Testing
@testable import ASTROSPIKECore

@Suite("Performance and soak")
struct PerformanceAndSoakTests {
    @Test("Twelve thousand fixed steps average under four milliseconds")
    func fixedStepBudget() {
        var engine = SimulationEngine.testing()
        let clock = ContinuousClock()
        let start = clock.now

        for tick in UInt64(0)..<12_000 {
            engine.step(inputs: [
                .cyan: PlayerInput(tick: tick, torque: 0.35, thrust: tick.isMultiple(of: 3)),
                .orange: PlayerInput(tick: tick, torque: -0.25, thrust: tick.isMultiple(of: 4)),
            ])
            if engine.state.match.phase == .pointFreeze {
                engine.prepareNextRally(mirrored: tick.isMultiple(of: 2))
                engine.beginPlay()
            } else if engine.state.match.phase == .finished {
                engine = .testing()
            }
        }

        #expect(start.duration(to: clock.now) < .seconds(48))
    }

    @Test("Twenty match-equivalents keep finite state and bounded collections")
    func twentyMatchSoak() {
        for match in 0..<20 {
            var engine = SimulationEngine.testing()
            for tick in UInt64(0)..<2_400 {
                engine.step(inputs: [
                    .cyan: PlayerInput(tick: tick, torque: sin(Double(tick) * 0.03), thrust: tick.isMultiple(of: 2)),
                    .orange: PlayerInput(tick: tick, torque: cos(Double(tick) * 0.04), thrust: tick.isMultiple(of: 3)),
                ])
                if engine.state.match.phase == .pointFreeze {
                    engine.prepareNextRally(mirrored: (match + Int(tick)).isMultiple(of: 2))
                    engine.beginPlay()
                }
                if engine.state.match.phase == .finished { break }
            }
            #expect(engine.state.ships.count == 2)
            #expect(engine.state.ball.position.x.isFinite)
            #expect(engine.state.ball.position.y.isFinite)
            #expect(engine.state.ball.velocity.x.isFinite)
            #expect(engine.state.ball.velocity.y.isFinite)
        }
    }
}
