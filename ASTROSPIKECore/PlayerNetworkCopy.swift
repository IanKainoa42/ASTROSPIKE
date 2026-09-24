/// Player-facing copy for Game Center, CloudKit, and invite failures.
///
/// Diagnostic strings (`GK12 COMMS FAILURE`, `CK11 SCHEMA MISSING`) stay in
/// the event log. Anything a pilot can see on screen maps through here.
public enum PlayerNetworkCopy {
    public enum GameCenter: CaseIterable, Sendable {
        case notAuthenticated
        case authenticationInProgress
        case userDenied
        case communicationsFailure
        case invitationsDisabled
        case restrictedToAutomatch
        case matchNotConnected
        case underage
        case gameUnrecognized
        case notSupported
        case cancelled
        case iCloudUnavailable
        case connectionTimeout
        case apiNotAvailable
        case other

        public var message: String {
            switch self {
            // GameKit will not show its sign-in sheet twice, so the way back
            // in is Settings, and the copy has to say so.
            case .notAuthenticated: "Sign in to Game Center in Settings"
            case .authenticationInProgress: "Still signing in"
            case .userDenied: "Game Center permission declined"
            case .communicationsFailure: "Couldn't reach Game Center"
            case .invitationsDisabled: "Invites are turned off"
            case .restrictedToAutomatch: "Friend invites aren't available"
            case .matchNotConnected: "Lost the match connection"
            case .underage: "Game Center isn't available on this account"
            case .gameUnrecognized, .notSupported, .apiNotAvailable:
                "Game Center isn't available"
            case .cancelled: "Search cancelled"
            case .iCloudUnavailable: "iCloud isn't available"
            case .connectionTimeout: "Connection timed out"
            case .other: "Couldn't reach Game Center. Try again."
            }
        }
    }

    public enum CloudKit: CaseIterable, Sendable {
        case notAuthenticated
        case network
        case unavailable
        case unknownItem
        case invalidArguments
        case quotaExceeded
        case permissionFailure
        case other

        public var message: String {
            switch self {
            case .notAuthenticated: "Sign in to iCloud"
            case .network: "No network. Pull to refresh."
            case .unavailable: "iCloud is unavailable"
            case .unknownItem: "Lobby isn't available yet"
            case .invalidArguments: "Couldn't load the lobby"
            case .quotaExceeded: "iCloud storage is full"
            case .permissionFailure: "Couldn't access iCloud"
            case .other: "Couldn't reach iCloud. Pull to refresh."
            }
        }
    }

    /// What the bay says while a table is being set. FINDING PILOT is right
    /// for a quick match and wrong for everything else: a pilot who tapped an
    /// invite sat under it with no word that they were on their way in.
    public enum Matchmaking {
        public static func joining(_ name: String) -> String {
            "JOINING \(name.uppercased())…"
        }

        public static func rejoining(_ name: String) -> String {
            "REJOINING \(name.uppercased())…"
        }

        /// The host's link fell over before it seated us. Only the host can
        /// ask again, and they do so automatically, so say what to watch for.
        public static func awaitingReinvite(_ name: String) -> String {
            "LINK DROPPED · ACCEPT \(name.uppercased())'S NEW INVITE"
        }

        public static func waiting(for names: [String]) -> String {
            guard let first = names.first else { return "WAITING FOR PILOTS…" }
            let others = names.count - 1
            return others > 0
                ? "WAITING FOR \(first.uppercased()) +\(others)…"
                : "WAITING FOR \(first.uppercased())…"
        }
    }

    public enum Invite: CaseIterable, Sendable {
        case accepted
        case declined
        case failed
        case incompatible
        case unableToConnect
        case noAnswer
        case other

        public var message: String {
            switch self {
            case .accepted: "Accepted"
            case .declined: "Declined"
            case .failed: "Invite didn't arrive"
            case .incompatible: "They need to update"
            case .unableToConnect: "Couldn't connect"
            case .noAnswer: "No answer"
            case .other: "No response"
            }
        }
    }
}
