import Testing
@testable import ASTROSPIKECore

@Suite("Match rules")
struct MatchRulesTests {
    @Test("A rattle against the wall tallies one touch, not five")
    func uncountedTouchesDoNotSpendTheAllowance() {
        var rules = MatchRules(allowedFloorBounces: 2)
        _ = rules.resolve([.ballTouchedShip(team: .cyan, counted: true)])
        // The same hull, re-hit on the next few steps because the ball is
        // pinned on the wall. Four more contacts, still one hit.
        for _ in 0 ..< 4 {
            #expect(rules.resolve([.ballTouchedShip(team: .cyan, counted: false)]).isEmpty)
        }

        #expect(rules.state.shipTouches[.cyan] == 1)
        #expect(rules.state.score == Score())
    }

    @Test("A free contact still refreshes the bounce allowance")
    func uncountedTouchStillClearsFloorContacts() {
        var rules = MatchRules(allowedFloorBounces: 2)
        _ = rules.resolve([.ballTouchedFloor(side: .cyan)])
        _ = rules.resolve([.ballTouchedFloor(side: .cyan)])

        _ = rules.resolve([.ballTouchedShip(team: .cyan, counted: false)])

        // Otherwise the debounce would just move the unfair loss onto the
        // next floor bounce.
        #expect(rules.state.floorContacts == FloorContactCounts())
        #expect(rules.resolve([.ballTouchedFloor(side: .cyan)]).isEmpty)
        #expect(rules.state.score == Score())
    }

    @Test("Touches are never a fault: only the floor ends a rally")
    func touchesAreUnlimited() {
        var rules = MatchRules(allowedFloorBounces: 2)
        // Far past the three the old rulebook allowed, on the same half,
        // with the ball never crossing over. Keep-up all day.
        for _ in 0 ..< 40 {
            #expect(rules.resolve([.ballTouchedShip(team: .cyan, counted: true)]).isEmpty)
        }
        #expect(rules.state.shipTouches[.cyan] == 40)
        #expect(rules.state.score == Score())
        #expect(rules.state.phase == .playing)

        // The floor is still live: one bounce too many and it is theirs.
        _ = rules.resolve([.ballTouchedFloor(side: .cyan)])
        _ = rules.resolve([.ballTouchedFloor(side: .cyan)])
        let events = rules.resolve([.ballTouchedFloor(side: .cyan)])
        #expect(events == [.point(scoringTeam: .orange, reason: .thirdBounce)])
    }

    @Test("Juggling clears the bounces every time, so a bounce between touches never adds up")
    func touchBounceTouchBounceIsLegal() {
        var rules = MatchRules(allowedFloorBounces: 1)
        for _ in 0 ..< 12 {
            #expect(rules.resolve([.ballTouchedShip(team: .cyan, counted: true)]).isEmpty)
            #expect(rules.resolve([.ballTouchedFloor(side: .cyan)]).isEmpty)
        }
        #expect(rules.state.score == Score())
    }

    @Test("The other side touching the ball clears your tally, even without it crossing over")
    func opponentTouchResetsYourCount() {
        var rules = MatchRules(allowedFloorBounces: 2)
        for _ in 0 ..< 3 {
            #expect(rules.resolve([.ballTouchedShip(team: .cyan, counted: true)]).isEmpty)
        }
        #expect(rules.state.shipTouches[.cyan] == 3)
        // Orange pokes it back into cyan's half without a center crossing.
        #expect(rules.resolve([.ballTouchedShip(team: .orange, counted: true)]).isEmpty)
        #expect(rules.state.shipTouches[.cyan] == 0)
        #expect(rules.state.shipTouches[.orange] == 1)
    }

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

        _ = rules.resolve([.ballTouchedShip(team: .cyan, counted: true)])

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

@Suite("Stakes")
struct MatchStakeTests {
    @Test("Nobody is at stake from love")
    func loveIsQuiet() {
        let state = MatchRuleState()
        #expect(state.stake(for: .cyan) == .none)
        #expect(state.stake(for: .orange) == .none)
        #expect(state.headlineStake == nil)
    }

    @Test("Six-four is set point, and only for the leader")
    func setPointNeedsTwoClear() {
        // Best of three, or the single-set default would make this match point.
        let state = MatchRuleState(score: Score(cyan: 6, orange: 4), setsToWin: 2)
        #expect(state.stake(for: .cyan) == .setPoint)
        #expect(state.stake(for: .orange) == .none)
        #expect(state.headlineStake?.team == .cyan)
    }

