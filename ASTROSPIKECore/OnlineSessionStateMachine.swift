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

    /// Every pilot who was asked has said no, and nobody has reached the
    /// table: there is nothing left to wait for. Only for sent invitations --
    /// an automatch has no recipients to run out of -- and only while the
    /// table is still being set, because GameKit hands the inviter a match
    /// before anyone answers, and a decline landing on that match used to
    /// leave FINDING PILOT up until the connect timeout.
    public static func invitationsExhausted(
        recipientCount: Int,
        declined: Int,
        awaitingTable: Bool,
        connectedPeers: Int
    ) -> Bool {
        recipientCount > 0 && declined >= recipientCount && awaitingTable && connectedPeers == 0
    }
}

/// What asking for Game Center should do right now.
///
/// GameKit answers its sign-in handler when the handler is installed and when
/// the app comes back to the foreground -- never because a pilot tapped a
/// button. Installing it again after it has already said "not signed in"
/// waits for an answer that is not coming, which is how QUICK MATCH sat on
/// SIGNING IN… forever.
public enum GameCenterSignInStep: Equatable, Sendable {
    /// Signed in: carry on.
    case proceed
    /// GameKit handed over its sign-in sheet and it is still usable.
    case presentSheet
    /// Nothing asked yet this launch: install the handler and let GameKit decide.
    case installHandler
    /// Installed and GameKit is still deciding: wait, but not forever.
    case waitForAnswer
    /// GameKit already said no, and will not ask again until the pilot signs
    /// in from Settings and comes back.
    case sendToSettings
}

public enum GameCenterSignIn {
    public static func nextStep(
        isAuthenticated: Bool,
        hasSignInSheet: Bool,
        handlerInstalled: Bool,
        handlerAnswered: Bool
    ) -> GameCenterSignInStep {
        if isAuthenticated { return .proceed }
        if hasSignInSheet { return .presentSheet }
        guard handlerInstalled else { return .installHandler }
        return handlerAnswered ? .sendToSettings : .waitForAnswer
    }
}

/// Who gets called back while a dropped pilot's chair is held, and whose
/// invite has to be withdrawn once the hold is over.
///
/// The automatic call-back used to go out on every hold and was never
/// withdrawn, so a pilot who dropped and came straight back kept finding
/// invites from a match they were already sitting in.
public struct SeatHoldCallback: Equatable, Sendable {
    /// Everyone invited during the hold under way, by player ID.
    public private(set) var invited: Set<String> = []

    public init() {}

    /// Seated pilots who are really gone: not in the match, not ready, and
    /// not still sending packets. Never the local pilot.
    public static func missing(
        seated: some Sequence<String>,
        localID: String,
        inMatch: Set<String>,
        ready: Set<String>,
        heardRecently: Set<String>
    ) -> [String] {
        seated.filter {
            $0 != localID && !inMatch.contains($0) && !ready.contains($0) && !heardRecently.contains($0)
        }.sorted()
    }

    /// The automatic call-back: each missing pilot at most once per hold.
    public mutating func automatic(_ missing: [String]) -> [String] {
        let fresh = missing.filter { !invited.contains($0) }
        invited.formUnion(fresh)
        return fresh
    }

    /// The pilot pressed RE-INVITE, so everyone missing is asked again --
    /// and remembered, so that invite is withdrawn with the hold too.
    public mutating func manual(_ missing: [String]) -> [String] {
        invited.formUnion(missing)
        return missing
    }

    /// The hold is over, whichever way. Hands back who still has an invite
    /// out, and starts the next hold with a clean slate.
    public mutating func close() -> [String] {
        defer { invited = [] }
        return invited.sorted()
    }
}

/// What the silence detector decided this second.
public enum PeerLivenessChange: Equatable, Sendable {
    /// Nothing to act on. Either every link is healthy, or the ones that are
    /// quiet were already quiet and the seat hold is already counting.
    case unchanged
    /// Pilots who have just crossed the silence threshold, longest-silent
    /// first and player ID breaking a tie. The first name is the one the
    /// forfeit is awarded against, so the order has to be the same on every
    /// board rather than whatever a `Set` happens to hand back.
    case wentSilent([String])
    /// Every quiet link closed again, and these are the pilots who came back.
    case resumed([String])
}

