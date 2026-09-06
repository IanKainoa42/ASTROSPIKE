import Foundation

// The lobby is the shared picture of who is flying right now: every pilot's
// presence, every online duel's score, and every tournament in progress. The
// types here are the pure record shapes and the bracket arithmetic; the app
// keeps them in CloudKit and never lets this file know.

/// What a pilot is doing, as they publish it to the lobby.
public enum PilotActivity: String, Codable, Equatable, Sendable, CaseIterable {
    /// On the home screen or in the hangar. Free to be invited.
    case idle
    /// Searching for a quick match or waiting on an invite they sent.
    case matching
    /// Flying an online duel. `PilotPresence.matchID` names it.
    case playing
    /// Flying against the AI. Visible, and still reachable by an invite.
    case solo

    public var label: String {
        switch self {
        case .idle: "IN THE HANGAR"
        case .matching: "LOOKING FOR A DUEL"
        case .playing: "IN A DUEL"
        case .solo: "FLYING SOLO"
        }
    }
}

/// One pilot's heartbeat. The lobby treats a presence older than
/// `LobbySnapshot.staleAfter` as offline, so a pilot who force-quits simply
/// fades out; nothing has to tear it down.
public struct PilotPresence: Codable, Equatable, Sendable, Identifiable {
    /// Game Center `gamePlayerID`, stable per player per game.
    public var id: String
    public var name: String
    public var hull: Hull
    public var activity: PilotActivity
    /// The `LiveMatch.id` being flown, while `activity` is `.playing`.
    public var matchID: String?
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        hull: Hull,
        activity: PilotActivity,
        matchID: String? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.hull = hull
        self.activity = activity
        self.matchID = matchID
        self.updatedAt = updatedAt
    }
}

/// An online duel as the host reports it: who is flying which side, the
/// score so far, and the result once it is over. Guests never write one.
public struct LiveMatch: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var hostID: String
    public var cyanID: String
    public var cyanName: String
    public var orangeID: String
    public var orangeName: String
    public var score: Score
    public var phase: MatchPhase
    public var winner: Team?
    /// Set when this duel is a tournament fixture, so the bracket advances.
    public var fixture: TournamentFixture?
    public var startedAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        hostID: String,
        cyanID: String,
        cyanName: String,
        orangeID: String,
        orangeName: String,
        score: Score = Score(),
        phase: MatchPhase = .playing,
        winner: Team? = nil,
        fixture: TournamentFixture? = nil,
        startedAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.hostID = hostID
        self.cyanID = cyanID
        self.cyanName = cyanName
        self.orangeID = orangeID
        self.orangeName = orangeName
        self.score = score
        self.phase = phase
        self.winner = winner
        self.fixture = fixture
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    public var isLive: Bool { phase != .finished }

    public func name(of team: Team) -> String { team == .cyan ? cyanName : orangeName }
    public func playerID(of team: Team) -> String { team == .cyan ? cyanID : orangeID }

    public func involves(_ playerID: String) -> Bool {
        cyanID == playerID || orangeID == playerID
    }

    /// `CYAN 7 – 5 ORANGE` style summary for a score card.
    public var scoreline: String {
        "\(score.cyan) – \(score.orange)"
    }
}

/// Which slot of which tournament a duel decides.
public struct TournamentFixture: Codable, Equatable, Hashable, Sendable {
    public var tournamentID: String
    public var round: Int
    public var slot: Int

    public init(tournamentID: String, round: Int, slot: Int) {
        self.tournamentID = tournamentID
        self.round = round
        self.slot = slot
    }
}

public struct TournamentEntrant: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var hull: Hull

    public init(id: String, name: String, hull: Hull) {
        self.id = id
        self.name = name
        self.hull = hull
    }
}

/// A decided fixture. Reported by the host of the duel that settled it.
public struct TournamentResult: Codable, Equatable, Sendable {
    public var round: Int
    public var slot: Int
    public var winnerID: String
    public var score: Score

    public init(round: Int, slot: Int, winnerID: String, score: Score) {
        self.round = round
        self.slot = slot
        self.winnerID = winnerID
        self.score = score
    }
}

public enum TournamentStatus: String, Codable, Equatable, Sendable {
    /// Taking entrants. Starts when full or when the organizer starts it.
    case open
    /// Bracket drawn; fixtures being played.
    case underway
    /// A champion stands.
    case finished

    public var label: String {
        switch self {
        case .open: "OPEN"
        case .underway: "UNDERWAY"
        case .finished: "FINISHED"
        }
    }
}

/// A single-elimination bracket of four or eight pilots. Entry order is the
/// seeding: the organizer is seed one, the next pilot to join seed two, and
/// so on. A bracket started short of full is padded with byes.
public struct Tournament: Codable, Equatable, Sendable, Identifiable {
    public static let allowedSizes = [4, 8]
    public static let minimumEntrantsToStart = 2

