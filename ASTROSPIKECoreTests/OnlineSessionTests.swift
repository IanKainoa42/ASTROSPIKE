import Testing
@testable import ASTROSPIKECore

@Suite("Online session recovery")
struct OnlineSessionTests {
    @Test("Reconnect within ten seconds requests a full resync")
    func reconnectRequestsResync() {
        var session = OnlineSessionStateMachine(localTeam: .cyan, ticksPerSecond: 120)

        #expect(session.remoteDisconnected(at: 200) == [.pause])
        #expect(session.advance(to: 1_399).isEmpty)
        #expect(session.remoteReconnected(at: 1_399) == [.requestFullResync, .startCountdown])
        #expect(session.phase == .playing)
    }

    @Test("Missing the ten second deadline awards a forfeit")
    func timeoutAwardsForfeit() {
        var session = OnlineSessionStateMachine(localTeam: .orange, ticksPerSecond: 120)
        _ = session.remoteDisconnected(at: 50)

        #expect(session.advance(to: 1_249).isEmpty)
        #expect(session.advance(to: 1_250) == [.forfeit(winner: .orange)])
        #expect(session.phase == .forfeited(winner: .orange))
    }

    @Test("A longer seat hold moves the forfeit deadline with it")
    func seatHoldWindowIsConfigurable() {
        var session = OnlineSessionStateMachine(localTeam: .cyan, ticksPerSecond: 120, reconnectWindowSeconds: 120)
        #expect(session.remoteDisconnected(at: 0) == [.pause])
        #expect(session.advance(to: 14_399).isEmpty)
        #expect(session.advance(to: 14_400) == [.forfeit(winner: .cyan)])
    }

    @Test("A terminal match ignores delayed reconnect callbacks")
    func terminalMatchCannotReconnect() {
        var lifecycle = OnlineMatchLifecycle()
        lifecycle.beginMatch()
        lifecycle.beginReconnect()
        lifecycle.finish()

        let accepted = lifecycle.acceptConnection()
        #expect(!accepted)
        #expect(lifecycle.phase == .terminal)
    }

    @Test("Reset allows a new match after a terminal result")
    func resetAllowsNextMatch() {
        var lifecycle = OnlineMatchLifecycle()
        lifecycle.beginMatch()
        lifecycle.finish()
        lifecycle.reset()

        #expect(lifecycle.phase == .idle)
        lifecycle.beginMatch()
        let accepted = lifecycle.acceptConnection()
        #expect(accepted)
        #expect(lifecycle.phase == .active)
    }

    @Test("Idle and terminal matches reject gameplay callbacks")
    func inactiveMatchesRejectCallbacks() {
        var lifecycle = OnlineMatchLifecycle()

        let idleConnection = lifecycle.acceptConnection()
        #expect(!idleConnection)
        #expect(!lifecycle.acceptsGameplayData)

        lifecycle.beginMatch()
        #expect(lifecycle.acceptsGameplayData)
        lifecycle.finish()
        #expect(!lifecycle.acceptsGameplayData)
        #expect(!lifecycle.acceptsNetworkMessages)
        let acceptedReconnect = lifecycle.beginReconnect()
        #expect(!acceptedReconnect)
        #expect(lifecycle.phase == .terminal)
    }

    @Test("Configuration accepts setup traffic without enabling gameplay")
    func configurationAcceptsOnlySetupTraffic() {
        var lifecycle = OnlineMatchLifecycle()
        lifecycle.beginConfiguration()

        #expect(lifecycle.acceptsNetworkMessages)
        #expect(!lifecycle.acceptsGameplayData)
        let acceptedConnection = lifecycle.acceptConnection()
        #expect(acceptedConnection)
        #expect(lifecycle.phase == .configuring)
    }
}

@Suite("Online seating")
struct OnlineSeatingTests {
    @Test("The inviter hosts even when a guest has the lower player ID")
    func inviterHosts() {
        let hosts = OnlineSeating.localHosts(localID: "A:_9", peerIDs: ["A:_1"], role: .inviter)
        #expect(hosts)
    }

    @Test("An invitee never hosts, even with the lowest player ID")
    func inviteeNeverHosts() {
        let hosts = OnlineSeating.localHosts(localID: "A:_1", peerIDs: ["A:_9"], role: .invitee)
        #expect(!hosts)
    }

    @Test("Automatch ends agree on the lowest player ID as host")
    func automatchElectsLowestID() {
        let low = OnlineSeating.localHosts(localID: "A:_1", peerIDs: ["A:_5", "A:_9"], role: .automatch)
        let high = OnlineSeating.localHosts(localID: "A:_9", peerIDs: ["A:_1", "A:_5"], role: .automatch)
        #expect(low)
        #expect(!high)
    }

