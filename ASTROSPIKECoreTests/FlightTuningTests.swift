import Foundation
import Testing
@testable import ASTROSPIKECore

@MainActor
@Suite("Flight tuning persistence")
struct FlightTuningTests {
    @Test("A fresh install plays best of three")
    func freshInstallIsBestOfThree() throws {
        try withIsolatedDefaults { defaults in
            #expect(FlightTuningSnapshot.defaults.setsToWin == 2)
            #expect(FlightTuningStore(defaults: defaults).setsToWin == 2)
        }
    }

    @Test("A pilot who already chose single game keeps it")
    func anExplicitChoiceOutranksTheNewDefault() throws {
        try withIsolatedDefaults { defaults in
            let first = FlightTuningStore(defaults: defaults)
            first.setsToWin = 1
            #expect(FlightTuningStore(defaults: defaults).setsToWin == 1)
        }
    }

    @Test("Tuned values survive store reconstruction")
    func valuesPersist() throws {
        try withIsolatedDefaults { defaults in
            let first = FlightTuningStore(defaults: defaults)
            first.gravityMagnitude = 1.4
            first.thrustAcceleration = 4.25
            first.rotationAcceleration = 2.5
            first.ballGravityMultiplier = 0.58
            first.ballDropHeight = 0.02
            first.ballDropSpeed = 0.09
            first.allowedBouncesPerHit = 4

            let restored = FlightTuningStore(defaults: defaults)
            #expect(restored.snapshot == first.snapshot)
        }
    }

    @Test("The ball ships at twice nominal and the slider carries into the physics")
    func ballSizeIsTunable() throws {
        try withIsolatedDefaults { defaults in
            // The shipped size. A bolt is 0.007 across, so at nominal the
            // edge of the ball was not a thing anyone could aim at.
            #expect(FlightTuningSnapshot.defaults.ballRadius == BallState.nominalRadius * 2)
            let store = FlightTuningStore(defaults: defaults)
            #expect(store.configuration.ballRadius == BallState.nominalRadius * 2)

            store.ballRadius = BallState.nominalRadius * 2.5
            #expect(FlightTuningStore(defaults: defaults).ballRadius == BallState.nominalRadius * 2.5)
            #expect(store.configuration.ballRadius == BallState.nominalRadius * 2.5)

            // Neither end of the slider can hand the engine a ball the court
            // was never cut for.
            store.ballRadius = BallState.nominalRadius * 12
            #expect(FlightTuningStore(defaults: defaults).ballRadius
                == BallState.nominalRadius * ArenaGeometry.maximumRadiusScale)
            store.ballRadius = 0.001
            #expect(FlightTuningStore(defaults: defaults).ballRadius == BallState.nominalRadius)
        }
    }

    @Test("Every serve stages a ball of the tuned size")
    func servesUseTheTunedBall() {
        var engine = SimulationEngine.testing()
        engine.updateConfiguration(SimulationConfiguration(ballRadius: BallState.nominalRadius * 2))
        // Immediately, so the slider is felt while flying rather than at the
        // next drop...
        #expect(engine.state.ball.radius == BallState.nominalRadius * 2)
        // ...and the next serve stages the same ball rather than a fresh
        // nominal one.
        engine.restartMatch()
        #expect(engine.state.ball.radius == BallState.nominalRadius * 2)
    }

    @Test("Reset restores every baked default")
    func resetRestoresDefaults() throws {
        try withIsolatedDefaults { defaults in
            let store = FlightTuningStore(defaults: defaults)
            store.gravityMagnitude = 3.7
            store.ballDropHeight = -0.20
            store.allowedBouncesPerHit = 5

            store.reset()

            #expect(store.snapshot == .defaults)
            #expect(store.configuration == SimulationConfiguration.online)
            #expect(defaults.object(forKey: "tuning.gravityMagnitude") == nil)
            #expect(defaults.object(forKey: "tuning.ballDropHeight") == nil)
            #expect(defaults.object(forKey: "tuning.allowedBouncesPerHit") == nil)
        }
    }

    @Test("Untouched sliders fly the same physics as an online match")
    func defaultsMatchOnlinePreset() throws {
        try withIsolatedDefaults { defaults in
            let store = FlightTuningStore(defaults: defaults)
            #expect(store.configuration == SimulationConfiguration.online)
            // Lighter than the 1.10 the online preset used to bake in on its own.
            #expect(SimulationConfiguration.online.gravity.y > -1.10)
            #expect(SimulationConfiguration.warmup.gravity == SimulationConfiguration.online.gravity)
            #expect(SimulationConfiguration.warmup.sandbox)
            // A moved slider follows the pilot into the bay and, via the
            // seating plan, onto every guest board.
            store.gravityMagnitude = 0.9
            let bay = SimulationConfiguration.warmup(from: store.configuration)
            #expect(bay.gravity.y == -0.9)
            #expect(bay.sandbox)
            #expect(store.snapshot.configuration == store.configuration)
        }
    }

    @Test("Bounce tuning reaches the simulation configuration")
    func bounceAllowanceConfiguresRules() throws {
        try withIsolatedDefaults { defaults in
            let store = FlightTuningStore(defaults: defaults)

            store.allowedBouncesPerHit = 4

            #expect(store.configuration.allowedFloorBounces == 4)
        }
    }

    private func withIsolatedDefaults(
        _ testName: String = #function,
        body: (UserDefaults) throws -> Void
    ) throws {
        let suiteName = "FlightTuningTests.\(testName).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try body(defaults)
    }
}
