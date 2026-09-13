import Foundation

public extension Team {
    var opponent: Team { self == .cyan ? .orange : .cyan }
}

public enum MatchPhase: String, Codable, Equatable, Sendable {
    case countdown
    case playing
    case serve
    case paused
    case finished
}

public enum PointReason: String, Codable, Equatable, Sendable {
    case goal
    case thirdBounce
    case touchLimit
    case crash
    case netContact
    case forfeit
}

public struct Score: Codable, Equatable, Sendable {
    public var cyan: Int
    public var orange: Int

    public init(cyan: Int = 0, orange: Int = 0) {
        self.cyan = cyan
        self.orange = orange
    }

    public subscript(team: Team) -> Int {
        get { team == .cyan ? cyan : orange }
        set {
            if team == .cyan { cyan = newValue } else { orange = newValue }
        }
    }
}

/// A plain per-side tally. Used for both floor bounces and ship touches.
public struct SideCounts: Codable, Equatable, Sendable {
    public var cyan: Int
    public var orange: Int

    public init(cyan: Int = 0, orange: Int = 0) {
        self.cyan = cyan
        self.orange = orange
    }

    public subscript(team: Team) -> Int {
        get { team == .cyan ? cyan : orange }
        set {
            if team == .cyan { cyan = newValue } else { orange = newValue }
        }
    }
}

public typealias FloorContactCounts = SideCounts

public struct MatchRuleState: Codable, Equatable, Sendable {
    /// Points in the set being played.
    public var score: Score
    public var floorContacts: SideCounts
    /// Ship touches taken during the current possession. Reset when the ball
    /// crosses the net, so the cap is per trip rather than per rally.
    public var shipTouches: SideCounts
    public var phase: MatchPhase
    /// Sets already won. A single-game match never gets past 1–0.
    public var sets: Score
    /// Sets a side needs for the match: 1 is a single game, 2 is best of
    /// three, 3 is best of five. Lives in the state so a guest's copy of the
    /// board carries the format the host is playing to.
    public var setsToWin: Int
    /// Who took the match, once it is finished. Set by the last set point or
    /// by a forfeit, so the result screen never has to infer it from points.
    public var winner: Team?

    public init(
        score: Score = Score(),
        floorContacts: SideCounts = SideCounts(),
        shipTouches: SideCounts = SideCounts(),
        phase: MatchPhase = .playing,
        sets: Score = Score(),
        setsToWin: Int = 1,
        winner: Team? = nil
    ) {
        self.score = score
        self.floorContacts = floorContacts
        self.shipTouches = shipTouches
        self.phase = phase
        self.sets = sets
        self.setsToWin = min(3, max(1, setsToWin))
        self.winner = winner
    }
}

/// How much a side has riding on the next point. Derived from the score
/// every time it is asked for -- it is deliberately not stored on
/// `MatchRuleState`, so it can never go stale on a guest's copy of the board
/// and it costs nothing on the wire.
public enum Stake: Int, Codable, Equatable, Sendable, Comparable {
    case none = 0
    /// One more point takes the set.
    case setPoint = 1
    /// One more point takes the match.
    case matchPoint = 2

    public static func < (lhs: Stake, rhs: Stake) -> Bool { lhs.rawValue < rhs.rawValue }
}

public extension MatchRuleState {
    /// What `team` is playing for. `.none` unless the very next point ends
    /// something. Both sides can be at set point at once (10-10 under the
    /// ceiling), which is the whole reason this is per-team.
    func stake(for team: Team) -> Stake {
        guard winner == nil, phase == .playing || phase == .serve else { return .none }
        guard MatchRules.winsSet(points: score[team] + 1, against: score[team.opponent]) else { return .none }
        return sets[team] + 1 >= setsToWin ? .matchPoint : .setPoint
    }

    /// The higher of the two stakes, and who holds it. Nil when nobody is
    /// serving for anything. Ties (both at set point) resolve to the side
    /// that is ahead, and to cyan when the score is level.
    var headlineStake: (team: Team, stake: Stake)? {
        let cyan = stake(for: .cyan)
        let orange = stake(for: .orange)
        guard cyan != .none || orange != .none else { return nil }
        if cyan == orange {
            return (score.orange > score.cyan ? .orange : .cyan, cyan)
        }
        return cyan > orange ? (.cyan, cyan) : (.orange, orange)
    }
}

public enum RuleContact: Codable, Equatable, Sendable {
    case ballTouchedFloor(side: Team)
    /// `counted` is false for the follow-up contacts of a single rattle --
    /// the ball pinned on a wall, re-hitting the same hull within a few
    /// ticks -- and for a hull playing the ball on the far half. Those still
    /// refresh the bounce allowance, they just don't spend a touch. Bolts
    /// never send this at all.
    case ballTouchedShip(team: Team, counted: Bool)
    case ballCrossedCenter(into: Team)
    case ballEnteredGoal(defending: Team)
    /// The ball dropped through the centre hoop. Who it belongs to is not
    /// carried here -- it is whoever touched the ball last, which the engine
    /// tracks on the world state.
    case ballEnteredHoop
    case shipDestroyed(team: Team, reason: PointReason)
}

public enum SimulationEvent: Codable, Equatable, Sendable {
    case point(scoringTeam: Team, reason: PointReason)
    case destruction(team: Team, reason: PointReason)
    case collisionEffect(position: SIMD2<Double>, intensity: Double)
    case rallyReset
    /// A set went to `winner` and the next one starts from love; `sets` is
    /// the tally after it. Never sent for the set that ends the match.
    case setEnded(winner: Team, sets: Score)
    case matchEnded(winner: Team)
}

