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

@Suite("Open table")
struct OpenTableTests {
    @Test("The first pilot to arrive flies the host; the rest sit on the bench in order")
    func firstArrivalOpensTheCourt() {
        let table = table()
        #expect(table.cyan == "ian")
        #expect(table.orange == "maya")
        #expect(table.queue == ["jo", "sam"])
        #expect(table.plan == ["ian": .cyan, "maya": .orange])
        #expect(table.benchLine(for: "jo") == "YOU'RE NEXT UP")
        #expect(table.benchLine(for: "sam") == "#2 IN LINE")
        #expect(table.benchLine(for: "maya") == nil)
    }

    @Test("A host alone at the table cannot seat a duel")
    func aLoneHostWaits() {
        var table = OpenTable(hostID: "ian")
        let seatedAlone = table.seatNextDuel()
        #expect(!seatedAlone)
        #expect(table.queue == ["ian"])
        table.arrive("maya")
        let seatedWithMaya = table.seatNextDuel()
        #expect(seatedWithMaya)
    }

    @Test("Winner stays on and keeps their colour; the loser goes to the back")
    func winnerStaysOn() {
        var table = table()
        table.finishDuel(winnerID: "maya")
        #expect(table.nextDuel == ["jo", "maya"])
        let seated = table.seatNextDuel()
        #expect(seated)
        #expect(table.cyan == "jo")
        #expect(table.orange == "maya")
        #expect(table.queue == ["sam", "ian"])
        #expect(table.wins == ["maya": 1])
        #expect(table.duelsPlayed == 1)
    }

    @Test("Everyone gets a turn: four duels bring every bench pilot to the court")
    func theBenchRotates() {
        var table = table()
        var flown: Set<String> = Set(table.court)
        for _ in 0 ..< 4 {
            // The host keeps winning; the bench still cycles through.
            table.finishDuel(winnerID: "ian")
            table.seatNextDuel()
            flown.formUnion(table.court)
        }
        #expect(flown == ["ian", "maya", "jo", "sam"])
        #expect(table.wins["ian"] == 4)
    }

    @Test("Two pilots and nobody waiting is a rematch")
    func twoPilotsRematch() {
        var table = table(arrivals: ["maya"])
        table.finishDuel(winnerID: "ian")
        let seated = table.seatNextDuel()
        #expect(seated)
        #expect(table.plan == ["ian": .cyan, "maya": .orange])
    }

    @Test("A duel nobody won sends both pilots to the back")
    func noResultMovesTheBenchUp() {
        var table = table()
        table.finishDuel(winnerID: nil)
        table.seatNextDuel()
        #expect(table.court == ["jo", "sam"])
        #expect(table.queue == ["ian", "maya"])
        #expect(table.wins.isEmpty)
    }

    @Test("A court pilot who leaves is not put back in line")
    func aDepartedLoserIsNotRequeued() {
        var table = table()
        table.depart("maya")
        table.finishDuel(winnerID: "ian")
        let seated = table.seatNextDuel()
        #expect(seated)
        #expect(table.court == ["ian", "jo"])
        #expect(table.queue == ["sam"])
        #expect(!table.contains("maya"))
    }

    @Test("Leaving the bench moves everyone behind up a place")
    func benchDeparture() {
        var table = table()
        table.depart("jo")
        #expect(table.benchLine(for: "sam") == "YOU'RE NEXT UP")
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
        var table = table()
        table.finishDuel(winnerID: "maya")
        table.keepOnly(["maya", "sam"])
        table.seatNextDuel()
        #expect(table.court == ["sam", "maya"])
        #expect(table.queue == ["ian"])
    }

    @Test("The seat hold is short while somebody is waiting to fly")
    func shortHoldWithABench() {
        #expect(table().seatHoldSeconds(standard: 120) == OpenTable.benchHoldSeconds)
        #expect(table(arrivals: ["maya"]).seatHoldSeconds(standard: 120) == 120)
        #expect(table().seatHoldSeconds(standard: 10) == 10)
    }

    @Test("Standings list winners only, most wins first")
    func standings() {
        var table = table()
        table.finishDuel(winnerID: "maya")
        table.seatNextDuel()
        table.finishDuel(winnerID: "maya")
        table.seatNextDuel()
        table.finishDuel(winnerID: "sam")
        let board = table.standings
        #expect(board.map(\.playerID) == ["maya", "sam"])
        #expect(board.map(\.wins) == [2, 1])
    }

    @Test("The table survives a Game Center round trip")
    func wireRoundTrip() throws {
        var open = table()
        open.finishDuel(winnerID: "maya")
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
