import Foundation

// A duel invitation is one pilot at a time: ask Maya, wait, and if she never
// looks at her phone, cancel and ask Jo. An open table asks everyone at once
// and keeps going after the first duel.
//
// The host sends one round of invitations to several pilots. The first to
// connect kicks off a duel with the host straight away -- nobody waits on the
// slowest phone. Everyone who turns up after that takes a place on the bench
// and watches the game in progress. When it ends, everybody who fits on the
// court flies the next one: three pilots are two against one and a bot, four
// are two a side, and partners change every game so each pilot takes a turn
// on the short-handed side. Only past four does anyone sit out: the winning
// side stays on, the losers go to the back of the line, and whoever has
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
    /// Chairs on the court: two a side.
    public static let courtSeats = 4
    /// The order chairs are filled in: one across the net first, so two
    /// pilots duel, then the wings, so a third makes it two against one and
    /// a bot on the empty wing.
    public static let seatOrder = OnlineSeating.order(teamUp: false)
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
    /// Who flies each chair in the game in progress, or the next one.
    /// Empty between a pilot leaving and the next game being seated; the
    /// wings are empty in a duel, and one of them is a bot with three.
    public private(set) var cyan: String?
    public private(set) var orange: String?
    public private(set) var cyanWing: String?
    public private(set) var orangeWing: String?
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

    /// Who sits in one chair.
    public func pilot(in seat: Seat) -> String? {
        switch seat {
        case .cyan: cyan
        case .orange: orange
        case .cyanWing: cyanWing
        case .orangeWing: orangeWing
        }
    }

    private mutating func seat(_ playerID: String?, in seat: Seat) {
        switch seat {
        case .cyan: cyan = playerID
        case .orange: orange = playerID
        case .cyanWing: cyanWing = playerID
        case .orangeWing: orangeWing = playerID
        }
    }

    /// Every filled chair.
    public var seats: [Seat: String] {
        var seats: [Seat: String] = [:]
        for seat in Self.seatOrder { seats[seat] = pilot(in: seat) }
        return seats
    }

    /// The pilots on the court, in the order their chairs are filled.
    public var court: [String] { Self.seatOrder.compactMap { pilot(in: $0) } }
    /// One side's pilots, lead first.
    public func side(_ team: Team) -> [String] {
        [Seat.lead(team), Seat.wing(team)].compactMap { pilot(in: $0) }
    }
    /// Everyone at the table: the court, then the bench in order.
    public var pilots: [String] { court + queue }
    public var isFull: Bool { pilots.count >= Self.maxPilots }
    /// Somebody is on each side of the net.
    public var isReady: Bool { cyan != nil && orange != nil }

    public func contains(_ playerID: String) -> Bool { pilots.contains(playerID) }
    public func isOnCourt(_ playerID: String) -> Bool { court.contains(playerID) }

    /// 1 for next up, 2 for the pilot after them; nil for anyone on the court
    /// or not at the table.
    public func place(of playerID: String) -> Int? {
        queue.firstIndex(of: playerID).map { $0 + 1 }
    }

    /// The host's seating plan for the game on the court. More than two
    /// pilots in it is doubles, and the host flies a bot in any empty chair.
    public var plan: [String: Seat] {
        var plan: [String: Seat] = [:]
        for (seat, id) in seats { plan[id] = seat }
        return plan
    }

    /// The chairs of the next game if it were seated now, or nil while the
    /// table is waiting on a challenger.
    public var nextCourt: [Seat: String]? {
        var next = self
        return next.seatNextDuel() ? next.seats : nil
    }

    /// A game as the scoreboard says it: IAN + JO V MAYA + BOT. A side with
    /// one pilot on a doubles court has a bot beside them.
    public static func matchup(of seats: [Seat: String], name: (String) -> String) -> String {
        let doubles = seats.count > 2
        return [Team.cyan, .orange].map { team in
            var side = [Seat.lead(team), Seat.wing(team)].compactMap { seats[$0] }.map(name)
            if doubles, side.count == 1 { side.append("BOT") }
            return side.joined(separator: " + ")
        }.joined(separator: " V ")
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
        for seat in Self.seatOrder where pilot(in: seat) == playerID {
            self.seat(nil, in: seat)
        }
    }

    /// A game is over, and every pilot on the winning side has a win.
    ///
    /// While everybody at the table fits on the court nobody sits out: the
    /// court stays, and with three or four on it partners change, so the
    /// pilot flying beside the bot is somebody new each game. Past that the
    /// winning side keeps its chairs and the losers go to the back of the
    /// bench; with no winner -- nobody could say who won -- the whole court
    /// goes to the back in the order it sat, so the bench moves up. A court
    /// pilot who already left is not put back in line.
    public mutating func finishDuel(winner: Team?) {
        duelsPlayed += 1
        if let winner {
            for id in side(winner) { wins[id, default: 0] += 1 }
        }
        if pilots.count <= Self.courtSeats {
            rotatePartners()
            return
        }
        for seat in Self.seatOrder where seat.team != winner {
            guard let seated = pilot(in: seat) else { continue }
            queue.append(seated)
            self.seat(nil, in: seat)
        }
    }

    /// The same pilots in new pairs. Three pass the chairs round one place,
    /// so each takes the side with the bot in turn; four keep the first
    /// chair and pass the other three, so everyone partners everyone.
    private mutating func rotatePartners() {
        var order = court
        switch order.count {
        case 3: order.append(order.removeFirst())
        case 4: order.append(order.remove(at: 1))
        default: return
        }
        for seat in Self.seatOrder { self.seat(nil, in: seat) }
        for (seat, id) in zip(Self.seatOrder, order) { self.seat(id, in: seat) }
    }

    public mutating func close() {
        isClosed = true
    }

    /// Fills the empty chairs from the head of the bench, up to two a side.
    /// True when there is somebody on each side of the net and a game can
    /// start. Nobody moves unless it can: a pilot left alone on the court
    /// would read as flying against nobody.
    @discardableResult
    public mutating func seatNextDuel() -> Bool {
        guard court.count + queue.count >= 2 else { return false }
        for seat in Self.seatOrder where pilot(in: seat) == nil && !queue.isEmpty {
            self.seat(queue.removeFirst(), in: seat)
        }
        if !isReady {
            // Somebody left and a side is empty: sit whoever is still here
            // back down in order, so both sides of the net have a pilot.
            let order = court
            for seat in Self.seatOrder { self.seat(nil, in: seat) }
            for (seat, id) in zip(Self.seatOrder, order) { self.seat(id, in: seat) }
        }
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
