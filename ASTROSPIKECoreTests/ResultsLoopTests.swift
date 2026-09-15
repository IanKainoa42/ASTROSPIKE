import Testing
@testable import ASTROSPIKECore

@Suite("Results loop")
struct ResultsLoopTests {
    @Test("The rival ladder is Rookie, then Pilot, then Ace")
    func rivalLadder() {
        #expect(AIDifficulty.rookie.next == .pilot)
        #expect(AIDifficulty.pilot.next == .ace)
        #expect(AIDifficulty.ace.next == nil)
    }

    @Test("A solo win offers play-again and the next rival")
    func offlineWinOffersTheNextRung() {
        let plan = ResultsPlan(offline: true, localWon: true, rival: .rookie)
        #expect(plan.canPlayAgain)
        #expect(plan.nextRival == .pilot)
    }

    @Test("Beating Ace still offers play-again and no harder rival")
    func aceWinHasNowhereLeftToClimb() {
        let plan = ResultsPlan(offline: true, localWon: true, rival: .ace)
        #expect(plan.canPlayAgain)
        #expect(plan.nextRival == nil)
    }

    @Test("A loss offers a rematch against the same rival, not a harder one")
    func lossRetriesTheSameRung() {
        let plan = ResultsPlan(offline: true, localWon: false, rival: .rookie)
        #expect(plan.canPlayAgain)
        #expect(plan.nextRival == nil)
    }

    @Test("An online duel does not offer play-again or a bot climb")
    func onlineMatchEndsAtTheMenu() {
        let plan = ResultsPlan(offline: false, localWon: true, rival: nil)
        #expect(!plan.canPlayAgain)
        #expect(plan.nextRival == nil)
    }

    @Test("The match-end cue follows the local winner, not the event itself")
    func matchEndCueTracksTheLocalSide() {
        #expect(MatchEndCue.forLocalSide(.cyan, winner: .cyan) == .win)
        #expect(MatchEndCue.forLocalSide(.cyan, winner: .orange) == .lose)
        #expect(MatchEndCue.forLocalSide(.orange, winner: .orange) == .win)
    }

    @Test("Resetting a finished match starts a fresh countdown at love")
    func resetMatchClearsAFinishedBoard() {
        var rules = MatchRules(state: MatchRuleState(score: Score(cyan: 7, orange: 3)))
        _ = rules.forfeit(winner: .cyan)
        #expect(rules.state.phase == .finished)

        rules.resetMatch()

        #expect(rules.state.phase == .countdown)
        #expect(rules.state.score == Score())
        #expect(rules.state.sets == Score())
        #expect(rules.state.winner == nil)
        #expect(rules.state.setsToWin == 1)
    }

    @Test("Restarting a finished engine reseats both ships and keeps the format")
    func restartMatchReseatsAFinishedEngine() {
        var engine = SimulationEngine.testing()
        engine.setMatchFormat(setsToWin: 2)
        engine.finishByForfeit(winner: .orange)
        #expect(engine.state.match.phase == .finished)

        engine.restartMatch()

        #expect(engine.state.match.phase == .countdown)
        #expect(engine.state.match.score == Score())
        #expect(engine.state.match.sets == Score())
        #expect(engine.state.match.winner == nil)
        #expect(engine.state.match.setsToWin == 2)
        #expect(engine.state.sidesSwapped == false)
        #expect(Set(engine.state.ships.keys) == Seat.singles)
        #expect(engine.state.tick == 0)
    }
}
