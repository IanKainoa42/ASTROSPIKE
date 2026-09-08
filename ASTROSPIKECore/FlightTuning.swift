import Foundation
import Observation

public struct FlightTuningSnapshot: Equatable, Sendable, Codable {
    public var gravityMagnitude: Double
    public var thrustAcceleration: Double
    public var rotationAcceleration: Double
    public var ballGravityMultiplier: Double
    public var ballDropHeight: Double
    public var ballDropSpeed: Double
    public var allowedBouncesPerHit: Int
    public var allowedTouchesPerSide: Int
    /// 1 = single game, 2 = best of three, 3 = best of five.
    public var setsToWin: Int

    /// The one baseline every mode flies. The online preset and the warm-up
    /// bay are built from these same numbers, so a quick game against a bot
    /// and a duel over Game Center feel identical until a slider moves.
    public static let defaults = FlightTuningSnapshot(
        gravityMagnitude: 0.5,
        thrustAcceleration: 1.75,
        rotationAcceleration: 5,
        ballGravityMultiplier: 0.2,
        ballDropHeight: 0.10,
        ballDropSpeed: 0.06,
        allowedBouncesPerHit: 3,
        allowedTouchesPerSide: 3,
        setsToWin: 1
    )

    public var configuration: SimulationConfiguration {
        SimulationConfiguration(
            gravity: .init(0, -gravityMagnitude),
            initialThrustAcceleration: thrustAcceleration,
            maximumThrustAcceleration: thrustAcceleration,
            torqueAcceleration: rotationAcceleration,
            ballGravityMultiplier: ballGravityMultiplier,
            ballDropHeight: ballDropHeight,
            ballDropSpeed: ballDropSpeed,
            allowedFloorBounces: allowedBouncesPerHit,
            allowedShipTouches: allowedTouchesPerSide
        )
    }
}

@MainActor
@Observable
public final class FlightTuningStore {
    @ObservationIgnored private let defaults: UserDefaults

    public var gravityMagnitude: Double {
        didSet { persist(gravityMagnitude, key: Keys.gravityMagnitude) }
    }
    public var thrustAcceleration: Double {
        didSet { persist(thrustAcceleration, key: Keys.thrustAcceleration) }
    }
    public var rotationAcceleration: Double {
        didSet { persist(rotationAcceleration, key: Keys.rotationAcceleration) }
    }
    public var ballGravityMultiplier: Double {
        didSet { persist(ballGravityMultiplier, key: Keys.ballGravityMultiplier) }
    }
    public var ballDropHeight: Double {
        didSet { persist(ballDropHeight, key: Keys.ballDropHeight) }
    }
    public var ballDropSpeed: Double {
        didSet { persist(ballDropSpeed, key: Keys.ballDropSpeed) }
    }
    public var allowedBouncesPerHit: Int {
        didSet { defaults.set(allowedBouncesPerHit, forKey: Keys.allowedBouncesPerHit) }
    }
    public var allowedTouchesPerSide: Int {
        didSet { defaults.set(allowedTouchesPerSide, forKey: Keys.allowedTouchesPerSide) }
    }
    public var setsToWin: Int {
        didSet { defaults.set(setsToWin, forKey: Keys.setsToWin) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let baked = FlightTuningSnapshot.defaults
        gravityMagnitude = Self.load(defaults, key: Keys.gravityMagnitude, fallback: baked.gravityMagnitude, range: 0.5 ... 4)
        thrustAcceleration = Self.load(defaults, key: Keys.thrustAcceleration, fallback: baked.thrustAcceleration, range: 1 ... 10)
        rotationAcceleration = Self.load(defaults, key: Keys.rotationAcceleration, fallback: baked.rotationAcceleration, range: 0.5 ... 8)
        ballGravityMultiplier = Self.load(defaults, key: Keys.ballGravityMultiplier, fallback: baked.ballGravityMultiplier, range: 0.1 ... 1.2)
        ballDropHeight = Self.load(defaults, key: Keys.ballDropHeight, fallback: baked.ballDropHeight, range: -0.30 ... 0.10)
        ballDropSpeed = Self.load(defaults, key: Keys.ballDropSpeed, fallback: baked.ballDropSpeed, range: 0 ... 0.8)
        allowedBouncesPerHit = Self.load(
            defaults,
            key: Keys.allowedBouncesPerHit,
            fallback: baked.allowedBouncesPerHit,
            range: 1 ... 5
        )
        allowedTouchesPerSide = Self.load(
            defaults,
            key: Keys.allowedTouchesPerSide,
            fallback: baked.allowedTouchesPerSide,
            range: 1 ... 6
        )
        setsToWin = Self.load(defaults, key: Keys.setsToWin, fallback: baked.setsToWin, range: 1 ... 3)
    }

    public var snapshot: FlightTuningSnapshot {
        FlightTuningSnapshot(
            gravityMagnitude: gravityMagnitude,
            thrustAcceleration: thrustAcceleration,
            rotationAcceleration: rotationAcceleration,
            ballGravityMultiplier: ballGravityMultiplier,
            ballDropHeight: ballDropHeight,
            ballDropSpeed: ballDropSpeed,
            allowedBouncesPerHit: allowedBouncesPerHit,
            allowedTouchesPerSide: allowedTouchesPerSide,
            setsToWin: setsToWin
        )
    }

    public var configuration: SimulationConfiguration { snapshot.configuration }

    public func reset() {
        let baked = FlightTuningSnapshot.defaults
        gravityMagnitude = baked.gravityMagnitude
        thrustAcceleration = baked.thrustAcceleration
        rotationAcceleration = baked.rotationAcceleration
        ballGravityMultiplier = baked.ballGravityMultiplier
        ballDropHeight = baked.ballDropHeight
        ballDropSpeed = baked.ballDropSpeed
        allowedBouncesPerHit = baked.allowedBouncesPerHit
        allowedTouchesPerSide = baked.allowedTouchesPerSide
        setsToWin = baked.setsToWin
        Keys.all.forEach(defaults.removeObject(forKey:))
    }

    private func persist(_ value: Double, key: String) {
        defaults.set(value, forKey: key)
    }

    private static func load(
        _ defaults: UserDefaults,
        key: String,
        fallback: Double,
        range: ClosedRange<Double>
    ) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return min(range.upperBound, max(range.lowerBound, defaults.double(forKey: key)))
    }

    private static func load(
        _ defaults: UserDefaults,
        key: String,
        fallback: Int,
        range: ClosedRange<Int>
    ) -> Int {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return min(range.upperBound, max(range.lowerBound, defaults.integer(forKey: key)))
    }

    private enum Keys {
        static let gravityMagnitude = "tuning.gravityMagnitude"
        static let thrustAcceleration = "tuning.thrustAcceleration"
        static let rotationAcceleration = "tuning.rotationAcceleration"
        static let ballGravityMultiplier = "tuning.ballGravityMultiplier"
        static let ballDropHeight = "tuning.ballDropHeight"
        static let ballDropSpeed = "tuning.ballDropSpeed"
        static let allowedBouncesPerHit = "tuning.allowedBouncesPerHit"
        static let allowedTouchesPerSide = "tuning.allowedTouchesPerSide"
        static let setsToWin = "tuning.setsToWin"
        static let all = [
            gravityMagnitude,
            thrustAcceleration,
            rotationAcceleration,
            ballGravityMultiplier,
            ballDropHeight,
            ballDropSpeed,
            allowedBouncesPerHit,
            allowedTouchesPerSide,
            setsToWin,
        ]
    }
}
