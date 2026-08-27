import Testing
@testable import ASTROSPIKECore

@Suite("Pure lander motion")
struct SimulationMotionTests {
    @Test("Gravity stays light enough for deliberate aerial control")
    func gravityIsLow() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position.y = 0.4
        engine.state.ships[.cyan]!.velocity = .zero

        for tick in 0 ..< 30 {
            engine.step(inputs: [
                .cyan: .idle(tick: UInt64(tick)),
                .orange: .idle(tick: UInt64(tick)),
            ])
        }

        #expect(engine.state.ships[.cyan]!.velocity.y > -0.4)
    }

    @Test("Sustained thrust ramps well beyond its gentle initial push")
    func sustainedThrustRampsRapidly() {
        var thrusting = SimulationEngine.testing()
        var falling = SimulationEngine.testing()
        thrusting.state.ships[.cyan]!.position.y = 0
        falling.state.ships[.cyan]!.position.y = 0
        thrusting.state.ships[.cyan]!.angle = .pi / 2
        falling.state.ships[.cyan]!.angle = .pi / 2

        thrusting.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0, thrust: true)])
        falling.step(inputs: [.cyan: .idle(tick: 0)])
        let initialThrustDelta = thrusting.state.ships[.cyan]!.velocity.y
            - falling.state.ships[.cyan]!.velocity.y

        for tick in 1 ..< 30 {
            thrusting.step(inputs: [.cyan: PlayerInput(tick: UInt64(tick), torque: 0, thrust: true)])
        }
        let velocityBeforeFinalStep = thrusting.state.ships[.cyan]!.velocity.y
        thrusting.step(inputs: [.cyan: PlayerInput(tick: 30, torque: 0, thrust: true)])
        let sustainedThrustDelta = thrusting.state.ships[.cyan]!.velocity.y
            - velocityBeforeFinalStep
            - falling.state.ships[.cyan]!.velocity.y

        #expect(sustainedThrustDelta > initialThrustDelta * 2)
    }

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
