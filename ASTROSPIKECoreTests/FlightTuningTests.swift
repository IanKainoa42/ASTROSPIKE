import Foundation
import Testing
@testable import ASTROSPIKECore

@MainActor
@Suite("Flight tuning persistence")
struct FlightTuningTests {
    @Test("Tuned values survive store reconstruction")
    func valuesPersist() throws {
        try withIsolatedDefaults { defaults in
            let first = FlightTuningStore(defaults: defaults)
            first.gravityMagnitude = 1.4
            first.thrustAcceleration = 4.25
            first.rotationAcceleration = 2.5
            first.ballGravityMultiplier = 0.58
            first.ballDropHeight = 0.55
            first.ballDropSpeed = 0.09
            first.allowedBouncesPerHit = 4

            let restored = FlightTuningStore(defaults: defaults)
            #expect(restored.snapshot == first.snapshot)
        }
    }

    @Test("Reset restores every baked default")
    func resetRestoresDefaults() throws {
        try withIsolatedDefaults { defaults in
            let store = FlightTuningStore(defaults: defaults)
            store.gravityMagnitude = 3.7
            store.ballDropHeight = 0.30
            store.allowedBouncesPerHit = 5

            store.reset()

            #expect(store.snapshot == .defaults)
            #expect(store.configuration == SimulationConfiguration())
            #expect(defaults.object(forKey: "tuning.gravityMagnitude") == nil)
            #expect(defaults.object(forKey: "tuning.ballDropHeight") == nil)
            #expect(defaults.object(forKey: "tuning.allowedBouncesPerHit") == nil)
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
