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
        // The whole point: an invite must outlast a locked phone.
        #expect(OnlineTimeouts.inviteConnectSeconds > OnlineTimeouts.automatchConnectSeconds * 2)
    }

    @Test func anInviteeWhoAnsweredDoesNotWaitOutALockedPhone() {
        // The invitee already said yes and the host is in the bay: no person
        // is left to wait for, so JOINING must give up in under a minute.
        #expect(OnlineTimeouts.connectSeconds(role: .invitee) == OnlineTimeouts.inviteeConnectSeconds)
        #expect(OnlineTimeouts.inviteeConnectSeconds <= 60)
        #expect(OnlineTimeouts.acceptedConnectSeconds < OnlineTimeouts.inviteConnectSeconds)
        // Game Center's answer comes well inside the connect window.
        #expect(OnlineTimeouts.joinAnswerSeconds < OnlineTimeouts.inviteeConnectSeconds)
    }
}

private func presence(
    _ id: String,
    _ activity: PilotActivity,
    tag: String? = nil,
    age: TimeInterval = 5
) -> PilotPresence {
    PilotPresence(id: id, name: id.uppercased(), hull: .lancet, activity: activity,
                  matchID: tag, updatedAt: epoch.addingTimeInterval(-age))
}

@Suite("Invite routing") struct InviteRoutingTests {
    @Test func aReplyToTheLastAskDoesNotAnswerTheNextOne() {
        let first = invite()
        let no = StandingInviteReply(inviteID: first.id, guestID: "maya", accepted: false,
                                     repliedAt: epoch.addingTimeInterval(30))
        #expect(StandingInviteBook(invites: [first], replies: [no]).status(of: first, at: epoch.addingTimeInterval(40)) == .declined)
        // Same pair, same record name, asked again an hour later.
        let again = invite(created: 3600)
        let book = StandingInviteBook(invites: [again], replies: [no])
        #expect(book.status(of: again, at: epoch.addingTimeInterval(3601)) == .open)
        #expect(book.inbox(for: "maya", at: epoch.addingTimeInterval(3601)).count == 1)
    }

    @Test func theGroupIsTheSameOnBothPhonesAndNeverQuickMatch() {
        let ask = invite()
        // The guest reads the record back from CloudKit: same fields, so the
        // same pool, computed in a different process.
        let readBack = StandingInvite(
            id: ask.id, hostID: ask.hostID, hostName: ask.hostName, hostHull: ask.hostHull,
            guestID: ask.guestID, guestName: ask.guestName,
            createdAt: Date(timeIntervalSince1970: ask.createdAt.timeIntervalSince1970),
            expiresAt: ask.expiresAt
        )
        #expect(ask.rendezvousGroup == readBack.rendezvousGroup)
        #expect(ask.rendezvousGroup > 0)
        // A second ask to the same pilot is a new pool, so a guest answering
        // the old one cannot land in the new one's search.
        #expect(invite(created: 60).rendezvousGroup != ask.rendezvousGroup)
        #expect(invite(guest: "zoe").rendezvousGroup != ask.rendezvousGroup)
    }

    @Test func aGuestLookingAtTheAppIsMetInGame() {
        let ask = invite()
        #expect(InviteRouting.send(ask, guest: presence("maya", .idle), at: epoch) == .inGame(group: ask.rendezvousGroup))
    }

    @Test func aGuestWhoIsBusyOrAwayGetsThePush() {
        let ask = invite()
        #expect(InviteRouting.send(ask, guest: nil, at: epoch) == .gameCenter)
        #expect(InviteRouting.send(ask, guest: presence("maya", .solo), at: epoch) == .gameCenter)
        // In the bay: no banner there, so the push.
        #expect(InviteRouting.send(ask, guest: presence("maya", .matching), at: epoch) == .gameCenter)
        #expect(InviteRouting.send(ask, guest: presence("maya", .playing), at: epoch) == .gameCenter)
        #expect(InviteRouting.send(ask, guest: presence("maya", .idle, age: 46), at: epoch) == .gameCenter)
        #expect(InviteRouting.send(ask, guest: presence("zoe", .idle), at: epoch) == .gameCenter)
    }

    @Test func aJoinNeverCrossesTheHostsOwnPush() {
        let ask = invite()
        let pushing = presence("ian", .matching, tag: ask.pushTag)
        #expect(InviteRouting.join(ask, host: pushing, at: epoch) == .callHostToPool(group: ask.rendezvousGroup))
        // A push for some other ask, or a host gone quiet, is not this one.
        #expect(InviteRouting.join(ask, host: presence("ian", .matching, tag: "gc:other"), at: epoch) == .gameCenter)
        #expect(InviteRouting.join(ask, host: presence("ian", .matching, tag: ask.pushTag, age: 46), at: epoch) == .gameCenter)
    }

    @Test func theHostLeavesItsPushForThePoolOnlyOnAYes() {
        let ask = invite()
        #expect(InviteRouting.hostMovesToPool(ask, waitingOn: ask.pushTag, status: .accepted))
        #expect(!InviteRouting.hostMovesToPool(ask, waitingOn: ask.pushTag, status: .open))
        #expect(!InviteRouting.hostMovesToPool(ask, waitingOn: ask.pushTag, status: .declined))
        #expect(!InviteRouting.hostMovesToPool(ask, waitingOn: ask.rendezvousTag, status: .accepted))
        #expect(!InviteRouting.hostMovesToPool(ask, waitingOn: nil, status: .accepted))
    }

    @Test func joinMeetsTheHostOnlyWhileItWaitsForThisAsk() {
        let ask = invite()
        let waiting = presence("ian", .matching, tag: ask.rendezvousTag)
        #expect(InviteRouting.join(ask, host: waiting, at: epoch) == .inGame(group: ask.rendezvousGroup))
        // Waiting on something else, gone quiet, or back on the menus: ring them.
        #expect(InviteRouting.join(ask, host: presence("ian", .matching), at: epoch) == .gameCenter)
        #expect(InviteRouting.join(ask, host: presence("ian", .matching, tag: "rv:other"), at: epoch) == .gameCenter)
        #expect(InviteRouting.join(ask, host: presence("ian", .idle, tag: ask.rendezvousTag), at: epoch) == .gameCenter)
        #expect(InviteRouting.join(ask, host: presence("ian", .matching, tag: ask.rendezvousTag, age: 46), at: epoch) == .gameCenter)
        #expect(InviteRouting.join(ask, host: nil, at: epoch) == .gameCenter)
    }
}
