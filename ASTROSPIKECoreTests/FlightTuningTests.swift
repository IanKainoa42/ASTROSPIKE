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

    @Test("Match rules survive store reconstruction")
    func valuesPersist() throws {
        try withIsolatedDefaults { defaults in
            let first = FlightTuningStore(defaults: defaults)
            first.allowedBouncesPerHit = 4
            first.setsToWin = 3

            let restored = FlightTuningStore(defaults: defaults)
            #expect(restored.snapshot == first.snapshot)
        }
    }

    @Test("Physics knobs are baked: a value left by an old slider is dropped on launch")
    func retiredSliderValuesAreForgotten() throws {
        try withIsolatedDefaults { defaults in
            // What a tester on an earlier build could have dialled in.
            defaults.set(3.7, forKey: "tuning.gravityMagnitude")
            defaults.set(BallState.nominalRadius * 3, forKey: "tuning.ballRadius")
            defaults.set(4.5, forKey: "tuning.tractorStrength")

            let store = FlightTuningStore(defaults: defaults)
            #expect(store.snapshot == .defaults)
            #expect(defaults.object(forKey: "tuning.gravityMagnitude") == nil)
            #expect(defaults.object(forKey: "tuning.ballRadius") == nil)
            #expect(defaults.object(forKey: "tuning.tractorStrength") == nil)

            // In memory it still moves, for the online preset and the bay;
            // it just never comes back on the next launch.
            store.gravityMagnitude = 1.4
            #expect(store.configuration.gravity.y == -1.4)
            #expect(FlightTuningStore(defaults: defaults).gravityMagnitude == FlightTuningSnapshot.defaults.gravityMagnitude)
        }
    }

    @Test("The ball ships at one and a half times nominal and the size carries into the physics")
    func ballSizeIsBaked() throws {
        try withIsolatedDefaults { defaults in
            // The shipped size. A bolt is 0.007 across, so at nominal the
            // edge of the ball was not a thing anyone could aim at.
            #expect(FlightTuningSnapshot.defaults.ballRadius == BallState.nominalRadius * 1.5)
            let store = FlightTuningStore(defaults: defaults)
            #expect(store.configuration.ballRadius == BallState.nominalRadius * 1.5)
            #expect(SimulationConfiguration.online.ballRadius == BallState.nominalRadius * 1.5)

            // The engine never takes a ball the court was not cut for.
            #expect(SimulationConfiguration(ballRadius: BallState.nominalRadius * 12).ballRadius
                == BallState.nominalRadius * ArenaGeometry.maximumRadiusScale)
            #expect(SimulationConfiguration(ballRadius: 0.001).ballRadius == BallState.nominalRadius)
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

    @Test("A fresh store flies the same physics as an online match")
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
