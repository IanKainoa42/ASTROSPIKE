import Foundation
import Testing
@testable import ASTROSPIKECore

@Suite("Head to head")
struct HeadToHeadTests {
    @Test func tenGamesAgainstBillyBobAreAllRemembered() {
        var ledger = HeadToHeadLedger()
        for game in 0..<10 {
            ledger.record(opponentID: "G:billy", name: "Billy Bob", won: game < 6)
        }
        let record = ledger.record(for: "G:billy")
        #expect(record?.wins == 6)
        #expect(record?.losses == 4)
        #expect(record?.games == 10)
        #expect(record?.scoreText == "6–4")
    }

    @Test func opponentsAreKeptApartAndRenamesFollowTheID() {
        var ledger = HeadToHeadLedger()
        ledger.record(opponentID: "a", name: "Old", won: true)
        ledger.record(opponentID: "b", name: "Maya", won: false)
        ledger.record(opponentID: "a", name: "New", won: false)
        #expect(ledger.rivals.count == 2)
        #expect(ledger.record(for: "a")?.name == "New")
        #expect(ledger.record(for: "a")?.scoreText == "1–1")
        #expect(ledger.record(for: "b")?.scoreText == "0–1")
    }

    @Test func mostPlayedSortsFirstAndLedgerRoundTrips() throws {
        var ledger = HeadToHeadLedger()
        ledger.record(opponentID: "once", name: "Once", won: true)
        ledger.record(opponentID: "twice", name: "Twice", won: true)
        ledger.record(opponentID: "twice", name: "Twice", won: true)
        #expect(ledger.sorted.map(\.id) == ["twice", "once"])
        let decoded = try JSONDecoder().decode(HeadToHeadLedger.self, from: JSONEncoder().encode(ledger))
        #expect(decoded == ledger)
    }
}
