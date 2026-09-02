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
    public var score: Score
    public var floorContacts: SideCounts
    /// Ship touches taken during the current possession. Reset when the ball
    /// crosses the net, so the cap is per trip rather than per rally.
    public var shipTouches: SideCounts
    public var phase: MatchPhase

    public init(
        score: Score = Score(),
        floorContacts: SideCounts = SideCounts(),
        shipTouches: SideCounts = SideCounts(),
        phase: MatchPhase = .playing
    ) {
        self.score = score
        self.floorContacts = floorContacts
        self.shipTouches = shipTouches
        self.phase = phase
    }
}

public enum RuleContact: Codable, Equatable, Sendable {
    case ballTouchedFloor(side: Team)
    case ballTouchedShip(team: Team)
    case ballCrossedCenter(into: Team)
    case ballEnteredGoal(defending: Team)
    case shipDestroyed(team: Team, reason: PointReason)
}

public enum SimulationEvent: Codable, Equatable, Sendable {
    case point(scoringTeam: Team, reason: PointReason)
    case destruction(team: Team, reason: PointReason)
    case collisionEffect(position: SIMD2<Double>, intensity: Double)
    case rallyReset
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
        self.allowedFloorBounces = min(5, max(1, allowedFloorBounces))
        self.allowedShipTouches = min(6, max(1, allowedShipTouches))
    }

    public mutating func updateAllowedFloorBounces(_ value: Int) {
        allowedFloorBounces = min(5, max(1, value))
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
            case let .ballTouchedShip(team):
                // A hit still refreshes the bounce allowance -- but the touch
                // tally does not reset, so touch/bounce/touch/bounce is no
                // longer an unlimited way to stall on your own half.
                state.floorContacts = SideCounts()
                state.shipTouches[team] += 1
                if state.shipTouches[team] > allowedShipTouches {
                    return awardPoint(to: team.opponent, reason: .touchLimit)
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
            case .ballEnteredGoal, .shipDestroyed:
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
        if hasWon(team) {
            state.phase = .finished
            events.append(.matchEnded(winner: team))
        } else {
            state.phase = .serve
        }
        return events
    }

    private func hasWon(_ team: Team) -> Bool {
        let points = state.score[team]
        let opponentPoints = state.score[team.opponent]
        return points >= 11 || (points >= 7 && points - opponentPoints >= 2)
    }
}
