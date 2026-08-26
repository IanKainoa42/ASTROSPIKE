import Testing
@testable import ASTROSPIKECore

@Suite("Pure lander motion")
struct SimulationMotionTests {
    @Test("Main thrust accelerates only along the ship nose")
    func thrustUsesCurrentHeading() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.angle = .pi / 2

        engine.step(inputs: [
            .cyan: PlayerInput(tick: 0, torque: 0, thrust: true),
            .orange: .idle(tick: 0),
        ])

        let velocity = engine.state.ships[.cyan]!.velocity
        #expect(abs(velocity.x) < 0.000_001)
        #expect(velocity.y > 0)
    }

    @Test("Releasing torque preserves angular momentum")
    func torqueReleaseDoesNotStabilizeShip() {
        var engine = SimulationEngine.testing()
        engine.step(inputs: [
            .cyan: PlayerInput(tick: 0, torque: 1, thrust: false),
            .orange: .idle(tick: 0),
        ])
        let angularVelocityAfterTorque = engine.state.ships[.cyan]!.angularVelocity
        let angleAfterTorque = engine.state.ships[.cyan]!.angle

        engine.step(inputs: [
            .cyan: .idle(tick: 1),
            .orange: .idle(tick: 1),
        ])

        #expect(angularVelocityAfterTorque > 0)
        #expect(engine.state.ships[.cyan]!.angularVelocity == angularVelocityAfterTorque)
        #expect(engine.state.ships[.cyan]!.angle > angleAfterTorque)
    }

    @Test("Torque input is clamped to its legal range")
    func torqueInputClamps() {
        #expect(PlayerInput(tick: 4, torque: 9, thrust: false).torque == 1)
        #expect(PlayerInput(tick: 4, torque: -9, thrust: false).torque == -1)
    }
}
