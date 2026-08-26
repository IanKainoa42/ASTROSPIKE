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
}
