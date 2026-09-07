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
}
