import Testing
@testable import ASTROSPIKECore

@Suite("Online failure reason copy")
struct OnlineFailureReasonTests {
    
    // MARK: - Authentication Failures
    
    @Test("Authentication failure messages are player-friendly")
    func authenticationMessages() {
        #expect(OnlineFailureReason.gameCenterNotAuthenticated.message == "Sign in to Game Center in Settings")
        #expect(OnlineFailureReason.gameCenterAuthInProgress.message == "Still signing in to Game Center")
        #expect(OnlineFailureReason.gameCenterUserDenied.message == "Game Center permission was declined")
        #expect(OnlineFailureReason.gameCenterCommunicationsFailure.message == "Couldn't reach Game Center")
        #expect(OnlineFailureReason.gameCenterSignInTimeout.message == "Game Center didn't respond. Try again.")
        #expect(OnlineFailureReason.gameCenterOther.message == "Couldn't reach Game Center. Try again.")
    }
    
    // MARK: - Restriction Failures
    
    @Test("Restriction failure messages explain the limitation")
    func restrictionMessages() {
        #expect(OnlineFailureReason.multiplayerRestricted.message == "Multiplayer is restricted by Screen Time")
        #expect(OnlineFailureReason.invitationsDisabled.message == "Invites are turned off in Screen Time")
        #expect(OnlineFailureReason.restrictedToAutomatch.message == "Friend invites aren't available")
    }
    
    // MARK: - Matchmaking Failures
    
    @Test("Matchmaking failure messages suggest next steps")
    func matchmakingMessages() {
        #expect(OnlineFailureReason.matchmakerUnavailable.message == "Matchmaker couldn't open. Try again.")
        #expect(OnlineFailureReason.matchmakingCancelled.message == "Search cancelled")
        #expect(OnlineFailureReason.noMatchReturned.message == "Couldn't start the match. Try again.")
        #expect(OnlineFailureReason.connectTimeout.message == "No one joined. Try inviting again.")
        #expect(OnlineFailureReason.handshakeTimeout.message == "Opponent connected but didn't respond")
    }
    
    // MARK: - Invite Response Failures
    
    @Test("Invite responses name the pilot who didn't join")
    func inviteResponseMessages() {
        #expect(OnlineFailureReason.inviteDeclined(pilotName: "Maya").message == "Maya declined the invite")
        #expect(OnlineFailureReason.inviteFailed(pilotName: "Ian").message == "Invite to Ian didn't arrive")
        #expect(OnlineFailureReason.inviteNoAnswer(pilotName: "Jo").message == "Jo didn't answer")
        #expect(OnlineFailureReason.inviteUnableToConnect(pilotName: "Sam").message == "Couldn't connect to Sam")
    }
    
    @Test("Incompatible invite tells who needs to update")
    func inviteIncompatibleMessage() {
        let reason = OnlineFailureReason.inviteIncompatibleRemote(pilotName: "Maya")
        #expect(reason.message == "Maya needs to update ASTROSPIKE")
    }
    
