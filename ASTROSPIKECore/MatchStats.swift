import Foundation

/// How a goal went in, read off the last thing that played the ball.
public enum GoalStyle: String, Codable, Equatable, Sendable {
    /// Off a hull.
    case hull
    /// Off a bolt.
    case bolt
    /// Off a bolt fired into a ball the shooter's side was holding in its
    /// tractor beam a moment before: reel it in, then blast it through.
    case slamDunk
    /// The defending side put it in its own goal.
    case ownGoal
}

/// What stopped a ball that was going in.
public enum SaveKind: String, Codable, Equatable, Sendable {
    case hull
    case bolt
    case beam
}

/// A play called out by name while the rally runs.
public enum PlayCall: Codable, Equatable, Sendable {
    /// A bolt landed on `victim`'s hull.
    case zap(victim: Seat)
    /// A bolt hit a ball the shooter's side had in its beam a moment
    /// before. If that ball goes in, it is a slam dunk.
    case slam
    /// The ball was going in and this play kept it out. Close: it was
    /// under a third of a second from the goal.
    case save(SaveKind, close: Bool)
}

/// The last thing to play a ball: whose hull or bolt, and whether that bolt
/// was a slam. Walls, the floor and the other ball do not change it -- a
/// shot that banks in is still the shooter's.
public struct BallPlay: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case hull
        case bolt
        case slamDunk
    }

    public var seat: Seat
    public var kind: Kind

    public init(seat: Seat, kind: Kind) {
        self.seat = seat
        self.kind = kind
    }
}

/// The last beam to have a real grip on a ball, and the tick it last held.
public struct BeamHold: Codable, Equatable, Sendable {
    public var seat: Seat
    public var tick: UInt64

    public init(seat: Seat, tick: UInt64) {
        self.seat = seat
        self.tick = tick
    }
}

/// One pilot's match. Every number is "this match", so a leaderboard can
/// take the best of them.
public struct PilotStats: Codable, Equatable, Sendable {
    /// Every goal credited to this pilot, whatever went in off.
    public var goals: Int
    /// Goals off a bolt, slam dunks included.
    public var boltGoals: Int
    public var slamDunks: Int
    public var ownGoals: Int
    /// Counted hull touches -- the same ones the rulebook counts.
    public var hits: Int
    /// Bolts that landed on a ball.
    public var boltHits: Int
    /// Bolts that landed on an enemy hull.
    public var zaps: Int
    /// Balls that were going into your goal and didn't, because you played
    /// them: every kind below included.
    public var saves: Int
    /// Saves on a ball under a third of a second from going in.
    public var closeSaves: Int
    /// Saves off one of your bolts.
    public var boltSaves: Int
    /// Saves your tractor beam made.
    public var beamSaves: Int

    public init(
        goals: Int = 0,
        boltGoals: Int = 0,
        slamDunks: Int = 0,
        ownGoals: Int = 0,
        hits: Int = 0,
        boltHits: Int = 0,
        zaps: Int = 0,
        saves: Int = 0,
        closeSaves: Int = 0,
        boltSaves: Int = 0,
        beamSaves: Int = 0
    ) {
        self.goals = goals
        self.boltGoals = boltGoals
        self.slamDunks = slamDunks
        self.ownGoals = ownGoals
        self.hits = hits
        self.boltHits = boltHits
        self.zaps = zaps
        self.saves = saves
        self.closeSaves = closeSaves
        self.boltSaves = boltSaves
        self.beamSaves = beamSaves
    }
}

/// The match's book of plays. Kept by whoever keeps the rulebook -- the host
/// online -- and carried to every board on the snapshot.
public struct MatchStats: Codable, Equatable, Sendable {
    public var pilots: [Seat: PilotStats]
    /// Times the ball has crossed the centre line in the point being played.
    public var rallyCrossings: Int
    /// The most crossings any one point of the match has run to. Crossings
    /// rather than touches: touches are unlimited, so a pilot keeping the
    /// ball up on their own hull could run a touch count up forever.
    public var longestRally: Int

    public init(pilots: [Seat: PilotStats] = [:], rallyCrossings: Int = 0, longestRally: Int = 0) {
        self.pilots = pilots
        self.rallyCrossings = rallyCrossings
        self.longestRally = longestRally
    }

    public subscript(seat: Seat) -> PilotStats {
        get { pilots[seat] ?? PilotStats() }
        set { pilots[seat] = newValue }
    }

