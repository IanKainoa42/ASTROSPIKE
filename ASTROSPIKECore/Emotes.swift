import Foundation

/// A celebration a pilot can play on their own ship, seen by everyone on the
/// court. Purely cosmetic: it never touches the simulation, so one fired
/// mid-rally cannot move a hull, a ball, or a point.
public enum Emote: String, Codable, CaseIterable, Hashable, Sendable {
    case barrelRoll
    case victoryBounce
    case fireworks
    case rainbow
    case shockwave
    case wave

    public var name: String {
        switch self {
        case .barrelRoll: "Barrel Roll"
        case .victoryBounce: "Victory Bounce"
        case .fireworks: "Fireworks"
        case .rainbow: "Rainbow"
        case .shockwave: "Shockwave"
        case .wave: "GG"
        }
    }

    /// Shown on the picker and floated over the ship as it plays.
    public var glyph: String {
        switch self {
        case .barrelRoll: "🌀"
        case .victoryBounce: "🕺"
        case .fireworks: "🎆"
        case .rainbow: "🌈"
        case .shockwave: "💥"
        case .wave: "👋"
        }
    }

    /// Seconds the ship animates for.
    public var duration: Double {
        switch self {
        case .barrelRoll: 0.9
        case .victoryBounce: 1.2
        case .fireworks: 1.4
        case .rainbow: 1.6
        case .shockwave: 1.0
        case .wave: 1.2
        }
    }

    /// When, as a fraction of `duration`, the scene sets off a burst around
    /// the ship -- fireworks, rings, sparkles. The hull's own motion is `pose`.
    public var bursts: [Double] {
        switch self {
        case .barrelRoll: [0, 0.5]
        case .victoryBounce: [0.25, 0.75]
        case .fireworks: [0, 0.3, 0.6]
        case .rainbow: [0]
        case .shockwave: [0, 0.2, 0.4]
        case .wave: [0]
        }
    }

    /// How the hull is drawn `t` of the way through (0...1).
    ///
    /// Emotes play mid-rally, so two promises hold for every emote at every
    /// `t`: the nose never turns -- a shot goes where the nose points, and
    /// the pilot is still aiming -- and the hull is never drawn bigger than
    /// it is, because the drawn hull is the hitbox. There is no rotation in
    /// a pose at all, and both scales stay within 1. A barrel roll is a roll
    /// about the long axis: the hull narrows to an edge and flips through.
    public func pose(at t: Double) -> EmotePose {
        guard t > 0, t < 1 else { return .rest }
        switch self {
        case .barrelRoll:
            // Two full rolls, easing out.
            let eased = 1 - (1 - t) * (1 - t)
            return EmotePose(scaleX: cos(eased * 4 * .pi), scaleY: 1, glow: 1 + 0.6 * sin(t * .pi))
        case .victoryBounce:
            // Four beats of squash and stretch, never past full size.
            let beat = sin(t * 8 * .pi)
            return EmotePose(
                scaleX: 1 - 0.22 * max(0, beat),
                scaleY: 1 - 0.22 * max(0, -beat),
                glow: 1 + 0.4 * abs(beat)
            )
        case .fireworks:
            return EmotePose(scaleX: 1, scaleY: 1, glow: 1 + 0.8 * sin(t * .pi))
        case .rainbow:
            return EmotePose(scaleX: 1, scaleY: 1, hue: (t * 2).truncatingRemainder(dividingBy: 1), glow: 1.8)
        case .shockwave:
            // Gathers itself, then lets go.
            let crouch = t < 0.2 ? t / 0.2 : max(0, 1 - (t - 0.2) / 0.15)
            return EmotePose(scaleX: 1 - 0.18 * crouch, scaleY: 1 - 0.18 * crouch, glow: 1 + 1.4 * crouch)
        case .wave:
            return EmotePose(scaleX: 1, scaleY: 1, glow: 1 + 0.5 * abs(sin(t * 3 * .pi)))
        }
    }
}

public struct EmotePose: Equatable, Sendable {
    /// Across the hull. Negative is the hull seen from its other side.
    public var scaleX: Double
    /// Along the hull, nose to tail.
    public var scaleY: Double
    /// When set, the hull is drawn in this hue (0...1) instead of its team's.
    public var hue: Double?
    /// Multiplies the hull's glow.
    public var glow: Double

    public init(scaleX: Double, scaleY: Double, hue: Double? = nil, glow: Double = 1) {
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.hue = hue
        self.glow = glow
    }

    public static let rest = EmotePose(scaleX: 1, scaleY: 1)
}

/// One emote per pilot per `interval`, so a taunt stays a taunt and a peer
/// cannot flood the court with effects.
public struct EmoteCooldown: Sendable {
    public static let interval: TimeInterval = 3

    public let interval: TimeInterval
    private var last: TimeInterval?

    public init(interval: TimeInterval = EmoteCooldown.interval) {
        self.interval = interval
    }

    /// Seconds until the next emote is allowed; zero when it is.
    public func remaining(at now: TimeInterval) -> TimeInterval {
        guard let last else { return 0 }
        return max(0, interval - (now - last))
    }

    /// Spends the cooldown if it is ready. False means the emote is refused.
    public mutating func attempt(at now: TimeInterval) -> Bool {
        guard remaining(at: now) == 0 else { return false }
        last = now
        return true
    }
}
