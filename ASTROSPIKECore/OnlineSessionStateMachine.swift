import Foundation

public enum OnlineSessionPhase: Equatable, Sendable {
    case playing
    case reconnecting(deadlineTick: UInt64)
    case forfeited(winner: Team)
}

public enum OnlineSessionAction: Equatable, Sendable {
    case pause
    case requestFullResync
    case startCountdown
    case forfeit(winner: Team)
}

public struct OnlineSessionStateMachine: Equatable, Sendable {
    public private(set) var phase: OnlineSessionPhase = .playing

    private let localTeam: Team
    private let reconnectWindowTicks: UInt64

    public init(localTeam: Team, ticksPerSecond: UInt64, reconnectWindowSeconds: UInt64 = 10) {
        self.localTeam = localTeam
        reconnectWindowTicks = ticksPerSecond * reconnectWindowSeconds
    }

    public mutating func remoteDisconnected(at tick: UInt64) -> [OnlineSessionAction] {
        guard case .playing = phase else { return [] }
        phase = .reconnecting(deadlineTick: tick + reconnectWindowTicks)
        return [.pause]
    }

    public mutating func advance(to tick: UInt64) -> [OnlineSessionAction] {
        guard case let .reconnecting(deadlineTick) = phase,
              tick >= deadlineTick else {
            return []
        }

        phase = .forfeited(winner: localTeam)
        return [.forfeit(winner: localTeam)]
    }

    public mutating func remoteReconnected(at tick: UInt64) -> [OnlineSessionAction] {
        guard case let .reconnecting(deadlineTick) = phase,
              tick < deadlineTick else {
            return advance(to: tick)
        }

        phase = .playing
        return [.requestFullResync, .startCountdown]
    }
}

public enum OnlineMatchLifecyclePhase: Equatable, Sendable {
    case idle
    case configuring
    case active
    case reconnecting
    case terminal
}

public struct OnlineMatchLifecycle: Equatable, Sendable {
    public private(set) var phase: OnlineMatchLifecyclePhase = .idle

    public var acceptsGameplayData: Bool {
        phase == .active || phase == .reconnecting
    }

    public var acceptsNetworkMessages: Bool {
        phase == .configuring || phase == .active || phase == .reconnecting
    }

    public init() {}

    public mutating func beginConfiguration() {
        phase = .configuring
    }

    public mutating func beginMatch() {
        phase = .active
    }

    @discardableResult
    public mutating func beginReconnect() -> Bool {
        guard phase == .active else { return false }
        phase = .reconnecting
        return true
    }

    @discardableResult
    public mutating func acceptConnection() -> Bool {
        if phase == .configuring { return true }
        guard phase == .active || phase == .reconnecting else { return false }
        phase = .active
        return true
    }

    public mutating func finish() {
        phase = .terminal
    }

    public mutating func reset() {
        phase = .idle
    }
}

/// How this end came to be in a Game Center match. It settles who hosts
/// without asking GameKit, whose own host choice returns nil on a match that
/// is not fully connected yet.
public enum OnlineMatchRole: Equatable, Sendable {
    /// Sent the invitations, so this end hosts.
    case inviter
    /// Accepted an invitation: the inviter hosts, whatever the player IDs say.
    case invitee
    /// Automatch: every end sees the same player list, so the lowest
    /// Game Center player ID hosts on every board at once.
    case automatch
}

/// The two decisions the table needs that must come out the same on every
/// phone: who seats it, and when everyone seated has answered.
public enum OnlineSeating {
    public static func localHosts(
        localID: String,
        peerIDs: some Sequence<String>,
        role: OnlineMatchRole
    ) -> Bool {
        switch role {
        case .inviter: true
        case .invitee: false
        case .automatch: peerIDs.allSatisfy { localID < $0 }
        }
    }

    /// True once every pilot in the seating plan other than the local one
    /// has sent `.ready`. Goes by the plan, not GameKit's expected count,
    /// which a guest's match never decrements for a declined third invitee.
    public static func allPeersReady(
        seating: [String: Seat],
        localID: String,
        readyPeers: Set<String>
    ) -> Bool {
        let peers = seating.keys.filter { $0 != localID }
        return !peers.isEmpty && peers.allSatisfy(readyPeers.contains)
    }

    /// When the host drops out of a live match somebody still at the table
    /// has to run the rules while the chair is held. The surviving guest with
    /// the lowest player ID takes over, on every remaining board at once.
    public static func localTakesOverHosting(
        localID: String,
        hostID: String?,
        droppedID: String,
        remainingPeerIDs: some Sequence<String>
    ) -> Bool {
        guard let hostID, hostID != localID, droppedID == hostID else { return false }
        return remainingPeerIDs.allSatisfy { $0 == droppedID || localID < $0 }
    }
}
