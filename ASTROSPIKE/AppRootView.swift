import ASTROSPIKECore
import SpriteKit
import SwiftUI

struct AppRootView: View {
    @State private var online = OnlineMatchCoordinator()
    @State private var lobby = LobbyService()
    @State private var tuning = FlightTuningStore()
    @State private var trackTuning = TrackTuningStore()
    @State private var profile = PilotProfileStore()
    /// Drawn once and kept: the pace ship should not change hulls every time
    /// the pilot restarts a race.
    @State private var rivalHull = PilotProfileStore().rivalHull()
    @State private var entitlements: HullEntitlements
    /// StoreKit for the premium hulls. Built here so it shares the one
    /// `HullEntitlements` the hangar reads; its listener starts in `.task`.
    @State private var store: HullStore
    @State private var gameMode: GameMode?
    @State private var sheet: MenuSheet?
    /// The track runs on its own engine and its own scene -- no ball, no
    /// teams, no rulebook -- so it sits beside `gameMode` rather than in it.
    @State private var showTrack: Bool
    @State private var showOnboarding: Bool
    /// Consumed by the first GameView; cleared on appear so Challenge does not
    /// inherit `--results-win` / `--results-lose`.
    @State private var resultsPreviewWinner: Team?
    @Environment(\.scenePhase) private var scenePhase
    private let diagnosticsPreview: OnlineDiagnosticsSnapshot?

    init() {
        let entitlements = HullEntitlements()
        _entitlements = State(initialValue: entitlements)
        _store = State(initialValue: HullStore(entitlements: entitlements))
        let arguments = ProcessInfo.processInfo.arguments
        let demoMode = arguments.contains("--demo")
        let diagnosticsPreviewMode = arguments.contains("--online-diagnostics-preview")
        let resultsPreview = arguments.contains("--results-win") || arguments.contains("--results-lose")
        diagnosticsPreview = diagnosticsPreviewMode ? OnlineDiagnosticsSnapshot(
            playerName: "GC TEST PILOT",
            localTeam: .cyan,
            authority: .host,
            pingMilliseconds: 42,
            linkState: .reconnecting,
            matchmakingState: .ready,
            reconnectSeconds: 7,
            eventLog: ["10:46:01 SIGNED IN: GC TEST PILOT", "10:46:09 INVITE → WINGMAN: NO ANSWER"]
        ) : nil
        // `--warmup` opens the bay directly, for screenshots and simulator checks
        // where Game Center cannot put an invite out.
        // `--arrange-pads` turns the drag layer on through the same default the
        // Settings toggle writes, so a test can turn it back off again.
        // `-arrangePads YES` lands in the argument domain instead, which
        // nothing at runtime is allowed to overwrite.
        if arguments.contains("--arrange-pads") {
            UserDefaults.standard.set(true, forKey: "arrangePads")
        }
        let warmupMode = arguments.contains("--warmup")
        _resultsPreviewWinner = State(
            initialValue: arguments.contains("--results-win") ? .cyan
                : arguments.contains("--results-lose") ? .orange
                : nil
        )
        _gameMode = State(initialValue: diagnosticsPreviewMode ? .online
            : warmupMode ? .warmup
            : resultsPreview ? .solo(.rookie)
            : demoMode ? .solo(.pilot) : nil)
        // Automation and UI tests land on the home screen; a fresh install lands
        // on the intro.
        let lobbyMode = arguments.contains("--lobby")
        // `--track` drops straight onto the circuit, for the same reason
        // `--warmup` drops into the bay: the simulator cannot work a sheet.
        let trackMode = arguments.contains("--track")
        _showTrack = State(initialValue: trackMode)
        let bypass = demoMode || warmupMode || diagnosticsPreviewMode || lobbyMode || trackMode
            || resultsPreview
            || arguments.contains("--skip-onboarding")
        _showOnboarding = State(initialValue: !bypass && !PilotProfileStore().hasCompletedOnboarding)
        // `--lobby` opens the board straight away; the simulator cannot tap it.
        _sheet = State(initialValue: lobbyMode ? .lobby : nil)
    }

