@preconcurrency import GameKit
import ASTROSPIKECore
import Observation
import UIKit
import os

@MainActor
@Observable
final class OnlineMatchCoordinator: NSObject,
    GKMatchDelegate,
    @MainActor GKMatchmakerViewControllerDelegate,
    GKLocalPlayerListener {
    enum Status: Equatable {
        case signedOut
        case authenticating
        case ready(playerName: String)
        case matching
        case connected
        case reconnecting(seconds: Int)
        case failed(message: String)

        var label: String {
            switch self {
            case .signedOut: "GAME CENTER OFFLINE"
            case .authenticating: "SIGNING IN…"
            case let .ready(name): "ONLINE • \(name)"
            case .matching: "FINDING PILOT…"
            case .connected: "LINK STABLE"
            case let .reconnecting(seconds):
                "LINK LOST · SEAT HELD \(seconds / 60):\(String(format: "%02d", seconds % 60))"
            case let .failed(message): message.uppercased()
            }
        }
    }

    private enum MatchmakingIntent: Equatable {
        case quickMatch
        case friendInvite
        case invite([GKPlayer])
    }

    /// Everyone the local pilot can invite without leaving the app: recent
    /// opponents first, then Game Center friends once that consent is given.
    private(set) var invitees: [GKPlayer] = []
    private(set) var isLoadingInvitees = false
    /// The latest word from an invited pilot, shown in the warm-up bay.
    private(set) var inviteNotice: String?

    private(set) var status: Status = .signedOut
    private(set) var isMatchReady = false
    private(set) var isAuthoritative = false
    private(set) var localSeat: Seat?
    var localTeam: Team? { localSeat?.team }
    /// The host's seating plan, Game Center player ID to seat.
    private(set) var seating: [String: Seat] = [:]
    var filledSeats: Set<Seat> { Set(seating.values) }
    /// Display names of everyone at the table, by Game Center player ID.
    var seatedPilotNames: [String: String] {
        var names = [GKLocalPlayer.local.gamePlayerID: GKLocalPlayer.local.displayName]
        for player in match?.players ?? [] { names[player.gamePlayerID] = player.displayName }
        return names
    }
    /// The latest input from every other pilot, by seat -- and only while it
    /// is still fresh. A packet is a statement about one tick, not a standing
    /// order: past `inputExpirySeconds` the seat goes quiet rather than
    /// keeping a dead pilot's throttle open. Rebuilt on each read, so hoist it
    /// out of a per-seat loop.
    var remoteInputs: [Seat: PlayerInput] {
        let now = Self.now
        return inputBuffers.compactMapValues {
            $0.current(at: now, expiringAfter: Self.inputExpirySeconds)
        }
    }
    /// Seats whose first packet has been noted, so the log says it once.
    private var heardSeats: Set<Seat> = []
    /// Peers whose packets carry another wire version, noted once each.
    private var mismatchedPeers: Set<String> = []
    /// The hulls the peers fly, once their profiles arrive. A seat missing
    /// here keeps its default, so the scene never shows a wrong hull.
    private(set) var remoteHulls: [Seat: Hull] = [:]
    /// Set by the app from the pilot profile; sent with the ready handshake.
    var localHull: Hull = .lancet
    private(set) var pingMilliseconds: Int?
    /// Rolling on-device log of Game Center events, oldest first.
    private(set) var eventLog: [String] = []

    private static let logger = Logger(subsystem: "com.iankainoa.ASTROSPIKE", category: "GameCenter")
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var diagnosticsSnapshot: OnlineDiagnosticsSnapshot {
        let linkState: OnlineLinkState
        let reconnectSeconds: Int?
        switch status {
        case .signedOut:
            linkState = .signedOut
            reconnectSeconds = nil
        case .authenticating:
            linkState = .authenticating
            reconnectSeconds = nil
        case .ready:
            linkState = .ready
            reconnectSeconds = nil
        case .matching:
            linkState = .matchmaking
            reconnectSeconds = nil
        case .connected:
            linkState = .connected
            reconnectSeconds = nil
        case let .reconnecting(seconds):
            linkState = .reconnecting
            reconnectSeconds = seconds
        case .failed:
            linkState = .failed
            reconnectSeconds = nil
        }

        let matchmakingState: OnlineMatchmakingState
        if isMatchReady {
            matchmakingState = .ready
        } else {
            matchmakingState = switch status {
            case .matching: .findingPeer
            case .connected, .reconnecting: .waitingForPeer
            default: .notLinked
            }
        }

        let authority: OnlineAuthority = if localTeam == nil {
            .undetermined
        } else if isAuthoritative {
            .host
        } else {
            .guest
        }

        let playerName: String? = switch status {
        case let .ready(name): name
        default: GKLocalPlayer.local.isAuthenticated ? GKLocalPlayer.local.displayName : nil
        }

        return OnlineDiagnosticsSnapshot(
            playerName: playerName,
            localTeam: localTeam,
            authority: authority,
            pingMilliseconds: pingMilliseconds,
            linkState: linkState,
            matchmakingState: matchmakingState,
            reconnectSeconds: reconnectSeconds,
            eventLog: eventLog
        )
    }

    /// Records an event for the diagnostics panel and the unified log.
    private func note(_ message: String) {
        Self.logger.info("\(message, privacy: .public)")
        eventLog.append("\(Self.clock.string(from: .now)) \(message)")
        if eventLog.count > 12 { eventLog.removeFirst(eventLog.count - 12) }
    }

    /// Compact, readable description of a GameKit failure: `GK<code> <NAME>`.
    nonisolated func describe(_ error: Error) -> String {
        let nsError = error as NSError
        var text: String
        if let gkError = error as? GKError {
            let name: String = switch gkError.code {
            case .notAuthenticated: "NOT AUTHENTICATED"
            case .authenticationInProgress: "AUTH IN PROGRESS"
            case .userDenied: "USER DENIED"
            case .communicationsFailure: "COMMS FAILURE"
            case .invitationsDisabled: "INVITATIONS DISABLED"
            case .restrictedToAutomatch: "RESTRICTED TO AUTOMATCH"
            case .matchRequestInvalid: "MATCH REQUEST INVALID"
            case .matchNotConnected: "MATCH NOT CONNECTED"
            case .underage: "UNDERAGE"
            case .gameUnrecognized: "GAME UNRECOGNIZED"
            case .notSupported: "NOT SUPPORTED"
            case .invalidPlayer: "INVALID PLAYER"
            case .cancelled: "CANCELLED"
            case .iCloudUnavailable: "ICLOUD UNAVAILABLE"
            case .notAuthorized: "NOT AUTHORIZED"
            case .connectionTimeout: "CONNECTION TIMEOUT"
            case .apiNotAvailable: "API NOT AVAILABLE"
            default: gkError.localizedDescription.uppercased()
            }
            text = "GK\(gkError.code.rawValue) \(name)"
        } else {
            text = "\(nsError.domain)#\(nsError.code) \(nsError.localizedDescription)"
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " ← \(underlying.domain)#\(underlying.code)"
        }
        return text
    }

    var onSnapshot: ((WorldState) -> Void)?
    var onResync: ((WorldState) -> Void)? {
        didSet {
            // A resync that beat the arena onto the screen is delivered the
            // moment the arena hooks in, instead of being thrown away.
            if let onResync, let pendingResync {
                self.pendingResync = nil
                onResync(pendingResync)
            }
        }
    }
    var onEvent: ((SimulationEvent) -> Void)?
    var onForfeit: ((Team) -> Void)?
    var onConnectionPaused: ((Bool) -> Void)?
    var onReconnect: (() -> Void)?

    private var match: GKMatch?
    private var sequence: UInt64 = 0
    private var inputBuffers: [Seat: RemoteInputBuffer] = [:]
    /// When the last packet of any kind arrived from each peer, by player ID.
    private var lastHeard: [String: TimeInterval] = [:]
    /// Peers judged gone from silence alone, because GameKit never said so.
    private var silentPeers: Set<String> = []
    private var heartbeatTask: Task<Void, Never>?
    /// This end's own clock, for measuring how long a link has been quiet.
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    /// How long a pilot's last input stays flyable. Inputs go out every other
    /// tick, so half a second of nothing is a dead link, not jitter.
    private static let inputExpirySeconds: TimeInterval = 0.5
    /// Total silence this long from a seated pilot is a dropped link, whatever
    /// GameKit still says. Pings go out every second, so this is five missed.
    private static let peerSilenceSeconds: TimeInterval = 5
    private var snapshotGate = AuthoritativeSnapshotGate()
    private var eventGate = MonotonicSequenceGate()
    private var lifecycle = OnlineMatchLifecycle()
    /// Game Center IDs of every peer whose `.ready` has arrived.
    private var readyPeers: Set<String> = []
    /// How this end joined: the inviter hosts, an invitee never does, and an
    /// automatch takes the lowest player ID on every board at once.
    private var role: OnlineMatchRole = .automatch
    /// Bumped on every search, invite, join and cancel, so a completion or
    /// recipient response from an earlier request cannot touch the current one.
    private var matchmakingGeneration = 0
    /// Invited pilots who said no (or never answered): seats that will stay
    /// empty, so the match can start without waiting for them.
    private var declinedInvites = 0
    /// The team that walked out, so the forfeit goes to the other side.
    private var pendingForfeitWinner: Team?
    private var session: OnlineSessionStateMachine?
    private var reconnectTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?
    /// How long to keep re-sending `.ready` before giving up on the peer.
    private static let handshakeTimeoutSeconds = 20
    private static let connectTimeoutSeconds = 30
    private var lastAuthoritativeState: WorldState?
    private var pendingResync: WorldState?
    /// Game Center ID of whoever runs the rules. A guest that outlives the
    /// host takes this over so the chair can be held.
    private var hostID: String?
    /// The host's sliders, from the seating plan. A guest sets its board up
    /// from these rather than its own settings.
    private(set) var hostTuning = FlightTuningSnapshot.defaults
    var hostSetsToWin: Int { hostTuning.setsToWin }
    /// The local sliders: what every board flies when this end hosts.
    var preferredTuning = FlightTuningSnapshot.defaults
    /// Every GKPlayer seen at this table, so a pilot who dropped can be
    /// invited back into the same match.
    private var knownPlayers: [String: GKPlayer] = [:]
    /// An invite arrived while our own link was being held: the arena is
    /// still up, so it resumes instead of starting over.
    private var resumingAfterDrop = false
    /// How long a dropped pilot's chair stays theirs before the forfeit.
    private static let seatHoldSeconds = 120
    /// Seconds into the hold before Game Center is asked to call them back.
    private static let reinviteDelaySeconds = 3
    private var pendingPing: UInt64?
    /// Stamps this board put on the wire. An echo carrying one of these is our
    /// own round trip coming home, never something to answer.
    private var ownPings: [UInt64] = []
    private let codec = WireCodec()
    private var isListenerRegistered = false
    private var pendingMatchmakingIntent: MatchmakingIntent?

    func authenticate() {
        guard !GKLocalPlayer.local.isAuthenticated else {
            signedIn()
            return
        }
        status = .authenticating
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
            Task { @MainActor in
                guard let self else { return }
                if let viewController {
                    self.note("AUTH: SHOWING SIGN-IN")
                    self.present(viewController)
                } else if GKLocalPlayer.local.isAuthenticated {
                    self.signedIn()
                } else if let error {
                    let detail = self.describe(error)
                    self.note("AUTH FAILED: \(detail)")
                    self.pendingMatchmakingIntent = nil
                    self.status = .failed(message: "Game Center unavailable · \(detail)")
                } else {
                    self.note("AUTH: SIGNED OUT")
                    self.pendingMatchmakingIntent = nil
                    self.status = .signedOut
                }
            }
        }
    }

    /// Invite delivery requires an authenticated local player, so the listener is
    /// registered here rather than in `init`. `registerListener` must run once only.
    private func signedIn() {
        if !isListenerRegistered {
            isListenerRegistered = true
            GKLocalPlayer.local.register(self)
        }
        let player = GKLocalPlayer.local
        var flags: [String] = []
        if player.isUnderage { flags.append("UNDERAGE") }
        if player.isMultiplayerGamingRestricted { flags.append("MULTIPLAYER RESTRICTED") }
        if player.isPersonalizedCommunicationRestricted { flags.append("COMMS RESTRICTED") }
        note("SIGNED IN: \(player.displayName)" + (flags.isEmpty ? "" : " · " + flags.joined(separator: ", ")))
        if player.isMultiplayerGamingRestricted {
            status = .failed(message: "Multiplayer restricted by Screen Time")
            pendingMatchmakingIntent = nil
            return
        }
        // Game Center runs this handler again whenever the app comes back to
        // the foreground, which is exactly when an invitee has just tapped
        // the invite. Overwriting `.matching` here sends them home instead
        // of into the bay.
        switch status {
        case .matching, .connected, .reconnecting: break
        default: status = .ready(playerName: player.displayName)
        }
        if let intent = pendingMatchmakingIntent {
            pendingMatchmakingIntent = nil
            switch intent {
            case .quickMatch: startQuickMatch()
            case .friendInvite: presentMatchmaker(inviteOnly: true)
            case let .invite(players): invite(players)
            }
        }
    }

    func presentQuickMatch() {
        presentMatchmaker(inviteOnly: false)
    }

    /// Apple's picker, kept as the fallback for pilots who are not in the
    /// in-app list. It is modal, so there is no warm-up bay behind it.
    func presentFriendInvite() {
        presentMatchmaker(inviteOnly: true)
    }

    /// Automatch without the modal picker, so the pilot warms up in the bay
    /// while Game Center searches.
    func startQuickMatch() {
        startMatchmaking(recipients: nil)
    }

    /// Sends Game Center invitations straight from the app and returns at
    /// once, so the pilot waits in the bay instead of in a modal sheet.
    func invite(_ players: [GKPlayer]) {
        startMatchmaking(recipients: players)
    }

    /// Drops a search or an outstanding invite. Safe when nothing is pending.
    func cancelMatchmaking() {
        matchmakingGeneration += 1
        GKMatchmaker.shared().cancel()
        if case .matching = status {
            note("MATCHMAKING: CANCELLED BY PILOT")
            status = .ready(playerName: GKLocalPlayer.local.displayName)
        }
    }

    func loadInvitees() {
        guard GKLocalPlayer.local.isAuthenticated, !isLoadingInvitees else { return }
        isLoadingInvitees = true
        GKLocalPlayer.local.loadRecentPlayers { [weak self] recent, recentError in
            GKLocalPlayer.local.loadFriends { friends, friendsError in
                // GameKit hands these back on its own queue; they are only ever
                // read on the main actor from here on.
                nonisolated(unsafe) let recent = recent
                nonisolated(unsafe) let friends = friends
                Task { @MainActor in
                    guard let self else { return }
                    if let recentError { self.note("RECENT PLAYERS: \(self.describe(recentError))") }
                    if let friendsError { self.note("FRIENDS: \(self.describe(friendsError))") }
                    var seen: Set<String> = []
                    self.invitees = ((recent ?? []) + (friends ?? []))
                        .filter { seen.insert($0.gamePlayerID).inserted }
                    self.note("INVITEES: \(self.invitees.count)")
                    self.isLoadingInvitees = false
                }
            }
        }
    }

    private func startMatchmaking(recipients: [GKPlayer]?) {
        guard GKLocalPlayer.local.isAuthenticated else {
            pendingMatchmakingIntent = recipients.map { .invite($0) } ?? .quickMatch
            authenticate()
            return
        }
        let request = GKMatchRequest()
        // One seat per invited pilot, up to four on the court.
        let partySize = min(4, 1 + (recipients?.count ?? 1))
        request.minPlayers = 2
        request.maxPlayers = partySize
        request.defaultNumberOfPlayers = partySize
        request.inviteMessage = partySize > 2 ? "Doubles in ASTROSPIKE" : "Duel me in ASTROSPIKE"
        request.recipients = recipients
        let recipientCount = recipients?.count ?? 0
        role = recipients != nil ? .inviter : .automatch
        declinedInvites = 0
        matchmakingGeneration += 1
        let generation = matchmakingGeneration
        request.recipientResponseHandler = { [weak self] player, response in
            Task { @MainActor in
                guard let self, generation == self.matchmakingGeneration else { return }
                let word = Self.describe(response)
                self.note("INVITE → \(player.displayName): \(word)")
                self.inviteNotice = "\(player.displayName.uppercased()) · \(word)"
                guard response != .accepted else { return }
                self.declinedInvites += 1
                // Everyone we asked said no, so there is nothing to wait for.
                if self.declinedInvites >= recipientCount, case .matching = self.status, self.match == nil {
                    GKMatchmaker.shared().cancel()
                    self.status = .failed(message: "\(player.displayName): \(word.lowercased())")
                } else {
                    self.tryStartAsHost()
                }
            }
        }
        inviteNotice = nil
        if let recipients {
            note("INVITING \(recipients.map(\.displayName).joined(separator: ", "))")
        } else {
            note("QUICK MATCH: SEARCHING")
        }
        status = .matching
        GKMatchmaker.shared().findMatch(for: request) { [weak self] match, error in
            nonisolated(unsafe) let match = match
            Task { @MainActor in
                guard let self, generation == self.matchmakingGeneration,
                      case .matching = self.status else { return }
                if let error {
                    let detail = self.describe(error)
                    self.note("MATCHMAKING FAILED: \(detail)")
                    self.status = .failed(message: detail)
                    return
                }
                guard let match else {
                    self.status = .failed(message: "No match returned")
                    return
                }
                let names = match.players.map(\.displayName).joined(separator: ", ")
                self.note("MATCH FOUND: [\(names)] · EXPECTING \(match.expectedPlayerCount) MORE")
                self.configure(match)
            }
        }
    }

    func sendInput(_ input: PlayerInput) {
        guard let localSeat else { return }
        send(.input(seat: localSeat, value: input), mode: .unreliable)
    }

    func sendSnapshot(_ state: WorldState) {
        guard isAuthoritative else { return }
        lastAuthoritativeState = state
        send(.snapshot(state), mode: .unreliable)
    }

    func sendEvent(_ event: SimulationEvent) {
        guard isAuthoritative else { return }
        send(.event(event), mode: .reliable)
    }

    func sendFullResync(_ state: WorldState) {
        guard isAuthoritative else { return }
        lastAuthoritativeState = state
        send(.resync(state), mode: .reliable)
    }

    func sendPing() {
        let sentAt = DispatchTime.now().uptimeNanoseconds
        pendingPing = sentAt
        ownPings.append(sentAt)
        if ownPings.count > 4 { ownPings.removeFirst(ownPings.count - 4) }
        // Best effort on purpose. This fires once a second for the life of the
        // match, the seat hold included -- and during a hold the pilot it is
        // addressed to is exactly the one who is gone. A ping that cannot go
        // out is the thing being measured, not a reason to call the match.
        sendQuietly(.ping(nanoseconds: sentAt), to: nil, mode: .unreliable)
    }

    private func presentMatchmaker(inviteOnly: Bool) {
        guard GKLocalPlayer.local.isAuthenticated else {
            pendingMatchmakingIntent = inviteOnly ? .friendInvite : .quickMatch
            authenticate()
            return
        }
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        request.defaultNumberOfPlayers = 2
        request.inviteMessage = "Duel me in ASTROSPIKE"
        request.recipientResponseHandler = { [weak self] player, response in
            Task { @MainActor in
                self?.note("INVITE → \(player.displayName): \(Self.describe(response))")
            }
        }
        guard let controller = GKMatchmakerViewController(matchRequest: request) else {
            note("MATCHMAKER: CONTROLLER UNAVAILABLE")
            status = .failed(message: "Matchmaker unavailable")
            return
        }
        controller.matchmakerDelegate = self
        controller.canStartWithMinimumPlayers = false
        controller.matchmakingMode = inviteOnly ? .inviteOnly : .automatchOnly
        role = inviteOnly ? .inviter : .automatch
        declinedInvites = 0
        matchmakingGeneration += 1
        note(inviteOnly ? "MATCHMAKER: INVITE PICKER OPEN" : "MATCHMAKER: QUICK MATCH SEARCHING")
        status = .matching
        present(controller)
    }

    private static func describe(_ response: GKInviteRecipientResponse) -> String {
        switch response {
        case .accepted: "ACCEPTED"
        case .declined: "DECLINED"
        case .failed: "FAILED TO DELIVER"
        case .incompatible: "INCOMPATIBLE (NO APP / VERSION)"
        case .unableToConnect: "UNABLE TO CONNECT"
        case .noAnswer: "NO ANSWER"
        @unknown default: "RESPONSE \(response.rawValue)"
        }
    }

    /// A programmatic `findMatch` hands the match back before the invited
    /// pilot has connected, and `chooseBestHostingPlayer` returns nil on a
    /// match that is not fully connected. So: wait for every seat to fill,
    /// then pick the host without asking GameKit at all.
    private func configure(_ match: GKMatch) {
        // A join that lands on top of an earlier match (a failed invite that
        // never left, an invite accepted mid-search) must not leave the old
        // transport alive and still pointed at us.
        if let stale = self.match, stale !== match { disconnectTransport() }
        self.match = match
        for player in match.players { knownPlayers[player.gamePlayerID] = player }
        hostID = nil
        hostTuning = .defaults
        readyPeers = []
        seating = [:]
        mismatchedPeers = []
        remoteHulls = [:]
        inputBuffers = [:]
        heardSeats = []
        lastHeard = [:]
        silentPeers = []
        isMatchReady = false
        isAuthoritative = false
        localSeat = nil
        lifecycle.beginConfiguration()
        match.delegate = self
        status = .matching
        let names = match.players.map(\.displayName).joined(separator: ", ")
        note("TABLE: [\(names)] IN · EXPECTING \(match.expectedPlayerCount) · \(roleLabel)")
        beginConnectWait()
        tryStartAsHost()
    }

    private func beginConnectWait() {
        handshakeTask?.cancel()
        let matchIdentifier = match.map(ObjectIdentifier.init)
        handshakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.connectTimeoutSeconds))
            guard let self, !Task.isCancelled,
                  self.match.map(ObjectIdentifier.init) == matchIdentifier,
                  self.lifecycle.phase == .configuring else { return }
            self.note("CONNECT TIMED OUT: PILOT NEVER JOINED")
            self.status = .failed(message: "Pilot never connected · try again")
            self.leaveMatch(preservingStatus: true)
        }
    }

    /// Once every seat that is going to fill has filled, the host seats the
    /// table and tells everyone. The inviter is the host; in a quick match
    /// both ends see the same player list, so the lowest Game Center player
    /// ID hosts with no negotiation and nothing that can come back nil.
    /// Guests do nothing here: their seat arrives in a `.seating` message.
    private func tryStartAsHost() {
        guard let match, lifecycle.phase == .configuring else { return }
        guard match.expectedPlayerCount <= declinedInvites else { return }
        // A decline can zero the expected count before the pilot who accepted
        // has actually connected. Seating the table then puts a bot in their
        // chair and leaves them knocking on a match that already started.
        guard !match.players.isEmpty else {
            note("WAITING FOR A PILOT TO CONNECT BEFORE SEATING")
            return
        }
        let localID = GKLocalPlayer.local.gamePlayerID
        let peerIDs = match.players.map(\.gamePlayerID).sorted()
        guard OnlineSeating.localHosts(localID: localID, peerIDs: peerIDs, role: role) else {
            note("WAITING FOR HOST TO SEAT THE TABLE")
            return
        }
        // Leads first, then wings, so three pilots are two against one plus
        // a bot on the empty wing rather than a lopsided pair.
        let order: [Seat] = [.cyan, .orange, .cyanWing, .orangeWing]
        var plan: [String: Seat] = [:]
        for (index, id) in ([localID] + peerIDs).prefix(order.count).enumerated() {
            plan[id] = order[index]
        }
        seating = plan
        hostID = localID
        hostTuning = preferredTuning
        isAuthoritative = true
        startConfiguredMatch()
    }

    private func startConfiguredMatch() {
        guard lifecycle.phase == .configuring,
              let seat = seating[GKLocalPlayer.local.gamePlayerID] else { return }
        handshakeTask?.cancel()
        localSeat = seat
        note("SEATED AS \(seat.label) · LOCAL IS \(isAuthoritative ? "HOST" : "GUEST") · \(seating.count) PILOTS")
        session = OnlineSessionStateMachine(
            localTeam: seat.team,
            ticksPerSecond: 120,
            reconnectWindowSeconds: UInt64(Self.seatHoldSeconds)
        )
        lifecycle.beginMatch()
        snapshotGate.reset()
        eventGate.reset()
        isMatchReady = allPeersReady
        status = isMatchReady ? .connected : .matching
        resumeIfBackAtTable()
        // Answer any `.ready` that arrived while we were still configuring:
        // the handshake loop below stops at once when the peer is already heard.
        sendHandshake()
        beginHandshake()
        beginHeartbeat()
    }

    /// A ping a second, for as long as the match runs.
    ///
    /// It was one ping at kick-off, which made `pingMilliseconds` a number
    /// from the distant past and left nothing at all flowing between two
    /// boards that were not stepping the simulation. The repeat gives both
    /// ends something to miss.
    private func beginHeartbeat() {
        heartbeatTask?.cancel()
        let started = Self.now
        let localID = GKLocalPlayer.local.gamePlayerID
        for id in seating.keys where id != localID { lastHeard[id] = started }
        silentPeers = []
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.match != nil else { return }
                self.sendPing()
                self.checkPeerLiveness()
            }
        }
    }

    /// GameKit does not always tell us a pilot has gone. A backgrounded app,
    /// a Wi-Fi handoff, a phone that went in a pocket mid-rally: the match
    /// object stays connected and the packets simply stop. Until this, the
    /// board went on flying the last packet it ever got -- a burn into the
    /// roof that never let up -- under a HUD still reading LINK STABLE.
    /// Silence is the signal, and it holds the seat exactly as a clean
    /// disconnect does.
    private func checkPeerLiveness() {
        // Only once the table is actually playing. A pilot who seats and then
        // never answers belongs to the handshake timeout, which gives up in
        // twenty seconds rather than holding their chair for two minutes.
        guard isMatchReady, lifecycle.acceptsGameplayData, !seating.isEmpty else { return }
        let localID = GKLocalPlayer.local.gamePlayerID
        let now = Self.now
        let silent = Set(seating.keys.filter {
            $0 != localID && now - (lastHeard[$0] ?? now) >= Self.peerSilenceSeconds
        })
        guard silent != silentPeers else { return }
        let gone = silent.subtracting(silentPeers)
        let returned = silentPeers.subtracting(silent)
        silentPeers = silent

        if let dropped = gone.first {
            let name = seatedPilotNames[dropped] ?? "PILOT"
            note("SILENT LINK: NOTHING FROM \(name) IN \(Int(Self.peerSilenceSeconds))s")
            for id in gone { readyPeers.remove(id) }
            pendingForfeitWinner = seating[dropped]?.team.opponent
            beginReconnectWindow()
            return
        }
        // A five-second hole that closes again was a bad stretch of network,
        // not a pilot walking out. Take the seat off hold rather than making
        // them sit through the rest of a two-minute count.
        guard silent.isEmpty, !returned.isEmpty, case .reconnecting = status else { return }
        note("PACKETS RESUMED · SEAT RECLAIMED")
        readyPeers.formUnion(returned)
        _ = lifecycle.acceptConnection()
        completeReconnect()
    }

    /// The peer only learns we are ready from a message, and a message sent
    /// before the peer has installed its match delegate is silently dropped by
    /// GameKit. Re-send the handshake every second until the peer's own `.ready`
    /// arrives, and fail visibly instead of sitting on FINDING PILOT forever.
    private func beginHandshake() {
        handshakeTask?.cancel()
        let matchIdentifier = match.map(ObjectIdentifier.init)
        note("HANDSHAKE: WAITING FOR PILOT READY")
        handshakeTask = Task { @MainActor [weak self] in
            var elapsed = 0
            while !Task.isCancelled {
                guard let self, self.match.map(ObjectIdentifier.init) == matchIdentifier else { return }
                if self.allPeersReady { return }
                if elapsed >= Self.handshakeTimeoutSeconds {
                    if case .reconnecting = self.status {
                        // A pilot who came back but never seated. The hold
                        // keeps counting and the forfeit lands on its own.
                        self.note("HANDSHAKE TIMED OUT: RETURNING PILOT NEVER SENT READY")
                        return
                    }
                    self.note("HANDSHAKE TIMED OUT: PEER NEVER SENT READY")
                    self.status = .failed(message: "Pilot never answered · try again")
                    self.leaveMatch(preservingStatus: true)
                    return
                }
                self.sendHandshake()
                try? await Task.sleep(for: .seconds(1))
                elapsed += 1
            }
        }
    }

    /// Every pilot in the seating plan has said `.ready`. The plan, not
    /// GameKit's expected count: a guest's match never learns that a third
    /// invitee declined, so its count would hold the guest in the bay forever.
    private var allPeersReady: Bool {
        guard match != nil, lifecycle.phase != .configuring else { return false }
        return OnlineSeating.allPeersReady(
            seating: seating,
            localID: GKLocalPlayer.local.gamePlayerID,
            readyPeers: readyPeers
        )
    }

    private var roleLabel: String {
        switch role {
        case .inviter: "INVITER HOSTS"
        case .invitee: "INVITEE, HOST SEATS US"
        case .automatch: "AUTOMATCH, LOWEST ID HOSTS"
        }
    }

    private func sendHandshake() {
        if isAuthoritative, !seating.isEmpty {
            send(.seating(plan: seating, tuning: hostTuning), mode: .reliable)
        }
        send(.ready, mode: .reliable)
        send(.profile(seat: localSeat ?? .cyan, hull: localHull), mode: .reliable)
    }

    private func send(_ payload: WirePayload, mode: GKMatch.SendDataMode) {
        guard let match else { return }
        do {
            sequence &+= 1
            let data = try codec.encode(WireEnvelope(sequence: sequence, payload: payload))
            try match.sendData(toAllPlayers: data, with: mode)
        } catch {
            note("SEND FAILED: \(describe(error))")
            status = .failed(message: "Network send failed")
        }
    }

    /// The heartbeat and its echoes: best effort, and addressed.
    ///
    /// A `playerID` answers one pilot rather than the table, because a ping
    /// echoed to everyone is an echo every other board then echoes back -- at
    /// three or four pilots the same stamp bounces between them forever, and a
    /// heartbeat re-seeds it every second. Nil addresses the table.
    ///
    /// Failure here is noted and dropped. Reliable sends carry real state and
    /// still go through `send(_:mode:)`, which does end the match on a throw.
    private func sendQuietly(_ payload: WirePayload, to playerID: String?, mode: GKMatch.SendDataMode) {
        guard let match else { return }
        do {
            sequence &+= 1
            let data = try codec.encode(WireEnvelope(sequence: sequence, payload: payload))
            if let playerID {
                guard let player = match.players.first(where: { $0.gamePlayerID == playerID })
                else { return }
                try match.send(data, to: [player], dataMode: mode)
            } else {
                guard !match.players.isEmpty else { return }
                try match.sendData(toAllPlayers: data, with: mode)
            }
        } catch {
            note("PING DROPPED: \(describe(error))")
        }
    }

    private func receive(_ data: Data, from playerID: String) {
        // Before the decode: a packet we cannot read still proves the pilot
        // is there, and that is all the liveness check is asking.
        lastHeard[playerID] = Self.now
        let envelope: WireEnvelope
        do {
            envelope = try codec.decode(data)
        } catch WireProtocolError.unsupportedVersion(let version) {
            // A pilot on another TestFlight build. Every packet they send is
            // useless to us, so say so once instead of silently sitting still.
            if mismatchedPeers.insert(playerID).inserted {
                let name = seatedPilotNames[playerID] ?? "PILOT"
                note("WIRE MISMATCH: \(name) IS ON WIRE \(version), WE ARE \(WireEnvelope.currentVersion)")
                inviteNotice = "\(name.uppercased()) IS ON A DIFFERENT BUILD · UPDATE BOTH"
            }
            return
        } catch {
            return
        }
        switch envelope.payload {
        case let .input(seat, value):
            guard lifecycle.acceptsGameplayData, seat != localSeat else { return }
            var buffer = inputBuffers[seat] ?? RemoteInputBuffer()
            if heardSeats.insert(seat).inserted {
                note("FIRST INPUT FROM \(seat.label) AT TICK \(value.tick)")
            }
            if buffer.accept(value, at: Self.now) { inputBuffers[seat] = buffer }
        case let .seating(plan, tuning):
            guard lifecycle.acceptsNetworkMessages, plan[GKLocalPlayer.local.gamePlayerID] != nil else { return }
            if lifecycle.phase == .configuring {
                seating = plan
                hostID = playerID
                hostTuning = tuning
                isAuthoritative = false
                startConfiguredMatch()
            } else if !isAuthoritative {
                // A guest that took over hosting reseated the table: remember
                // who runs the rules now, so the next drop is judged right.
                hostID = playerID
                hostTuning = tuning
            }
        case let .snapshot(state):
            if lifecycle.acceptsGameplayData, snapshotGate.accept(tick: state.tick) {
                onSnapshot?(state)
            }
        case let .event(event):
            if lifecycle.acceptsGameplayData, eventGate.accept(sequence: envelope.sequence) {
                onEvent?(event)
            }
        case .ready:
            guard lifecycle.acceptsNetworkMessages else { return }
            let firstHearing = readyPeers.insert(playerID).inserted
            guard lifecycle.phase != .configuring else { return }
            // Answer once more now that the peer is provably listening, in
            // case everything we sent before this point was dropped.
            if firstHearing {
                note("HANDSHAKE: PILOT READY (\(readyPeers.count)/\(match?.players.count ?? 1))")
                sendHandshake()
            }
            guard allPeersReady else { return }
            if case .reconnecting = status {
                completeReconnect()
            } else {
                if !isMatchReady { isMatchReady = true }
                if status != .connected { status = .connected }
                resumeIfBackAtTable()
            }
        case let .profile(seat, hull):
            guard lifecycle.acceptsNetworkMessages, seat != localSeat else { return }
            remoteHulls[seat] = hull
            note("\(seat.label) FLIES \(hull.spec.name.uppercased())")
        case let .ping(sentAt):
            guard lifecycle.acceptsNetworkMessages else { return }
            guard !ownPings.contains(sentAt) else {
                // Our own stamp home again. The first board to answer times the
                // trip; a second pilot's echo of the same stamp is that same
                // trip, not a new question.
                guard pendingPing == sentAt else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                pingMilliseconds = Int((now - sentAt) / 1_000_000)
                pendingPing = nil
                return
            }
            sendQuietly(.ping(nanoseconds: sentAt), to: playerID, mode: .unreliable)
        case let .resync(state):
            if lifecycle.acceptsGameplayData {
                snapshotGate.reset(to: state.tick)
                if let onResync { onResync(state) } else { pendingResync = state }
            }
        }
    }

    /// A pilot dropped. Their chair is held for two minutes: the board
    /// pauses, Game Center is asked to call them back, and only when the hold
    /// runs out does the match go to the side that stayed.
    private func beginReconnectWindow() {
        guard lifecycle.beginReconnect(), var session else { return }
        _ = session.remoteDisconnected(at: 0)
        self.session = session
        status = .reconnecting(seconds: Self.seatHoldSeconds)
        onConnectionPaused?(true)
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            for remaining in stride(from: Self.seatHoldSeconds - 1, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if remaining == 0 {
                    self.note("SEAT HOLD EXPIRED · FORFEIT")
                    self.status = .failed(message: "Opponent forfeited")
                    self.isMatchReady = false
                    self.lifecycle.finish()
                    self.heartbeatTask?.cancel()
                    self.heartbeatTask = nil
                    if let winner = self.pendingForfeitWinner ?? self.localTeam { self.onForfeit?(winner) }
                    self.disconnectTransport()
                    return
                }
                self.status = .reconnecting(seconds: remaining)
                if remaining == Self.seatHoldSeconds - Self.reinviteDelaySeconds {
                    self.reinviteDroppedPilots()
                }
            }
        }
    }

    /// The returning pilot has seated and said `.ready`: the hold is over.
    /// The host restarts the rally and resyncs everyone from its board.
    private func completeReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        if var session {
            _ = session.remoteReconnected(at: 0)
            self.session = session
        }
        status = .connected
        isMatchReady = true
        note("SEAT RECLAIMED · RESUMING")
        onReconnect?()
    }

    /// Our own link dropped and the peer called us back into a new match
    /// with the arena still up. Once everyone is heard, the board unpauses
    /// and waits for the host's resync.
    private func resumeIfBackAtTable() {
        guard resumingAfterDrop, isMatchReady else { return }
        resumingAfterDrop = false
        note("BACK AT THE TABLE")
        onReconnect?()
    }

    /// Ask Game Center to invite whoever dropped back into this same match.
    /// Runs on its own a few seconds into the hold, and again from the arena
    /// button for as long as the chair is held.
    func reinviteDroppedPilots() {
        guard let match, case .reconnecting = status else { return }
        var present = Set(match.players.map(\.gamePlayerID))
        present.insert(GKLocalPlayer.local.gamePlayerID)
        let missing = seating.keys.filter { !present.contains($0) }.compactMap { knownPlayers[$0] }
        guard !missing.isEmpty else {
            note("NOBODY TO RE-INVITE")
            return
        }
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 4
        request.recipients = missing
        request.inviteMessage = "Your seat is still open. Come back!"
        note("RE-INVITING \(missing.map(\.displayName).joined(separator: ", "))")
        GKMatchmaker.shared().addPlayers(to: match, matchRequest: request) { [weak self] error in
            let detail = error.map { self?.describe($0) ?? "\($0)" }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let detail {
                    self.note("RE-INVITE FAILED: \(detail)")
                } else {
                    self.note("RE-INVITE SENT")
                }
            }
        }
    }

    private func present(_ controller: UIViewController) {
        guard let presenter = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController else { return }
        var top = presenter
        while let presented = top.presentedViewController { top = presented }
        top.present(controller, animated: true)
    }

    func matchmakerViewControllerWasCancelled(_ viewController: GKMatchmakerViewController) {
        note("MATCHMAKER: CANCELLED")
        viewController.dismiss(animated: true)
        status = .ready(playerName: GKLocalPlayer.local.displayName)
    }

    func matchmakerViewController(_ viewController: GKMatchmakerViewController, didFailWithError error: Error) {
        let detail = describe(error)
        note("MATCHMAKER FAILED: \(detail)")
        viewController.dismiss(animated: true)
        status = .failed(message: detail)
    }

    func matchmakerViewController(_ viewController: GKMatchmakerViewController, didFind match: GKMatch) {
        let names = match.players.map(\.displayName).joined(separator: ", ")
        note("MATCH FOUND: [\(names)] · EXPECTING \(match.expectedPlayerCount) MORE")
        viewController.dismiss(animated: true)
        configure(match)
    }

    nonisolated func match(_ match: GKMatch, didReceive data: Data, fromRemotePlayer player: GKPlayer) {
        let playerID = player.gamePlayerID
        Task { @MainActor [weak self] in
            guard let self, self.match === match else { return }
            self.receive(data, from: playerID)
        }
    }

    nonisolated func match(_ match: GKMatch, player: GKPlayer, didChange state: GKPlayerConnectionState) {
        let displayName = player.displayName
        let playerID = player.gamePlayerID
        nonisolated(unsafe) let safePlayer = player
        Task { @MainActor [weak self] in
            guard let self, self.match === match else { return }
            self.knownPlayers[playerID] = safePlayer
            self.handlePeerConnectionChange(displayName: displayName, playerID: playerID, state: state)
        }
    }

    private func handlePeerConnectionChange(displayName: String, playerID: String, state: GKPlayerConnectionState) {
        let word = state == .connected ? "CONNECTED" : state == .disconnected ? "DISCONNECTED" : "UNKNOWN"
        note("PEER \(displayName): \(word) · \(match?.players.count ?? 0) IN · EXPECTING \(match?.expectedPlayerCount ?? 0)")
        switch state {
        case .connected:
            guard lifecycle.acceptConnection() else { return }
            if lifecycle.phase == .configuring {
                tryStartAsHost()
                return
            }
            if isAuthoritative, seating[playerID] == nil {
                seatLateArrival(playerID, displayName: displayName)
            }
            if case .reconnecting = status {
                // Their chair was held. They come back on a fresh match
                // object with no seat, so they need the plan again; their
                // `.ready` is what closes the hold.
                note("\(displayName) IS BACK · RESEATING")
                sendHandshake()
                beginHandshake()
                return
            }
            reconnectTask?.cancel()
            status = .connected
            isMatchReady = allPeersReady
            onConnectionPaused?(false)
        case .disconnected:
            readyPeers.remove(playerID)
            // Whoever left loses it for their side, whichever side that is.
            pendingForfeitWinner = seating[playerID]?.team.opponent
            let localID = GKLocalPlayer.local.gamePlayerID
            let remaining = seating.keys.filter { $0 != localID }
            if OnlineSeating.localTakesOverHosting(
                localID: localID, hostID: hostID, droppedID: playerID, remainingPeerIDs: remaining
            ) {
                // The host walked out of a live match. Somebody has to run
                // the rules while their chair is held, and it is us.
                isAuthoritative = true
                hostID = localID
                note("HOST \(displayName) DROPPED · LOCAL NOW HOSTS")
            }
            beginReconnectWindow()
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    /// A pilot who connects after the host has kicked off gets the first
    /// empty chair -- the one a bot has been keeping warm -- and a fresh
    /// seating plan so their own board can start.
    private func seatLateArrival(_ playerID: String, displayName: String) {
        let order: [Seat] = [.cyan, .orange, .cyanWing, .orangeWing]
        guard let seat = order.first(where: { !filledSeats.contains($0) }) else {
            note("NO CHAIR LEFT FOR \(displayName)")
            return
        }
        seating[playerID] = seat
        note("LATE ARRIVAL \(displayName) SEATED AS \(seat.label)")
        sendHandshake()
        if let lastAuthoritativeState { sendFullResync(lastAuthoritativeState) }
    }

    nonisolated func match(_ match: GKMatch, shouldReinviteDisconnectedPlayer player: GKPlayer) -> Bool {
        false
    }

    nonisolated func match(_ match: GKMatch, didFailWithError error: Error?) {
        let message = error.map { describe($0) }
        Task { @MainActor [weak self] in
            guard let self, self.match === match else { return }
            let detail = message ?? "The match ended"
            self.note("MATCH FAILED: \(detail)")
            // A log line was the whole of it, which is how a pilot got dropped
            // with the arena still up and nothing on screen to say so.
            guard self.lifecycle.acceptsNetworkMessages else { return }
            self.status = .failed(message: detail)
        }
    }

    nonisolated func player(_ player: GKPlayer, didAccept invite: GKInvite) {
        let displayName = invite.sender.displayName
        nonisolated(unsafe) let safeInvite = invite
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.handleInviteAccepted(senderDisplayName: displayName, invite: safeInvite)
        }
    }

    private func handleInviteAccepted(senderDisplayName: String, invite: GKInvite) {
        let rejoining = lifecycle.phase == .reconnecting
        guard !lifecycle.acceptsGameplayData || rejoining else {
            note("INVITE FROM \(senderDisplayName) IGNORED: MATCH IN PROGRESS")
            return
        }
        if rejoining {
            // Our own link died with the arena still up. The peer held our
            // chair and is calling us back: take the new match and resume.
            reconnectTask?.cancel()
            reconnectTask = nil
            resumingAfterDrop = true
            note("REJOINING \(senderDisplayName) · SEAT WAS HELD")
        } else {
            note("INVITE ACCEPTED FROM \(senderDisplayName)")
        }
        // Our own search or invite, if one is out, is over: the completion
        // it fires with `.cancelled` belongs to the old generation.
        matchmakingGeneration += 1
        let generation = matchmakingGeneration
        GKMatchmaker.shared().cancel()
        role = .invitee
        declinedInvites = 0
        inviteNotice = "JOINING \(senderDisplayName.uppercased())"
        status = .matching
        GKMatchmaker.shared().match(for: invite) { [weak self] match, error in
            nonisolated(unsafe) let match = match
            Task { @MainActor in
                guard let self, generation == self.matchmakingGeneration,
                      case .matching = self.status else { return }
                if let error {
                    let detail = self.describe(error)
                    self.note("INVITE JOIN FAILED: \(detail)")
                    self.status = .failed(message: detail)
                    return
                }
                guard let match else {
                    self.status = .failed(message: "Could not open invitation")
                    return
                }
                self.configure(match)
            }
        }
    }

    /// Game Center app / Messages "Play together" route: the system hands us the
    /// chosen recipients and expects us to open a matchmaker pre-filled with them.
    nonisolated func player(_ player: GKPlayer, didRequestMatchWithRecipients recipientPlayers: [GKPlayer]) {
        nonisolated(unsafe) let players = recipientPlayers
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.note("SYSTEM MATCH REQUEST WITH \(players.map(\.displayName).joined(separator: ", "))")
            self.invite(players)
        }
    }

    func leaveMatch() {
        leaveMatch(preservingStatus: false)
    }

    private func leaveMatch(preservingStatus: Bool) {
        disconnectTransport()
        reconnectTask?.cancel()
        reconnectTask = nil
        finishTask?.cancel()
        finishTask = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        session = nil
        lifecycle.reset()
        snapshotGate.reset()
        eventGate.reset()
        inputBuffers = [:]
        heardSeats = []
        lastHeard = [:]
        silentPeers = []
        mismatchedPeers = []
        remoteHulls = [:]
        isMatchReady = false
        isAuthoritative = false
        localSeat = nil
        seating = [:]
        readyPeers = []
        role = .automatch
        declinedInvites = 0
        pendingForfeitWinner = nil
        pingMilliseconds = nil
        pendingPing = nil
        ownPings = []
        lastAuthoritativeState = nil
        pendingResync = nil
        hostID = nil
        hostTuning = .defaults
        knownPlayers = [:]
        resumingAfterDrop = false
        onSnapshot = nil
        onResync = nil
        onEvent = nil
        onForfeit = nil
        onConnectionPaused = nil
        onReconnect = nil
        if !preservingStatus {
            status = GKLocalPlayer.local.isAuthenticated
                ? .ready(playerName: GKLocalPlayer.local.displayName)
                : .signedOut
        }
    }

    private func disconnectTransport() {
        match?.delegate = nil
        match?.disconnect()
        match = nil
    }

    func finishCompletedMatch() {
        guard lifecycle.acceptsGameplayData else { return }
        lifecycle.finish()
        isMatchReady = false
        reconnectTask?.cancel()
        reconnectTask = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        finishTask?.cancel()
        finishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled, self.lifecycle.phase == .terminal else { return }
            self.disconnectTransport()
            self.finishTask = nil
        }
    }
}
