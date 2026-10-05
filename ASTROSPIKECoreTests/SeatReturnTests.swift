import Foundation
import Testing
@testable import ASTROSPIKECore

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func presence(_ id: String, tag: String?, age: TimeInterval = 5) -> PilotPresence {
    PilotPresence(id: id, name: id.uppercased(), hull: .lancet, activity: .matching,
                  matchID: tag, updatedAt: epoch.addingTimeInterval(-age))
}

@Suite struct SeatReturnTests {
    @Test func bothEndsWorkOutTheSamePool() {
        // The holder reads its seating, the returner its ticket: different
        // orders, the same chairs.
        let holder = SeatReturn.group(seated: ["maya", "ian"])
        let returner = SeatReturn.group(seated: Set(["ian", "maya"]))
        #expect(holder == returner)
        #expect(holder != 0)
        #expect(holder != SeatReturn.group(seated: ["ian", "sam"]))
    }

    @Test func theHolderOpensTheChairOnlyToThePilotItIsHolding() {
        let group = SeatReturn.group(seated: ["ian", "maya"])
        let tag = SeatReturn.tag(group: group)
        #expect(SeatReturn.isReturning(presence("ian", tag: tag), pilot: "ian", group: group, at: epoch))
        // Someone else wearing the tag is not the pilot whose chair it is.
        #expect(!SeatReturn.isReturning(presence("sam", tag: tag), pilot: "ian", group: group, at: epoch))
        // Another match's pool, or no search at all.
        #expect(!SeatReturn.isReturning(presence("ian", tag: SeatReturn.tag(group: group + 1)), pilot: "ian", group: group, at: epoch))
        #expect(!SeatReturn.isReturning(presence("ian", tag: nil), pilot: "ian", group: group, at: epoch))
        // A presence from a phone that has since gone quiet.
        let stale = presence("ian", tag: tag, age: InviteRouting.presenceWindow + 1)
        #expect(!SeatReturn.isReturning(stale, pilot: "ian", group: group, at: epoch))
    }

    @Test func theTicketRunsOnTheWallClockShortOfTheHold() {
        let ticket = SeatReturnTicket(
            seated: ["ian", "maya"], localID: "ian", opponentNames: ["MAYA"],
            seat: nil, hostID: "maya", leftAt: epoch, holdSeconds: 120
        )
        #expect(ticket.others == ["maya"])
        #expect(ticket.group == SeatReturn.group(seated: ["maya", "ian"]))
        let lastChance = epoch.addingTimeInterval(120 - SeatReturnTicket.margin - 1)
        #expect(ticket.isOpen(at: lastChance))
        #expect(ticket.secondsLeft(at: lastChance) == 1)
        // The others' hold ends on their clock, not ours.
        #expect(!ticket.isOpen(at: epoch.addingTimeInterval(120 - SeatReturnTicket.margin)))
        #expect(ticket.secondsLeft(at: epoch.addingTimeInterval(500)) == 0)
    }
}
