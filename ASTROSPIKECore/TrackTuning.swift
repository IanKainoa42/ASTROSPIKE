import Foundation
import Observation

/// The circuit's own dev sliders. Deliberately not part of
/// `FlightTuningSnapshot`: that one crosses the wire in the seating payload,
/// and the race has never been online. The flight model still comes off the
/// match's sliders -- the same ship, the same gravity -- and only what is
/// peculiar to racing lives here.
public struct TrackTuningSnapshot: Equatable, Sendable, Codable {
    /// Half the width of the tarmac. The loop shrinks to make room for it.
    public var laneHalfWidth: Double
    /// How long a ship stays damaged after touching a rail. Not a stun: the
    /// controls still answer, they just answer weakly.
    public var damageSeconds: Double
    /// The share of thrust and steering a damaged ship still has. Under one,
    /// so the hit costs time without taking the ship away from the pilot.
    public var damagePowerKept: Double
    /// How much of the ship's speed survives the contact itself.
    public var railSpeedKept: Double
    /// Laps to take the flag. Zero means the loop never ends.
    public var laps: Int
    /// How hard the pace ship tries.
    public var rivalPace: Double

    public init(
        laneHalfWidth: Double = TrackGeometry.defaultHalfWidth,
        damageSeconds: Double = 2.5,
        damagePowerKept: Double = 0.45,
        railSpeedKept: Double = 0.55,
        laps: Int = 0,
        rivalPace: Double = 0.88
    ) {
        self.laneHalfWidth = laneHalfWidth
        self.damageSeconds = damageSeconds
        self.damagePowerKept = damagePowerKept
        self.railSpeedKept = railSpeedKept
        self.laps = laps
        self.rivalPace = rivalPace
    }

    /// Ten seconds is the ceiling the pilot asked for, not the setting: a lap
    /// is under six seconds, so ten would leave a ship crippled for most of
    /// two of them. The default is a couple of seconds, and the slider goes
    /// all the way up for anyone who wants the ceiling.
    public static let defaults = TrackTuningSnapshot()

    /// The corridor this snapshot asks for.
    public var track: TrackGeometry {
        TrackGeometry.circuit(halfWidth: laneHalfWidth)
    }

    /// True when the race has no finish line to reach.
    public var isEndless: Bool { laps <= 0 }
}

/// The circuit sliders, persisted. Same shape as `FlightTuningStore` so the
/// settings screens read alike.
@MainActor
@Observable
public final class TrackTuningStore {
    @ObservationIgnored private let defaults: UserDefaults

    public var laneHalfWidth: Double { didSet { persist(laneHalfWidth, key: Keys.laneHalfWidth) } }
    public var damageSeconds: Double { didSet { persist(damageSeconds, key: Keys.damageSeconds) } }
    public var damagePowerKept: Double { didSet { persist(damagePowerKept, key: Keys.damagePowerKept) } }
    public var railSpeedKept: Double { didSet { persist(railSpeedKept, key: Keys.railSpeedKept) } }
    public var laps: Int { didSet { defaults.set(laps, forKey: Keys.laps) } }
    public var rivalPace: Double { didSet { persist(rivalPace, key: Keys.rivalPace) } }

    private enum Keys {
        static let laneHalfWidth = "track.laneHalfWidth"
        static let damageSeconds = "track.damageSeconds"
        static let damagePowerKept = "track.damagePowerKept"
        static let railSpeedKept = "track.railSpeedKept"
        static let laps = "track.laps"
        static let rivalPace = "track.rivalPace"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let fallback = TrackTuningSnapshot.defaults
        func read(_ key: String, _ value: Double) -> Double {
            defaults.object(forKey: key) as? Double ?? value
        }
        // A lane width saved under the old oval sits outside the circuit's
        // range. Clamp it on the way in, or the slider pins at its maximum
        // while the label still reads the stale number.
        laneHalfWidth = min(
            TrackGeometry.halfWidthLimits.maximum,
            max(TrackGeometry.halfWidthLimits.minimum, read(Keys.laneHalfWidth, fallback.laneHalfWidth))
        )
        damageSeconds = read(Keys.damageSeconds, fallback.damageSeconds)
        damagePowerKept = read(Keys.damagePowerKept, fallback.damagePowerKept)
        railSpeedKept = read(Keys.railSpeedKept, fallback.railSpeedKept)
        laps = defaults.object(forKey: Keys.laps) as? Int ?? fallback.laps
        rivalPace = read(Keys.rivalPace, fallback.rivalPace)
    }

    public var snapshot: TrackTuningSnapshot {
        TrackTuningSnapshot(
            laneHalfWidth: laneHalfWidth,
            damageSeconds: damageSeconds,
            damagePowerKept: damagePowerKept,
            railSpeedKept: railSpeedKept,
            laps: laps,
            rivalPace: rivalPace
        )
    }

    public func reset() {
        let fallback = TrackTuningSnapshot.defaults
        laneHalfWidth = fallback.laneHalfWidth
        damageSeconds = fallback.damageSeconds
        damagePowerKept = fallback.damagePowerKept
        railSpeedKept = fallback.railSpeedKept
        laps = fallback.laps
        rivalPace = fallback.rivalPace
    }

    private func persist(_ value: Double, key: String) {
        defaults.set(value, forKey: key)
    }
}
