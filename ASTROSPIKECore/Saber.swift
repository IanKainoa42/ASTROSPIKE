import Foundation
import simd

/// A flick of the thumb on the SABER pad while it is held.
public enum SaberFlick: String, Codable, CaseIterable, Sendable {
    case left, right, up, down
}

/// What the blade is doing. Every move is a motion of the hull and blade,
/// never a shot: the ball goes where the moving blade sends it, off the
/// angle it was met at.
public enum SaberMove: String, Codable, Sendable {
    /// A full turn to the left (anticlockwise) on the side thruster, back
    /// to exactly where the nose started.
    case spinLeft
    /// A full turn to the right.
    case spinRight
    /// A slow poke along the nose: the blade reaches out from short.
    case dink
    /// A fast chop through a part turn, swung whichever way carries the
    /// blade downward.
    case spike

    public init(_ flick: SaberFlick) {
        switch flick {
        case .left: self = .spinLeft
        case .right: self = .spinRight
        case .up: self = .dink
        case .down: self = .spike
        }
    }
}

/// One hull's saber, carried in `ShipState` so every board draws the same
/// blade and the host's hits are the guest's.
public struct SaberState: Codable, Equatable, Sendable {
    /// How far the blade is out, 0 sheathed to 1 full length.
    public var drawn: Double = 0
    public var move: SaberMove?
    /// Seconds into the move.
    public var moveTime: Double = 0
    /// The hull's angle when the move began.
    public var startAngle: Double = 0
    /// +1 anticlockwise, -1 clockwise: the way the spin or chop turns.
    public var turn: Double = 0
    /// The pilot's last flick count seen, so each flick starts one move.
    public var flickCount: UInt8 = 0

    public init() {}

    public var isOut: Bool { drawn > 0 }

    // Short keys: every hull with a blade out rides each snapshot.
    private enum CodingKeys: String, CodingKey {
        case drawn = "d", move = "m", moveTime = "t", startAngle = "a", turn = "r", flickCount = "f"
    }
}

public enum Saber {
    /// The blade's full length, from the nose tip. About one and a half
    /// default balls.
    public static let length = 0.14
    /// The blade's half thickness.
    public static let radius = 0.006
    /// Seconds to sheathe the blade. Drawing it is instant: the press is
    /// the blade.
    public static let drawTime = 0.12
    /// A blade at rest is a dead bat: a ball flown into it comes off soft.
    /// The moves are what put pace on it.
    public static let restitution = 0.35
    public static let spinDuration = 0.3
    public static let spikeDuration = 0.24
    /// How far the chop turns the hull: 150 degrees.
    public static let spikeArc = 150.0 * .pi / 180
    public static let dinkDuration = 0.22
    /// The dink starts the blade this short and reaches out to full.
    public static let dinkShort = 0.45
    /// Blade samples per step, so a spinning tip cannot pass through the
    /// smallest ball between two steps.
    public static let samples = 6

    public static func duration(of move: SaberMove) -> Double {
        switch move {
        case .spinLeft, .spinRight: spinDuration
        case .spike: spikeDuration
        case .dink: dinkDuration
        }
    }

    /// The fraction of `arc` turned `u` (0...1) of the way through a move:
    /// starts and ends at rest, quickest in the middle.
    static func turned(_ u: Double) -> Double {
        let u = min(1, max(0, u))
        return u - sin(2 * .pi * u) / (2 * .pi)
    }

    /// d(turned)/du.
    static func turnRate(_ u: Double) -> Double {
        let u = min(1, max(0, u))
        return 1 - cos(2 * .pi * u)
    }

    /// The arc a move turns the hull through, signed by `turn`.
    static func arc(of move: SaberMove) -> Double {
        switch move {
        case .spinLeft, .spinRight: 2 * .pi
        case .spike: spikeArc
        case .dink: 0
        }
    }

    /// The way a chop turns so the blade comes down. A nose already pointing
    /// at the floor comes down whichever way; one pointing near straight up
    /// chops toward the net.
    public static func spikeTurn(angle: Double, netward: Double) -> Double {
        let ax = cos(angle)
        if abs(ax) < 0.25 { return netward > 0 ? -1 : 1 }
        return ax > 0 ? -1 : 1
    }

    /// The blade's reach as a fraction of `length`: the draw times the dink's
    /// poke, if one is on.
    public static func reach(_ saber: SaberState) -> Double {
        guard saber.move == .dink else { return saber.drawn }
        let u = saber.moveTime / dinkDuration
        return saber.drawn * (dinkShort + (1 - dinkShort) * turned(u))
    }

    /// How fast the reach is growing, in lengths a second.
    public static func reachRate(_ saber: SaberState) -> Double {
        guard saber.move == .dink else { return 0 }
        let u = saber.moveTime / dinkDuration
        return saber.drawn * (1 - dinkShort) * turnRate(u) / dinkDuration
    }
}

extension ShipState {
    /// Advances the hull's saber one step: draws or sheathes the blade,
    /// starts a move on a fresh flick, and flies the move. Returns true while
    /// a move owns the hull's turn, so the stick is ignored.
    mutating func stepSaber(held: Bool, flick: SaberFlick?, flickCount: UInt8, netward: Double, dt: Double) -> Bool {
        let rate = dt / Saber.drawTime
        // A press takes the pilot's count as it stands: the last flick of an
        // earlier press is not a new one. Drawn first: a sheathed saber is
        // not stored, so a count written before the blade is out was thrown
        // away and every press after the first flick replayed that flick.
        let pressed = held && !saber.isOut
        saber.drawn = held ? 1 : max(0, saber.drawn - rate)
        if pressed { saber.flickCount = flickCount }
        // Only a held pad reads flicks, and only a new count starts a move:
        // a dropped packet repeats the last count, an idle tick sends none.
        if held {
            if flickCount != saber.flickCount {
                saber.flickCount = flickCount
                if let flick, saber.move == nil {
                    let move = SaberMove(flick)
                    saber.move = move
                    saber.moveTime = 0
                    saber.startAngle = angle
                    switch move {
                    case .spinLeft: saber.turn = 1
                    case .spinRight: saber.turn = -1
                    case .spike: saber.turn = Saber.spikeTurn(angle: angle, netward: netward)
                    case .dink: saber.turn = 0
                    }
                }
            }
        }
        guard let move = saber.move else { return false }
        saber.moveTime += dt
        let duration = Saber.duration(of: move)
        let u = saber.moveTime / duration
        let arc = Saber.arc(of: move) * saber.turn
        if arc != 0 {
            // Flown on a set profile from the start angle, not a torque: a
            // full spin lands the nose exactly where it began.
            angle = saber.startAngle + arc * Saber.turned(u)
            angularVelocity = u < 1 ? arc * Saber.turnRate(u) / duration : 0
        }
        if u >= 1 {
            saber.move = nil
            saber.moveTime = 0
            if arc != 0 { angularVelocity = 0 }
        }
        return arc != 0
    }

    /// Drops whatever the blade was doing: a stun or a lost hull.
    mutating func cancelSaberMove() {
        saber.move = nil
        saber.moveTime = 0
    }
}