/// GameKit does not always tell us a pilot has gone. A backgrounded app, a
/// Wi-Fi handoff, a phone that went in a pocket mid-rally: the match object
/// stays connected and the packets simply stop. Until this, a board went on
/// flying the last packet it ever got -- a burn into the roof that never let
/// up -- under a HUD still reading LINK STABLE. Silence is the signal, and it
/// holds the seat exactly as a clean disconnect does.
///
/// The decision lives here rather than beside the match object so it can be
/// tested without two phones, which is the only way it ever gets tested.
public struct PeerLivenessMonitor: Equatable, Sendable {
    /// Total silence this long from a seated pilot is a dropped link, whatever
    /// GameKit still says. Pings go out every second, so five of them missed.
    public let silenceSeconds: TimeInterval
    /// When the last packet of any kind arrived from each peer, by player ID.
    private var lastHeard: [String: TimeInterval] = [:]
    private var silent: Set<String> = []

    public init(silenceSeconds: TimeInterval = 5) {
        self.silenceSeconds = silenceSeconds
    }

    /// Pilots currently judged gone from silence alone.
    public var silentPeers: Set<String> { silent }

    /// Start the clock on a table. Every seated peer counts as just-heard, so
    /// the first check after a match starts cannot trip on an empty history.
    public mutating func begin(peers: some Sequence<String>, at now: TimeInterval) {
        lastHeard = Dictionary(uniqueKeysWithValues: Set(peers).map { ($0, now) })
        silent = []
    }

    /// A packet arrived. Called before the decode: a packet we cannot read
    /// still proves the pilot is there, and that is all this is asking.
    public mutating func heard(_ peerID: String, at now: TimeInterval) {
        lastHeard[peerID] = now
    }

    /// Pilots with a packet in the last `seconds`. They are still at the
    /// table, whatever GameKit says, and need no invite back.
    public func heard(within seconds: TimeInterval, at now: TimeInterval) -> Set<String> {
        Set(lastHeard.filter { now - $0.value < seconds }.keys)
    }

    /// Forget everything. A monitor carried into the next match would measure
    /// this one's silence against timestamps two matches old.
    public mutating func reset() {
        lastHeard = [:]
        silent = []
    }

    /// The once-a-second verdict on every seated peer.
    ///
    /// A peer with no history at all counts as just-heard rather than gone:
    /// a pilot who seats and then never answers belongs to the handshake
    /// timeout, which gives up in twenty seconds rather than holding their
    /// chair for two minutes.
    public mutating func check(peers: some Sequence<String>, at now: TimeInterval) -> PeerLivenessChange {
        let quiet = Set(peers.filter { now - (lastHeard[$0] ?? now) >= silenceSeconds })
        guard quiet != silent else { return .unchanged }
        let gone = quiet.subtracting(silent)
        let returned = silent.subtracting(quiet)
        silent = quiet

        if !gone.isEmpty {
            return .wentSilent(gone.sorted {
                let left = lastHeard[$0] ?? now
                let right = lastHeard[$1] ?? now
                return left == right ? $0 < $1 : left < right
            })
        }
        // A five-second hole that closes again was a bad stretch of network,
        // not a pilot walking out. Take the seat off hold rather than making
        // them sit through the rest of a two-minute count. One of two coming
        // back is not that: the table is still a pilot short.
        guard quiet.isEmpty, !returned.isEmpty else { return .unchanged }
        return .resumed(returned.sorted())
    }
}

/// How long to wait for a table to actually fill, by how it was called.
///
/// These are two different clocks wearing one number. An automatch is
/// machine-to-machine: Game Center either finds somebody in half a minute or
/// it is not going to. An invitation is a *person* -- the push has to land,
/// the phone has to come out of a pocket, the passcode has to be typed, the
/// app has to cold-start. Thirty seconds of that is barely the notification
/// banner, and the pilot who tapped INVITE saw CONNECTION TIMEOUT while
/// their opponent was still unlocking. Give the human path minutes.
public enum OnlineTimeouts {
    /// Automatch found a table but nobody connected. No invitation is out, so
    /// there is nothing to hold the door open for.
    public static let automatchConnectSeconds = 45
    /// An invitation is out and unanswered. The door stays open this long, so
    /// a pilot who picks their phone up minutes later still lands on the court
    /// without being asked a second time. Matches AstroCross.
    public static let inviteConnectSeconds = 300

    public static func connectSeconds(role: OnlineMatchRole) -> Int {
        switch role {
        case .automatch: automatchConnectSeconds
        case .inviter, .invitee: inviteConnectSeconds
        }
    }
}
