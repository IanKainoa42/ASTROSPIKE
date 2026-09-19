/// Typed failure reasons for online matchmaking, invites, handshakes, and
/// disconnections. Every failure surfaces through this model so the UI always
/// shows a specific, actionable explanation — never a generic "connection failed".
///
/// See `docs/ONLINE_FAILURE_REASONS.md` for the full catalog and guidance on
/// adding new reasons.
public enum OnlineFailureReason: Equatable, Sendable {
    // MARK: - Authentication
    
    /// Game Center is not signed in; the pilot must sign in via Settings.
    case gameCenterNotAuthenticated
    /// Game Center is still deciding whether to sign in.
    case gameCenterAuthInProgress
    /// The pilot declined Game Center permission.
    case gameCenterUserDenied
    /// Game Center could not be reached (network or service issue).
    case gameCenterCommunicationsFailure
    /// Game Center timed out during sign-in (no response in 15s).
    case gameCenterSignInTimeout
    /// An unrecognized Game Center error occurred.
    case gameCenterOther
    
    // MARK: - Screen Time / Restrictions
    
    /// Multiplayer is restricted by Screen Time settings.
    case multiplayerRestricted
    /// Invites are disabled in Screen Time settings.
    case invitationsDisabled
    /// Friend invites are restricted; only automatch is allowed.
    case restrictedToAutomatch
    
    // MARK: - Matchmaking
    
    /// The matchmaker modal could not be shown (no key window).
    case matchmakerUnavailable
    /// The pilot cancelled the search or invite.
    case matchmakingCancelled
    /// Game Center returned no match object (unexpected).
    case noMatchReturned
    /// A connection timeout occurred (30s without peers joining).
    case connectTimeout
    /// The peer never sent a ready handshake (20s timeout).
    case handshakeTimeout
    
    // MARK: - Invite Responses
    
    /// The invited pilot declined the invitation.
    case inviteDeclined(pilotName: String)
    /// The invite could not be delivered (network or Game Center issue).
    case inviteFailed(pilotName: String)
    /// The invited pilot has an incompatible app version — they need to update.
    case inviteIncompatibleRemote(pilotName: String)
    /// The invited pilot couldn't connect (network issue on their end).
    case inviteUnableToConnect(pilotName: String)
    /// The invited pilot never responded.
    case inviteNoAnswer(pilotName: String)
    /// All invited pilots refused or could not connect.
    case allInvitesRefused(lastPilotName: String, lastReason: InviteRefusalReason)
    
    // MARK: - Wire Protocol Mismatch
    
    /// The remote peer is on a different wire protocol version.
    /// - `remoteVersion`: the peer's wire version
    /// - `localVersion`: our wire version
    /// - `pilotName`: the peer's display name
    /// If `remoteVersion < localVersion`, they need to update.
    /// If `remoteVersion > localVersion`, we need to update.
    case wireVersionMismatch(remoteVersion: UInt16, localVersion: UInt16, pilotName: String)
    
    // MARK: - Mid-Match Failures
    
    /// A reliable network send failed.
    case networkSendFailed
    /// The GKMatch reported a failure (with optional underlying error).
    case matchFailed(underlyingMessage: String?)
    /// The opponent forfeited (seat hold expired after 120s).
    case opponentForfeited
    /// The match connection was lost (GK reported match not connected).
    case matchNotConnected
    /// A connection timeout occurred mid-match.
    case connectionTimeout
    
    // MARK: - Invite Acceptance Failures
    
    /// Accepting an invite failed (GK error while joining).
    case inviteJoinFailed(underlyingMessage: String?)
    /// The invite object returned no match.
    case couldNotOpenInvitation
}

/// The specific reason an invite was refused, for categorization.
public enum InviteRefusalReason: Equatable, Sendable {
    case declined
    case failed
    case incompatible
    case unableToConnect
    case noAnswer
    case other
}

// MARK: - Player-Facing Copy

