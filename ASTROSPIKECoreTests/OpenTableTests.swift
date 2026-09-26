import Foundation
import Testing
@testable import ASTROSPIKECore

/// Ian hosts; Maya, Jo and Sam arrive in that order.
private func table(arrivals: [String] = ["maya", "jo", "sam"]) -> OpenTable {
    var table = OpenTable(hostID: "ian")
    for id in arrivals { table.arrive(id) }
    table.seatNextDuel()
    return table
}

/// A table of six: four on the court and Ana and Lee on the bench.
private func fullTable() -> OpenTable {
    table(arrivals: ["maya", "jo", "sam", "ana", "lee"])
}

@Suite("Open table")
struct OpenTableTests {
    @Test("The first pilot to arrive flies the host; a pilot arriving mid-game waits on the bench")
    func firstArrivalOpensTheCourt() {
        var table = table(arrivals: ["maya"])
        #expect(table.plan == ["ian": .cyan, "maya": .orange])
        table.arrive("jo")
        #expect(table.queue == ["jo"])
        #expect(table.benchLine(for: "jo") == "YOU'RE NEXT UP")
        #expect(table.benchLine(for: "maya") == nil)
    }

    @Test("A host alone at the table cannot seat a game")
    func aLoneHostWaits() {
        var table = OpenTable(hostID: "ian")
        let seatedAlone = table.seatNextDuel()
        #expect(!seatedAlone)
        #expect(table.queue == ["ian"])
        #expect(table.nextCourt == nil)
        table.arrive("maya")
        let seatedWithMaya = table.seatNextDuel()
        #expect(seatedWithMaya)
    }

    @Test("Three pilots all fly: two against one and a bot")
    func threeIsTwoAgainstOnePlusABot() {
        var table = table(arrivals: ["maya"])
        table.arrive("jo")
        table.finishDuel(winner: .cyan)
        let seated = table.seatNextDuel()
        #expect(seated)
        #expect(table.queue.isEmpty)
        #expect(table.plan == ["ian": .cyan, "maya": .orange, "jo": .cyanWing])
        #expect(OnlineSeating.roster(filled: Set(table.plan.values), teamUp: false) == Seat.doubles)
        #expect(OpenTable.matchup(of: table.seats) { $0.uppercased() } == "IAN + JO V MAYA + BOT")
    }

    @Test("With three, everyone takes a turn beside the bot")
    func theShortHandedSideRotates() {
        var table = table(arrivals: ["maya", "jo"])
        var shortHanded: [String] = []
        for _ in 0 ..< 3 {
            shortHanded.append(contentsOf: table.side(.orange))
            #expect(table.side(.cyan).count == 2)
            table.finishDuel(winner: .cyan)
            table.seatNextDuel()
        }
        #expect(shortHanded == ["maya", "jo", "ian"])
        #expect(table.queue.isEmpty)
    }

    @Test("Four pilots are two a side and trade partners every game")
    func fourIsTwoASide() {
        var table = table()
        #expect(table.queue.isEmpty)
        #expect(table.side(.cyan) == ["ian", "jo"])
        #expect(table.side(.orange) == ["maya", "sam"])
        var partners: Set<Set<String>> = []
        for _ in 0 ..< 3 {
            partners.insert(Set(table.side(.cyan)))
            partners.insert(Set(table.side(.orange)))
            table.finishDuel(winner: .orange)
            table.seatNextDuel()
        }
        #expect(partners.count == 6)
        #expect(table.court.count == 4)
    }

    @Test("A fourth pilot sitting down fills the bot's chair")
    func aFourthReplacesTheBot() {
        var table = table(arrivals: ["maya", "jo"])
        table.arrive("sam")
        table.finishDuel(winner: .cyan)
        table.seatNextDuel()
        #expect(table.court.count == 4)
        #expect(table.queue.isEmpty)
    }

    @Test("Every pilot on the winning side is credited")
    func teamWins() {
        var table = table(arrivals: ["maya", "jo"])
        table.finishDuel(winner: .cyan)
        #expect(table.wins == ["ian": 1, "jo": 1])
        #expect(table.duelsPlayed == 1)
    }

    @Test("Past four the winning side stays on and the losers go to the back")
    func winnersStayOn() {
        var table = fullTable()
        #expect(table.queue == ["ana", "lee"])
        table.finishDuel(winner: .cyan)
        #expect(table.nextCourt == [.cyan: "ian", .cyanWing: "jo", .orange: "ana", .orangeWing: "lee"])
        let seated = table.seatNextDuel()
        #expect(seated)
        #expect(table.side(.cyan) == ["ian", "jo"])
        #expect(table.side(.orange) == ["ana", "lee"])
        #expect(table.queue == ["maya", "sam"])
    }

    @Test("Everyone gets a turn: the bench always reaches the court")
    func theBenchRotates() {
        var table = fullTable()
        var flown: Set<String> = Set(table.court)
        for _ in 0 ..< 3 {
            // The host's side keeps winning; the bench still cycles through.
            table.finishDuel(winner: .cyan)
            table.seatNextDuel()
            flown.formUnion(table.court)
        }
        #expect(flown == ["ian", "maya", "jo", "sam", "ana", "lee"])
        #expect(table.wins["ian"] == 3)
    }