    /// Books a goal against the last play on the ball. Nil when nobody had
    /// played it -- a ball that falls in off the serve is nobody's goal.
    ///
    /// A ball an attacker's beam is pulling as it goes in is that pilot's
    /// slam dunk, whoever touched it last: reeling it into the net is the
    /// play. A defender's beam on it is no slam -- that is a save that failed.
    @discardableResult
    public mutating func creditGoal(lastPlay: BallPlay?, pulledBy: Seat? = nil, defending: Team) -> (seat: Seat, style: GoalStyle)? {
        if let puller = pulledBy, puller.team != defending {
            self[puller].goals += 1
            self[puller].slamDunks += 1
            if let play = lastPlay, play.seat == puller, play.kind != .hull { self[puller].boltGoals += 1 }
            return (puller, .slamDunk)
        }
        guard let play = lastPlay else { return nil }
        if play.seat.team == defending {
            self[play.seat].ownGoals += 1
            return (play.seat, .ownGoal)
        }
        self[play.seat].goals += 1
        switch play.kind {
        case .hull:
            return (play.seat, .hull)
        case .bolt:
            self[play.seat].boltGoals += 1
            return (play.seat, .bolt)
        case .slamDunk:
            self[play.seat].boltGoals += 1
            self[play.seat].slamDunks += 1
            return (play.seat, .slamDunk)
        }
    }

    /// One side's match so far: its pilots' numbers added up.
    public func total(for team: Team) -> PilotStats {
        pilots.filter { $0.key.team == team }.values.reduce(into: PilotStats()) { sum, pilot in
            sum.goals += pilot.goals
            sum.boltGoals += pilot.boltGoals
            sum.slamDunks += pilot.slamDunks
            sum.ownGoals += pilot.ownGoals
            sum.hits += pilot.hits
            sum.boltHits += pilot.boltHits
            sum.zaps += pilot.zaps
            sum.saves += pilot.saves
            sum.closeSaves += pilot.closeSaves
            sum.boltSaves += pilot.boltSaves
            sum.beamSaves += pilot.beamSaves
        }
    }

    public mutating func ballCrossedCenter() {
        rallyCrossings += 1
        longestRally = max(longestRally, rallyCrossings)
    }

    public mutating func pointEnded() {
        rallyCrossings = 0
    }
}

/// The per-match Game Center leaderboards. Each keeps a player's best single
/// match. The ids must match App Store Connect exactly: a typo is not an
/// error, the score just goes nowhere.
public enum StatBoard: String, CaseIterable, Sendable {
    case goals = "astrospike.match.goals"
    case boltGoals = "astrospike.match.boltgoals"
    case slamDunks = "astrospike.match.slamdunks"
    case zaps = "astrospike.match.zaps"
    case longestRally = "astrospike.match.longestrally"

    public var title: String {
        switch self {
        case .goals: "Most Goals in a Match"
        case .boltGoals: "Most Bolt Goals in a Match"
        case .slamDunks: "Most Slam Dunks in a Match"
        case .zaps: "Most Zaps in a Match"
        case .longestRally: "Longest Rally"
        }
    }

    /// The suffix Game Center prints after the number.
    public var unit: (singular: String, plural: String) {
        switch self {
        case .goals: ("goal", "goals")
        case .boltGoals: ("bolt goal", "bolt goals")
        case .slamDunks: ("slam dunk", "slam dunks")
        case .zaps: ("zap", "zaps")
        case .longestRally: ("crossing", "crossings")
        }
    }

    public func value(in stats: MatchStats, for seat: Seat) -> Int {
        let pilot = stats[seat]
        return switch self {
        case .goals: pilot.goals
        case .boltGoals: pilot.boltGoals
        case .slamDunks: pilot.slamDunks
        case .zaps: pilot.zaps
        case .longestRally: stats.longestRally
        }
    }

    /// What to send at the end of a match: every board the pilot scored on.
    /// A zero is never a best, so it is never sent.
    public static func submissions(from stats: MatchStats, for seat: Seat) -> [(board: StatBoard, value: Int)] {
        allCases.compactMap { board in
            let value = board.value(in: stats, for: seat)
            return value > 0 ? (board, value) : nil
        }
    }
}

/// The bay's two Game Center boards, fed from warm-up and practice rather
/// than from a match: the longest keep-up streak, and the most hoops popped
/// in one stay. Kept apart from `StatBoard` so a match never sends to them.
public enum PracticeBoard: String, CaseIterable, Sendable {
    case keepUp = "astrospike.practice.keepups"
    case hoops = "astrospike.practice.hoops"

    public var title: String {
        switch self {
        case .keepUp: "Longest Keep-Up"
        case .hoops: "Most Hoops in One Practice"
        }
    }

    public var unit: (singular: String, plural: String) {
        switch self {
        case .keepUp: ("touch", "touches")
        case .hoops: ("hoop", "hoops")
        }
    }

    /// What to send when the pilot leaves the bay. A zero is never sent.
    public static func submissions(keepUp: Int, hoops: Int) -> [(board: PracticeBoard, value: Int)] {
        let all: [(board: PracticeBoard, value: Int)] = [(.keepUp, keepUp), (.hoops, hoops)]
        return all.filter { $0.value > 0 }
    }
}