extension OnlineFailureReason {
    /// The player-facing message for this failure reason. Always actionable
    /// where possible, never contains GK codes or engineer jargon.
    public var message: String {
        switch self {
        // Authentication
        case .gameCenterNotAuthenticated:
            return "Sign in to Game Center in Settings"
        case .gameCenterAuthInProgress:
            return "Still signing in to Game Center"
        case .gameCenterUserDenied:
            return "Game Center permission was declined"
        case .gameCenterCommunicationsFailure:
            return "Couldn't reach Game Center"
        case .gameCenterSignInTimeout:
            return "Game Center didn't respond. Try again."
        case .gameCenterOther:
            return "Couldn't reach Game Center. Try again."
            
        // Restrictions
        case .multiplayerRestricted:
            return "Multiplayer is restricted by Screen Time"
        case .invitationsDisabled:
            return "Invites are turned off in Screen Time"
        case .restrictedToAutomatch:
            return "Friend invites aren't available"
            
        // Matchmaking
        case .matchmakerUnavailable:
            return "Matchmaker couldn't open. Try again."
        case .matchmakingCancelled:
            return "Search cancelled"
        case .noMatchReturned:
            return "Couldn't start the match. Try again."
        case .connectTimeout:
            return "No one joined. Try inviting again."
        case .handshakeTimeout:
            return "Opponent connected but didn't respond"
            
        // Invite responses
        case .inviteDeclined(let name):
            return "\(name) declined the invite"
        case .inviteFailed(let name):
            return "Invite to \(name) didn't arrive"
        case .inviteIncompatibleRemote(let name):
            return "\(name) needs to update ASTROSPIKE"
        case .inviteUnableToConnect(let name):
            return "Couldn't connect to \(name)"
        case .inviteNoAnswer(let name):
            return "\(name) didn't answer"
        case .allInvitesRefused(let name, let reason):
            return allRefusedMessage(lastPilot: name, reason: reason)
            
        // Wire mismatch
        case .wireVersionMismatch(let remote, let local, let name):
            if remote < local {
                return "\(name) needs to update ASTROSPIKE"
            } else {
                return "Update ASTROSPIKE to play with \(name)"
            }
            
        // Mid-match failures
        case .networkSendFailed:
            return "Network send failed. Reconnecting…"
        case .matchFailed(let underlying):
            if let underlying, !underlying.isEmpty {
                return underlying
            }
            return "The match ended unexpectedly"
        case .opponentForfeited:
            return "Opponent left the match"
        case .matchNotConnected:
            return "Lost the match connection"
        case .connectionTimeout:
            return "Connection timed out"
            
        // Invite acceptance
        case .inviteJoinFailed(let underlying):
            if let underlying, !underlying.isEmpty {
                return underlying
            }
            return "Couldn't join the match. Try again."
        case .couldNotOpenInvitation:
            return "Couldn't open the invitation"
        }
    }
    
    private func allRefusedMessage(lastPilot: String, reason: InviteRefusalReason) -> String {
        switch reason {
        case .declined:
            return "\(lastPilot) declined"
        case .failed:
            return "Invite to \(lastPilot) didn't arrive"
        case .incompatible:
            return "\(lastPilot) needs to update ASTROSPIKE"
        case .unableToConnect:
            return "Couldn't connect to \(lastPilot)"
        case .noAnswer:
            return "\(lastPilot) didn't answer"
        case .other:
            return "\(lastPilot) couldn't be reached"
        }
    }
}

// MARK: - Convenience Initializers

extension OnlineFailureReason {
    /// Creates a failure reason from a Game Center error.
    public static func fromGameCenterError(_ kind: PlayerNetworkCopy.GameCenter) -> OnlineFailureReason {
        switch kind {
        case .notAuthenticated: return .gameCenterNotAuthenticated
        case .authenticationInProgress: return .gameCenterAuthInProgress
        case .userDenied: return .gameCenterUserDenied
        case .communicationsFailure: return .gameCenterCommunicationsFailure
        case .invitationsDisabled: return .invitationsDisabled
        case .restrictedToAutomatch: return .restrictedToAutomatch
        case .matchNotConnected: return .matchNotConnected
        case .underage: return .gameCenterOther
        case .gameUnrecognized, .notSupported, .apiNotAvailable: return .gameCenterOther
        case .cancelled: return .matchmakingCancelled
        case .iCloudUnavailable: return .gameCenterOther
        case .connectionTimeout: return .connectionTimeout
        case .other: return .gameCenterOther
        }
    }
    
    /// Creates a failure reason from an invite response.
    public static func fromInviteResponse(
        _ kind: PlayerNetworkCopy.Invite,
        pilotName: String
    ) -> OnlineFailureReason {
        switch kind {
        case .accepted: return .gameCenterOther
        case .declined: return .inviteDeclined(pilotName: pilotName)
        case .failed: return .inviteFailed(pilotName: pilotName)
        case .incompatible: return .inviteIncompatibleRemote(pilotName: pilotName)
        case .unableToConnect: return .inviteUnableToConnect(pilotName: pilotName)
        case .noAnswer: return .inviteNoAnswer(pilotName: pilotName)
        case .other: return .inviteNoAnswer(pilotName: pilotName)
        }
    }
    
    /// Maps an invite response kind to an InviteRefusalReason for aggregation.
    public static func refusalReason(from kind: PlayerNetworkCopy.Invite) -> InviteRefusalReason {
        switch kind {
        case .accepted: return .other
        case .declined: return .declined
        case .failed: return .failed
        case .incompatible: return .incompatible
        case .unableToConnect: return .unableToConnect
        case .noAnswer: return .noAnswer
        case .other: return .other
        }
    }
}

// MARK: - Notice-Only Reasons

/// Reasons that surface as a notice (yellow caption) rather than a terminal
/// failure. These keep the match running but inform the pilot of an issue.
public enum OnlineNoticeReason: Equatable, Sendable {
    /// A peer is on a different wire version. Packets are dropped but the
    /// match continues until timeout or manual leave.
    case wireVersionMismatch(pilotName: String, remoteVersion: UInt16, localVersion: UInt16)
    
    /// An invite response that isn't terminal (declined by one of many, etc.)
    case inviteResponse(pilotName: String, kind: PlayerNetworkCopy.Invite)
    
    public var message: String {
        switch self {
        case .wireVersionMismatch(let name, let remote, let local):
            if remote < local {
                return "\(name.uppercased()) NEEDS TO UPDATE"
            } else {
                return "YOU NEED TO UPDATE TO PLAY WITH \(name.uppercased())"
            }
        case .inviteResponse(let name, let kind):
            return "\(name.uppercased()) · \(kind.message.uppercased())"
        }
    }
}
