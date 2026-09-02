import Foundation

public enum OnlineAuthority: Equatable, Sendable {
    case host
    case guest
    case undetermined
}

public enum OnlineLinkState: Equatable, Sendable {
    case signedOut
    case authenticating
    case ready
    case matchmaking
    case connected
    case reconnecting
    case failed
}

public enum OnlineMatchmakingState: Equatable, Sendable {
    case notLinked
    case findingPeer
    case waitingForPeer
    case ready
}

public struct OnlineDiagnosticsSnapshot: Equatable, Sendable {
    public let playerName: String?
    public let localTeam: Team?
    public let authority: OnlineAuthority
    public let pingMilliseconds: Int?
    public let linkState: OnlineLinkState
    public let matchmakingState: OnlineMatchmakingState
    public let reconnectSeconds: Int?
    /// Most recent Game Center events, oldest first. Surfaced verbatim in the
    /// diagnostics panel so invite and matchmaking failures can be read on-device.
    public let eventLog: [String]

    public init(
        playerName: String?,
        localTeam: Team?,
        authority: OnlineAuthority,
        pingMilliseconds: Int?,
        linkState: OnlineLinkState,
        matchmakingState: OnlineMatchmakingState,
        reconnectSeconds: Int?,
        eventLog: [String] = []
    ) {
        self.playerName = playerName
        self.localTeam = localTeam
        self.authority = authority
        self.pingMilliseconds = pingMilliseconds
        self.linkState = linkState
        self.matchmakingState = matchmakingState
        self.reconnectSeconds = reconnectSeconds
        self.eventLog = eventLog
    }

    public var playerLabel: String {
        guard let playerName, !playerName.isEmpty else { return "NOT SIGNED IN" }
        return playerName
    }

    public var sideLabel: String {
        localTeam?.rawValue.uppercased() ?? "UNASSIGNED"
    }

    public var authorityLabel: String {
        switch authority {
        case .host: "HOST"
        case .guest: "GUEST"
        case .undetermined: "PENDING"
        }
    }

    public var pingLabel: String {
        pingMilliseconds.map { "\($0) MS" } ?? "—"
    }

    public var linkLabel: String {
        switch linkState {
        case .signedOut: "OFFLINE"
        case .authenticating: "SIGNING IN"
        case .ready: "GAME CENTER READY"
        case .matchmaking: "MATCHMAKING"
        case .connected: "STABLE"
        case .reconnecting: "RECONNECTING"
        case .failed: "FAILED"
        }
    }

    public var matchmakingLabel: String {
        switch matchmakingState {
        case .notLinked: "NOT LINKED"
        case .findingPeer: "FINDING PEER"
        case .waitingForPeer: "WAITING FOR PEER"
        case .ready: "READY"
        }
    }

    public var reconnectLabel: String {
        reconnectSeconds.map { "\($0) S" } ?? "—"
    }

    /// The newest event, or a placeholder when nothing has happened yet.
    public var eventLabel: String {
        eventLog.last ?? "NO EVENTS YET"
    }

    /// The newest `limit` events, newest first, for the expanded panel.
    public func recentEvents(limit: Int) -> [String] {
        Array(eventLog.suffix(limit).reversed())
    }
}
