import Foundation

// A duel invitation is one pilot at a time: ask Maya, wait, and if she never
// looks at her phone, cancel and ask Jo. An open table asks everyone at once
// and keeps going after the first duel.
//
// The host sends one round of invitations to several pilots. The first to
// connect kicks off a duel with the host straight away -- nobody waits on the
// slowest phone. Everyone who turns up after that takes a place on the bench,
// watches the duel in progress, and waits their turn. When a duel ends the
// winner stays on, the loser goes to the back of the line, and whoever has
// waited longest flies next, until the host closes the table.
//
// This file is the arithmetic: who is on the court, who is next, and who has
// won how many tonight. The host owns it and broadcasts it whole on every
// change, so every board shows the same line and nothing has to be merged.

public struct OpenTable: Codable, Equatable, Sendable {
    /// Everyone at the table, host included. The host sends every snapshot
    /// to every peer, so this is what keeps its upload modest.
    public static let maxPilots = 6
    /// How many pilots one open table can ask at once.
    public static var maxInvitees: Int { maxPilots - 1 }
    /// How long the results card stays up before the next duel is seated.
    public static let intermissionSeconds = 10
    /// How long a board between duels waits past the intermission for the
    /// host's next seating before it calls the table closed.
    public static let seatingGraceSeconds = 20
    /// A dropped pilot's chair is held this long, not the full two minutes,
    /// while somebody is on the bench waiting to fly.
    public static let benchHoldSeconds = 30

    /// Game Center `gamePlayerID` of the pilot who opened the table. Only
    /// they seat duels and only their broadcast is believed.
    public let hostID: String
    /// Who flies cyan and orange in the duel in progress, or the next one.
    /// Empty between a pilot leaving and the next duel being seated.
    public private(set) var cyan: String?
    public private(set) var orange: String?
    /// The bench, next up first.
    public private(set) var queue: [String]
    /// Duels won at this table, by player ID.
    public private(set) var wins: [String: Int]
    /// Duels finished at this table.
    public private(set) var duelsPlayed: Int
    /// The host closed the table on purpose. Sent once, on the way out, so
    /// the boards at it end now instead of holding the host's chair as if
    /// its link had merely dropped.
    public private(set) var isClosed = false

    /// A table with only its host sitting at it.
    public init(hostID: String) {
        self.hostID = hostID
        queue = [hostID]
        wins = [:]
        duelsPlayed = 0
    }

    /// The pilots on the court, cyan first.
    public var court: [String] { [cyan, orange].compactMap { $0 } }
    /// Everyone at the table: the court, then the bench in order.
    public var pilots: [String] { court + queue }
    public var isFull: Bool { pilots.count >= Self.maxPilots }
    /// Both chairs have a pilot in them.
    public var isReady: Bool { cyan != nil && orange != nil }

    public func contains(_ playerID: String) -> Bool { pilots.contains(playerID) }
    public func isOnCourt(_ playerID: String) -> Bool { court.contains(playerID) }

    /// 1 for next up, 2 for the pilot after them; nil for anyone on the court
    /// or not at the table.
    public func place(of playerID: String) -> Int? {
        queue.firstIndex(of: playerID).map { $0 + 1 }
    }

    /// The host's seating plan for the duel on the court.
    public var plan: [String: Seat] {
        var plan: [String: Seat] = [:]
        if let cyan { plan[cyan] = .cyan }
        if let orange { plan[orange] = .orange }
        return plan
    }

    /// Who flies the next duel if it were seated now: whoever keeps their
    /// chair, then the head of the bench into any empty one.
    public var nextDuel: [String] {
        var bench = queue[...]
        return [cyan, orange].compactMap { $0 ?? bench.popFirst() }
    }

    /// A pilot sat down at the table. They join the back of the bench; the
    /// court only changes when a duel is seated. False when they are already
    /// here or the table is full.
    @discardableResult
    public mutating func arrive(_ playerID: String) -> Bool {
        guard !contains(playerID), !isFull else { return false }
        queue.append(playerID)
        return true
    }

    /// A pilot left the table, from the bench or the court. Their wins stay
    /// on the board: the night still happened.
    public mutating func depart(_ playerID: String) {
        queue.removeAll { $0 == playerID }
        if cyan == playerID { cyan = nil }
        if orange == playerID { orange = nil }
    }

    /// A duel is over. The winner keeps their chair and the loser goes to
    /// the back of the bench. With no winner -- nobody could say who won --
    /// both go to the back in the order they sat, so the bench moves up.
    /// A court pilot who already left is not put back in line.
    public mutating func finishDuel(winnerID: String?) {
        duelsPlayed += 1
        if let winnerID { wins[winnerID, default: 0] += 1 }
        for (index, seated) in [cyan, orange].enumerated() {
            guard let seated, seated != winnerID else { continue }
            queue.append(seated)
            if index == 0 { cyan = nil } else { orange = nil }
        }
    }

    public mutating func close() {
        isClosed = true
    }

    /// Fills the empty chairs from the head of the bench. True when both
    /// chairs are filled and a duel can start. Nobody moves unless both
    /// chairs can be filled: a pilot left alone on the court would read as
    /// flying a duel against nobody.
    @discardableResult
    public mutating func seatNextDuel() -> Bool {
        let empty = [cyan, orange].filter { $0 == nil }.count
        guard queue.count >= empty else { return false }
        if cyan == nil { cyan = queue.removeFirst() }
        if orange == nil { orange = queue.removeFirst() }
        return true
    }

    /// Forgets everyone not in `present`, the host excepted, so a pilot
    /// whose departure the host never heard about is not seated.
    public mutating func keepOnly(_ present: Set<String>) {
        for id in pilots where id != hostID && !present.contains(id) {
            depart(id)
        }
    }

    /// How long a dropped pilot's chair is held. A bench full of pilots
    /// waiting on a phone that is not coming back is the thing this table
    /// exists to avoid, so the hold is short while anybody is waiting.
    public func seatHoldSeconds(standard: Int) -> Int {
        queue.isEmpty ? standard : min(standard, Self.benchHoldSeconds)
    }

    /// The table's wins, most first. Pilots with none are left off.
    public var standings: [(playerID: String, wins: Int)] {
        wins
            .filter { $0.value > 0 }
            .map { (playerID: $0.key, wins: $0.value) }
            .sorted { $0.wins != $1.wins ? $0.wins > $1.wins : $0.playerID < $1.playerID }
    }

    /// What the bench shows one pilot: NEXT UP, or their place in line. Nil
    /// for a pilot on the court or not at the table.
    public func benchLine(for playerID: String) -> String? {
        guard let place = place(of: playerID) else { return nil }
        return place == 1 ? "YOU'RE NEXT UP" : "#\(place) IN LINE"
    }
}