    var body: some View {
        ZStack {
            CosmicBackground()
            if showTrack {
                TrackView(
                    flight: tuning.snapshot,
                    tuning: trackTuning,
                    // The circuit flies the hull the pilot picked in the
                    // hangar, against the same pace hull a solo match faces.
                    hulls: [.player: profile.selectedHull, .rival: rivalHull]
                ) {
                    withAnimation(.easeOut(duration: 0.25)) { showTrack = false }
                }
                    .transition(.opacity)
            } else if let gameMode {
                GameView(
                    mode: gameMode,
                    online: online,
                    lobby: lobby,
                    tuning: tuning,
                    profile: profile,
                    diagnosticsOverride: diagnosticsPreview,
                    previewWinner: resultsPreviewWinner,
                    continueWith: { mode in
                        withAnimation(.easeOut(duration: 0.25)) { self.gameMode = mode }
                    }
                ) {
                    self.gameMode = nil
                }
                .id(gameMode)
                .onAppear { resultsPreviewWinner = nil }
                .transition(.opacity.combined(with: .scale(scale: 1.03)))
            } else if showOnboarding {
                OnboardingFlow(profile: profile, entitlements: entitlements, store: store) { launch in
                    withAnimation(.easeOut(duration: 0.25)) {
                        showOnboarding = false
                        if launch { gameMode = .solo(.rookie) }
                    }
                }
                .transition(.opacity)
            } else {
                HomeView(online: online, profile: profile, sheet: $sheet) { mode in
                    withAnimation(.easeOut(duration: 0.25)) { gameMode = mode }
                }
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            online.localHull = profile.selectedHull
            online.preferredTuning = tuning.snapshot
            lobby.localHull = profile.selectedHull
            if diagnosticsPreview == nil {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--joining-preview") {
                    online.previewMatchmaking(headline: PlayerNetworkCopy.Matchmaking.joining("Ian"))
                    return
                }
                #endif
                online.authenticate()
            }
        }
        .task {
            // Runs for the app's lifetime: the listener has to be up before
            // the hangar opens, or an Ask to Buy approval or a purchase made
            // on another device lands with nobody home.
            await store.start()
            // A refund can revoke the hull the pilot is flying. Put them back
            // in something they own rather than launching a locked ship.
            if !entitlements.isUnlocked(profile.selectedHull) {
                profile.selectedHull = .lancet
            }
        }
        .onChange(of: tuning.snapshot) { _, snapshot in online.preferredTuning = snapshot }
        .onChange(of: profile.selectedHull) { _, hull in
            online.localHull = hull
            lobby.localHull = hull
        }
        .onChange(of: online.isMatchReady) { _, ready in
            if ready {
                // The invitee is usually sitting in the lobby or the invite
                // sheet when the match comes up. Drop it, or the arena runs
                // hidden underneath and their ship sits idle on the host's board.
                sheet = nil
                withAnimation { gameMode = .online }
                if online.isAuthoritative { announceHostedDuel() }
            }
        }
        .onChange(of: online.status) { _, status in
            // Signed in: this pilot can show up in the lobby.
            if case .ready = status { lobby.start() }
            syncLobbyActivity()
            // An invite or a search is out: fly in the bay instead of staring
            // at a status label.
            if case .matching = status, gameMode == nil, !showOnboarding {
                sheet = nil
                withAnimation(.easeOut(duration: 0.25)) { gameMode = .warmup }
            }
        }
        .onChange(of: gameMode) { _, _ in syncLobbyActivity() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: lobby.start()
            case .background: lobby.stop()
            default: break
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .difficulty:
                DifficultyPicker { difficulty in
                    sheet = nil
                    gameMode = .solo(difficulty)
                }
                .presentationDetents([.medium])
            case .tutorial:
                FlightTutorial()
            case .settings:
                SettingsView(tuning: tuning, trackTuning: trackTuning, replayIntro: {
                    sheet = nil
                    showOnboarding = true
                }).presentationDetents([.large])
            case .hangar:
                HangarSheet(profile: profile, entitlements: entitlements, store: store)
            case .lobby:
                LobbyView(lobby: lobby, online: online)
                    .presentationDetents([.large])
            case .modes:
                ModePicker { mode in
                    sheet = nil
                    withAnimation(.easeOut(duration: 0.25)) { gameMode = mode }
                } startTrack: {
                    sheet = nil
                    withAnimation(.easeOut(duration: 0.25)) { showTrack = true }
                }
                .presentationDetents([.large])
            case .invite:
                InviteSheet(online: online) {
                    sheet = nil
                    // Let the sheet finish dismissing before Game Center's own
                    // picker takes the top of the stack.
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        online.presentFriendInvite()
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    /// What this pilot is doing, as the lobby should show it.
    private func syncLobbyActivity() {
        let activity: PilotActivity = switch gameMode {
        case .online: .playing
        case .warmup: .matching
        case .solo, .doubles, .volleyball, .basketball: .solo
        case nil: if case .matching = online.status { .matching } else { .idle }
        }
        lobby.setActivity(activity, matchID: activity == .playing ? lobby.hostedDuel?.id : nil)
    }

    /// The host puts the duel on the lobby's board as soon as the table is
    /// seated. Doubles is recorded as its two leads.
    private func announceHostedDuel() {
        let names = online.seatedPilotNames
        guard let cyanID = online.seating.first(where: { $0.value == .cyan })?.key,
              let orangeID = online.seating.first(where: { $0.value == .orange })?.key else { return }
        Task {
            await lobby.hostDuelStarted(
                cyanID: cyanID, cyanName: names[cyanID] ?? "?",
                orangeID: orangeID, orangeName: names[orangeID] ?? "?"
            )
        }
    }
}

private enum MenuSheet: String, Identifiable {
    case difficulty, tutorial, settings, hangar, invite, lobby, modes
    var id: String { rawValue }
}

private struct InviteSheet: View {
    let online: OnlineMatchCoordinator
    let openPicker: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Pick a pilot. You fly in the warm-up bay while they answer.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("RECENT PILOTS AND FRIENDS") {
                    if online.invitees.isEmpty {
                        if online.isLoadingInvitees {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Nobody yet. Use the Game Center picker below.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(online.invitees, id: \.gamePlayerID) { player in
                        Button { online.invite([player]) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.cyan)
                                Text(player.displayName).font(.headline)
                                Spacer()
                                Image(systemName: "paperplane.fill").foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Invite \(player.displayName)")
                    }
                }
                Section {
                    Button(action: openPicker) {
                        Label("Game Center picker", systemImage: "person.2.wave.2.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("invite-picker-fallback")
                } footer: {
                    Text("Apple's picker reaches anyone, but it is a modal sheet: no bay while you wait.")
                }
            }
            .navigationTitle("INVITE A PILOT")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { online.loadInvitees() }
        .accessibilityIdentifier("invite-screen")
    }
}

private struct HomeView: View {
    let online: OnlineMatchCoordinator
    let profile: PilotProfileStore
    @Binding var sheet: MenuSheet?
    let startGame: (GameMode) -> Void

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: min(52, geometry.size.width * 0.055)) {
                VStack(alignment: .leading, spacing: 10) {
                    (Text("ASTRO").foregroundStyle(.cyan) + Text("SPIKE").foregroundStyle(.orange))
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                        .allowsTightening(true)
                    Text("ZERO-G. ONE NET. NO BRAKES.")
                        .font(.caption.weight(.bold)).tracking(2.4)
                        .foregroundStyle(.white.opacity(0.62))
                    Spacer().frame(height: 14)
                    TeamMarkRow()
                    Spacer()
                    Button { sheet = .hangar } label: {
                        HStack(spacing: 12) {
                            HullBadge(hull: profile.selectedHull, team: .cyan).frame(width: 48, height: 52)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("YOUR HULL").font(.caption2.monospaced().weight(.bold)).tracking(2)
                                    .foregroundStyle(.white.opacity(0.5))
                                Text(profile.selectedHull.spec.name.uppercased())
                                    .font(.headline.weight(.black)).tracking(1).foregroundStyle(.cyan)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Your hull: \(profile.selectedHull.spec.name). Open hangar")
                    .accessibilityIdentifier("home-hull")
                    Spacer().frame(height: 10)
                    Label(online.statusLabel, systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(statusColor).lineLimit(1)
                }
                .font(.system(size: min(58, geometry.size.height * 0.13), weight: .black, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 12) {
                    MenuButton(title: "SOLO FLIGHT", subtitle: "ROOKIE • PILOT • ACE", icon: "person.fill") { sheet = .difficulty }
                    MenuButton(title: "QUICK MATCH", subtitle: "AUTOMATIC ONLINE DUEL", icon: "bolt.horizontal.circle.fill") { online.startQuickMatch() }
                    MenuButton(title: "LOBBY", subtitle: "WHO'S ONLINE • LIVE DUELS • BRACKETS", icon: "person.3.fill") { sheet = .lobby }
                    // Volleyball, basketball and the circuit are parked (Ian may spin them into
                    // their own game); `sheet = .modes` still opens them if ever wanted back.
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                        SmallMenuButton(title: "INVITE", icon: "person.2.wave.2.fill") { sheet = .invite }
                        SmallMenuButton(title: "HANGAR", icon: "airplane.circle") { sheet = .hangar }
                        SmallMenuButton(title: "HOW TO FLY", icon: "questionmark.circle") { sheet = .tutorial }
                        SmallMenuButton(title: "SETTINGS", icon: "slider.horizontal.3") { sheet = .settings }
                    }
                }
                .frame(maxWidth: 430)
            }
            .padding(.horizontal, max(36, geometry.size.width * 0.07))
            .padding(.vertical, max(24, geometry.size.height * 0.08))
        }
        .accessibilityIdentifier("home-screen")
    }

    private var statusColor: Color {
        switch online.status {
        case .connected, .ready: .green
        case .failed: .orange
        case .authenticating, .matching, .reconnecting: .yellow
        case .signedOut: .white.opacity(0.6)
        }
    }
}

private struct GameView: View {
    let mode: GameMode
    let online: OnlineMatchCoordinator
    let lobby: LobbyService
    let tuning: FlightTuningStore
    let profile: PilotProfileStore
    let diagnosticsOverride: OnlineDiagnosticsSnapshot?
    let previewWinner: Team?
    let continueWith: (GameMode) -> Void
    let exit: () -> Void

    @State private var session: GameSession
    @State private var showPause = false
    @State private var showLeaveConfirmation = false
    /// Why the link ended, when it ended for a reason the seat hold does not
    /// cover. Non-nil puts a card over the arena instead of leaving the pilot
    /// flying a match that is already over.
    @State private var linkFailure: String?
    @AppStorage("largeControls") private var largeControls = false
    @AppStorage("leftHanded") private var leftHanded = false
    @AppStorage("haptics") private var haptics = true
    @Environment(\.scenePhase) private var scenePhase

    init(
        mode: GameMode,
        online: OnlineMatchCoordinator,
        lobby: LobbyService,
        tuning: FlightTuningStore,
        profile: PilotProfileStore,
        diagnosticsOverride: OnlineDiagnosticsSnapshot? = nil,
        previewWinner: Team? = nil,
        continueWith: @escaping (GameMode) -> Void,
        exit: @escaping () -> Void
    ) {
        self.mode = mode
        self.online = online
        self.lobby = lobby
        self.tuning = tuning
        self.profile = profile
        self.diagnosticsOverride = diagnosticsOverride
        self.previewWinner = previewWinner
        self.continueWith = continueWith
        self.exit = exit
        let configuration = switch mode {
        case .solo, .doubles: tuning.configuration
        case .volleyball: SimulationConfiguration.volleyball(from: tuning.configuration)
        case .basketball: SimulationConfiguration.basketball(from: tuning.configuration)
        // The host's sliders reach the guest with the seating plan; the host
        // seeded them from its own store, so both read the same numbers.
        case .online: online.hostTuning.configuration
        case .warmup: SimulationConfiguration.warmup(from: tuning.configuration)
        }
        _session = State(initialValue: GameSession(
            mode: mode,
            online: online,
            lobby: lobby,
            configuration: configuration,
            setsToWin: tuning.setsToWin,
            localHull: profile.selectedHull,
            rivalHull: profile.rivalHull(),
            finishedAs: previewWinner
        ))
    }

    /// Live matches keep the engineer HUD in Debug. Release only shows it
    /// when `--online-diagnostics-preview` supplies a snapshot.
    private var showsConnectionDiagnostics: Bool {
        if diagnosticsOverride != nil { return true }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
        ZStack {
            SpriteView(scene: session.scene, options: [.ignoresSiblingOrder])
                .ignoresSafeArea().accessibilityHidden(true)
            VStack(spacing: 0) {
                if mode == .warmup {
                    WarmupHUD(session: session, online: online) { showLeaveConfirmation = true }
                } else {
                    MatchHUD(
                        state: session.state,
                        localTeam: localTeam,
                        allowedBounces: allowedBounces,
                        allowedTouches: allowedTouches,
                        online: mode == .online ? online : nil,
                        actionLabel: mode == .online ? "Leave online match" : "Pause match",
                        actionIcon: mode == .online ? "xmark" : "slider.horizontal.3"
                    ) {
                        if mode == .online {
                            showLeaveConfirmation = true
                        } else {
                            if !session.isPaused { session.togglePause() }
                            showPause = true
                        }
                    }
                }
                if mode == .online, showsConnectionDiagnostics {
                    GameCenterDiagnosticsPanel(
                        diagnostics: diagnosticsOverride ?? online.diagnosticsSnapshot
                    )
                    .padding(.top, 4)
                }
                if mode == .online, case .reconnecting = online.status {
                    Button {
                        online.reinviteDroppedPilots()
                    } label: {
                        Label("RE-INVITE PILOT", systemImage: "arrow.uturn.backward.circle.fill")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.yellow)
                    .padding(.top, 6)
                    .accessibilityIdentifier("reinvite-button")
                }
                if mode != .warmup {
                    let left = session.state.team(onHalfAt: -1)
                    let right = left.opponent
                    HStack {
                        TeamSideBadge(
                            title: left == localTeam ? "YOU" : (mode == .online ? "OPPONENT" : "CPU"),
                            team: left,
                            isLocal: left == localTeam
                        )
                        Spacer()
                        TeamSideBadge(
                            title: right == localTeam ? "YOU" : (mode == .online ? "OPPONENT" : "CPU"),
                            team: right,
                            isLocal: right == localTeam
                        )
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 4)
                }
                TouchControls(torque: $session.torque, thrust: $session.thrust, fire: $session.fire,
                              tractor: $session.tractor,
                              largeControls: largeControls, leftHanded: leftHanded,
                              arenaFrame: Self.arenaFrame(in: geometry),
                              windowFrame: TouchControls.windowFrame(in: geometry),
                              playerTint: localTeam == .cyan ? .cyan : .orange)
            }
            // Takes no space and never hit-tests, so a hardware keyboard flies
            // the ship without displacing the thumb controls.
            KeyboardControls(
                torque: $session.torque,
                thrust: $session.thrust,
                fire: $session.fire,
                tractor: $session.tractor,
                onCommand: keyCommandHandler
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            if session.state.match.phase == .countdown { CountdownView(value: session.countdown) }
            if let seconds = session.setBreakCountdown {
                CountdownView(value: seconds, title: session.lastPointText, caption: "SWITCH SIDES")
            } else if session.state.match.phase == .serve {
                VStack(spacing: 8) {
                    if let text = session.lastPointText {
                        Text(text)
                            .font(.system(size: 26, weight: .black, design: .rounded)).tracking(2)
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(.black.opacity(0.66), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.35)))
                    }
                    let servingSide = session.state.team(onHalfAt: session.state.serveDriftSign)
                    let isLocalServe = servingSide == localTeam
                    let serveColor = servingSide == .cyan ? Color.cyan : Color.orange
                    HStack(spacing: 6) {
                        Image(systemName: "tennisball.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text(isLocalServe ? "YOUR SERVE" : (mode == .online ? "OPPONENT SERVE" : "CPU SERVE"))
                            .font(.system(size: 13, weight: .black, design: .monospaced))
                            .tracking(1.4)
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(serveColor, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.4), lineWidth: 1))
                    .accessibilityIdentifier("serve-banner")
                }
            }
            if let linkFailure, session.state.match.phase != .finished {
                LinkLostOverlay(message: linkFailure, exit: leaveGame)
            }
            if session.state.match.phase == .finished {
                ResultsOverlay(
                    state: session.state,
                    localTeam: localTeam,
                    plan: resultsPlan,
                    playAgain: playAgain,
                    challenge: challengeNext,
                    exit: leaveGame
                )
            }
            if showPause {
                CourtPauseOverlay(
                    tuning: tuning,
                    restartDrop: { session.restartRally(with: tuning.configuration) },
                    resume: {
                        showPause = false
                        session.resume()
                    },
                    quit: {
                        showPause = false
                        leaveGame()
                    }
                )
            }
        }
        .accessibilityIdentifier("game-screen")
        .confirmationDialog(
            mode == .warmup ? "Leave the Bay?" : "Leave Match?",
            isPresented: $showLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button(mode == .warmup ? "Cancel Invite" : "Leave Match", role: .destructive, action: leaveGame)
            Button(mode == .warmup ? "Keep Warming Up" : "Keep Playing", role: .cancel) {}
        } message: {
            Text(mode == .warmup
                ? "Leaving withdraws the invite or search."
                : "Leaving disconnects you from the current Game Center match.")
        }
        .onAppear { FeedbackCenter.shared.hapticsEnabled = haptics; session.start() }
        .onDisappear {
            session.stop()
            if mode == .online { online.leaveMatch() }
        }
        .onChange(of: online.status) { _, status in
            if mode == .warmup, case .ready = status { exit() }
            guard mode == .online else { return }
            if case let .failed(reason) = status {
                linkFailure = reason.message
            } else if case .connected = status {
                linkFailure = nil
            } else if case .reconnecting = status {
                linkFailure = nil
            }
        }
        .onChange(of: tuning.snapshot) { _, _ in
            session.applyTuning(tuning.configuration)
        }
        .onChange(of: online.remoteHulls) { _, hulls in
            if mode == .online {
                for (seat, hull) in hulls {
                    session.scene.setHull(hull, for: seat)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            session.setApplicationActive(phase == .active)
        }
        }
    }

    /// Where the court sits on screen, in global coordinates. The scene
    /// fills the whole window (it ignores the safe area), so its size is
    /// this safe-area frame grown back out by the insets.
    private static func arenaFrame(in geometry: GeometryProxy) -> CGRect {
        let safe = geometry.frame(in: .global)
        let insets = geometry.safeAreaInsets
        let window = CGRect(
            x: safe.minX - insets.leading, y: safe.minY - insets.top,
            width: safe.width + insets.leading + insets.trailing,
            height: safe.height + insets.top + insets.bottom
        )
        let centred = ArenaScene.arenaRect(in: window.size)
        return centred.offsetBy(dx: window.midX, dy: window.midY)
    }

    private var localTeam: Team { online.localTeam ?? .cyan }

    private var allowedBounces: Int {
        switch mode {
        case .solo, .doubles: tuning.allowedBouncesPerHit
        // Volleyball's floor is live and the hoop court has no faults at all;
        // both come off `SimulationConfiguration`, not the pilot's sliders.
        case .volleyball: 0
        case .basketball, .online, .warmup: 3
        }
    }

    private var allowedTouches: Int {
        switch mode {
        case .solo, .doubles: tuning.allowedTouchesPerSide
        case .volleyball, .basketball, .online, .warmup: 3
        }
    }

    private var localHomeSide: Team {
        session.state.ships[team: localTeam]?.homeSide ?? localTeam
    }

    /// Nil while a sheet owns the screen, so Escape closes the sheet instead of
    /// re-triggering the thing that opened it.
    private var keyCommandHandler: ((FlightControlCommand) -> Void)? {
        if showPause || showLeaveConfirmation { return nil }
        return handleKeyCommand
    }

    /// Keyboard equivalents for the two buttons a pilot actually needs mid-match.
    private func handleKeyCommand(_ command: FlightControlCommand) {
        switch command {
        case .pause:
            if mode.isOffline {
                session.togglePause()
                showPause = true
            } else {
                showLeaveConfirmation = true
            }
        case .confirm:
            // Primary action on the results card: stay in the loop when we can.
            if session.state.match.phase == .finished {
                if resultsPlan.canPlayAgain {
                    playAgain()
                } else {
                    leaveGame()
                }
            }
        }
    }

    private func leaveGame() {
        switch mode {
        case .online:
            lobby.hostDuelAbandoned()
            online.leaveMatch()
        case .warmup: online.cancelMatchmaking()
        case .solo, .doubles, .volleyball, .basketball: break
        }
        exit()
    }

    private var resultsPlan: ResultsPlan {
        ResultsPlan(
            offline: mode.isOffline,
            localWon: didLocalPlayerWin,
            rival: mode.rivalDifficulty
        )
    }

    private var didLocalPlayerWin: Bool {
        if let winner = session.state.match.winner { return winner == localTeam }
        return session.state.match.score[localTeam] > session.state.match.score[localTeam.opponent]
    }

    private func playAgain() {
        session.restartMatch()
    }

    private func challengeNext() {
        guard let next = resultsPlan.nextRival else { return }
        continueWith(mode.withRival(next))
    }
}

/// The bay's scoreboard: a keep-up streak, hoops popped, goals scored, and
/// the state of the invite in the middle where the match rules would be.
private struct WarmupHUD: View {
    let session: GameSession
    let online: OnlineMatchCoordinator
    let leave: () -> Void

    var body: some View {
        HStack {
            stat(title: "KEEP-UP", value: session.state.match.shipTouches.cyan,
                 detail: "BEST \(session.bestKeepUp)", tint: .cyan)
            Spacer()
            VStack(spacing: 3) {
                Text("WARM-UP BAY").font(.caption2.monospaced().weight(.bold)).tracking(2)
                    .foregroundStyle(.white.opacity(0.55))
                if let headline = online.matchmakingHeadline {
                    // Who they are waiting on, big enough to read mid-hoop.
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(.yellow)
                        Text(headline).font(.subheadline.monospaced().weight(.black)).tracking(1)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
                    .overlay(Capsule().stroke(.yellow.opacity(0.75), lineWidth: 1.5))
                    .accessibilityIdentifier("matchmaking-headline")
                } else {
                    Label(online.status.label, systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2.weight(.bold)).foregroundStyle(statusColor).lineLimit(1)
                }
                if let notice = online.inviteNotice {
                    Text(notice).font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(.yellow.opacity(0.9)).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            stat(title: "HOOPS", value: session.ringsPopped,
                 detail: "GOALS \(session.state.match.score.cyan)", tint: .yellow)
            Button(action: leave) {
                Image(systemName: "xmark").frame(width: 42, height: 42).background(.black.opacity(0.45), in: Circle())
            }
            .accessibilityLabel("Leave warm-up bay").accessibilityIdentifier("match-action-button")
        }
        .padding(.horizontal, 24).padding(.top, 10)
        .accessibilityIdentifier("warmup-hud")
    }

    private func stat(title: String, value: Int, detail: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Text(value.formatted()).font(.system(size: 36, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2.monospaced().weight(.bold)).tracking(1.5)
                Text(detail).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.55))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch online.status {
        case .connected, .ready: .green
        case .matching, .authenticating, .reconnecting: .yellow
        case .failed: .orange
        case .signedOut: .white.opacity(0.6)
        }
    }
}

private struct TeamSideBadge: View {
    let title: String
    let team: Team
    var isLocal: Bool = false

    var body: some View {
        let color = team == .cyan ? Color.cyan : .orange
        Text("\(title) • \(team.rawValue.uppercased())")
            .font(.caption2.monospaced().weight(.black))
            .tracking(1.2)
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(.black.opacity(0.42), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.7), lineWidth: 1.5))
            .accessibilityLabel(isLocal ? "Your side: \(team.rawValue.capitalized)" : "\(title): \(team.rawValue.capitalized)")
    }
}

private struct MatchHUD: View {
    let state: WorldState
    let localTeam: Team
    let allowedBounces: Int
    let allowedTouches: Int
    let online: OnlineMatchCoordinator?
    let actionLabel: String
    let actionIcon: String
    let action: () -> Void

    /// The scoreboard sits the way the court does: each side's score over its
    /// own half, so it changes ends with the teams between sets.
    private var leftTeam: Team { state.team(onHalfAt: -1) }

    var body: some View {
        HStack {
            score(team: leftTeam)
            Spacer()
            VStack(spacing: 2) {
                // The format line steps aside when a point is actually on
                // the line -- that is the one moment the middle of the HUD
                // has something urgent to say.
                if let headline = state.match.headlineStake {
                    stakeCallout(headline)
                } else {
                    rulesChip
                }
                if state.match.setsToWin > 1 { setPips }
                if let online {
                    Label(online.statusLabel, systemImage: signalIcon)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(statusColor)
                }
            }
            Spacer()
            score(team: leftTeam.opponent)
            Button(action: action) {
                Image(systemName: actionIcon)
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.45), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.25)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(actionLabel)
            .accessibilityIdentifier("match-action-button")
        }
        .padding(.horizontal, 24).padding(.top, 10)
    }

    private var formatLabel: String {
        switch state.match.setsToWin {
        case 2: "BEST OF 3 • SETS TO 7"
        case 3: "BEST OF 5 • SETS TO 7"
        default: "FIRST TO 7 • WIN BY 2"
        }
    }

    private var rulesChip: some View {
        let isServe = state.match.phase == .serve
        return Text(formatLabel)
            .font(.system(size: 12, weight: .black, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(isServe ? .white : .white.opacity(0.85))
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(isServe ? Color.yellow : Color.white.opacity(0.35), lineWidth: isServe ? 2 : 1)
            )
            .accessibilityIdentifier("match-rules-chip")
    }

    /// One pip per set a side needs, filled as they take them, each side's
    /// pips on the half that side is flying.
    private var setPips: some View {
        HStack(spacing: 8) {
            ForEach([leftTeam, leftTeam.opponent], id: \.self) { team in
                HStack(spacing: 3) {
                    ForEach(0..<state.match.setsToWin, id: \.self) { index in
                        Circle().fill(index < state.match.sets[team] ? Self.tint(team) : .white.opacity(0.18))
                            .frame(width: 6, height: 6)
                    }
                }
            }
        }
        .accessibilityLabel("Sets: you \(state.match.sets[localTeam]), rival \(state.match.sets[localTeam.opponent])")
    }

    private static func tint(_ team: Team) -> Color { team == .cyan ? .cyan : .orange }

    /// Names the side and what the next point takes. Carries the team tint
    /// as a filled capsule so it reads from across the room mid-rally.
    private func stakeCallout(_ headline: (team: Team, stake: Stake)) -> some View {
        let tint = headline.team == .cyan ? Color.cyan : Color.orange
        let word = headline.stake == .matchPoint ? "MATCH POINT" : "SET POINT"
        let side = headline.team == .cyan ? "CYAN" : "ORANGE"
        return Text("\(side) · \(word)")
            .font(.caption2.monospaced().weight(.black))
            .tracking(1.4)
            .foregroundStyle(.black)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(tint, in: Capsule())
            .accessibilityLabel("\(side) \(word.lowercased())")
            .accessibilityIdentifier("stake-callout")
    }

    private func score(team: Team) -> some View {
        let tint = Self.tint(team)
        let value = state.match.score[team]
        let bounces = state.match.floorContacts[team]
        let touches = state.match.shipTouches[team]
        let stake = state.match.stake(for: team)
        let isLocal = team == localTeam
        return HStack(spacing: 12) {
            VStack(spacing: 3) {
                Image(systemName: team == .cyan ? "minus" : "diamond.fill").foregroundStyle(tint)
                Text(isLocal ? "YOU" : (online == nil ? "CPU" : "OPP"))
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(tint, in: Capsule())
                    .accessibilityIdentifier(isLocal ? "hud-you-tag" : "hud-opponent-tag")
            }
            Text(value.formatted())
                .font(.system(size: 36, weight: .black, design: .rounded).monospacedDigit())
                // A ring on the number itself, so the side that is serving
                // for it is obvious even when the eye never leaves the score.
                .padding(stake == .none ? 0 : 5)
                .background {
                    if stake != .none {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(tint, lineWidth: stake == .matchPoint ? 3 : 1.5)
                    }
                }
            // Up arrows are touches, down arrows are bounces -- which way the
            // ball was headed when it spent one.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 1) {
                    ForEach(0..<allowedTouches, id: \.self) { index in
                        Image(systemName: "arrow.up")
                            .foregroundStyle(index < touches ? tint : .white.opacity(0.16))
                    }
                }
                HStack(spacing: 1) {
                    ForEach(0..<allowedBounces, id: \.self) { index in
                        Image(systemName: "arrow.down")
                            .foregroundStyle(index < bounces ? tint.opacity(0.75) : .white.opacity(0.16))
                    }
                }
            }
            .font(.system(size: 10, weight: .black))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            (isLocal ? "Your side, " : "Rival side, ")
                + "\(team.rawValue) score \(value), \(touches) of \(allowedTouches) touches used, "
                + "\(bounces) of \(allowedBounces) bounces used"
                + (stake == .none ? "" : stake == .matchPoint ? ", match point" : ", set point")
        )
    }

    private var signalIcon: String {
        guard let ping = online?.pingMilliseconds else { return "wifi" }
        return ping < 80 ? "wifi" : ping < 160 ? "wifi.exclamationmark" : "exclamationmark.triangle"
    }

    private var statusColor: Color {
        guard let online else { return .white.opacity(0.6) }
        return switch online.status {
        case .connected, .ready: .green
        case .matching, .authenticating, .reconnecting: .yellow
        case .failed: .orange
        case .signedOut: .white.opacity(0.6)
        }
    }
}

struct CountdownView: View {
    let value: Int
    var title: String? = nil
    var caption = "NEUTRAL CENTER DROP"
    var body: some View {
        VStack(spacing: 8) {
            if let title {
                Text(title).font(.system(size: 22, weight: .black, design: .rounded)).tracking(2)
            }
            Text(value > 0 ? value.formatted() : "DROP").font(.system(size: 74, weight: .black, design: .rounded)).contentTransition(.numericText())
            Text(caption).font(.caption.monospaced().weight(.bold)).tracking(2).foregroundStyle(.white.opacity(0.6))
        }
        .accessibilityElement(children: .combine).accessibilityIdentifier("countdown")
    }
}

/// The alternate courts, and the track. Volleyball and basketball still want
/// a rival, so the difficulty is chosen here rather than behind another sheet.
private struct ModePicker: View {
    let start: (GameMode) -> Void
    let startTrack: () -> Void
    @State private var difficulty: AIDifficulty = .pilot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("GAME MODES").font(.title.bold())

                Picker("Rival", selection: $difficulty) {
                    ForEach(AIDifficulty.allCases, id: \.self) { level in
                        Text(level.rawValue.uppercased()).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("mode-difficulty")

                ModeCard(
                    title: "VOLLEYBALL",
                    icon: "volleyball.fill",
                    tint: .cyan,
                    detail: "The net stands up out of the floor and covers the bottom half of the arena. Nothing goes through it — play it over the top. Three touches a trip, and the first time the ball touches the ground the rally is over."
                ) { start(.volleyball(difficulty)) }

                ModeCard(
                    title: "BASKETBALL",
                    icon: "basketball.fill",
                    tint: .orange,
                    detail: "One rim at centre court and both halves shoot at it. Clip a post and the shot is off. First ball to drop through wins the match outright — for whoever touched it last, whichever side it fell from."
                ) { start(.basketball(difficulty)) }

                ModeCard(
                    title: "TIME TRIAL",
                    icon: "flag.checkered",
                    tint: .green,
                    detail: "A tight circuit with a live railing. Steer and throttle the same way you fly. Touch a rail and you are penalised: the car is stunned, the throttle goes dead, and a second goes on your lap."
                ) { startTrack() }
            }
            .padding(28)
        }
        .accessibilityIdentifier("mode-picker")
    }
}

private struct ModeCard: View {
    let title: String, icon: String, tint: Color, detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: icon).font(.largeTitle).frame(width: 46).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline.weight(.black)).tracking(1.4)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(tint.opacity(0.35)))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mode-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }
}