    @Test("Ready means every seated peer has answered, whatever GameKit expects")
    func readinessFollowsTheSeatingPlan() {
        let seating: [String: Seat] = ["host": .cyan, "guest": .orange, "wing": .cyanWing]
        let oneMissing = OnlineSeating.allPeersReady(seating: seating, localID: "host", readyPeers: ["guest"])
        let everyone = OnlineSeating.allPeersReady(seating: seating, localID: "host", readyPeers: ["guest", "wing"])
        let nobodySeated = OnlineSeating.allPeersReady(seating: [:], localID: "host", readyPeers: ["guest"])
        let onlyLocal = OnlineSeating.allPeersReady(seating: ["host": .cyan], localID: "host", readyPeers: [])
        #expect(!oneMissing)
        #expect(everyone)
        #expect(!nobodySeated)
        #expect(!onlyLocal)
    }

    @Test("The lowest surviving guest takes over hosting, and only when the host dropped")
    func guestTakesOverWhenHostDrops() {
        let hostDropped = OnlineSeating.localTakesOverHosting(
            localID: "b", hostID: "a", droppedID: "a", remainingPeerIDs: ["a"]
        )
        let wingDropped = OnlineSeating.localTakesOverHosting(
            localID: "b", hostID: "a", droppedID: "c", remainingPeerIDs: ["a", "c"]
        )
        let hostStays = OnlineSeating.localTakesOverHosting(
            localID: "a", hostID: "a", droppedID: "b", remainingPeerIDs: ["b"]
        )
        let lowerGuestRemains = OnlineSeating.localTakesOverHosting(
            localID: "c", hostID: "a", droppedID: "a", remainingPeerIDs: ["a", "b"]
        )
        let lowestGuest = OnlineSeating.localTakesOverHosting(
            localID: "b", hostID: "a", droppedID: "a", remainingPeerIDs: ["a", "c"]
        )
        let noHostKnown = OnlineSeating.localTakesOverHosting(
            localID: "b", hostID: nil, droppedID: "a", remainingPeerIDs: ["a"]
        )
        #expect(hostDropped)
        #expect(!wingDropped)
        #expect(!hostStays)
        #expect(!lowerGuestRemains)
        #expect(lowestGuest)
        #expect(!noHostKnown)
    }
}

@Suite("Peer liveness")
struct PeerLivenessTests {
    private let peers = ["guest", "wing"]

    @Test("Five seconds of nothing from a seated pilot reads as a dropped link")
    func silenceTripsAfterTheThreshold() {
        var monitor = PeerLivenessMonitor(silenceSeconds: 5)
        monitor.begin(peers: peers, at: 100)

        #expect(monitor.check(peers: peers, at: 104.9) == .unchanged)
        #expect(monitor.check(peers: peers, at: 105) == .wentSilent(["guest", "wing"]))
        #expect(monitor.silentPeers == ["guest", "wing"])
    }

    @Test("A pilot who is still sending never trips")
    func trafficKeepsASeatAlive() {
        var monitor = PeerLivenessMonitor(silenceSeconds: 5)
        monitor.begin(peers: peers, at: 0)

        for tick in stride(from: 1.0, through: 20.0, by: 1.0) {
            monitor.heard("guest", at: tick)
            monitor.heard("wing", at: tick)
            #expect(monitor.check(peers: peers, at: tick) == .unchanged)
        }
    }

    @Test("Packets resuming inside the hold reclaims the seat")
    func aReturningPilotReclaimsTheSeat() {
        var monitor = PeerLivenessMonitor(silenceSeconds: 5)
        monitor.begin(peers: ["guest"], at: 0)

        #expect(monitor.check(peers: ["guest"], at: 6) == .wentSilent(["guest"]))
        monitor.heard("guest", at: 8)
        #expect(monitor.check(peers: ["guest"], at: 8) == .resumed(["guest"]))
        #expect(monitor.silentPeers.isEmpty)
    }

    @Test("A hold that nobody answers never fires twice, and runs out to a forfeit")
    func anUnansweredHoldRunsToForfeit() {
        var monitor = PeerLivenessMonitor(silenceSeconds: 5)
        monitor.begin(peers: ["guest"], at: 0)
        #expect(monitor.check(peers: ["guest"], at: 5) == .wentSilent(["guest"]))

        // The detector stays quiet for the whole hold rather than re-arming it.
        for second in stride(from: 6.0, through: 125.0, by: 1.0) {
            #expect(monitor.check(peers: ["guest"], at: second) == .unchanged)
        }

        var session = OnlineSessionStateMachine(localTeam: .cyan, ticksPerSecond: 120, reconnectWindowSeconds: 120)
        #expect(session.remoteDisconnected(at: 600) == [.pause])
        #expect(session.advance(to: 15_000) == [.forfeit(winner: .cyan)])
    }

