import Foundation
import Observation

public struct FlightTuningSnapshot: Equatable, Sendable, Codable {
    public var gravityMagnitude: Double
    public var thrustAcceleration: Double
    public var rotationAcceleration: Double
    public var ballGravityMultiplier: Double
    /// How big the ball is, in arena units. Ships at twice nominal: a bolt is
    /// 0.007 across, so against a 0.042 ball clipping the edge on purpose was
    /// not a shot anyone could take, and spin arrived by accident. Rides the
    /// wire with the rest of the host's tuning, because the two boards have
    /// to agree on the size of the thing they are both simulating.
    public var ballRadius: Double
    public var ballDropHeight: Double
    public var ballDropSpeed: Double
    /// How hard the tractor beam reels the ball in. Ian's own knob -- the
    /// beam is the one control that is felt rather than seen, so the strength
    /// it pulls at is a setting rather than a baked constant.
    public var tractorStrength: Double
    public var allowedBouncesPerHit: Int
    public var allowedTouchesPerSide: Int
    /// 1 = single game, 2 = best of three, 3 = best of five. This is the one
    /// place the shipped default lives -- `MatchRuleState`'s own `setsToWin`
    /// default stays at 1 because a bare rule state is a single set by
    /// construction, not a match anybody plays.
    public var setsToWin: Int

    /// The one baseline every mode flies. The online preset and the warm-up
    /// bay are built from these same numbers, so a quick game against a bot
    /// and a duel over Game Center feel identical until a slider moves.
    public static let defaults = FlightTuningSnapshot(
        gravityMagnitude: 0.5,
        thrustAcceleration: 2.75,
        rotationAcceleration: 5.5,
        ballGravityMultiplier: 0.2,
        ballRadius: BallState.nominalRadius * 2,
        ballDropHeight: 0.10,
        ballDropSpeed: 0.06,
        tractorStrength: 2.6,
        allowedBouncesPerHit: 3,
        allowedTouchesPerSide: 3,
        setsToWin: 2
    )

    public var configuration: SimulationConfiguration {
        SimulationConfiguration(
            gravity: .init(0, -gravityMagnitude),
            initialThrustAcceleration: thrustAcceleration,
            maximumThrustAcceleration: thrustAcceleration,
            torqueAcceleration: rotationAcceleration,
            ballGravityMultiplier: ballGravityMultiplier,
            ballRadius: ballRadius,
            ballDropHeight: ballDropHeight,
            ballDropSpeed: ballDropSpeed,
            allowedFloorBounces: allowedBouncesPerHit,
            allowedShipTouches: allowedTouchesPerSide,
            tractorStrength: tractorStrength
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
    public var ballRadius: Double {
        didSet { persist(ballRadius, key: Keys.ballRadius) }
    }
    public var ballDropHeight: Double {
        didSet { persist(ballDropHeight, key: Keys.ballDropHeight) }
    }
    public var ballDropSpeed: Double {
        didSet { persist(ballDropSpeed, key: Keys.ballDropSpeed) }
    }
    public var tractorStrength: Double {
        didSet { persist(tractorStrength, key: Keys.tractorStrength) }
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
        ballRadius = Self.load(
            defaults,
            key: Keys.ballRadius,
            fallback: baked.ballRadius,
            range: BallState.nominalRadius ... BallState.nominalRadius * ArenaGeometry.maximumRadiusScale
        )
        ballDropHeight = Self.load(defaults, key: Keys.ballDropHeight, fallback: baked.ballDropHeight, range: -0.30 ... 0.10)
        ballDropSpeed = Self.load(defaults, key: Keys.ballDropSpeed, fallback: baked.ballDropSpeed, range: 0 ... 0.8)
        tractorStrength = Self.load(
            defaults,
            key: Keys.tractorStrength,
            fallback: baked.tractorStrength,
            range: 1 ... 4.5
        )
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
            ballRadius: ballRadius,
            ballDropHeight: ballDropHeight,
            ballDropSpeed: ballDropSpeed,
            tractorStrength: tractorStrength,
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
        ballRadius = baked.ballRadius
        ballDropHeight = baked.ballDropHeight
        ballDropSpeed = baked.ballDropSpeed
        tractorStrength = baked.tractorStrength
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
        static let ballRadius = "tuning.ballRadius"
        static let ballDropHeight = "tuning.ballDropHeight"
        static let ballDropSpeed = "tuning.ballDropSpeed"
        static let tractorStrength = "tuning.tractorStrength"
        static let allowedBouncesPerHit = "tuning.allowedBouncesPerHit"
        static let allowedTouchesPerSide = "tuning.allowedTouchesPerSide"
        static let setsToWin = "tuning.setsToWin"
        static let all = [
            gravityMagnitude,
            thrustAcceleration,
            rotationAcceleration,
            ballGravityMultiplier,
            ballRadius,
            ballDropHeight,
            ballDropSpeed,
            tractorStrength,
            allowedBouncesPerHit,
            allowedTouchesPerSide,
            setsToWin,
        ]
    }
}