private struct DifficultyPicker: View {
    let choose: (AIDifficulty) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CHOOSE YOUR RIVAL").font(.title.bold())
            HStack(spacing: 12) {
                ForEach(AIDifficulty.allCases, id: \.self) { difficulty in
                    Button { choose(difficulty) } label: {
                        VStack(spacing: 10) {
                            Image(systemName: difficulty.icon).font(.title)
                            Text(difficulty.rawValue.uppercased()).font(.headline)
                            Text(difficulty.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 120)
                    }
                    .buttonStyle(.bordered).tint(difficulty == .ace ? .orange : .cyan)
                    .accessibilityIdentifier("difficulty-\(difficulty.rawValue)")
                }
            }
        }
        .padding(28).accessibilityIdentifier("difficulty-picker")
    }
}

private struct FlightTutorial: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    TutorialCard(number: "01", icon: "arrow.left.and.right", title: "STEER", text: "Hold left or right to rotate. Release to stop turning; your ship keeps its current angle and flight momentum.")
                    TutorialCard(number: "02", icon: "flame.fill", title: "THRUST", text: "Hold for steady main-engine acceleration. There is no auto-leveling and no brake. The exhaust is a real jet: a ball sitting in your plume gets shoved down it, so you can hover under a dropping ball to cushion it or blast one away. That is not a touch.")
                    TutorialCard(number: "02b", icon: "bolt.fill", title: "FIRE", text: "Tap to fire a bolt from the nose. It knocks the ball along the line you are pointing and is not a touch. Bolts fly the whole court but you can only fire from your own half, and they never hurt a ship.")
                    TutorialCard(number: "03", icon: "keyboard", title: "KEYBOARD", text: "On a Mac, or with a keyboard attached, fly with A and D to steer and W or up arrow to thrust, with Space to fire. The arrow keys steer too. Escape or P pauses, return confirms — the whole match runs without the screen. Touch and keys work together.")
                    TutorialCard(number: "04", icon: "volleyball.fill", title: "SCORE", text: "The goal hangs from the roof, dead centre, and it is a portal. The face on your side is yours to defend: a ball that goes in through it is a point for the other side. Get the ball into their half, lifted, and into the face over there — or make them put it into their own. Clip the hard rounded bottom and it just bounces. Three touches a trip on your own half, three bounces a touch.")
                    TutorialCard(number: "05", icon: "tray.and.arrow.down.fill", title: "THE LIP", text: "A ledge juts out under each face and tilts inward: a ball that lands on the lip rolls straight into the portal. Skim the ball under the cap so it drops onto the far lip, and it is in. Above the goal the roof bulges with the same curve as the corners, so nothing rides the ceiling into the mouth. Neither the lip nor the bulge counts as a bounce.")
                    TutorialCard(number: "06", icon: "arrow.left.and.right.circle.fill", title: "CROSS", text: "Fly under the goal, or straight through the portal itself, to reach the opponent’s side — the net stops the ball, never your hull, so you can sit in the mouth and defend. You can fly as far as the colored MAX CROSS line.")
                    TutorialCard(number: "07", icon: "burst.fill", title: "NO WRECKS", text: "Nothing destroys your ship. Ground, walls, ceiling, the roof bulge and the other ship all rebound. Points are won on the ball alone: a goal, a fourth touch, or a fourth bounce. After every set the teams switch sides and keep their colours, so everyone plays both halves.")
                }.padding(28)
            }
            .navigationTitle("How to Fly").toolbar { Button("Done") { dismiss() } }
        }
        .accessibilityIdentifier("tutorial-screen")
    }
}

