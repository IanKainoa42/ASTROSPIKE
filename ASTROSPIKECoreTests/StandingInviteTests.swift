import Foundation
import Testing
@testable import ASTROSPIKECore

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func invite(
    host: String = "ian",
    guest: String = "maya",
    created: TimeInterval = 0,
    lifetime: TimeInterval = StandingInviteBook.lifetime,
    withdrawn: Bool = false
) -> StandingInvite {
    let createdAt = epoch.addingTimeInterval(created)
    return StandingInvite(
        id: StandingInvite.id(hostID: host, guestID: guest),
        hostID: host,
        hostName: host.uppercased(),
        hostHull: .lancet,
        guestID: guest,
        guestName: guest.uppercased(),
        createdAt: createdAt,
        expiresAt: createdAt.addingTimeInterval(lifetime),
        withdrawn: withdrawn
    )
}

@Suite struct StandingInviteTests {
    @Test func openInviteReachesTheGuestInbox() {
        let book = StandingInviteBook(invites: [invite()])
        #expect(book.inbox(for: "maya", at: epoch).count == 1)
        #expect(book.outbox(from: "ian", at: epoch).count == 1)
        // Neither end sees the other's side of it.
        #expect(book.outbox(from: "maya", at: epoch).isEmpty)
        #expect(book.inbox(for: "ian", at: epoch).isEmpty)
    }

    @Test func anInviteAgesOut() {
        let book = StandingInviteBook(invites: [invite()])
        let later = epoch.addingTimeInterval(StandingInviteBook.lifetime + 1)
        #expect(book.status(of: invite(), at: later) == .expired)
        #expect(book.inbox(for: "maya", at: later).isEmpty)
    }

    @Test func anAnswerBeatsTheClock() {
        // Accepted a minute before the window shut: still accepted an hour
        // later, not silently expired.
        let sent = invite()
        let reply = StandingInviteReply(
            inviteID: sent.id,
            guestID: "maya",
            accepted: true,
            repliedAt: sent.expiresAt.addingTimeInterval(-60)
        )
        let book = StandingInviteBook(invites: [sent], replies: [reply])
        #expect(book.status(of: sent, at: sent.expiresAt.addingTimeInterval(3600)) == .accepted)
    }

    @Test func answeringClearsBothScreens() {
        let sent = invite()
        for accepted in [true, false] {
            let reply = StandingInviteReply(
                inviteID: sent.id, guestID: "maya", accepted: accepted, repliedAt: epoch
            )
            let book = StandingInviteBook(invites: [sent], replies: [reply])
            #expect(book.inbox(for: "maya", at: epoch).isEmpty)
            #expect(book.outbox(from: "ian", at: epoch).isEmpty)
            #expect(book.status(of: sent, at: epoch) == (accepted ? .accepted : .declined))
        }
    }

    @Test func theHostCanTakeItBack() {
        let pulled = invite(withdrawn: true)
        let book = StandingInviteBook(invites: [pulled])
        #expect(book.status(of: pulled, at: epoch) == .withdrawn)
        #expect(book.inbox(for: "maya", at: epoch).isEmpty)
    }

    @Test func anAnswerAlreadyGivenSurvivesAWithdrawal() {
        // The guest tapped JOIN and is already sending the live invite; the
        // host pulling the record must not un-accept it under them.
        let pulled = invite(withdrawn: true)
        let reply = StandingInviteReply(
            inviteID: pulled.id, guestID: "maya", accepted: true, repliedAt: epoch
        )
        let book = StandingInviteBook(invites: [pulled], replies: [reply])
        #expect(book.status(of: pulled, at: epoch) == .accepted)
    }

    @Test func reinvitingTheSamePilotReplacesRatherThanStacks() {
        let first = invite(created: 0)
        let second = invite(created: 600)
        let book = StandingInviteBook(invites: [first, second])
        #expect(book.invites.count == 1)
        #expect(book.invites.first?.createdAt == second.createdAt)
        #expect(book.inbox(for: "maya", at: epoch.addingTimeInterval(600)).count == 1)
    }

    @Test func theNewestReplyWins() {
        let sent = invite()
        let no = StandingInviteReply(inviteID: sent.id, guestID: "maya", accepted: false, repliedAt: epoch)
        let yes = StandingInviteReply(
            inviteID: sent.id, guestID: "maya", accepted: true,
            repliedAt: epoch.addingTimeInterval(30)
        )
        #expect(StandingInviteBook(invites: [sent], replies: [no, yes]).status(of: sent, at: epoch) == .accepted)
        #expect(StandingInviteBook(invites: [sent], replies: [yes, no]).status(of: sent, at: epoch) == .accepted)
    }

    @Test func inboxIsNewestFirstAcrossHosts() {
        let old = invite(host: "ian", created: 0)
        let new = invite(host: "sam", created: 900)
        let book = StandingInviteBook(invites: [old, new])
        #expect(book.inbox(for: "maya", at: epoch.addingTimeInterval(900)).map(\.hostID) == ["sam", "ian"])
    }

    @Test func aWaitingInviteStopsTheButtonSendingAnother() {
        let book = StandingInviteBook(invites: [invite()])
        #expect(book.hasOpenInvite(from: "ian", to: "maya", at: epoch))
        #expect(!book.hasOpenInvite(from: "ian", to: "sam", at: epoch))
        let stale = epoch.addingTimeInterval(StandingInviteBook.lifetime + 1)
        #expect(!book.hasOpenInvite(from: "ian", to: "maya", at: stale))
    }

    @Test func settledAsksAreReportedBackToTheHost() {
        let toMaya = invite(guest: "maya")
        let toSam = invite(guest: "sam")
        let reply = StandingInviteReply(
            inviteID: toMaya.id, guestID: "maya", accepted: false, repliedAt: epoch
        )
        let book = StandingInviteBook(invites: [toMaya, toSam], replies: [reply])
        let answers = book.answers(for: "ian", at: epoch)
        #expect(answers.count == 1)
        #expect(answers.first?.invite.guestID == "maya")
        #expect(answers.first?.status == .declined)
    }

    @Test func idIsStablePerPairAndNotReversible() {
        #expect(StandingInvite.id(hostID: "ian", guestID: "maya")
            == StandingInvite.id(hostID: "ian", guestID: "maya"))
        #expect(StandingInvite.id(hostID: "ian", guestID: "maya")
            != StandingInvite.id(hostID: "maya", guestID: "ian"))
    }

    @Test func aStandingInviteRoundTripsThroughJSON() {
        let sent = invite()
        let data = try! JSONEncoder().encode(sent)
        #expect(try! JSONDecoder().decode(StandingInvite.self, from: data) == sent)
    }
}

@Suite struct OnlineTimeoutTests {
    @Test func aPersonGetsLongerThanAMatchmakingServer() {
        #expect(OnlineTimeouts.connectSeconds(role: .automatch) == OnlineTimeouts.automatchConnectSeconds)
        #expect(OnlineTimeouts.connectSeconds(role: .inviter) == OnlineTimeouts.inviteConnectSeconds)
        #expect(OnlineTimeouts.connectSeconds(role: .invitee) == OnlineTimeouts.inviteConnectSeconds)
        // The whole point: an invite must outlast a locked phone.
        #expect(OnlineTimeouts.inviteConnectSeconds > OnlineTimeouts.automatchConnectSeconds * 2)
    }
}
