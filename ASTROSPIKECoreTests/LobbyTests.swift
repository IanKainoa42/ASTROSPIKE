import Foundation
import Testing
@testable import ASTROSPIKECore

@Suite("Tournament bracket")
struct TournamentBracketTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func entrant(_ seed: Int) -> TournamentEntrant {
        TournamentEntrant(id: "p\(seed)", name: "Pilot \(seed)", hull: .lancet)
    }

    private func tournament(size: Int, entrants: Int, started: Bool = true) -> Tournament {
        Tournament(
            id: "t1", name: "Friday Cup", organizerID: "p1", size: size,
            entrants: (1 ... entrants).map(entrant),
            createdAt: epoch, startedAt: started ? epoch : nil, updatedAt: epoch
        )
    }

    @Test("Seeding keeps the top two seeds apart until the final")
    func seedOrder() {
        #expect(Bracket.seedOrder(size: 4) == [1, 4, 2, 3])
        #expect(Bracket.seedOrder(size: 8) == [1, 8, 4, 5, 2, 7, 3, 6])
    }

    @Test("A full four-pilot bracket plays two semis and a final")
    func fourPilotBracket() {
        var cup = tournament(size: 4, entrants: 4)
        let first = cup.bracket
        #expect(first.rounds.count == 2)
        #expect(first.readyPairings.map(\.id) == ["r0s0", "r0s1"])
        #expect(first.pairing(round: 0, slot: 0)?.homeID == "p1")
        #expect(first.pairing(round: 0, slot: 0)?.awayID == "p4")
        #expect(first.pairing(round: 0, slot: 1)?.homeID == "p2")
        #expect(first.pairing(round: 0, slot: 1)?.awayID == "p3")
        #expect(first.champion == nil)

        let ok1 = cup.report(TournamentResult(round: 0, slot: 0, winnerID: "p4", score: Score(cyan: 5, orange: 7)), at: epoch)
        #expect(ok1)
        let ok2 = cup.report(TournamentResult(round: 0, slot: 1, winnerID: "p2", score: Score(cyan: 7, orange: 2)), at: epoch)
        #expect(ok2)
        let final = cup.bracket.pairing(round: 1, slot: 0)
        #expect(final?.homeID == "p4")
        #expect(final?.awayID == "p2")
        #expect(final?.isReady == true)
        #expect(cup.status == .underway)

        let ok3 = cup.report(TournamentResult(round: 1, slot: 0, winnerID: "p2", score: Score(cyan: 3, orange: 7)), at: epoch)
        #expect(ok3)
        #expect(cup.bracket.champion == "p2")
        #expect(cup.status == .finished)
        #expect(cup.bracket.isEliminated("p4"))
        #expect(!cup.bracket.isEliminated("p2"))
    }

    @Test("A short bracket pads with byes that advance on their own")
    func byesAdvance() {
        let cup = tournament(size: 8, entrants: 5)
        let bracket = cup.bracket
        // 1v8, 4v5, 2v7, 3v6 with seeds 6-8 missing: 1, 2 and 3 walk through.
        #expect(bracket.pairing(round: 0, slot: 0)?.isBye == true)
        #expect(bracket.pairing(round: 0, slot: 0)?.winnerID == "p1")
        #expect(bracket.pairing(round: 0, slot: 1)?.isReady == true)
        #expect(bracket.pairing(round: 0, slot: 2)?.winnerID == "p2")
        #expect(bracket.pairing(round: 0, slot: 3)?.winnerID == "p3")
        #expect(bracket.readyPairings.map(\.id) == ["r0s1", "r1s1"])
        #expect(bracket.pairing(round: 1, slot: 0)?.homeID == "p1")
        #expect(bracket.pairing(round: 1, slot: 0)?.awayID == nil)
        #expect(bracket.pairing(round: 1, slot: 1)?.homeID == "p2")
        #expect(bracket.pairing(round: 1, slot: 1)?.awayID == "p3")
        #expect(bracket.nextPairing(for: "p1") == nil)
        #expect(bracket.nextPairing(for: "p4")?.opponent(of: "p4") == "p5")
        #expect(bracket.nextPairing(for: "p4")?.inviterID == "p4")
    }

    @Test("Reports are rejected when the fixture is not ready or the winner is a stranger")
    func reportGuards() {
        var cup = tournament(size: 4, entrants: 4)
        // The final has nobody in it yet.
        let ok4 = cup.report(TournamentResult(round: 1, slot: 0, winnerID: "p1", score: Score()), at: epoch)
        #expect(!ok4)
        // Not a pilot in that fixture.
        let ok5 = cup.report(TournamentResult(round: 0, slot: 0, winnerID: "p2", score: Score()), at: epoch)
        #expect(!ok5)
        // Off the bracket entirely.
        let ok6 = cup.report(TournamentResult(round: 3, slot: 0, winnerID: "p1", score: Score()), at: epoch)
        #expect(!ok6)
        let ok7 = cup.report(TournamentResult(round: 0, slot: 0, winnerID: "p1", score: Score(cyan: 7, orange: 0)), at: epoch)
        #expect(ok7)
        // Second report on a decided fixture cannot flip it.
        let ok8 = cup.report(TournamentResult(round: 0, slot: 0, winnerID: "p4", score: Score(cyan: 0, orange: 7)), at: epoch)
        #expect(!ok8)
        #expect(cup.bracket.pairing(round: 0, slot: 0)?.winnerID == "p1")
        #expect(cup.results.count == 1)

        var unstarted = tournament(size: 4, entrants: 4, started: false)
        let ok9 = unstarted.report(TournamentResult(round: 0, slot: 0, winnerID: "p1", score: Score()), at: epoch)
        #expect(!ok9)
    }

    @Test("Joining fills seats in order and the last seat starts the bracket")
    func joiningAndStarting() {
        var cup = Tournament(id: "t2", name: "Cup", organizerID: "p1", size: 4, createdAt: epoch, updatedAt: epoch)
        let ok10 = cup.join(entrant(1), at: epoch)
        #expect(ok10)
        #expect(cup.status == .open)
        #expect(!cup.canStart)
        let ok11 = cup.join(entrant(1), at: epoch)
        #expect(!ok11, "double join")
        let ok12 = cup.join(entrant(2), at: epoch)
        #expect(ok12)
        #expect(cup.canStart)
        let ok13 = cup.start(by: "p2", at: epoch)
        #expect(!ok13, "only the organizer starts short")
        let ok14 = cup.join(entrant(3), at: epoch)
        #expect(ok14)
        let ok15 = cup.join(entrant(4), at: epoch)
        #expect(ok15)
        #expect(cup.hasStarted, "full bracket starts itself")
        #expect(cup.status == .underway)
        let ok16 = cup.join(entrant(5), at: epoch)
        #expect(!ok16, "no joining a started bracket")
        #expect(cup.entrants.map(\.id) == ["p1", "p2", "p3", "p4"])

        var short = Tournament(id: "t3", name: "Cup", organizerID: "p1", size: 8, createdAt: epoch, updatedAt: epoch)
        short.join(entrant(1), at: epoch)
        short.join(entrant(2), at: epoch)
        short.join(entrant(3), at: epoch)
        let ok17 = short.start(by: "p1", at: epoch)
        #expect(ok17)
        #expect(short.bracket.readyPairings.map(\.id) == ["r1s1"], "1 has a bye, 2 v 3 in round two")
        #expect(short.bracket.pairing(round: 1, slot: 1)?.homeID == "p2")
        #expect(short.bracket.pairing(round: 1, slot: 1)?.awayID == "p3")
    }

    @Test("Odd sizes fall back to four")
    func sizeFallback() {
        let cup = Tournament(id: "t4", name: "Cup", organizerID: "p1", size: 6, createdAt: epoch, updatedAt: epoch)
        #expect(cup.size == 4)
        #expect(cup.bracket.rounds.count == 2)
    }

    @Test("Tournament survives a JSON round trip")
    func codableRoundTrip() throws {
        var cup = tournament(size: 8, entrants: 6)
        cup.report(TournamentResult(round: 0, slot: 1, winnerID: "p5", score: Score(cyan: 4, orange: 7)), at: epoch)
        let data = try JSONEncoder().encode(cup)
        let decoded = try JSONDecoder().decode(Tournament.self, from: data)
        #expect(decoded == cup)
        #expect(decoded.bracket == cup.bracket)
    }
}