private struct TutorialCard: View {
    let number: String, icon: String, title: String, text: String
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Text(number).font(.title.monospaced().bold()).foregroundStyle(.cyan)
            Image(systemName: icon).font(.title).foregroundStyle(.orange).frame(width: 42)
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(text).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(18).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct SettingsView: View {
    @Bindable var tuning: FlightTuningStore
    @Bindable var trackTuning: TrackTuningStore
    var replayIntro: (() -> Void)?
    @AppStorage("largeControls") private var largeControls = false
    @AppStorage("leftHanded") private var leftHanded = false
    @AppStorage("clusterControls") private var clusterControls = false
    @AppStorage("haptics") private var haptics = true
    @AppStorage("arrangePads") private var arrangePads = false
    var body: some View {
        NavigationStack {
            Form {
                Toggle("Large controls", isOn: $largeControls)
                Toggle("Swap controls for left-handed play", isOn: $leftHanded)
                Toggle("Cluster controls to thumb side", isOn: $clusterControls)
                Toggle("Arrange pads (drag them in a match)", isOn: $arrangePads)
                Button("Reset pad layout") { UserDefaults.standard.removeObject(forKey: "padOffsets2") }
                Toggle("Haptics", isOn: $haptics)
                LabeledContent("Reduced Motion", value: "Follows iOS Accessibility")
                Section("Tractor Beam") {
                    TuningSlider(
                        title: "Pull strength",
                        value: $tuning.tractorStrength,
                        range: 1 ... 4.5,
                        step: 0.1,
                        readout: { $0.formatted(.number.precision(.fractionLength(1))) }
                    )
                    Text("How hard the beam reels the ball in. Applies to solo matches immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Match Rules") {
                    Stepper(
                        "Touches per side: \(tuning.allowedTouchesPerSide)",
                        value: $tuning.allowedTouchesPerSide,
                        in: 1 ... 6
                    )
                    Stepper(
                        "Bounces per hit: \(tuning.allowedBouncesPerHit)",
                        value: $tuning.allowedBouncesPerHit,
                        in: 1 ... 5
                    )
                    Picker("Match length", selection: $tuning.setsToWin) {
                        Text("Single game").tag(1)
                        Text("Best of 3").tag(2)
                        Text("Best of 5").tag(3)
                    }
                    .accessibilityIdentifier("match-length")
                    Text("Touches and bounces apply to solo matches; online uses three of each. Match length applies to solo matches and to any online match you host.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                #if DEBUG
                Section("Developer") {
                    NavigationLink("Flight Tuning") {
                        FlightTuningView(tuning: tuning)
                    }
                }
                #endif
                if let replayIntro {
                    Section("Intro") {
                        Button("Replay intro", action: replayIntro)
                            .accessibilityIdentifier("replay-intro")
                    }
                }
                Section("Team symbols") { Label("Cyan uses a bar", systemImage: "minus"); Label("Orange uses a diamond", systemImage: "diamond.fill") }
            }.navigationTitle("Settings")
        }
        .accessibilityIdentifier("settings-screen")
    }
}

private struct FlightTuningView: View {
    @Bindable var tuning: FlightTuningStore
    var restartDrop: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    GroupBox("Ship") {
                        VStack(spacing: 14) {
                            TuningSlider(title: "Gravity", value: $tuning.gravityMagnitude, range: 0.5 ... 4, step: 0.1)
                            TuningSlider(title: "Thrust", value: $tuning.thrustAcceleration, range: 2 ... 10, step: 0.25)
                            TuningSlider(title: "Rotation", value: $tuning.rotationAcceleration, range: 0.5 ... 8, step: 0.25)
                        }
                    }
                    GroupBox("Ball Drop") {
                        VStack(spacing: 14) {
                            TuningSlider(title: "Ball gravity", value: $tuning.ballGravityMultiplier, range: 0.1 ... 1.2, step: 0.02)
                            TuningSlider(title: "Drop height", value: $tuning.ballDropHeight, range: -0.30 ... 0.10, step: 0.01)
                            TuningSlider(title: "Drop speed", value: $tuning.ballDropSpeed, range: 0 ... 0.8, step: 0.01)
                            TuningSlider(title: "Tractor pull", value: $tuning.tractorStrength, range: 1 ... 4.5, step: 0.1)
                        }
                    }
                    GroupBox("Match Rule") {
                        Stepper(
                            "Touches per side: \(tuning.allowedTouchesPerSide)",
                            value: $tuning.allowedTouchesPerSide,
                            in: 1 ... 6
                        )
                        Stepper(
                            "Bounces per hit: \(tuning.allowedBouncesPerHit)",
                            value: $tuning.allowedBouncesPerHit,
                            in: 1 ... 5
                        )
                    }
                }
                Text("Solo flight only. Ship and gravity changes apply immediately; drop height and speed apply on the next drop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let restartDrop {
                    Button("Restart Drop", action: restartDrop)
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                }
                Button("Reset Defaults", role: .destructive) { tuning.reset() }
                    .buttonStyle(.bordered)
            }
            .padding(20)
        }
        .navigationTitle("Flight Tuning")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("flight-tuning-screen")
    }
}