public struct MatchRules: Sendable {
    public private(set) var state: MatchRuleState
    public private(set) var allowedFloorBounces: Int
    public private(set) var allowedShipTouches: Int

    public init(
        state: MatchRuleState = MatchRuleState(),
        allowedFloorBounces: Int = 1,
        allowedShipTouches: Int = 3
    ) {
        self.state = state
        // Zero is a legal setting: volleyball ends the rally on the first
        // touch of the floor rather than the second.
        self.allowedFloorBounces = min(5, max(0, allowedFloorBounces))
        self.allowedShipTouches = min(6, max(1, allowedShipTouches))
    }

    public mutating func updateAllowedFloorBounces(_ value: Int) {
        allowedFloorBounces = min(5, max(0, value))
    }

    /// 1 = single game, 2 = best of three, 3 = best of five.
    public mutating func updateSetsToWin(_ value: Int) {
        state.setsToWin = min(3, max(1, value))
    }

    public mutating func updateAllowedShipTouches(_ value: Int) {
        allowedShipTouches = min(6, max(1, value))
    }

    public mutating func beginNextRally() {
        guard state.phase != .finished else { return }
        state.floorContacts = SideCounts()
        state.shipTouches = SideCounts()
        state.phase = .playing
    }

    public mutating func prepareNextRally() {
        guard state.phase != .finished else { return }
        state.floorContacts = SideCounts()
        state.shipTouches = SideCounts()
        state.phase = .countdown
    }

    public mutating func forfeit(winner: Team) -> [SimulationEvent] {
        guard state.phase != .finished else { return [] }
        state.score[winner] += 1
        state.floorContacts = SideCounts()
        state.shipTouches = SideCounts()
        state.phase = .finished
        state.winner = winner
        return [
            .point(scoringTeam: winner, reason: .forfeit),
            .matchEnded(winner: winner),
        ]
    }

    public mutating func resolve(_ contacts: [RuleContact]) -> [SimulationEvent] {
        guard state.phase == .playing else { return [] }

        if let goal = contacts.compactMap({ contact -> Team? in
            guard case let .ballEnteredGoal(defending) = contact else { return nil }
            return defending
        }).first {
            return awardPoint(to: goal.opponent, reason: .goal)
        }

        for contact in contacts {
            switch contact {
            case let .ballTouchedShip(team, counted):
                // A hit still refreshes the bounce allowance -- but the touch
                // tally does not reset, so touch/bounce/touch/bounce is no
                // longer an unlimited way to stall on your own half. The
                // refresh happens even on a free contact: a rattle that does
                // not spend a touch must not spend a bounce either.
                state.floorContacts = SideCounts()
                if counted {
                    state.shipTouches[team] += 1
                    if state.shipTouches[team] > allowedShipTouches {
                        return awardPoint(to: team.opponent, reason: .touchLimit)
                    }
                }
            case let .ballCrossedCenter(team):
                state.floorContacts[team] = 0
                // Sending it over ends the possession for both sides.
                state.shipTouches = SideCounts()
            case let .ballTouchedFloor(side):
                state.floorContacts[side] += 1
                if state.floorContacts[side] > allowedFloorBounces {
                    return awardPoint(to: side.opponent, reason: .thirdBounce)
                }
            case .ballEnteredGoal, .ballEnteredHoop, .shipDestroyed:
                break
            }
        }

        let destructions = contacts.compactMap { contact -> (Team, PointReason)? in
            guard case let .shipDestroyed(team, reason) = contact else { return nil }
            return (team, reason)
        }
        let destroyedTeams = Set(destructions.map(\.0))
        if destroyedTeams.count == 2 {
            state.floorContacts = SideCounts()
            state.shipTouches = SideCounts()
            state.phase = .serve
            return [.rallyReset]
        }
        if let destruction = destructions.first {
            return awardPoint(to: destruction.0.opponent, reason: destruction.1)
        }
        return []
    }

    private mutating func awardPoint(to team: Team, reason: PointReason) -> [SimulationEvent] {
        state.score[team] += 1
        state.floorContacts = SideCounts()
        state.shipTouches = SideCounts()
        var events: [SimulationEvent] = [.point(scoringTeam: team, reason: reason)]
        if hasWonSet(team) {
            state.sets[team] += 1
            if state.sets[team] >= state.setsToWin {
                state.phase = .finished
                state.winner = team
                events.append(.matchEnded(winner: team))
            } else {
                // Next set from love, same sides, straight into a serve.
                events.append(.setEnded(winner: team, sets: state.sets))
                state.score = Score()
                state.phase = .serve
            }
        } else {
            state.phase = .serve
        }
        return events
    }

    private func hasWonSet(_ team: Team) -> Bool {
        MatchRules.winsSet(points: state.score[team], against: state.score[team.opponent])
    }
}

public extension MatchRules {
    /// First to this many points, if they are two clear.
    static let setTarget = 7
    /// The set cannot run past this. At `setCeiling - 1` all the way up the
    /// next point takes it, which is the one score where the two-clear rule
    /// does not hold.
    static let setCeiling = 11

    /// The single win condition for a set. The HUD asks the same question of
    /// a hypothetical `score + 1` to decide whether a side is at set point,
    /// so it has to live somewhere both can reach.
    static func winsSet(points: Int, against opponentPoints: Int) -> Bool {
        points >= setCeiling || (points >= setTarget && points - opponentPoints >= 2)
    }
}