    @Test("Six-all is nobody's set point: seven-six is not two clear")
    func oneClearIsNotSetPoint() {
        let state = MatchRuleState(score: Score(cyan: 6, orange: 6), setsToWin: 2)
        #expect(state.stake(for: .cyan) == .none)
        #expect(state.stake(for: .orange) == .none)
    }

    @Test("At the ceiling both sides are at set point")
    func ceilingPutsBothAtStake() {
        let state = MatchRuleState(score: Score(cyan: 10, orange: 10), setsToWin: 2)
        #expect(state.stake(for: .cyan) == .setPoint)
        #expect(state.stake(for: .orange) == .setPoint)
        // Level, so the tie resolves to cyan rather than to nothing.
        #expect(state.headlineStake?.team == .cyan)
    }

    @Test("A single-set match makes every set point a match point")
    func singleSetIsAlwaysMatchPoint() {
        let state = MatchRuleState(score: Score(cyan: 6, orange: 4))
        #expect(state.stake(for: .cyan) == .matchPoint)
    }

    @Test("The set that would take the match reads as match point")
    func lastSetIsMatchPoint() {
        let state = MatchRuleState(
            score: Score(cyan: 6, orange: 0),
            sets: Score(cyan: 1, orange: 0),
            setsToWin: 2
        )
        #expect(state.stake(for: .cyan) == .matchPoint)
    }

    @Test("A set point in a best of three is only a set point")
    func earlierSetIsNotMatchPoint() {
        let state = MatchRuleState(score: Score(cyan: 6, orange: 0), setsToWin: 2)
        #expect(state.stake(for: .cyan) == .setPoint)
    }

    @Test("A finished match has nothing left on the line")
    func finishedMatchHasNoStake() {
        let state = MatchRuleState(
            score: Score(cyan: 6, orange: 4),
            phase: .finished,
            winner: .cyan
        )

        #expect(state.stake(for: .cyan) == .none)
        #expect(state.headlineStake == nil)
    }

    @Test("The HUD's question and the rule that ends the set are the same one")
    func stakeAgreesWithTheWinCondition() {
        for cyan in 0...12 {
            for orange in 0...12 {
                var rules = MatchRules(state: MatchRuleState(score: Score(cyan: cyan, orange: orange)))
                let predicted = rules.state.stake(for: .cyan) != .none
                _ = rules.resolve([.ballEnteredGoal(defending: .orange)])
                let actuallyEnded = rules.state.phase == .finished || rules.state.score == Score()
                #expect(predicted == actuallyEnded, "cyan \(cyan)-\(orange)")
            }
        }
    }

    @Test("Two-ball goals keep playing until the set is decided")
    func goalsKeepPlaying() {
        var rules = MatchRules(state: MatchRuleState(phase: .playing))
        let events = rules.resolve([.ballEnteredGoal(defending: .cyan)], goalsKeepPlaying: true)
        #expect(rules.state.score.orange == 1)
        #expect(rules.state.phase == .playing)
        #expect(events.contains { if case .point = $0 { true } else { false } })
        // Both balls in on one step: two points, still playing.
        _ = rules.resolve([.ballEnteredGoal(defending: .cyan), .ballEnteredGoal(defending: .orange)], goalsKeepPlaying: true)
        #expect(rules.state.score == Score(cyan: 1, orange: 2))
        #expect(rules.state.phase == .playing)
        // One ball: a goal is a serve, as ever.
        var single = MatchRules(state: MatchRuleState(phase: .playing))
        _ = single.resolve([.ballEnteredGoal(defending: .cyan)])
        #expect(single.state.phase == .serve)
    }

    @Test("A two-ball goal that ends the set still stops for the serve")
    func setPointStopsTwoBallPlay() {
        var rules = MatchRules(state: MatchRuleState(score: Score(cyan: 0, orange: 6), phase: .playing, setsToWin: 2))
        let events = rules.resolve([.ballEnteredGoal(defending: .cyan), .ballEnteredGoal(defending: .cyan)], goalsKeepPlaying: true)
        #expect(events.contains { if case .setEnded = $0 { true } else { false } })
        #expect(rules.state.phase == .serve)
        // The second ball's goal lands after the set is over: it is dropped.
        #expect(rules.state.score == Score())
        #expect(rules.state.sets.orange == 1)
    }
}