/// Shared with the circuit's own sliders, which live in `RaceTuningView`.
struct TuningSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// How the number beside the title reads. Two decimals suit the flight
    /// sliders, whose range is wide; the corridor moves in thousandths and
    /// is felt in hulls, so it gets to say so rather than showing the same
    /// rounded number at both ends of its travel.
    var readout: (Double) -> String = {
        $0.formatted(.number.precision(.fractionLength(2)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(readout(value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(readout(value))
        }
    }
}

private struct CourtPauseOverlay: View {
    @Bindable var tuning: FlightTuningStore
    let restartDrop: () -> Void
    let resume: () -> Void
    let quit: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            NavigationStack {
                FlightTuningView(tuning: tuning, restartDrop: restartDrop)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Resume", action: resume)
                                .accessibilityIdentifier("resume-button")
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button("Quit", role: .destructive, action: quit)
                                .accessibilityIdentifier("quit-match-paused")
                        }
                    }
            }
            .frame(maxWidth: 620, maxHeight: 460)
            .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.25)))
            .padding(20)
        }
        .accessibilityIdentifier("pause-screen")
    }
}

/// The match is over and it was the network that ended it. One statement of
/// what happened, one way out.
private struct LinkLostOverlay: View {
    let message: String
    let exit: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 40, weight: .semibold)).foregroundStyle(.orange)
            Text("LINK LOST").font(.caption.monospaced().bold()).tracking(3)
            Text(message.uppercased())
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            Button("BACK TO MENU", action: exit).buttonStyle(.borderedProminent).tint(.orange)
        }
        .padding(30)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26))
        .accessibilityIdentifier("link-lost-screen")
    }
}

