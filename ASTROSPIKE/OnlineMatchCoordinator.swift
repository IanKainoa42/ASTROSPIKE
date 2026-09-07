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
            case let .reconnecting(seconds): "RECONNECTING \(seconds)"
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
    /// The latest input from every other pilot, by seat.
    private(set) var remoteInputs: [Seat: PlayerInput] = [:]
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
    var onResync: ((WorldState) -> Void)?
    var onEvent: ((SimulationEvent) -> Void)?
    var onForfeit: ((Team) -> Void)?
    var onConnectionPaused: ((Bool) -> Void)?
    var onReconnect: (() -> Void)?

    private var match: GKMatch?
    private var sequence: UInt64 = 0
    private var inputBuffers: [Seat: RemoteInputBuffer] = [:]
    private var snapshotGate = AuthoritativeSnapshotGate()
    private var eventGate = MonotonicSequenceGate()
    private var lifecycle = OnlineMatchLifecycle()
    /// Game Center IDs of every peer whose `.ready` has arrived.
    private var readyPeers: Set<String> = []
    /// True when this device sent the invites, which makes it the host.
    private var isInviter = false
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
    private var pendingPing: UInt64?
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
        status = .ready(playerName: player.displayName)
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
        isInviter = recipients != nil
        declinedInvites = 0
        request.recipientResponseHandler = { [weak self] player, response in
            Task { @MainActor in
                guard let self else { return }
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
                guard let self, case .matching = self.status else { return }
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
        send(.ping(nanoseconds: sentAt), mode: .unreliable)
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
        isInviter = inviteOnly
        declinedInvites = 0
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
        self.match = match
        readyPeers = []
        seating = [:]
        lifecycle.beginConfiguration()
        match.delegate = self
        status = .matching
        if match.expectedPlayerCount > 0 {
            note("WAITING FOR \(match.expectedPlayerCount) MORE PILOT(S) TO CONNECT")
        }
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
        let hostID = isInviter ? localID : ([localID] + peerIDs).min() ?? localID
        guard hostID == localID else {
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
        isAuthoritative = true
        startConfiguredMatch()
    }

    private func startConfiguredMatch() {
        guard lifecycle.phase == .configuring,
              let seat = seating[GKLocalPlayer.local.gamePlayerID] else { return }
        handshakeTask?.cancel()
        localSeat = seat
        note("SEATED AS \(seat.label) · LOCAL IS \(isAuthoritative ? "HOST" : "GUEST") · \(seating.count) PILOTS")
        session = OnlineSessionStateMachine(localTeam: seat.team, ticksPerSecond: 120)
        lifecycle.beginMatch()
        snapshotGate.reset()
        eventGate.reset()
        isMatchReady = allPeersReady
        status = isMatchReady ? .connected : .matching
        // Answer any `.ready` that arrived while we were still configuring:
        // the handshake loop below stops at once when the peer is already heard.
        sendHandshake()
        beginHandshake()
        sendPing()
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

    /// Every peer this match still expects has said `.ready`.
    private var allPeersReady: Bool {
        guard let match, lifecycle.phase != .configuring, !match.players.isEmpty else { return false }
        return match.expectedPlayerCount <= declinedInvites
            && match.players.allSatisfy { readyPeers.contains($0.gamePlayerID) }
    }

    private func sendHandshake() {
        if isAuthoritative, !seating.isEmpty { send(.seating(seating), mode: .reliable) }
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

    private func receive(_ data: Data, from playerID: String) {
        guard let envelope = try? codec.decode(data) else { return }
        switch envelope.payload {
        case let .input(seat, value):
            guard lifecycle.acceptsGameplayData, seat != localSeat else { return }
            var buffer = inputBuffers[seat] ?? RemoteInputBuffer()
            if buffer.accept(value) {
                inputBuffers[seat] = buffer
                remoteInputs[seat] = value
            }
        case let .seating(plan):
            guard lifecycle.acceptsNetworkMessages else { return }
            if lifecycle.phase == .configuring, plan[GKLocalPlayer.local.gamePlayerID] != nil {
                seating = plan
                isAuthoritative = false
                startConfiguredMatch()
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
            if allPeersReady {
                isMatchReady = true
                status = .connected
            }
        case let .profile(seat, hull):
            guard lifecycle.acceptsNetworkMessages, seat != localSeat else { return }
            remoteHulls[seat] = hull
            note("\(seat.label) FLIES \(hull.spec.name.uppercased())")
        case let .ping(sentAt):
            guard lifecycle.acceptsNetworkMessages else { return }
            if pendingPing == sentAt {
                let now = DispatchTime.now().uptimeNanoseconds
                pingMilliseconds = Int((now - sentAt) / 1_000_000)
                pendingPing = nil
            } else {
                send(.ping(nanoseconds: sentAt), mode: .unreliable)
            }
        case let .resync(state):
            if lifecycle.acceptsGameplayData {
                snapshotGate.reset(to: state.tick)
                onResync?(state)
            }
        }
    }

    private func beginReconnectWindow() {
        guard lifecycle.beginReconnect(), var session else { return }
        _ = session.remoteDisconnected(at: 0)
        self.session = session
        status = .reconnecting(seconds: 10)
        onConnectionPaused?(true)
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            for remaining in stride(from: 9, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if remaining == 0 {
                    self.status = .failed(message: "Opponent forfeited")
                    self.isMatchReady = false
                    self.lifecycle.finish()
                    if let winner = self.pendingForfeitWinner ?? self.localTeam { self.onForfeit?(winner) }
                    self.disconnectTransport()
                    return
                }
                self.status = .reconnecting(seconds: remaining)
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
        Task { @MainActor [weak self] in
            guard let self, self.match === match else { return }
            self.handlePeerConnectionChange(displayName: displayName, playerID: playerID, state: state)
        }
    }

    private func handlePeerConnectionChange(displayName: String, playerID: String, state: GKPlayerConnectionState) {
        note("PEER \(displayName): \(state == .connected ? "CONNECTED" : state == .disconnected ? "DISCONNECTED" : "UNKNOWN")")
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
            let wasReconnecting: Bool
            if case .reconnecting = status { wasReconnecting = true } else { wasReconnecting = false }
            reconnectTask?.cancel()
            status = .connected
            isMatchReady = allPeersReady
            if wasReconnecting {
                if var session {
                    _ = session.remoteReconnected(at: 0)
                    self.session = session
                }
                onReconnect?()
            } else {
                onConnectionPaused?(false)
            }
        case .disconnected:
            // Whoever left loses it for their side, whichever side that is.
            pendingForfeitWinner = seating[playerID]?.team.opponent
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
            if let message { self.note("MATCH FAILED: \(message)") }
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
        note("INVITE ACCEPTED FROM \(senderDisplayName)")
        inviteNotice = "JOINING \(senderDisplayName.uppercased())"
        status = .matching
        GKMatchmaker.shared().match(for: invite) { [weak self] match, error in
            nonisolated(unsafe) let match = match
            Task { @MainActor in
                guard let self, case .matching = self.status else { return }
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
        session = nil
        lifecycle.reset()
        snapshotGate.reset()
        eventGate.reset()
        inputBuffers = [:]
        remoteInputs = [:]
        remoteHulls = [:]
        isMatchReady = false
        isAuthoritative = false
        localSeat = nil
        seating = [:]
        readyPeers = []
        isInviter = false
        declinedInvites = 0
        pendingForfeitWinner = nil
        pingMilliseconds = nil
        pendingPing = nil
        lastAuthoritativeState = nil
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
        finishTask?.cancel()
        finishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled, self.lifecycle.phase == .terminal else { return }
            self.disconnectTransport()
            self.finishTask = nil
        }
    }
}
