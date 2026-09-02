import Testing
@testable import ASTROSPIKECore

@Suite("Online diagnostics presentation")
struct OnlineDiagnosticsTests {
    @Test("Connected host exposes player, side, authority, ping, and ready link")
    func connectedHostPresentation() {
        let diagnostics = OnlineDiagnosticsSnapshot(
            playerName: "Pilot A",
            localTeam: .cyan,
            authority: .host,
            pingMilliseconds: 42,
            linkState: .connected,
            matchmakingState: .ready,
            reconnectSeconds: nil
        )

        #expect(diagnostics.playerLabel == "Pilot A")
        #expect(diagnostics.sideLabel == "CYAN")
        #expect(diagnostics.authorityLabel == "HOST")
        #expect(diagnostics.pingLabel == "42 MS")
        #expect(diagnostics.linkLabel == "STABLE")
        #expect(diagnostics.matchmakingLabel == "READY")
        #expect(diagnostics.reconnectLabel == "—")
    }

    @Test("Reconnecting guest exposes the live recovery countdown")
    func reconnectingGuestPresentation() {
        let diagnostics = OnlineDiagnosticsSnapshot(
            playerName: "Pilot B",
            localTeam: .orange,
            authority: .guest,
            pingMilliseconds: 187,
            linkState: .reconnecting,
            matchmakingState: .ready,
            reconnectSeconds: 7
        )

        #expect(diagnostics.sideLabel == "ORANGE")
        #expect(diagnostics.authorityLabel == "GUEST")
        #expect(diagnostics.linkLabel == "RECONNECTING")
        #expect(diagnostics.reconnectLabel == "7 S")
    }

    @Test("Matchmaking leaves unresolved match values visibly pending")
    func matchmakingPresentation() {
        let diagnostics = OnlineDiagnosticsSnapshot(
            playerName: "Pilot C",
            localTeam: nil,
            authority: .undetermined,
            pingMilliseconds: nil,
            linkState: .matchmaking,
            matchmakingState: .findingPeer,
            reconnectSeconds: nil
        )

        #expect(diagnostics.sideLabel == "UNASSIGNED")
        #expect(diagnostics.authorityLabel == "PENDING")
        #expect(diagnostics.pingLabel == "—")
        #expect(diagnostics.linkLabel == "MATCHMAKING")
        #expect(diagnostics.matchmakingLabel == "FINDING PEER")
        #expect(diagnostics.reconnectLabel == "—")
    }
}

@Test func eventLogSurfacesNewestFirstWithPlaceholder() {
    let empty = OnlineDiagnosticsSnapshot(
        playerName: nil, localTeam: nil, authority: .undetermined, pingMilliseconds: nil,
        linkState: .signedOut, matchmakingState: .notLinked, reconnectSeconds: nil
    )
    #expect(empty.eventLabel == "NO EVENTS YET")
    #expect(empty.recentEvents(limit: 5).isEmpty)

    let logged = OnlineDiagnosticsSnapshot(
        playerName: "A", localTeam: nil, authority: .undetermined, pingMilliseconds: nil,
        linkState: .ready, matchmakingState: .notLinked, reconnectSeconds: nil,
        eventLog: ["one", "two", "three"]
    )
    #expect(logged.eventLabel == "three")
    #expect(logged.recentEvents(limit: 2) == ["three", "two"])
}