    @Test("All invites refused summarizes the last refusal")
    func allInvitesRefusedMessages() {
        #expect(OnlineFailureReason.allInvitesRefused(
            lastPilotName: "Maya",
            lastReason: .declined
        ).message == "Maya declined")
        
        #expect(OnlineFailureReason.allInvitesRefused(
            lastPilotName: "Ian",
            lastReason: .incompatible
        ).message == "Ian needs to update ASTROSPIKE")
        
        #expect(OnlineFailureReason.allInvitesRefused(
            lastPilotName: "Jo",
            lastReason: .noAnswer
        ).message == "Jo didn't answer")
        
        #expect(OnlineFailureReason.allInvitesRefused(
            lastPilotName: "Sam",
            lastReason: .failed
        ).message == "Invite to Sam didn't arrive")
    }
    
    // MARK: - Wire Version Mismatch
    
    @Test("Wire mismatch identifies who needs to update")
    func wireMismatchMessages() {
        // Remote is older, they need to update
        let theyNeedUpdate = OnlineFailureReason.wireVersionMismatch(
            remoteVersion: 19,
            localVersion: 20,
            pilotName: "Maya"
        )
        #expect(theyNeedUpdate.message == "Maya needs to update ASTROSPIKE")
        
        // Remote is newer, we need to update
        let weNeedUpdate = OnlineFailureReason.wireVersionMismatch(
            remoteVersion: 21,
            localVersion: 20,
            pilotName: "Ian"
        )
        #expect(weNeedUpdate.message == "Update ASTROSPIKE to play with Ian")
    }
    
    // MARK: - Mid-Match Failures
    
    @Test("Mid-match failure messages are specific")
    func midMatchMessages() {
        #expect(OnlineFailureReason.networkSendFailed.message == "Network send failed. Reconnecting…")
        #expect(OnlineFailureReason.opponentForfeited.message == "Opponent left the match")
        #expect(OnlineFailureReason.matchNotConnected.message == "Lost the match connection")
        #expect(OnlineFailureReason.connectionTimeout.message == "Connection timed out")
    }
    
    @Test("Match failed uses underlying message when available")
    func matchFailedMessages() {
        let withUnderlying = OnlineFailureReason.matchFailed(underlyingMessage: "Server unavailable")
        #expect(withUnderlying.message == "Server unavailable")
        
        let withoutUnderlying = OnlineFailureReason.matchFailed(underlyingMessage: nil)
        #expect(withoutUnderlying.message == "The match ended unexpectedly")
        
        let withEmptyUnderlying = OnlineFailureReason.matchFailed(underlyingMessage: "")
        #expect(withEmptyUnderlying.message == "The match ended unexpectedly")
    }
    
    // MARK: - Invite Acceptance Failures
    
    @Test("Invite join failure messages")
    func inviteJoinMessages() {
        let withUnderlying = OnlineFailureReason.inviteJoinFailed(underlyingMessage: "Network error")
        #expect(withUnderlying.message == "Network error")
        
        let withoutUnderlying = OnlineFailureReason.inviteJoinFailed(underlyingMessage: nil)
        #expect(withoutUnderlying.message == "Couldn't join the match. Try again.")
        
        #expect(OnlineFailureReason.couldNotOpenInvitation.message == "Couldn't open the invitation")
    }
    
    // MARK: - No Engineer Jargon
    
    @Test("No failure message contains GK codes or engineer jargon")
    func noEngineerJargon() {
        let allReasons: [OnlineFailureReason] = [
            .gameCenterNotAuthenticated,
            .gameCenterAuthInProgress,
            .gameCenterUserDenied,
            .gameCenterCommunicationsFailure,
            .gameCenterSignInTimeout,
            .gameCenterOther,
            .multiplayerRestricted,
            .invitationsDisabled,
            .restrictedToAutomatch,
            .matchmakerUnavailable,
            .matchmakingCancelled,
            .noMatchReturned,
            .connectTimeout,
            .handshakeTimeout,
            .inviteDeclined(pilotName: "Test"),
            .inviteFailed(pilotName: "Test"),
            .inviteIncompatibleRemote(pilotName: "Test"),
            .inviteUnableToConnect(pilotName: "Test"),
            .inviteNoAnswer(pilotName: "Test"),
            .allInvitesRefused(lastPilotName: "Test", lastReason: .declined),
            .wireVersionMismatch(remoteVersion: 19, localVersion: 20, pilotName: "Test"),
            .networkSendFailed,
            .matchFailed(underlyingMessage: nil),
            .opponentForfeited,
            .matchNotConnected,
            .connectionTimeout,
            .inviteJoinFailed(underlyingMessage: nil),
            .couldNotOpenInvitation
        ]
        
        for reason in allReasons {
            let message = reason.message
            #expect(!message.contains("GK"), "\(reason): \(message)")
            #expect(!message.contains("#"), "\(reason): \(message)")
            #expect(!message.uppercased().contains("ERROR CODE"), "\(reason): \(message)")
            #expect(!message.isEmpty, "\(reason) has no message")
        }
    }
    
    // MARK: - Conversion from PlayerNetworkCopy
    
    @Test("Game Center errors convert to failure reasons")
    func gameCenterErrorConversion() {
        #expect(OnlineFailureReason.fromGameCenterError(.notAuthenticated) == .gameCenterNotAuthenticated)
        #expect(OnlineFailureReason.fromGameCenterError(.communicationsFailure) == .gameCenterCommunicationsFailure)
        #expect(OnlineFailureReason.fromGameCenterError(.invitationsDisabled) == .invitationsDisabled)
        #expect(OnlineFailureReason.fromGameCenterError(.restrictedToAutomatch) == .restrictedToAutomatch)
        #expect(OnlineFailureReason.fromGameCenterError(.matchNotConnected) == .matchNotConnected)
        #expect(OnlineFailureReason.fromGameCenterError(.cancelled) == .matchmakingCancelled)
        #expect(OnlineFailureReason.fromGameCenterError(.connectionTimeout) == .connectionTimeout)
        #expect(OnlineFailureReason.fromGameCenterError(.other) == .gameCenterOther)
    }
    
    @Test("Invite responses convert to failure reasons with pilot names")
    func inviteResponseConversion() {
        #expect(OnlineFailureReason.fromInviteResponse(.declined, pilotName: "Maya") == .inviteDeclined(pilotName: "Maya"))
        #expect(OnlineFailureReason.fromInviteResponse(.failed, pilotName: "Ian") == .inviteFailed(pilotName: "Ian"))
        #expect(OnlineFailureReason.fromInviteResponse(.incompatible, pilotName: "Jo") == .inviteIncompatibleRemote(pilotName: "Jo"))
        #expect(OnlineFailureReason.fromInviteResponse(.noAnswer, pilotName: "Sam") == .inviteNoAnswer(pilotName: "Sam"))
    }
    
    @Test("Invite responses convert to refusal reasons")
    func refusalReasonConversion() {
        #expect(OnlineFailureReason.refusalReason(from: .declined) == .declined)
        #expect(OnlineFailureReason.refusalReason(from: .failed) == .failed)
        #expect(OnlineFailureReason.refusalReason(from: .incompatible) == .incompatible)
        #expect(OnlineFailureReason.refusalReason(from: .unableToConnect) == .unableToConnect)
        #expect(OnlineFailureReason.refusalReason(from: .noAnswer) == .noAnswer)
        #expect(OnlineFailureReason.refusalReason(from: .other) == .other)
    }
}