    @Test("Two pilots and nobody waiting is a rematch")
    func twoPilotsRematch() {
        var table = table(arrivals: ["maya"])
        table.finishDuel(winner: .cyan)
        let seated = table.seatNextDuel()
        #expect(seated)
        #expect(table.plan == ["ian": .cyan, "maya": .orange])
        #expect(OpenTable.matchup(of: table.seats) { $0.uppercased() } == "IAN V MAYA")
    }

    @Test("A game nobody won sends the whole court to the back")
    func noResultMovesTheBenchUp() {
        var table = fullTable()
        table.finishDuel(winner: nil)
        table.seatNextDuel()
        #expect(table.court == ["ana", "lee", "ian", "maya"])
        #expect(table.queue == ["jo", "sam"])
        #expect(table.wins.isEmpty)
    }

    @Test("A court pilot who leaves is not put back in line")
    func aDepartedLoserIsNotRequeued() {
        var table = fullTable()
        table.depart("maya")
        table.finishDuel(winner: .cyan)
        let seated = table.seatNextDuel()
        #expect(seated)
        #expect(table.side(.orange) == ["ana", "lee"])
        #expect(table.queue == ["sam"])
        #expect(!table.contains("maya"))
    }

    @Test("A side left empty is filled from whoever is still here")
    func anEmptySideIsRefilled() {
        var table = table(arrivals: ["maya", "jo"])
        table.depart("maya")
        table.finishDuel(winner: .cyan)
        let seated = table.seatNextDuel()
        #expect(seated)
        #expect(table.isReady)
        #expect(table.court.count == 2)
        #expect(Set(table.plan.values) == Seat.singles)
    }

    @Test("Leaving the bench moves everyone behind up a place")
    func benchDeparture() {
        var table = fullTable()
        table.depart("ana")
        #expect(table.benchLine(for: "lee") == "YOU'RE NEXT UP")
    }

    @Test("Nobody sits down twice, and a full table turns pilots away")
    func arrivalsAreBounded() {
        var table = table()
        let joAgain = table.arrive("jo")
        let hostAgain = table.arrive("ian")
        #expect(!joAgain)
        #expect(!hostAgain)
        let ana = table.arrive("ana")
        let lee = table.arrive("lee")
        #expect(ana && lee)
        #expect(table.pilots.count == OpenTable.maxPilots)
        #expect(table.isFull)
        let kai = table.arrive("kai")
        #expect(!kai)
    }

    @Test("Pilots the host never saw leave are dropped before seating, never the host")
    func keepOnlyThePresent() {
        var table = fullTable()
        table.finishDuel(winner: .orange)
        table.keepOnly(["maya", "sam", "lee"])
        table.seatNextDuel()
        #expect(table.side(.orange) == ["maya", "sam"])
        #expect(table.side(.cyan) == ["lee", "ian"])
        #expect(table.queue.isEmpty)
    }

    @Test("The seat hold is short while somebody is waiting to fly")
    func shortHoldWithABench() {
        #expect(fullTable().seatHoldSeconds(standard: 120) == OpenTable.benchHoldSeconds)
        #expect(table().seatHoldSeconds(standard: 120) == 120)
        #expect(fullTable().seatHoldSeconds(standard: 10) == 10)
    }

    @Test("Standings list winners only, most wins first")
    func standings() {
        var table = table(arrivals: ["maya"])
        table.finishDuel(winner: .orange)
        table.seatNextDuel()
        table.finishDuel(winner: .orange)
        table.seatNextDuel()
        table.finishDuel(winner: .cyan)
        let board = table.standings
        #expect(board.map(\.playerID) == ["maya", "ian"])
        #expect(board.map(\.wins) == [2, 1])
    }

    @Test("The table survives a Game Center round trip")
    func wireRoundTrip() throws {
        var open = fullTable()
        open.finishDuel(winner: .orange)
        let envelope = WireEnvelope(sequence: 7, payload: .table(open))
        let decoded = try WireCodec().decode(WireCodec().encode(envelope))
        #expect(decoded == envelope)
    }

    @Test("A closed table says so on the wire")
    func closingTravels() throws {
        var open = table()
        #expect(!open.isClosed)
        open.close()
        let decoded = try WireCodec().decode(WireCodec().encode(WireEnvelope(sequence: 9, payload: .table(open))))
        guard case let .table(received) = decoded.payload else {
            Issue.record("expected a table payload")
            return
        }
        #expect(received.isClosed)
    }

    @Test("Between duels the link stays up, nothing is flown, and nobody is held")
    func intermissionLifecycle() {
        var lifecycle = OnlineMatchLifecycle()
        lifecycle.beginMatch()
        lifecycle.beginIntermission()
        #expect(lifecycle.acceptsNetworkMessages)
        #expect(!lifecycle.acceptsGameplayData)
        // A pilot dropping between duels leaves the bench; no seat is held.
        let held = lifecycle.beginReconnect()
        #expect(!held)
        // A new face arriving between duels changes nothing.
        let accepted = lifecycle.acceptConnection()
        #expect(accepted)
        #expect(lifecycle.phase == .intermission)
        lifecycle.beginMatch()
        #expect(lifecycle.acceptsGameplayData)
    }

    @Test("The bay names everyone an open table is waiting on")
    func openTableHeadline() {
        #expect(PlayerNetworkCopy.Matchmaking.openTable(waitingFor: ["Maya", "Jo", "Sam"])
            == "OPEN TABLE · WAITING FOR MAYA +2…")
    }
}