private struct ResultsOverlay: View {
    let state: WorldState
    let localTeam: Team
    let plan: ResultsPlan
    let playAgain: () -> Void
    let challenge: () -> Void
    let exit: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text(didLocalPlayerWin ? "YOU WIN" : "YOU LOSE")
                .font(.caption.monospaced().bold()).tracking(3)
            // Yours first, in your colour, whichever colour you flew.
            if state.match.setsToWin > 1 {
                scoreLine(state.match.sets)
                Text("YOU — RIVAL · SETS · LAST SET \(state.match.score[localTeam])–\(state.match.score[localTeam.opponent])")
                    .font(.caption2.monospaced().weight(.semibold)).foregroundStyle(.secondary)
            } else {
                scoreLine(state.match.score)
                Text("YOU — RIVAL")
                    .font(.caption2.monospaced().weight(.semibold)).foregroundStyle(.secondary)
            }
            if plan.canPlayAgain {
                Button("PLAY AGAIN", action: playAgain)
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .accessibilityIdentifier("results-play-again")
            }
            if let next = plan.nextRival {
                Button("CHALLENGE \(next.rawValue.uppercased())", action: challenge)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .accessibilityIdentifier("results-challenge")
            }
            Button("BACK TO MENU", action: exit)
                .buttonStyle(.bordered)
                .tint(.white)
                .accessibilityIdentifier("results-back-to-menu")
        }
        .padding(30).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("results-screen")
    }

    private func scoreLine(_ tally: Score) -> some View {
        let rival = localTeam.opponent
        return HStack(spacing: 18) {
            Text(tally[localTeam].formatted()).foregroundStyle(localTeam == .cyan ? Color.cyan : .orange)
            Text("—").foregroundStyle(.secondary)
            Text(tally[rival].formatted()).foregroundStyle(rival == .cyan ? Color.cyan : .orange)
        }
        .font(.system(size: 58, weight: .black, design: .rounded).monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("You \(tally[localTeam]), rival \(tally[rival])")
    }

    private var didLocalPlayerWin: Bool {
        if let winner = state.match.winner { return winner == localTeam }
        return state.match.score[localTeam] > state.match.score[localTeam.opponent]
    }
}