    @Test("A pilot nobody has heard from yet belongs to the handshake, not the hold")
    func anUnseededPeerNeverTrips() {
        var monitor = PeerLivenessMonitor(silenceSeconds: 5)
        monitor.begin(peers: ["guest"], at: 0)

        // "wing" seated after the heartbeat seeded the table.
        #expect(monitor.check(peers: ["guest", "wing"], at: 3) == .unchanged)
        #expect(monitor.check(peers: ["wing"], at: 900) == .unchanged)
        #expect(monitor.silentPeers.isEmpty)
    }

    @Test("One of two silent pilots coming back is not a reclaimed seat")
    func aPartialReturnHoldsTheSeat() {
        var monitor = PeerLivenessMonitor(silenceSeconds: 5)
        monitor.begin(peers: peers, at: 0)
        #expect(monitor.check(peers: peers, at: 6) == .wentSilent(["guest", "wing"]))

        monitor.heard("guest", at: 7)
        #expect(monitor.check(peers: peers, at: 7) == .unchanged)
        #expect(monitor.silentPeers == ["wing"])
    }

    @Test("Two pilots dropping in the same tick report longest-silent first")
    func simultaneousDropsAreOrdered() {
        var monitor = PeerLivenessMonitor(silenceSeconds: 5)
        monitor.begin(peers: ["alpha", "bravo", "charlie"], at: 0)
        monitor.heard("bravo", at: 1)
        monitor.heard("charlie", at: 2)

        // alpha has been quiet longest, then bravo, then charlie -- and the
        // first name decides who the forfeit is awarded against.
        #expect(monitor.check(peers: ["alpha", "bravo", "charlie"], at: 7)
                == .wentSilent(["alpha", "bravo", "charlie"]))
    }

    @Test("Equally silent pilots break the tie on player ID")
    func tiesBreakOnPlayerID() {
        var monitor = PeerLivenessMonitor(silenceSeconds: 5)
        monitor.begin(peers: ["zulu", "alpha"], at: 0)

        #expect(monitor.check(peers: ["zulu", "alpha"], at: 5) == .wentSilent(["alpha", "zulu"]))
    }

    @Test("A reset monitor does not carry the last match's silence into the next one")
    func resetClearsTheTable() {
        var monitor = PeerLivenessMonitor(silenceSeconds: 5)
        monitor.begin(peers: ["guest"], at: 0)
        #expect(monitor.check(peers: ["guest"], at: 10) == .wentSilent(["guest"]))

        monitor.reset()
        #expect(monitor.silentPeers.isEmpty)
        // Two matches later, with timestamps from an age ago still on the clock.
        monitor.begin(peers: ["guest"], at: 5_000)
        #expect(monitor.check(peers: ["guest"], at: 5_001) == .unchanged)
    }
}

@Suite("Game Center sign-in")
struct GameCenterSignInTests {
    @Test("A pilot already signed in goes straight through")
    func signedInProceeds() {
        #expect(GameCenterSignIn.nextStep(
            isAuthenticated: true, hasSignInSheet: false, handlerInstalled: true, handlerAnswered: true
        ) == .proceed)
    }

    @Test("The first ask of a launch installs the handler")
    func firstAskInstalls() {
        #expect(GameCenterSignIn.nextStep(
            isAuthenticated: false, hasSignInSheet: false, handlerInstalled: false, handlerAnswered: false
        ) == .installHandler)
    }

    @Test("Asking again after Game Center said no goes to Settings instead of SIGNING IN forever")
    func askingAgainAfterNoSendsToSettings() {
        #expect(GameCenterSignIn.nextStep(
            isAuthenticated: false, hasSignInSheet: false, handlerInstalled: true, handlerAnswered: true
        ) == .sendToSettings)
    }

    @Test("Asking while Game Center is still deciding waits for it")
    func askingMidAnswerWaits() {
        #expect(GameCenterSignIn.nextStep(
            isAuthenticated: false, hasSignInSheet: false, handlerInstalled: true, handlerAnswered: false
        ) == .waitForAnswer)
    }

    @Test("A sign-in sheet that could not be shown is shown on the next ask")
    func heldSheetIsShown() {
        #expect(GameCenterSignIn.nextStep(
            isAuthenticated: false, hasSignInSheet: true, handlerInstalled: true, handlerAnswered: true
        ) == .presentSheet)
    }
}