@Suite("Online notice reason copy")
struct OnlineNoticeReasonTests {
    
    @Test("Wire mismatch notice identifies who needs to update")
    func wireMismatchNotice() {
        // Remote is older
        let theyNeedUpdate = OnlineNoticeReason.wireVersionMismatch(
            pilotName: "Maya",
            remoteVersion: 19,
            localVersion: 20
        )
        #expect(theyNeedUpdate.message == "MAYA NEEDS TO UPDATE")
        
        // Remote is newer
        let weNeedUpdate = OnlineNoticeReason.wireVersionMismatch(
            pilotName: "Ian",
            remoteVersion: 21,
            localVersion: 20
        )
        #expect(weNeedUpdate.message == "YOU NEED TO UPDATE TO PLAY WITH IAN")
    }
    
    @Test("Invite response notices are uppercased with pilot name")
    func inviteResponseNotice() {
        let declined = OnlineNoticeReason.inviteResponse(pilotName: "Maya", kind: .declined)
        #expect(declined.message == "MAYA · DECLINED")
        
        let incompatible = OnlineNoticeReason.inviteResponse(pilotName: "Ian", kind: .incompatible)
        #expect(incompatible.message == "IAN · THEY NEED TO UPDATE")
        
        let noAnswer = OnlineNoticeReason.inviteResponse(pilotName: "Jo", kind: .noAnswer)
        #expect(noAnswer.message == "JO · NO ANSWER")
    }
}
