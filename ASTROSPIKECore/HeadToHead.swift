import Foundation

/// The pilot's running record against one opponent, kept by Game Center
/// player ID so a renamed pilot is still the same rival.
public struct RivalRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// The last name this pilot played under.
    public var name: String
    public var wins: Int
    public var losses: Int
    public var lastPlayed: Date

    public var games: Int { wins + losses }

    /// "6–4": my wins, then theirs.
    public var scoreText: String { "\(wins)–\(losses)" }

    public init(id: String, name: String, wins: Int = 0, losses: Int = 0, lastPlayed: Date = .distantPast) {
        self.id = id
        self.name = name
        self.wins = wins
        self.losses = losses
        self.lastPlayed = lastPlayed
    }
}

/// Every opponent the pilot has finished an online match against.
public struct HeadToHeadLedger: Codable, Equatable, Sendable {
    public private(set) var rivals: [String: RivalRecord] = [:]

    public init() {}

    /// Books one finished match against `opponentID` and returns the updated record.
    @discardableResult
    public mutating func record(opponentID: String, name: String, won: Bool, at date: Date = .now) -> RivalRecord {
        var rival = rivals[opponentID] ?? RivalRecord(id: opponentID, name: name)
        if !name.isEmpty { rival.name = name }
        if won { rival.wins += 1 } else { rival.losses += 1 }
        rival.lastPlayed = date
        rivals[opponentID] = rival
        return rival
    }

    public func record(for opponentID: String) -> RivalRecord? { rivals[opponentID] }

    /// Most played first, then most recent.
    public var sorted: [RivalRecord] {
        rivals.values.sorted {
            $0.games != $1.games ? $0.games > $1.games : $0.lastPlayed > $1.lastPlayed
        }
    }
}