@Suite("Declined invitations")
struct DeclinedInvitationTests {
    @Test("Everyone asked said no and nobody is at the table: stop waiting")
    func everyoneDeclinedEndsTheWait() {
        #expect(OnlineSeating.invitationsExhausted(
            recipientCount: 1, declined: 1, awaitingTable: true, connectedPeers: 0
        ))
    }

    @Test("One of two invitees declining still waits for the other")
    func oneOfTwoKeepsWaiting() {
        #expect(!OnlineSeating.invitationsExhausted(
            recipientCount: 2, declined: 1, awaitingTable: true, connectedPeers: 0
        ))
    }

    @Test("A quick match has nobody to run out of")
    func automatchNeverExhausts() {
        #expect(!OnlineSeating.invitationsExhausted(
            recipientCount: 0, declined: 1, awaitingTable: true, connectedPeers: 0
        ))
    }

    @Test("A pilot already connected is not called off by a late refusal")
    func connectedPilotKeepsTheTable() {
        #expect(!OnlineSeating.invitationsExhausted(
            recipientCount: 2, declined: 2, awaitingTable: true, connectedPeers: 1
        ))
    }

    @Test("A table that is already playing is not called off")
    func playingTableIsLeftAlone() {
        #expect(!OnlineSeating.invitationsExhausted(
            recipientCount: 1, declined: 1, awaitingTable: false, connectedPeers: 0
        ))
    }
}

@Suite("What actually ends an invitation")
struct InviteTerminalityTests {
    @Test("Silence is not a no")
    func silenceIsNotARefusal() {
        // Game Center stopped chasing. The invite is still on their phone.
        #expect(!InviteRefusalReason.noAnswer.isTerminal)
        #expect(!InviteRefusalReason.unableToConnect.isTerminal)
    }

    @Test("A real answer ends it")
    func realAnswersAreTerminal() {
        #expect(InviteRefusalReason.declined.isTerminal)
        #expect(InviteRefusalReason.failed.isTerminal)
        #expect(InviteRefusalReason.incompatible.isTerminal)
        #expect(InviteRefusalReason.other.isTerminal)
    }

    @Test("Every Game Center response maps to a terminality")
    func everyResponseIsClassified() {
        for kind in PlayerNetworkCopy.Invite.allCases where kind != .accepted {
            let reason = OnlineFailureReason.refusalReason(from: kind)
            #expect(reason.isTerminal == (kind != .noAnswer && kind != .unableToConnect))
        }
    }
}

@Suite("Seat hold call-back")
struct SeatHoldCallbackTests {
    @Test("Only pilots who are really gone are called back")
    func missingIsOnlyTheGone() {
        let missing = SeatHoldCallback.missing(
            seated: ["local", "zulu", "inMatch", "ready", "chatty", "alpha"],
            localID: "local",
            inMatch: ["inMatch"],
            ready: ["ready"],
            heardRecently: ["chatty"]
        )
        #expect(missing == ["alpha", "zulu"])
    }

    @Test("The automatic call-back asks each pilot once per hold")
    func automaticAsksOnce() {
        var callback = SeatHoldCallback()
        #expect(callback.automatic(["guest"]) == ["guest"])
        #expect(callback.automatic(["guest"]).isEmpty)
        #expect(callback.automatic(["guest", "wing"]) == ["wing"])
    }

    @Test("RE-INVITE asks again, and that invite is withdrawn with the hold too")
    func manualAsksAgainAndIsRemembered() {
        var callback = SeatHoldCallback()
        _ = callback.automatic(["guest"])
        #expect(callback.manual(["guest", "wing"]) == ["guest", "wing"])
        #expect(callback.close() == ["guest", "wing"])
    }

    @Test("Closing the hold hands back every invite still out and starts the next hold clean")
    func closeWithdrawsAndResets() {
        var callback = SeatHoldCallback()
        _ = callback.automatic(["guest"])
        #expect(callback.close() == ["guest"])
        #expect(callback.close().isEmpty)
        #expect(callback.automatic(["guest"]) == ["guest"])
    }

    @Test("A packet in the last two seconds counts as still here")
    func heardRecentlyIsAWindow() {
        var monitor = PeerLivenessMonitor(silenceSeconds: 5)
        monitor.begin(peers: ["guest", "wing"], at: 0)
        monitor.heard("guest", at: 9)
        #expect(monitor.heard(within: 2, at: 10) == ["guest"])
        #expect(monitor.heard(within: 2, at: 11).isEmpty)
    }
}
