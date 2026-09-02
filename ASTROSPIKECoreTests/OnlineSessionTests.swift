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
