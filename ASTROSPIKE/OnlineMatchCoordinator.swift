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
        case failed(reason: OnlineFailureReason)

        var label: String {
            switch self {
            case .signedOut: "GAME CENTER OFFLINE"
            case .authenticating: "SIGNING IN…"
            case let .ready(name): "ONLINE • \(name)"
            case .matching: "FINDING PILOT…"
            case .connected: "LINK STABLE"
            case let .reconnecting(seconds):
                "LINK LOST · SEAT HELD \(seconds / 60):\(String(format: "%02d", seconds % 60))"
            case let .failed(reason): reason.message.uppercased()
            }
        }
    }

    /// The specific failure reason when status is `.failed`, for UI surfaces
    /// that need more than a label (e.g. LinkLostOverlay).
    var failureReason: OnlineFailureReason? {
        if case let .failed(reason) = status { return reason }
        return nil
    }

    private enum MatchmakingIntent: Equatable {
        case quickMatch
        case friendInvite(teamUp: Bool)
        case invite([GKPlayer], teamUp: Bool)
    }

    /// Everyone the local pilot can invite without leaving the app: recent
    /// opponents first, then Game Center friends once that consent is given.
    private(set) var invitees: [GKPlayer] = []
    private(set) var isLoadingInvitees = false
    /// The latest word from an invited pilot, shown in the warm-up bay.
    private(set) var inviteNotice: String?
    /// Who the bay is waiting on, while it is waiting: JOINING IAN…,
    /// WAITING FOR MAYA…. Nil in a quick match, which really is finding one.
    var matchmakingHeadline: String? {
        guard case .matching = status else { return nil }
        return matchmakingHeadlineText
    }
    /// Seconds left on the door while an invitation is out and unanswered,
    /// nil when nothing is being waited on.
    ///
    /// An invited pilot gets five minutes to pick their phone up, which is
    /// the right window and far too long to sit under a headline that never
    /// changes. A number that ticks is the difference between "it's working"
    /// and "it's hung".
    private(set) var doorSecondsRemaining: Int?

    /// The status line every HUD shows.
    var statusLabel: String {
        guard let headline = matchmakingHeadline else { return status.label }
        guard let left = doorSecondsRemaining else { return headline }
        return "\(headline) · \(left)s"
    }

    #if DEBUG
    /// `--joining-preview`: the bay as an invitee sees it, without Game Center.
    func previewMatchmaking(headline: String) {
        matchmakingHeadlineText = headline
        status = .matching
    }
    #endif

    private(set) var status: Status = .signedOut
    private(set) var isMatchReady = false
    private(set) var isAuthoritative = false
    private(set) var localSeat: Seat?
    var localTeam: Team? { localSeat?.team }
    /// Bumped each time a fresh table is seated. The arena keys on it: a
    /// `GameSession` captures its seat and roster when it is built, and one
    /// left over from an earlier match flew the old seat while this end sent
    /// inputs for the new one. A pilot rejoining a held seat keeps theirs.
    private(set) var seatingGeneration = 0
    /// The host's seating plan, Game Center player ID to seat.
    private(set) var seating: [String: Seat] = [:]
    var filledSeats: Set<Seat> { Set(seating.values) }
    /// The host called a team-up: its guests fly beside it and the empty
    /// chairs go to bots. A guest takes this from the seating plan.
    private(set) var teamUp = false
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
    /// Why the first mismatched peer could not be read, kept so the failure
    /// that lands later (at once, or when the handshake times out) names
    /// the build gap rather than blaming a pilot who did answer.
    private var mismatchReason: OnlineFailureReason?
    /// The hulls the peers fly, once their profiles arrive. A seat missing
    /// here keeps its default, so the scene never shows a wrong hull.
    private(set) var remoteHulls: [Seat: Hull] = [:]
    /// Set by the app from the pilot profile; sent with the ready handshake.
    var localHull: Hull = .lancet
    private(set) var pingMilliseconds: Int?
    /// Rolling on-device log of Game Center events, oldest first.
    private(set) var eventLog: [String] = []

    private static let eventLogDepth = 250

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
        // Deep enough to hold a whole sign-in → invite → connect → drop →
        // rejoin run. Multiplayer is only ever debugged after the fact, from
        // whatever the pilot can send back, and a twelve-line window threw
        // the start of every story away before the end of it happened.
        if eventLog.count > Self.eventLogDepth {
            eventLog.removeFirst(eventLog.count - Self.eventLogDepth)
        }
    }

    /// The whole link log as plain text, with enough of a header to be
    /// worth reading a week later: which build, which device, which pilot.
    ///
    /// Game Center cannot run in the simulator, so every multiplayer defect
    /// this app has ever had was found on hardware, away from a debugger,
    /// and reported from memory. This is the thing to send instead.
    func linkTranscript(lobbyEvents: [String] = []) -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let device = UIDevice.current
        var lines = [
            "ASTROSPIKE LINK LOG",
            "\(Date.now.formatted(date: .abbreviated, time: .standard))",
            "APP \(version) (\(build)) · WIRE \(WireEnvelope.currentVersion)",
            "\(device.model) · iOS \(device.systemVersion)",
            "PILOT \(GKLocalPlayer.local.isAuthenticated ? GKLocalPlayer.local.displayName : "not signed in")",
            "STATE \(status.label) · ROLE \(roleLabel)",
            "",
            "-- GAME CENTER --",
        ]
        lines += eventLog.isEmpty ? ["(nothing yet)"] : eventLog
        if !lobbyEvents.isEmpty {
            lines += ["", "-- LOBBY --"] + lobbyEvents
        }
        return lines.joined(separator: "\n")
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

    /// What a pilot sees. Codes and engineer names stay in `describe`.
    nonisolated func playerFacingGameCenter(_ error: Error) -> String {
        gameCenterKind(error).message
    }

    nonisolated private func gameCenterKind(_ error: Error) -> PlayerNetworkCopy.GameCenter {
        guard let gkError = error as? GKError else { return .other }
        let kind: PlayerNetworkCopy.GameCenter = switch gkError.code {
        case .notAuthenticated: .notAuthenticated
        case .authenticationInProgress: .authenticationInProgress
        case .userDenied: .userDenied
        case .communicationsFailure: .communicationsFailure
        case .invitationsDisabled: .invitationsDisabled
        case .restrictedToAutomatch: .restrictedToAutomatch
        case .matchNotConnected: .matchNotConnected
        case .underage: .underage
        case .gameUnrecognized: .gameUnrecognized
        case .notSupported: .notSupported
        case .cancelled: .cancelled
        case .iCloudUnavailable: .iCloudUnavailable
        case .connectionTimeout: .connectionTimeout
        case .apiNotAvailable: .apiNotAvailable
        default: .other
        }
        return kind
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
    /// Who has gone quiet, and for how long. The decision itself lives in
    /// Core, where it can be exercised without a second phone.
    private var liveness = PeerLivenessMonitor(silenceSeconds: OnlineMatchCoordinator.peerSilenceSeconds)
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
    /// Who the current hold is for. When it runs out and their side still
    /// has a human, their chair goes to a bot instead of the match ending.
    private var droppedPilots: Set<String> = []
    private var session: OnlineSessionStateMachine?
    private var reconnectTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?
    /// How long to keep re-sending `.ready` before giving up on the peer.
    private static let handshakeTimeoutSeconds = 20

    /// The notice under the status line on a build mismatch: the name and
    /// what to do about it. The status line itself comes from
    /// `OnlineFailureReason.wireVersionMismatch`.
    private static func mismatchNotice(_ name: String) -> String {
        "\(name.uppercased()) IS ON AN OLDER BUILD · UPDATE BOTH APPS IN TESTFLIGHT, THEN INVITE AGAIN"
    }
    /// How long a table gets to fill, by how it was called. An automatch is
    /// a server search; an invitation is a person who has to be pushed,
    /// unlocked and cold-started. See `OnlineTimeouts`.
    private var connectTimeoutSeconds: Int { OnlineTimeouts.connectSeconds(role: role) }
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
    /// How long the host waits for Game Center's expected count to settle
    /// before seating the pilots who are already at the table.
    private static let seatGraceSeconds = 8
    private var pendingPing: UInt64?
    /// Stamps this board put on the wire. An echo carrying one of these is our
    /// own round trip coming home, never something to answer.
    private var ownPings: [UInt64] = []
    private let codec = WireCodec()
    private var isListenerRegistered = false
    private var pendingMatchmakingIntent: MatchmakingIntent?
    /// GameKit answers the sign-in handler when it is installed and when the
    /// app comes back to the foreground -- never because a pilot tapped. So
    /// the handler goes in once, and a second ask is judged on its answer.
    private var authHandlerInstalled = false
    private var authHandlerAnswered = false
    /// A sign-in sheet GameKit handed over with nothing on screen to show it
    /// from. Shown the next time the pilot asks, rather than dropped.
    private var pendingSignInSheet: UIViewController?
    private weak var presentedSignInSheet: UIViewController?
    private var signInWatchdog: Task<Void, Never>?
    private static let signInTimeoutSeconds = 15
    /// The bay's headline while an invite is out or being joined.
    private var matchmakingHeadlineText: String?
    /// Invitations out during the current seat hold, so they can be withdrawn.
    private var seatHoldCallback = SeatHoldCallback()
    /// A packet this recent means the pilot is still at the table.
    private static let recentlyHeardSeconds: TimeInterval = 2

    func authenticate() {
        let step = GameCenterSignIn.nextStep(
            isAuthenticated: GKLocalPlayer.local.isAuthenticated,
            hasSignInSheet: pendingSignInSheet != nil,
            handlerInstalled: authHandlerInstalled,
            handlerAnswered: authHandlerAnswered
        )
        switch step {
        case .proceed:
            signedIn()
        case .presentSheet:
            guard let sheet = pendingSignInSheet else { return }
            pendingSignInSheet = nil
            showSignIn(sheet)
        case .waitForAnswer:
            status = .authenticating
            startSignInWatchdog()
        case .sendToSettings:
            // Setting the handler again here is what used to hang QUICK MATCH
            // on SIGNING IN…: GameKit had already answered and never did again.
            note("AUTH: GAME CENTER ALREADY SAID NO · SEND TO SETTINGS")
            pendingMatchmakingIntent = nil
            status = .failed(reason: .gameCenterNotAuthenticated)
        case .installHandler:
            installAuthenticateHandler()
        }
    }

    private func installAuthenticateHandler() {
        authHandlerInstalled = true
        status = .authenticating
        startSignInWatchdog()
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
            Task { @MainActor in
                guard let self else { return }
                self.authHandlerAnswered = true
                self.signInWatchdog?.cancel()
                self.signInWatchdog = nil
                if let viewController {
                    self.showSignIn(viewController)
                } else if GKLocalPlayer.local.isAuthenticated {
                    self.signedIn()
                } else if let error {
                    let detail = self.describe(error)
                    self.note("AUTH FAILED: \(detail)")
                    self.pendingMatchmakingIntent = nil
                    self.status = .failed(reason: .fromGameCenterError(self.gameCenterKind(error)))
                } else {
                    self.note("AUTH: SIGNED OUT")
                    self.pendingMatchmakingIntent = nil
                    self.status = .signedOut
                }
            }
        }
    }

    private func showSignIn(_ sheet: UIViewController) {
        if present(sheet) {
            note("AUTH: SHOWING SIGN-IN")
            presentedSignInSheet = sheet
            status = .authenticating
            // If the pilot swipes the sheet away and GameKit stays quiet,
            // SIGNING IN… must still time out.
            startSignInWatchdog()
            return
        }
        // Nothing on screen to show it from yet. Keep it for the next tap.
        note("AUTH: SIGN-IN SHEET HELD · NOTHING TO PRESENT FROM")
        pendingSignInSheet = sheet
        if pendingMatchmakingIntent != nil {
            pendingMatchmakingIntent = nil
            status = .failed(reason: .gameCenterOther)
        } else {
            status = .signedOut
        }
    }

    /// GameKit can also simply never answer. SIGNING IN… gets a way past itself.
    private func startSignInWatchdog() {
        signInWatchdog?.cancel()
        signInWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.signInTimeoutSeconds))
            guard let self, !Task.isCancelled else { return }
            self.signInWatchdog = nil
            guard case .authenticating = self.status else { return }
            // Still typing an Apple ID password: give them another window.
            if self.presentedSignInSheet?.presentingViewController != nil {
                self.startSignInWatchdog()
                return
            }
            self.note("AUTH: NO ANSWER FROM GAME CENTER IN \(Self.signInTimeoutSeconds)s")
            self.pendingMatchmakingIntent = nil
            self.status = .failed(reason: .gameCenterSignInTimeout)
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
            status = .failed(reason: .multiplayerRestricted)
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
            case let .friendInvite(teamUp): presentMatchmaker(inviteOnly: true, teamUp: teamUp)
            case let .invite(players, teamUp): invite(players, teamUp: teamUp)
            }
        }
    }

    func presentQuickMatch() {
        presentMatchmaker(inviteOnly: false)
    }

    /// Apple's picker, kept as the fallback for pilots who are not in the
    /// in-app list. It is modal, so there is no warm-up bay behind it.
    func presentFriendInvite(teamUp: Bool = false) {
        presentMatchmaker(inviteOnly: true, teamUp: teamUp)
    }

    /// Automatch without the modal picker, so the pilot warms up in the bay
    /// while Game Center searches.
    func startQuickMatch() {
        startMatchmaking(recipients: nil, teamUp: false)
    }

    /// Sends Game Center invitations straight from the app and returns at
    /// once, so the pilot waits in the bay instead of in a modal sheet.
    /// A team-up seats them on the inviter's side instead of across the net.
    func invite(_ players: [GKPlayer], teamUp: Bool = false) {
        startMatchmaking(recipients: players, teamUp: teamUp)
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
            // GameKit hands these back on its own queue; they are only ever
            // read on the main actor from here on.
            nonisolated(unsafe) let recent = recent
            GKLocalPlayer.local.loadFriends { friends, friendsError in
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

    private func startMatchmaking(recipients: [GKPlayer]?, teamUp: Bool) {
        guard GKLocalPlayer.local.isAuthenticated else {
            pendingMatchmakingIntent = recipients.map { .invite($0, teamUp: teamUp) } ?? .quickMatch
            authenticate()
            return
        }
        let request = GKMatchRequest()
        // One seat per invited pilot, up to four on the court.
        let partySize = min(4, 1 + (recipients?.count ?? 1))
        request.minPlayers = 2
        request.maxPlayers = partySize
        request.defaultNumberOfPlayers = partySize
        request.inviteMessage = teamUp ? "Team up with me in ASTROSPIKE"
            : partySize > 2 ? "Doubles in ASTROSPIKE" : "Duel me in ASTROSPIKE"
        request.recipients = recipients
        self.teamUp = teamUp
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
                let notice = OnlineNoticeReason.inviteResponse(
                    pilotName: player.displayName,
                    kind: Self.inviteKind(response)
                )
                self.inviteNotice = notice.message
                guard response != .accepted else { return }
                let refusalReason = OnlineFailureReason.refusalReason(from: Self.inviteKind(response))
                // Game Center giving up on delivery is not the pilot saying no.
                // The invitation is still sitting on their phone, so hold the
                // door for the rest of the connect window instead of tearing
                // the search down and making them get asked all over again.
                guard refusalReason.isTerminal else {
                    self.note("INVITE STILL OPEN ON \(player.displayName)'S PHONE · HOLDING THE DOOR")
                    self.tryStartAsHost()
                    return
                }
                self.declinedInvites += 1
                // Everyone we asked said no, so there is nothing to wait for.
                // GameKit hands the inviter a match before anyone answers, so
                // "no match yet" was the wrong test: the refusal landed on a
                // match already being set and FINDING PILOT sat there until
                // the connect timeout.
                let awaitingTable = self.lifecycle.phase == .configuring
                    || (self.lifecycle.phase == .idle && self.status == .matching)
                if OnlineSeating.invitationsExhausted(
                    recipientCount: recipientCount,
                    declined: self.declinedInvites,
                    awaitingTable: awaitingTable,
                    connectedPeers: self.match?.players.count ?? 0
                ) {
                    self.note("EVERY INVITE REFUSED · CALLING IT")
                    self.matchmakingGeneration += 1
                    GKMatchmaker.shared().cancel()
                    self.status = .failed(reason: .allInvitesRefused(
                        lastPilotName: player.displayName,
                        lastReason: refusalReason
                    ))
                    self.leaveMatch(preservingStatus: true)
                } else {
                    self.tryStartAsHost()
                }
            }
        }
        inviteNotice = nil
        matchmakingHeadlineText = recipients.map {
            PlayerNetworkCopy.Matchmaking.waiting(for: $0.map(\.displayName))
        }
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
                    self.status = .failed(reason: .fromGameCenterError(self.gameCenterKind(error)))
                    return
                }
                guard let match else {
                    self.status = .failed(reason: .noMatchReturned)
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

    private func presentMatchmaker(inviteOnly: Bool, teamUp: Bool = false) {
        guard GKLocalPlayer.local.isAuthenticated else {
            pendingMatchmakingIntent = inviteOnly ? .friendInvite(teamUp: teamUp) : .quickMatch
            authenticate()
            return
        }
        let request = GKMatchRequest()
        request.minPlayers = 2
        // A team-up can bring up to three friends; a duel is one on one.
        request.maxPlayers = teamUp ? 4 : 2
        request.defaultNumberOfPlayers = 2
        request.inviteMessage = teamUp ? "Team up with me in ASTROSPIKE" : "Duel me in ASTROSPIKE"
        self.teamUp = teamUp
        request.recipientResponseHandler = { [weak self] player, response in
            Task { @MainActor in
                self?.note("INVITE → \(player.displayName): \(Self.describe(response))")
            }
        }
        guard let controller = GKMatchmakerViewController(matchRequest: request) else {
            note("MATCHMAKER: CONTROLLER UNAVAILABLE")
            status = .failed(reason: .matchmakerUnavailable)
            return
        }
        controller.matchmakerDelegate = self
        controller.canStartWithMinimumPlayers = false
        controller.matchmakingMode = inviteOnly ? .inviteOnly : .automatchOnly
        role = inviteOnly ? .inviter : .automatch
        declinedInvites = 0
        matchmakingGeneration += 1
        matchmakingHeadlineText = nil
        note(inviteOnly ? "MATCHMAKER: INVITE PICKER OPEN" : "MATCHMAKER: QUICK MATCH SEARCHING")
        status = .matching
        guard present(controller) else {
            note("MATCHMAKER: NOTHING TO PRESENT FROM")
            status = .failed(reason: .matchmakerUnavailable)
            return
        }
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

    private static func playerPhrase(_ response: GKInviteRecipientResponse) -> String {
        inviteKind(response).message
    }

    private static func inviteKind(_ response: GKInviteRecipientResponse) -> PlayerNetworkCopy.Invite {
        let kind: PlayerNetworkCopy.Invite = switch response {
        case .accepted: .accepted
        case .declined: .declined
        case .failed: .failed
        case .incompatible: .incompatible
        case .unableToConnect: .unableToConnect
        case .noAnswer: .noAnswer
        @unknown default: .other
        }
        return kind
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
        mismatchReason = nil
        remoteHulls = [:]
        inputBuffers = [:]
        heardSeats = []
        liveness.reset()
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
        let window = connectTimeoutSeconds
        note("WAITING UP TO \(window)s FOR THE TABLE TO FILL")
        doorSecondsRemaining = window
        handshakeTask = Task { @MainActor [weak self] in
            // A second at a time rather than one long sleep, so the bay can
            // show the door closing instead of a headline that sits still
            // for five minutes and reads as a hang.
            for left in stride(from: window - 1, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled,
                      self.match.map(ObjectIdentifier.init) == matchIdentifier,
                      self.lifecycle.phase == .configuring else { return }
                self.doorSecondsRemaining = left
                // Game Center's count of who is still coming can stick at one
                // with the pilot already connected. Past the grace window,
                // seat whoever is in the match rather than wait it out.
                if window - left >= Self.seatGraceSeconds { self.tryStartAsHost(graceElapsed: true) }
            }
            guard let self, !Task.isCancelled,
                  self.match.map(ObjectIdentifier.init) == matchIdentifier,
                  self.lifecycle.phase == .configuring else { return }
            self.doorSecondsRemaining = nil
            self.note("CONNECT TIMED OUT AFTER \(window)s: PILOT NEVER JOINED")
            self.status = .failed(reason: .connectTimeout)
            self.leaveMatch(preservingStatus: true)
        }
    }

    /// Once every seat that is going to fill has filled, the host seats the
    /// table and tells everyone. The inviter is the host; in a quick match
    /// both ends see the same player list, so the lowest Game Center player
    /// ID hosts with no negotiation and nothing that can come back nil.
    /// Guests do nothing here: their seat arrives in a `.seating` message.
    private func tryStartAsHost(graceElapsed: Bool = false) {
        guard let match, lifecycle.phase == .configuring else { return }
        // A decline can zero the expected count before the pilot who accepted
        // has actually connected. Seating the table then puts a bot in their
        // chair and leaves them knocking on a match that already started.
        guard OnlineSeating.shouldSeat(
            expected: match.expectedPlayerCount,
            declined: declinedInvites,
            connectedPeers: match.players.count,
            graceElapsed: graceElapsed
        ) else {
            if match.players.isEmpty { note("WAITING FOR A PILOT TO CONNECT BEFORE SEATING") }
            return
        }
        if graceElapsed, match.expectedPlayerCount > declinedInvites {
            note("STILL EXPECTING \(match.expectedPlayerCount) · SEATING WHO IS HERE")
        }
        let localID = GKLocalPlayer.local.gamePlayerID
        let peerIDs = match.players.map(\.gamePlayerID).sorted()
        guard OnlineSeating.localHosts(localID: localID, peerIDs: peerIDs, role: role) else {
            note("WAITING FOR HOST TO SEAT THE TABLE")
            return
        }
        seating = OnlineSeating.plan(localID: localID, peerIDs: peerIDs, teamUp: teamUp)
        hostID = localID
        hostTuning = preferredTuning
        isAuthoritative = true
        startConfiguredMatch()
    }

    private func startConfiguredMatch() {
        guard lifecycle.phase == .configuring,
              let seat = seating[GKLocalPlayer.local.gamePlayerID] else { return }
        handshakeTask?.cancel()
        doorSecondsRemaining = nil
        localSeat = seat
        if !resumingAfterDrop { seatingGeneration += 1 }
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
        let localID = GKLocalPlayer.local.gamePlayerID
        liveness.begin(peers: seating.keys.filter { $0 != localID }, at: Self.now)
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.match != nil else { return }
                self.sendPing()
                self.checkPeerLiveness()
            }
        }
    }

    /// Act on the silence detector's once-a-second verdict. The judgement is
    /// `PeerLivenessMonitor`'s; what is left here is the part that needs a
    /// match object -- the seat, the name on the HUD, the hold.
    private func checkPeerLiveness() {
        // Only once the table is actually playing. A pilot who seats and then
        // never answers belongs to the handshake timeout, which gives up in
        // twenty seconds rather than holding their chair for two minutes.
        guard isMatchReady, lifecycle.acceptsGameplayData, !seating.isEmpty else { return }
        let localID = GKLocalPlayer.local.gamePlayerID
        let peers = seating.keys.filter { $0 != localID }

        switch liveness.check(peers: peers, at: Self.now) {
        case .unchanged:
            return
        case .wentSilent(let gone):
            // Longest-silent first, so the pilot the forfeit is awarded
            // against is the same one on every board at the table.
            guard let dropped = gone.first else { return }
            let name = seatedPilotNames[dropped] ?? "PILOT"
            note("SILENT LINK: NOTHING FROM \(name) IN \(Int(Self.peerSilenceSeconds))s")
            for id in gone { readyPeers.remove(id) }
            droppedPilots.formUnion(gone)
            pendingForfeitWinner = seating[dropped]?.team.opponent
            beginReconnectWindow()
        case .resumed(let returned):
            guard case .reconnecting = status else { return }
            note("PACKETS RESUMED · SEAT RECLAIMED")
            readyPeers.formUnion(returned)
            _ = lifecycle.acceptConnection()
            completeReconnect()
        }
    }

    /// The peer only learns we are ready from a message, and a message sent
    /// before the peer has installed its match delegate is silently dropped by
    /// GameKit. Re-send the handshake every second until the peer's own `.ready`
    /// arrives, and fail visibly instead of sitting on FINDING PILOT forever.
    private func beginHandshake() {
        handshakeTask?.cancel()
        doorSecondsRemaining = nil
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
                    // A peer we could never decode did answer -- we just
                    // could not read it. Never blame them for silence.
                    if !self.mismatchedPeers.isEmpty {
                        self.note("HANDSHAKE TIMED OUT: PEER IS ON ANOTHER WIRE VERSION")
                        self.status = .failed(reason: self.mismatchReason ?? .handshakeTimeout)
                    } else {
                        self.note("HANDSHAKE TIMED OUT: PEER NEVER SENT READY")
                        self.status = .failed(reason: .handshakeTimeout)
                    }
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
            send(.seating(plan: seating, tuning: hostTuning, teamUp: teamUp), mode: .reliable)
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
            if mode == .unreliable { unreliableSendFailures = 0 }
        } catch {
            // An unreliable packet that would not go is what unreliable
            // means: the next input or snapshot covers it. One throw used to
            // end the whole match, which is how a single blip on a cellular
            // link read as "network send failed". Only a run of them -- or a
            // reliable send, which carries real state -- is a dead link.
            if mode == .unreliable {
                unreliableSendFailures += 1
                guard unreliableSendFailures >= Self.unreliableSendFailureLimit else { return }
            }
            // A held seat is already being handled by the reconnect clock;
            // a send that fails during the hold is expected, not fatal.
            if case .reconnecting = status {
                note("SEND DROPPED DURING HOLD: \(describe(error))")
                return
            }
            note("SEND FAILED: \(describe(error))")
            status = .failed(reason: .networkSendFailed)
        }
    }

    /// Consecutive unreliable sends that threw. Inputs go out sixty times a
    /// second, so this many in a row is half a second of a link that will
    /// take nothing, not a blip.
    private var unreliableSendFailures = 0
    private static let unreliableSendFailureLimit = 30

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
        liveness.heard(playerID, at: Self.now)
        let envelope: WireEnvelope
        do {
            envelope = try codec.decode(data)
        } catch WireProtocolError.unsupportedVersion(let version) {
            // A pilot on another TestFlight build. Every packet they send is
            // useless to us, so say so once instead of silently sitting still.
            if mismatchedPeers.insert(playerID).inserted {
                let name = seatedPilotNames[playerID] ?? "PILOT"
                note("WIRE MISMATCH: \(name) IS ON WIRE \(version), WE ARE \(WireEnvelope.currentVersion)")
                inviteNotice = Self.mismatchNotice(name)
                let reason = OnlineFailureReason.wireVersionMismatch(
                    remoteVersion: version,
                    localVersion: WireEnvelope.currentVersion,
                    pilotName: name
                )
                if mismatchReason == nil { mismatchReason = reason }
                // Sitting on this until the handshake times out ends in
                // "Pilot never answered", which is both wrong and useless:
                // they did answer, we cannot read it, and no amount of
                // waiting fixes a build. Say the real reason now, while the
                // host is still in the bay wondering why nothing connects.
                // A pilot mid-reconnect keeps their hold -- the forfeit
                // clock is already running and a terminal status here would
                // cut it short.
                if case .reconnecting = status {} else {
                    status = .failed(reason: reason)
                    leaveMatch(preservingStatus: true)
                }
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
        case let .seating(plan, tuning, teamUp):
            guard lifecycle.acceptsNetworkMessages, plan[GKLocalPlayer.local.gamePlayerID] != nil else { return }
            if lifecycle.phase == .configuring {
                seating = plan
                hostID = playerID
                hostTuning = tuning
                self.teamUp = teamUp
                isAuthoritative = false
                startConfiguredMatch()
            } else if !isAuthoritative {
                // A guest that took over hosting reseated the table: remember
                // who runs the rules now, so the next drop is judged right.
                // A reseat can also bench a pilot whose hold ran out.
                //
                // Only the host, or whoever steps up once the host has
                // dropped, may reseat a live table. A stale plan from a
                // pilot who is not running the rules would seat the guest
                // in a game nobody is hosting.
                let hostHasDropped = hostID.map { droppedPilots.contains($0) } ?? true
                guard playerID == hostID || hostHasDropped else {
                    note("IGNORED SEATING FROM \(playerID): NOT THE HOST")
                    return
                }
                if hostID != playerID {
                    // A new host's sequence numbers and ticks start from its
                    // own counters, and gates tuned to the old host would
                    // throw everything it sends away.
                    snapshotGate.reset()
                    eventGate.reset()
                }
                seating = plan
                hostID = playerID
                hostTuning = tuning
            } else if playerID < GKLocalPlayer.local.gamePlayerID {
                // Two boards both think they host -- both stepped up during
                // the same hold. The lower ID runs the rules, the same rule
                // that seated the table, so this end stands down.
                note("YIELDING HOST TO \(playerID)")
                isAuthoritative = false
                hostID = playerID
                seating = plan
                hostTuning = tuning
                snapshotGate.reset()
                eventGate.reset()
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
                    if let benched = OnlineSeating.seatingAfterHold(seating: self.seating, dropped: self.droppedPilots) {
                        self.benchDroppedPilots(keeping: benched)
                        return
                    }
                    self.note("SEAT HOLD EXPIRED · FORFEIT")
                    self.status = .failed(reason: .opponentForfeited)
                    self.isMatchReady = false
                    self.lifecycle.finish()
                    self.heartbeatTask?.cancel()
                    self.heartbeatTask = nil
                    if let winner = self.pendingForfeitWinner ?? self.localTeam { self.onForfeit?(winner) }
                    self.withdrawCallbacks()
                    self.disconnectTransport()
                    return
                }
                self.status = .reconnecting(seconds: remaining)
                if remaining == Self.seatHoldSeconds - Self.reinviteDelaySeconds {
                    self.callBackDroppedPilots(automatic: true)
                }
            }
        }
    }

    /// The hold ran out on a pilot whose teammate is still here. A bot takes
    /// their chair -- the host flies it -- and the match plays on. Every
    /// board runs its own hold clock, so each one reseats itself the same
    /// way; the host's reseat confirms it.
    private func benchDroppedPilots(keeping staying: [String: Seat]) {
        let names = droppedPilots.map { seatedPilotNames[$0] ?? "PILOT" }.joined(separator: ", ")
        note("SEAT HOLD EXPIRED · BOT TAKES \(names)'S CHAIR")
        seating = staying
        let localID = GKLocalPlayer.local.gamePlayerID
        let peers = staying.keys.filter { $0 != localID }
        readyPeers.formIntersection(peers)
        if let hostID, staying[hostID] == nil,
           peers.allSatisfy({ localID < $0 }) {
            // The host was the one benched: the lowest ID left runs the rules.
            isAuthoritative = true
            self.hostID = localID
        }
        if isAuthoritative, !peers.isEmpty {
            send(.seating(plan: seating, tuning: hostTuning, teamUp: teamUp), mode: .reliable)
        }
        completeReconnect()
    }

    /// The returning pilot has seated and said `.ready`: the hold is over.
    /// The host restarts the rally and resyncs everyone from its board.
    private func completeReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        droppedPilots = []
        handshakeTask?.cancel()
        handshakeTask = nil
        doorSecondsRemaining = nil
        withdrawCallbacks()
        // The `.ready` route closes a hold without a connection change, which
        // left the lifecycle in `.reconnecting`: the next drop then got no
        // hold at all, and any invite was taken for a rejoin.
        _ = lifecycle.acceptConnection()
        // Everyone seated has just proven they are here. Judging the returning
        // pilot by a packet from before the drop would call them silent at
        // once, open a second hold, and send a second call-back.
        let localID = GKLocalPlayer.local.gamePlayerID
        liveness.begin(peers: seating.keys.filter { $0 != localID }, at: Self.now)
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

    /// The arena's RE-INVITE PILOT button: asks again every time it is pressed.
    func reinviteDroppedPilots() {
        callBackDroppedPilots(automatic: false)
    }

    /// Ask Game Center to invite whoever dropped back into this same match.
    /// The automatic call-back goes to each pilot once per hold; every
    /// invite sent is remembered so it can be withdrawn when the hold ends.
    private func callBackDroppedPilots(automatic: Bool) {
        guard let match, case .reconnecting = status else { return }
        let gone = SeatHoldCallback.missing(
            seated: seating.keys,
            localID: GKLocalPlayer.local.gamePlayerID,
            inMatch: Set(match.players.map(\.gamePlayerID)),
            ready: readyPeers,
            heardRecently: liveness.heard(within: Self.recentlyHeardSeconds, at: Self.now)
        )
        let ids = automatic ? seatHoldCallback.automatic(gone) : seatHoldCallback.manual(gone)
        let missing = ids.compactMap { knownPlayers[$0] }
        guard !missing.isEmpty else {
            note(gone.isEmpty ? "NOBODY TO RE-INVITE" : "CALL-BACK ALREADY OUT")
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

    /// The hold is over, whichever way. A call-back still out is withdrawn, or
    /// the pilot keeps getting invites to a match they are already back in.
    private func withdrawCallbacks() {
        let outstanding = seatHoldCallback.close().compactMap { knownPlayers[$0] }
        guard !outstanding.isEmpty else { return }
        for player in outstanding { GKMatchmaker.shared().cancelPendingInvite(to: player) }
        note("CALL-BACK WITHDRAWN: \(outstanding.map(\.displayName).joined(separator: ", "))")
    }

    /// False when there is nothing on screen to present from, so the caller
    /// can say so instead of leaving the pilot on a spinner.
    private func present(_ controller: UIViewController) -> Bool {
        guard let presenter = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController else { return false }
        var top = presenter
        while let presented = top.presentedViewController { top = presented }
        top.present(controller, animated: true)
        return true
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
        status = .failed(reason: .fromGameCenterError(gameCenterKind(error)))
    }

    func matchmakerViewController(_ viewController: GKMatchmakerViewController, didFind match: GKMatch) {
        let names = match.players.map(\.displayName).joined(separator: ", ")
        note("MATCH FOUND: [\(names)] · EXPECTING \(match.expectedPlayerCount) MORE")
        viewController.dismiss(animated: true)
        configure(match)
    }

    nonisolated func match(_ match: GKMatch, didReceive data: Data, fromRemotePlayer player: GKPlayer) {
        let playerID = player.gamePlayerID
        let matchID = ObjectIdentifier(match)
        Task { @MainActor [weak self] in
            guard let self, self.match.map(ObjectIdentifier.init) == matchID else { return }
            self.receive(data, from: playerID)
        }
    }

    nonisolated func match(_ match: GKMatch, player: GKPlayer, didChange state: GKPlayerConnectionState) {
        let displayName = player.displayName
        let playerID = player.gamePlayerID
        nonisolated(unsafe) let safePlayer = player
        let matchID = ObjectIdentifier(match)
        Task { @MainActor [weak self] in
            guard let self, self.match.map(ObjectIdentifier.init) == matchID else { return }
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
                // A connection is a pilot who is here: the silence clock must
                // not call them gone again before their first packet lands.
                liveness.heard(playerID, at: Self.now)
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
            droppedPilots.insert(playerID)
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
                snapshotGate.reset()
                eventGate.reset()
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
        guard let seat = OnlineSeating.order(teamUp: teamUp).first(where: { !filledSeats.contains($0) }) else {
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
        let diagnostic = error.map { describe($0) }
        let reason: OnlineFailureReason = error.map { .fromGameCenterError(gameCenterKind($0)) }
            ?? .matchFailed(underlyingMessage: nil)
        let matchID = ObjectIdentifier(match)
        Task { @MainActor [weak self] in
            guard let self, self.match.map(ObjectIdentifier.init) == matchID else { return }
            let detail = diagnostic ?? "The match ended"
            self.note("MATCH FAILED: \(detail)")
            // A log line was the whole of it, which is how a pilot got dropped
            // with the arena still up and nothing on screen to say so.
            guard self.lifecycle.acceptsNetworkMessages else { return }
            self.status = .failed(reason: reason)
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
        // The headline, not a footnote: an invitee sat in the bay under
        // FINDING PILOT with no word that they were on their way in.
        inviteNotice = nil
        matchmakingHeadlineText = rejoining
            ? PlayerNetworkCopy.Matchmaking.rejoining(senderDisplayName)
            : PlayerNetworkCopy.Matchmaking.joining(senderDisplayName)
        status = .matching
        GKMatchmaker.shared().match(for: invite) { [weak self] match, error in
            nonisolated(unsafe) let match = match
            Task { @MainActor in
                guard let self, generation == self.matchmakingGeneration,
                      case .matching = self.status else { return }
                if let error {
                    let detail = self.describe(error)
                    self.note("INVITE JOIN FAILED: \(detail)")
                    let reason: OnlineFailureReason = .inviteJoinFailed(
                        underlyingMessage: self.playerFacingGameCenter(error)
                    )
                    self.status = .failed(reason: reason)
                    return
                }
                guard let match else {
                    self.status = .failed(reason: .couldNotOpenInvitation)
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
        withdrawCallbacks()
        disconnectTransport()
        reconnectTask?.cancel()
        reconnectTask = nil
        finishTask?.cancel()
        finishTask = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        doorSecondsRemaining = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        session = nil
        lifecycle.reset()
        snapshotGate.reset()
        eventGate.reset()
        inputBuffers = [:]
        heardSeats = []
        liveness.reset()
        mismatchedPeers = []
        mismatchReason = nil
        remoteHulls = [:]
        isMatchReady = false
        isAuthoritative = false
        localSeat = nil
        seating = [:]
        readyPeers = []
        role = .automatch
        declinedInvites = 0
        pendingForfeitWinner = nil
        droppedPilots = []
        teamUp = false
        pingMilliseconds = nil
        pendingPing = nil
        ownPings = []
        lastAuthoritativeState = nil
        pendingResync = nil
        hostID = nil
        hostTuning = .defaults
        knownPlayers = [:]
        resumingAfterDrop = false
        matchmakingHeadlineText = nil
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
        withdrawCallbacks()
        isMatchReady = false
        reconnectTask?.cancel()
        reconnectTask = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        doorSecondsRemaining = nil
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