private struct MenuButton: View {
    let title: String, subtitle: String, icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.title2).frame(width: 34)
                VStack(alignment: .leading, spacing: 2) { Text(title).font(.headline.weight(.black)).tracking(1); Text(subtitle).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.52)) }
                Spacer(); Image(systemName: "chevron.right")
            }
            .padding(.horizontal, 20).frame(minHeight: 68)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12)))
        }
        .buttonStyle(.plain).accessibilityIdentifier(title.lowercased().replacingOccurrences(of: " ", with: "-"))
    }
}

private struct SmallMenuButton: View {
    let title: String, icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label(title, systemImage: icon).font(.caption.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7).padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 44).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 13)) }
            .buttonStyle(.plain).accessibilityIdentifier(title.lowercased().replacingOccurrences(of: " ", with: "-"))
    }
}

private struct TeamMarkRow: View {
    var body: some View {
        HStack(spacing: 14) { Label("CYAN", systemImage: "minus").foregroundStyle(.cyan); Text("VS").foregroundStyle(.white.opacity(0.35)); Label("ORANGE", systemImage: "diamond.fill").foregroundStyle(.orange) }
            .font(.caption.monospaced().bold())
    }
}

struct CosmicBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.01, green: 0.02, blue: 0.08), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.cyan.opacity(0.13), .clear], center: .leading, startRadius: 0, endRadius: 430)
            RadialGradient(colors: [.orange.opacity(0.10), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 390)
        }.ignoresSafeArea()
    }
}

private extension AIDifficulty {
    var icon: String { switch self { case .rookie: "sparkles"; case .pilot: "airplane"; case .ace: "bolt.fill" } }
    var detail: String { switch self { case .rookie: "Patient learner"; case .pilot: "Balanced rival"; case .ace: "Fast and fearless" } }
}

#Preview { AppRootView() }