@Suite("Lobby snapshot")
struct LobbySnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func pilot(_ id: String, name: String, secondsAgo: TimeInterval, activity: PilotActivity = .idle) -> PilotPresence {
        PilotPresence(id: id, name: name, hull: .anvil, activity: activity, updatedAt: now.addingTimeInterval(-secondsAgo))
    }

    private func match(_ id: String, secondsAgo: TimeInterval, phase: MatchPhase = .playing) -> LiveMatch {
        LiveMatch(
            id: id, hostID: "h", cyanID: "h", cyanName: "Host", orangeID: "g", orangeName: "Guest",
            score: Score(cyan: 3, orange: 1), phase: phase, winner: phase == .finished ? .cyan : nil,
            startedAt: now.addingTimeInterval(-secondsAgo - 60), updatedAt: now.addingTimeInterval(-secondsAgo)
        )
    }

    @Test("Online pilots drop the stale and the self, friends float to the top")
    func onlineOrdering() {
        let snapshot = LobbySnapshot(pilots: [
            pilot("me", name: "Me", secondsAgo: 0),
            pilot("zed", name: "Zed", secondsAgo: 10),
            pilot("amy", name: "amy", secondsAgo: 20),
            pilot("bob", name: "Bob", secondsAgo: 30),
            pilot("old", name: "Old", secondsAgo: LobbySnapshot.staleAfter + 1),
        ])
        let online = snapshot.onlinePilots(at: now, friends: ["zed"], excluding: "me")
        #expect(online.map(\.id) == ["zed", "amy", "bob"])
    }

    @Test("Live duels exclude finished and abandoned ones, newest first")
    func liveMatches() {
        let snapshot = LobbySnapshot(matches: [
            match("older", secondsAgo: 40),
            match("done", secondsAgo: 5, phase: .finished),
            match("newer", secondsAgo: 2),
            match("abandoned", secondsAgo: LobbySnapshot.matchStaleAfter + 1),
        ])
        #expect(snapshot.liveMatches(at: now).map(\.id) == ["newer", "older"])
        #expect(snapshot.recentResults().map(\.id) == ["done"])
        #expect(snapshot.matches[0].scoreline == "3 – 1")
        #expect(snapshot.matches[0].involves("g"))
        #expect(!snapshot.matches[0].involves("me"))
    }

    @Test("Visible tournaments: mine, then open, then underway, never finished")
    func tournamentOrdering() {
        let me = TournamentEntrant(id: "me", name: "Me", hull: .lancet)
        let other = TournamentEntrant(id: "o", name: "Other", hull: .anvil)
        let mine = Tournament(id: "mine", name: "Mine", organizerID: "o", size: 4, entrants: [other, me], createdAt: now, updatedAt: now)
        let open = Tournament(id: "open", name: "Open", organizerID: "o", size: 4, entrants: [other], createdAt: now.addingTimeInterval(-10), updatedAt: now)
        let underway = Tournament(id: "under", name: "Under", organizerID: "o", size: 4, entrants: [other, TournamentEntrant(id: "x", name: "X", hull: .anvil)], createdAt: now, startedAt: now, updatedAt: now)
        var finished = Tournament(id: "fin", name: "Fin", organizerID: "o", size: 4, entrants: [other, TournamentEntrant(id: "x", name: "X", hull: .anvil)], createdAt: now, startedAt: now, updatedAt: now)
        // Two entrants in a four-slot bracket: both first-round fixtures are
        // byes, so the final is the only match that ever flies.
        let reported = finished.report(TournamentResult(round: 1, slot: 0, winnerID: "o", score: Score(cyan: 7, orange: 1)), at: now)
        #expect(reported)
        #expect(finished.status == .finished)
        let snapshot = LobbySnapshot(tournaments: [finished, underway, open, mine])
        #expect(snapshot.visibleTournaments(for: "me").map(\.id) == ["mine", "open", "under"])
    }

    @Test("A duel between bracket rivals is their fixture; anyone else's is not")
    func fixtureLookup() {
        let pilots = (1 ... 4).map { TournamentEntrant(id: "p\($0)", name: "P\($0)", hull: .lancet) }
        let cup = Tournament(id: "cup", name: "Cup", organizerID: "p1", size: 4, entrants: pilots, createdAt: now, startedAt: now, updatedAt: now)
        let snapshot = LobbySnapshot(tournaments: [cup])
        #expect(snapshot.fixture(between: "p4", and: "p1") == TournamentFixture(tournamentID: "cup", round: 0, slot: 0))
        #expect(snapshot.fixture(between: "p2", and: "p3") == TournamentFixture(tournamentID: "cup", round: 0, slot: 1))
        #expect(snapshot.fixture(between: "p1", and: "p2") == nil, "not until the final")
        #expect(snapshot.fixture(between: "p1", and: "stranger") == nil)
    }
}
