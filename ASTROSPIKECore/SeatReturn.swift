import Foundation

// A pilot whose phone left a live match -- the app went to the background,
// or they walked out -- still has a chair: the others hold it for a while.
// Getting back used to need Apple's banner, the call-back invite the board
// holding the chair sends. That banner lands while the app is closed and is
// easy to lose, and coming back to the app offered no way in.
//
// RETURN TO MATCH is the way in. Both ends work out the same private
// automatch pool from the chairs they were sitting in. The returning pilot
// searches it and says so in the lobby; the board holding the chair sees
// that and opens the chair to the pool, and GameKit puts them back in the
// same match with no banner on either phone.

/// The pool and the time limit for getting back into one match.
public enum SeatReturn {
    /// The pool both ends search, from who was seated. Order-free, stable
    /// across processes, never 0 (every quick match searches 0), and salted
    /// apart from an invite's pool.
    public static func group(seated: some Sequence<String>) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in "return|\(seated.sorted().joined(separator: "|"))".utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let group = Int(hash & 0x7FFF_FFFF)
        return group == 0 ? 1 : group
    }

    /// What the returning pilot's presence says while it searches.
    public static func tag(group: Int) -> String { "rj:\(group)" }

    /// True when `pilot` -- whose chair this board is holding -- is in the
    /// app right now and searching this match's pool.
    public static func isReturning(_ presence: PilotPresence?, pilot: String, group: Int, at now: Date) -> Bool {
        guard let presence, presence.id == pilot,
              now.timeIntervalSince(presence.updatedAt) <= InviteRouting.presenceWindow else { return false }
        return presence.matchID == tag(group: group)
    }
}

/// What a pilot who left a match keeps, so they can come back to it.
public struct SeatReturnTicket: Equatable, Sendable {
    /// Everyone seated when they left, them included.
    public var seated: Set<String>
    public var localID: String
    /// The other pilots, for the button: "VS MAYA".
    public var opponentNames: [String]
    /// Their chair and who was running the rules, so the board knows which
    /// seating plan to believe when it is back.
    public var seat: Seat?
    public var hostID: String?
    /// Their own clock stops while the phone is suspended; the others'
    /// does not. This is the wall-clock moment the chair is given up.
    public var until: Date

    /// Short of the others' hold: their clock starts when they notice the
    /// silence, a few seconds after this one left, and a search that lands
    /// on the last second still has to connect.
    public static let margin: TimeInterval = 10

    public init(seated: Set<String>, localID: String, opponentNames: [String], seat: Seat?, hostID: String?, leftAt: Date, holdSeconds: Int) {
        self.seated = seated
        self.localID = localID
        self.opponentNames = opponentNames
        self.seat = seat
        self.hostID = hostID
        until = leftAt.addingTimeInterval(TimeInterval(holdSeconds) - Self.margin)
    }

    public var group: Int { SeatReturn.group(seated: seated) }
    public var others: Set<String> { seated.subtracting([localID]) }

    public func isOpen(at now: Date) -> Bool { now < until }

    public func secondsLeft(at now: Date) -> Int { max(0, Int(until.timeIntervalSince(now).rounded(.up))) }
}