    public var id: String
    public var name: String
    public var organizerID: String
    public var size: Int
    public var entrants: [TournamentEntrant]
    public var results: [TournamentResult]
    public var createdAt: Date
    public var startedAt: Date?
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        organizerID: String,
        size: Int,
        entrants: [TournamentEntrant] = [],
        results: [TournamentResult] = [],
        createdAt: Date,
        startedAt: Date? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.organizerID = organizerID
        self.size = Self.allowedSizes.contains(size) ? size : 4
        self.entrants = entrants
        self.results = results
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    public var organizerName: String {
        entrants.first { $0.id == organizerID }?.name ?? "?"
    }

    public var isFull: Bool { entrants.count >= size }
    public var hasStarted: Bool { startedAt != nil }
    public var canStart: Bool { !hasStarted && entrants.count >= Self.minimumEntrantsToStart }

    public var status: TournamentStatus {
        if !hasStarted { return .open }
        return bracket.champion == nil ? .underway : .finished
    }

    public var bracket: Bracket { Bracket(entrants: entrants, size: size, results: results) }

    public func isEntered(_ playerID: String) -> Bool {
        entrants.contains { $0.id == playerID }
    }

    /// Adds a pilot. False when the bracket is started, full, or already has them.
    @discardableResult
    public mutating func join(_ entrant: TournamentEntrant, at now: Date) -> Bool {
        guard !hasStarted, !isFull, !isEntered(entrant.id) else { return false }
        entrants.append(entrant)
        updatedAt = now
        if isFull { startedAt = now }
        return true
    }

    /// Draws the bracket with whoever has joined. Only the organizer may
    /// start short; a full bracket starts itself on the last join.
    @discardableResult
    public mutating func start(by playerID: String, at now: Date) -> Bool {
        guard canStart, playerID == organizerID else { return false }
        startedAt = now
        updatedAt = now
        return true
    }

    /// Records a fixture's outcome. Rejected unless the fixture is ready to
    /// play and the winner is one of its two pilots, so a stale or duplicate
    /// report can never rewrite the bracket.
    @discardableResult
    public mutating func report(_ result: TournamentResult, at now: Date) -> Bool {
        guard hasStarted,
              let pairing = bracket.pairing(round: result.round, slot: result.slot),
              pairing.isReady,
              pairing.homeID == result.winnerID || pairing.awayID == result.winnerID else {
            return false
        }
        results.append(result)
        updatedAt = now
        return true
    }
}

/// The drawn bracket: rounds of pairings, byes already advanced, with the
/// fixtures that are ready to fly and, at the end, the champion.
public struct Bracket: Equatable, Sendable {
    public struct Pairing: Equatable, Sendable, Identifiable {
        public var round: Int
        public var slot: Int
        public var homeID: String?
        public var awayID: String?
        public var winnerID: String?
        public var score: Score?

        public var id: String { "r\(round)s\(slot)" }

        /// Both pilots known and nobody has won yet.
        public var isReady: Bool { homeID != nil && awayID != nil && winnerID == nil }
        public var isDecided: Bool { winnerID != nil }
        /// One side empty: the other advances without flying.
        public var isBye: Bool { (homeID == nil) != (awayID == nil) }

        public func includes(_ playerID: String) -> Bool {
            homeID == playerID || awayID == playerID
        }

        public func opponent(of playerID: String) -> String? {
            if homeID == playerID { return awayID }
            if awayID == playerID { return homeID }
            return nil
        }

        /// The pilot who sends the invite, so both do not invite at once.
        public var inviterID: String? { homeID }
    }

    public private(set) var rounds: [[Pairing]] = []

