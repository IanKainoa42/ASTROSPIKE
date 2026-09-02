@preconcurrency import GameKit
import ASTROSPIKECore
import Observation
import UIKit
import os

@MainActor
@Observable
final class OnlineMatchCoordinator: NSObject,
    @MainActor GKMatchDelegate,
    @MainActor GKMatchmakerViewControllerDelegate,
    @MainActor GKLocalPlayerListener {
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
    }

    private(set) var status: Status = .signedOut
    private(set) var isMatchReady = false
    private(set) var isAuthoritative = false
    private(set) var localTeam: Team?
    private(set) var remoteInput: PlayerInput?
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
    private func describe(_ error: Error) -> String {
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
    private var inputBuffer = RemoteInputBuffer()
    private var snapshotGate = AuthoritativeSnapshotGate()
    private var eventGate = MonotonicSequenceGate()
    private var lifecycle = OnlineMatchLifecycle()
    private var peerReadyReceived = false
    private var session: OnlineSessionStateMachine?
    private var reconnectTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
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
            presentMatchmaker(inviteOnly: intent == .friendInvite)
        }
    }

    func presentQuickMatch() {
        presentMatchmaker(inviteOnly: false)
    }

    func presentFriendInvite() {
        presentMatchmaker(inviteOnly: true)
    }

    func sendInput(_ input: PlayerInput) {
        guard let localTeam else { return }
        send(.input(team: localTeam, value: input), mode: .unreliable)
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

    private func configure(_ match: GKMatch) {
        self.match = match
        peerReadyReceived = false
        lifecycle.beginConfiguration()
        match.delegate = self
        let matchIdentifier = ObjectIdentifier(match)
        match.chooseBestHostingPlayer { [weak self] player in
            // Read everything off the player here: GKPlayer is not Sendable, so
            // only plain values may cross into the main actor.
            let hostPlayerID = player?.gamePlayerID
            let hostName = player?.displayName ?? "?"
            Task { @MainActor in
                guard let self,
                      self.match.map(ObjectIdentifier.init) == matchIdentifier else { return }
                guard let hostPlayerID else {
                    self.note("HOST SELECTION FAILED")
                    self.status = .failed(message: "Unable to select host")
                    self.leaveMatch(preservingStatus: true)
                    return
                }
                let localID = GKLocalPlayer.local.gamePlayerID
                self.isAuthoritative = hostPlayerID == localID
                self.note("HOST: \(hostName) · LOCAL IS \(self.isAuthoritative ? "HOST" : "GUEST")")
                self.localTeam = self.isAuthoritative ? .cyan : .orange
                self.session = OnlineSessionStateMachine(
                    localTeam: self.localTeam ?? .cyan,
                    ticksPerSecond: 120
                )
                self.lifecycle.beginMatch()
                self.snapshotGate.reset()
                self.eventGate.reset()
                self.isMatchReady = (self.match?.expectedPlayerCount ?? 0) == 0 && self.peerReadyReceived
                self.status = self.isMatchReady ? .connected : .matching
                self.send(.ready, mode: .reliable)
                self.sendPing()
            }
        }
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

    private func receive(_ data: Data) {
        guard let envelope = try? codec.decode(data) else { return }
        switch envelope.payload {
        case let .input(_, value):
            if lifecycle.acceptsGameplayData, inputBuffer.accept(value) {
                remoteInput = inputBuffer.latest
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
            peerReadyReceived = true
            guard lifecycle.phase != .configuring else { return }
            isMatchReady = true
            status = .connected
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
                    if let localTeam = self.localTeam { self.onForfeit?(localTeam) }
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

    func match(_ match: GKMatch, didReceive data: Data, fromRemotePlayer player: GKPlayer) {
        guard self.match === match else { return }
        receive(data)
    }

    func match(_ match: GKMatch, player: GKPlayer, didChange state: GKPlayerConnectionState) {
        guard self.match === match else { return }
        note("PEER \(player.displayName): \(state == .connected ? "CONNECTED" : state == .disconnected ? "DISCONNECTED" : "UNKNOWN")")
        switch state {
        case .connected:
            guard lifecycle.acceptConnection() else { return }
            if lifecycle.phase == .configuring {
                return
            }
            let wasReconnecting: Bool
            if case .reconnecting = status { wasReconnecting = true } else { wasReconnecting = false }
            reconnectTask?.cancel()
            status = .connected
            isMatchReady = match.expectedPlayerCount == 0 && peerReadyReceived
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
            beginReconnectWindow()
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    func match(_ match: GKMatch, shouldReinviteDisconnectedPlayer player: GKPlayer) -> Bool {
        true
    }

    func player(_ player: GKPlayer, didAccept invite: GKInvite) {
        note("INVITE ACCEPTED FROM \(invite.sender.displayName)")
        guard let controller = GKMatchmakerViewController(invite: invite) else {
            note("INVITE: CONTROLLER UNAVAILABLE")
            status = .failed(message: "Could not open invitation")
            return
        }
        controller.matchmakerDelegate = self
        status = .matching
        present(controller)
    }

    /// Game Center app / Messages "Play together" route: the system hands us the
    /// chosen recipients and expects us to open a matchmaker pre-filled with them.
    func player(_ player: GKPlayer, didRequestMatchWithRecipients recipientPlayers: [GKPlayer]) {
        note("SYSTEM MATCH REQUEST WITH \(recipientPlayers.map(\.displayName).joined(separator: ", "))")
        guard GKLocalPlayer.local.isAuthenticated else {
            pendingMatchmakingIntent = .friendInvite
            authenticate()
            return
        }
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        request.defaultNumberOfPlayers = 2
        request.recipients = recipientPlayers
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
        controller.matchmakingMode = .inviteOnly
        status = .matching
        present(controller)
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
        session = nil
        lifecycle.reset()
        snapshotGate.reset()
        eventGate.reset()
        inputBuffer = RemoteInputBuffer()
        remoteInput = nil
        isMatchReady = false
        isAuthoritative = false
        localTeam = nil
        pingMilliseconds = nil
        pendingPing = nil
        peerReadyReceived = false
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
        finishTask?.cancel()
        finishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled, self.lifecycle.phase == .terminal else { return }
            self.disconnectTransport()
            self.finishTask = nil
        }
    }
}
