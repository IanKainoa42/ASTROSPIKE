import Testing
@testable import ASTROSPIKECore

@Suite("Match rules")
struct MatchRulesTests {
    @Test("Third floor contact concedes a point")
    func thirdBounceScores() {
        var rules = MatchRules(allowedFloorBounces: 2)

        #expect(rules.resolve([.ballTouchedFloor(side: .cyan)]).isEmpty)
        #expect(rules.resolve([.ballTouchedFloor(side: .cyan)]).isEmpty)
        let events = rules.resolve([.ballTouchedFloor(side: .cyan)])

        #expect(rules.state.score.orange == 1)
        #expect(events == [.point(scoringTeam: .orange, reason: .thirdBounce)])
        #expect(rules.state.phase == .pointFreeze)
    }

    @Test("A ship hit refreshes the bounce allowance without a center crossing")
    func shipHitResetsBounceAllowance() {
        var rules = MatchRules(allowedFloorBounces: 2)
        _ = rules.resolve([.ballTouchedFloor(side: .cyan)])
        _ = rules.resolve([.ballTouchedFloor(side: .cyan)])

        _ = rules.resolve([.ballTouchedShip(team: .cyan)])

        #expect(rules.state.floorContacts == FloorContactCounts())
        #expect(rules.resolve([.ballTouchedFloor(side: .cyan)]).isEmpty)
        #expect(rules.resolve([.ballTouchedFloor(side: .cyan)]).isEmpty)
        #expect(rules.state.score == Score())
    }

    @Test("The configured allowance scores only after that many bounces")
    func customBounceAllowance() {
        var rules = MatchRules(allowedFloorBounces: 4)

        for _ in 0 ..< 4 {
            #expect(rules.resolve([.ballTouchedFloor(side: .orange)]).isEmpty)
        }
        let events = rules.resolve([.ballTouchedFloor(side: .orange)])

        #expect(events == [.point(scoringTeam: .cyan, reason: .thirdBounce)])
    }

    @Test("Crossing center starts a fresh possession on the entered side")
    func crossingCenterResetsEnteredSide() {
        var rules = MatchRules()
        _ = rules.resolve([.ballTouchedFloor(side: .cyan)])
        _ = rules.resolve([.ballTouchedFloor(side: .cyan)])

        _ = rules.resolve([.ballCrossedCenter(into: .orange)])
        _ = rules.resolve([.ballCrossedCenter(into: .cyan)])

        #expect(rules.state.floorContacts.cyan == 0)
        #expect(rules.resolve([.ballTouchedFloor(side: .cyan)]).isEmpty)
    }

    @Test("Goal outranks a ship death in the same frame")
    func ballEventPrecedesDeath() {
        var rules = MatchRules()

        let events = rules.resolve([
            .shipDestroyed(team: .cyan, reason: .crash),
            .ballEnteredGoal(defending: .orange),
        ])

        #expect(events == [.point(scoringTeam: .cyan, reason: .goal)])
        #expect(rules.state.score.cyan == 1)
    }

    @Test("Simultaneous ship deaths replay without scoring")
    func simultaneousDeathsReplay() {
        var rules = MatchRules()

        let events = rules.resolve([
            .shipDestroyed(team: .cyan, reason: .crash),
            .shipDestroyed(team: .orange, reason: .netContact),
        ])

        #expect(events == [.rallyReset])
        #expect(rules.state.score == Score(cyan: 0, orange: 0))
    }

    @Test("Seven requires a two point lead and eleven is a hard cap")
    func matchEndingRules() {
        var rules = MatchRules(state: MatchRuleState(score: Score(cyan: 6, orange: 6)))
        _ = rules.resolve([.ballEnteredGoal(defending: .orange)])
        #expect(rules.state.phase == .pointFreeze)
        rules.beginNextRally()
        _ = rules.resolve([.ballEnteredGoal(defending: .cyan)])
        rules.beginNextRally()
        _ = rules.resolve([.ballEnteredGoal(defending: .orange)])
        #expect(rules.state.phase == .pointFreeze)
        rules.beginNextRally()
        let winningEvents = rules.resolve([.ballEnteredGoal(defending: .orange)])
        #expect(rules.state.score == Score(cyan: 9, orange: 7))
        #expect(rules.state.phase == .finished)
        #expect(winningEvents.last == .matchEnded(winner: .cyan))

        var capped = MatchRules(state: MatchRuleState(score: Score(cyan: 10, orange: 10)))
        let cappedEvents = capped.resolve([.ballEnteredGoal(defending: .cyan)])
        #expect(capped.state.phase == .finished)
        #expect(cappedEvents.last == .matchEnded(winner: .orange))
    }

    @Test("A disconnect forfeit finishes immediately for the connected player")
    func forfeitFinishesMatch() {
        var rules = MatchRules()

        let events = rules.forfeit(winner: .cyan)

        #expect(rules.state.phase == .finished)
        #expect(rules.state.score.cyan == 1)
        #expect(events == [
            .point(scoringTeam: .cyan, reason: .forfeit),
            .matchEnded(winner: .cyan),
        ])
    }
}