    public init(entrants: [TournamentEntrant], size: Int, results: [TournamentResult]) {
        let size = Tournament.allowedSizes.contains(size) ? size : 4
        let order = Self.seedOrder(size: size)
        let slots: [String?] = order.map { seed in
            seed <= entrants.count ? entrants[seed - 1].id : nil
        }
        var first: [Pairing] = []
        for slot in 0 ..< size / 2 {
            first.append(Pairing(round: 0, slot: slot, homeID: slots[slot * 2], awayID: slots[slot * 2 + 1]))
        }
        rounds = [first]
        var count = size / 2
        while count > 1 {
            count /= 2
            rounds.append((0 ..< count).map { Pairing(round: rounds.count, slot: $0) })
        }

        let reported = Dictionary(
            results.map { (key: "r\($0.round)s\($0.slot)", value: $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for roundIndex in rounds.indices {
            for slot in rounds[roundIndex].indices {
                var pairing = rounds[roundIndex][slot]
                if pairing.isBye {
                    pairing.winnerID = pairing.homeID ?? pairing.awayID
                } else if pairing.homeID != nil, pairing.awayID != nil,
                          let result = reported[pairing.id],
                          pairing.includes(result.winnerID) {
                    pairing.winnerID = result.winnerID
                    pairing.score = result.score
                }
                rounds[roundIndex][slot] = pairing
                guard let winner = pairing.winnerID, roundIndex + 1 < rounds.count else { continue }
                if slot.isMultiple(of: 2) {
                    rounds[roundIndex + 1][slot / 2].homeID = winner
                } else {
                    rounds[roundIndex + 1][slot / 2].awayID = winner
                }
            }
        }
    }

    /// Standard seeding so the top two seeds can only meet in the final:
    /// 4 → 1,4,2,3 and 8 → 1,8,4,5,2,7,3,6.
    public static func seedOrder(size: Int) -> [Int] {
        guard size > 1 else { return [1] }
        return seedOrder(size: size / 2).flatMap { [$0, size + 1 - $0] }
    }

    public var champion: String? { rounds.last?.first?.winnerID }

    public func pairing(round: Int, slot: Int) -> Pairing? {
        guard rounds.indices.contains(round), rounds[round].indices.contains(slot) else { return nil }
        return rounds[round][slot]
    }

    /// Fixtures that can be flown right now.
    public var readyPairings: [Pairing] {
        rounds.flatMap { $0 }.filter(\.isReady)
    }

    /// The fixture a pilot has to fly next, or nil when they are waiting on
    /// another result, eliminated, or the champion.
    public func nextPairing(for playerID: String) -> Pairing? {
        readyPairings.first { $0.includes(playerID) }
    }

    public func isEliminated(_ playerID: String) -> Bool {
        rounds.flatMap { $0 }.contains { $0.includes(playerID) && $0.isDecided && $0.winnerID != playerID }
    }
}

/// Everything the lobby fetched, plus the freshness and ordering rules the
/// screen applies to it.
public struct LobbySnapshot: Equatable, Sendable {
    /// A heartbeat older than this means the pilot is gone.
    public static let staleAfter: TimeInterval = 90
    /// A live duel that has not reported a score for this long is abandoned.
    public static let matchStaleAfter: TimeInterval = 180

    public var pilots: [PilotPresence]
    public var matches: [LiveMatch]
    public var tournaments: [Tournament]

    public init(pilots: [PilotPresence] = [], matches: [LiveMatch] = [], tournaments: [Tournament] = []) {
        self.pilots = pilots
        self.matches = matches
        self.tournaments = tournaments
    }

    /// Other pilots seen recently, friends first, then by name.
    public func onlinePilots(at now: Date, friends: Set<String>, excluding localID: String) -> [PilotPresence] {
        pilots
            .filter { $0.id != localID && now.timeIntervalSince($0.updatedAt) <= Self.staleAfter }
            .sorted { lhs, rhs in
                let lhsFriend = friends.contains(lhs.id), rhsFriend = friends.contains(rhs.id)
                if lhsFriend != rhsFriend { return lhsFriend }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// Duels in progress, most recently updated first.
    public func liveMatches(at now: Date) -> [LiveMatch] {
        matches
            .filter { $0.isLive && now.timeIntervalSince($0.updatedAt) <= Self.matchStaleAfter }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Finished duels, newest first, for the recent-results strip.
    public func recentResults(limit: Int = 6) -> [LiveMatch] {
        Array(matches.filter { !$0.isLive }.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    /// The fixture two pilots are due to fly, when they are both in a ready
    /// pairing of a bracket that is underway. The host asks this at kick-off
    /// so a duel between bracket rivals advances the bracket without anyone
    /// having to say it is a tournament match.
    public func fixture(between first: String, and second: String) -> TournamentFixture? {
        for tournament in tournaments where tournament.status == .underway {
            if let pairing = tournament.bracket.readyPairings.first(where: { $0.includes(first) && $0.includes(second) }) {
                return TournamentFixture(tournamentID: tournament.id, round: pairing.round, slot: pairing.slot)
            }
        }
        return nil
    }

    /// Tournaments worth showing: the pilot's own first, then open ones,
    /// then those underway; finished ones drop off.
    public func visibleTournaments(for localID: String) -> [Tournament] {
        tournaments
            .filter { $0.status != .finished }
            .sorted { lhs, rhs in
                let lhsMine = lhs.isEntered(localID), rhsMine = rhs.isEntered(localID)
                if lhsMine != rhsMine { return lhsMine }
                if lhs.status != rhs.status { return lhs.status == .open }
                return lhs.createdAt > rhs.createdAt
            }
    }
}
