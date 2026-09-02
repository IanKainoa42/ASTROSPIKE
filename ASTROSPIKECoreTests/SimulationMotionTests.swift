import Foundation
import Testing
@testable import ASTROSPIKECore

@Suite("Pure lander motion")
struct SimulationMotionTests {
    @Test("A free-falling lander uses the reduced lunar gravity")
    func gravityUsesReducedLunarTuning() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position.y = 0.4
        engine.state.ships[.cyan]!.velocity = .zero

        for tick in 0 ..< 30 {
            engine.step(inputs: [
                .cyan: .idle(tick: UInt64(tick)),
                .orange: .idle(tick: UInt64(tick)),
            ])
        }

        #expect(abs(engine.state.ships[.cyan]!.velocity.y - -0.5) < 0.000_001)
    }

    @Test("Main thrust uses the reduced lunar acceleration")
    func thrustUsesReducedLunarTuning() {
        var thrusting = SimulationEngine.testing()
        var falling = SimulationEngine.testing()
        thrusting.state.ships[.cyan]!.position.y = 0.5
        falling.state.ships[.cyan]!.position.y = 0.5
        thrusting.state.ships[.cyan]!.angle = .pi / 2
        falling.state.ships[.cyan]!.angle = .pi / 2

        let dt = thrusting.configuration.stepDuration
        let initialThrustVelocity = thrusting.state.ships[.cyan]!.velocity.y
        let initialFallingVelocity = falling.state.ships[.cyan]!.velocity.y
        thrusting.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0, thrust: true)])
        falling.step(inputs: [.cyan: .idle(tick: 0)])
        let initialAcceleration = (
            thrusting.state.ships[.cyan]!.velocity.y - initialThrustVelocity
                - (falling.state.ships[.cyan]!.velocity.y - initialFallingVelocity)
        ) / dt

        for tick in 1 ..< 30 {
            thrusting.step(inputs: [.cyan: PlayerInput(tick: UInt64(tick), torque: 0, thrust: true)])
            falling.step(inputs: [.cyan: .idle(tick: UInt64(tick))])
        }
        let thrustVelocityBeforeFinalStep = thrusting.state.ships[.cyan]!.velocity.y
        let fallingVelocityBeforeFinalStep = falling.state.ships[.cyan]!.velocity.y
        thrusting.step(inputs: [.cyan: PlayerInput(tick: 30, torque: 0, thrust: true)])
        falling.step(inputs: [.cyan: .idle(tick: 30)])
        let sustainedAcceleration = (
            thrusting.state.ships[.cyan]!.velocity.y - thrustVelocityBeforeFinalStep
                - (falling.state.ships[.cyan]!.velocity.y - fallingVelocityBeforeFinalStep)
        ) / dt

        #expect(abs(initialAcceleration - 5.5) < 0.000_001)
        #expect(abs(sustainedAcceleration - 5.5) < 0.000_001)
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

    @Test("Releasing rotation input stops the ship immediately")
    func rotationStopsOnRelease() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.angle = 0.4
        engine.step(inputs: [
            .cyan: PlayerInput(tick: 0, torque: 1, thrust: false),
            .orange: .idle(tick: 0),
        ])
        let angleAfterInput = engine.state.ships[.cyan]!.angle

        #expect(abs(engine.state.ships[.cyan]!.angularVelocity - 3) < 0.000_001)
        #expect(angleAfterInput > 0.4)

        engine.step(inputs: [
            .cyan: .idle(tick: 1),
            .orange: .idle(tick: 1),
        ])

        #expect(engine.state.ships[.cyan]!.angularVelocity == 0)
        #expect(engine.state.ships[.cyan]!.angle == angleAfterInput)
    }

    @Test("Holding full rotation turns at the configured rate")
    func rotationUsesReducedLunarTuning() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position.y = 0.5
        engine.state.ships[.orange]!.position.y = 0.5
        let initialAngle = engine.state.ships[.cyan]!.angle

        for tick in 0 ..< 120 {
            engine.step(inputs: [
                .cyan: PlayerInput(tick: UInt64(tick), torque: 1, thrust: false),
                .orange: .idle(tick: UInt64(tick)),
            ])
        }

        #expect(abs(engine.state.ships[.cyan]!.angularVelocity - 3) < 0.000_001)
        #expect(abs((engine.state.ships[.cyan]!.angle - initialAngle) - 3) < 0.000_001)
    }

    @Test("Torque input is clamped to its legal range")
    func torqueInputClamps() {
        #expect(PlayerInput(tick: 4, torque: 9, thrust: false).torque == 1)
        #expect(PlayerInput(tick: 4, torque: -9, thrust: false).torque == -1)
    }

    @Test("Updated tuning takes effect on the next simulation tick")
    func liveTuningAppliesImmediately() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position.y = 0.5
        engine.state.ships[.cyan]!.angle = .pi / 2
        engine.state.ball.position = .init(-0.4, 0.5)
        engine.state.ball.velocity = .zero
        var tuning = engine.configuration
        tuning.gravity = .init(0, -1)
        tuning.initialThrustAcceleration = 4
        tuning.maximumThrustAcceleration = 4
        tuning.torqueAcceleration = 2
        tuning.ballGravityMultiplier = 0.5
        engine.updateConfiguration(tuning)

        engine.step(inputs: [
            .cyan: PlayerInput(tick: 0, torque: 1, thrust: true),
            .orange: .idle(tick: 0),
        ])

        let dt = 1.0 / 120.0
        let expectedShipAngle = .pi / 2 + 2 * dt
        let expectedVerticalVelocity = (-1 + 4 * sin(expectedShipAngle)) * dt
        #expect(abs(engine.state.ships[.cyan]!.velocity.y - expectedVerticalVelocity) < 0.000_001)
        #expect(abs(engine.state.ships[.cyan]!.angularVelocity - 2) < 0.000_001)
        #expect(abs(engine.state.ball.velocity.y - -0.5 * dt) < 0.000_001)
    }
}
