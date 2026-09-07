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
        #expect(rules.state.phase == .serve)
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
        #expect(rules.state.phase == .serve)
        rules.beginNextRally()
        _ = rules.resolve([.ballEnteredGoal(defending: .cyan)])
        rules.beginNextRally()
        _ = rules.resolve([.ballEnteredGoal(defending: .orange)])
        #expect(rules.state.phase == .serve)
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

    @Test("Best of three: a set point resets the score, the second set takes the match")
    func bestOfThree() {
        var rules = MatchRules(state: MatchRuleState(score: Score(cyan: 6, orange: 2), setsToWin: 2))
        let setEvents = rules.resolve([.ballEnteredGoal(defending: .orange)])
        #expect(setEvents == [
            .point(scoringTeam: .cyan, reason: .goal),
            .setEnded(winner: .cyan, sets: Score(cyan: 1, orange: 0)),
        ])
        #expect(rules.state.sets == Score(cyan: 1, orange: 0))
        #expect(rules.state.score == Score())
        #expect(rules.state.phase == .serve)
        #expect(rules.state.winner == nil)

        rules.beginNextRally()
        var second = MatchRules(state: MatchRuleState(score: Score(cyan: 6, orange: 0), sets: rules.state.sets, setsToWin: 2))
        let matchEvents = second.resolve([.ballEnteredGoal(defending: .orange)])
        #expect(matchEvents.last == .matchEnded(winner: .cyan))
        #expect(second.state.sets == Score(cyan: 2, orange: 0))
        #expect(second.state.phase == .finished)
        #expect(second.state.winner == .cyan)
    }

    @Test("A single game still ends on the first set")
    func singleGameIsOneSet() {
        var rules = MatchRules(state: MatchRuleState(score: Score(cyan: 6, orange: 0)))
        let events = rules.resolve([.ballEnteredGoal(defending: .orange)])
        #expect(events.last == .matchEnded(winner: .cyan))
        #expect(rules.state.sets == Score(cyan: 1, orange: 0))
        #expect(rules.state.winner == .cyan)
    }

    @Test("The format rides along in the state through the engine")
    func formatSurvivesAnEngineRebuild() {
        var engine = SimulationEngine.testing()
        engine.setMatchFormat(setsToWin: 3)
        #expect(engine.state.match.setsToWin == 3)
        let rebuilt = SimulationEngine(state: engine.state)
        #expect(rebuilt.state.match.setsToWin == 3)
        var clamped = SimulationEngine.testing()
        clamped.setMatchFormat(setsToWin: 9)
        #expect(clamped.state.match.setsToWin == 3)
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
