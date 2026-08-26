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
}
