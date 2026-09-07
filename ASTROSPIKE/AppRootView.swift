import ASTROSPIKECore
import SpriteKit
import SwiftUI

struct AppRootView: View {
    @State private var online = OnlineMatchCoordinator()
    @State private var lobby = LobbyService()
    @State private var tuning = FlightTuningStore()
    @State private var profile = PilotProfileStore()
    @State private var entitlements = HullEntitlements()
    @State private var gameMode: GameMode?
    @State private var sheet: MenuSheet?
    @State private var showOnboarding: Bool
    @Environment(\.scenePhase) private var scenePhase
    private let diagnosticsPreview: OnlineDiagnosticsSnapshot?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let demoMode = arguments.contains("--demo")
        let diagnosticsPreviewMode = arguments.contains("--online-diagnostics-preview")
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
        let warmupMode = arguments.contains("--warmup")
        _gameMode = State(initialValue: diagnosticsPreviewMode ? .online
            : warmupMode ? .warmup
            : demoMode ? .solo(.pilot) : nil)
        // Automation and UI tests land on the home screen; a fresh install lands
        // on the intro.
        let lobbyMode = arguments.contains("--lobby")
        let bypass = demoMode || warmupMode || diagnosticsPreviewMode || lobbyMode || arguments.contains("--skip-onboarding")
        _showOnboarding = State(initialValue: !bypass && !PilotProfileStore().hasCompletedOnboarding)
        // `--lobby` opens the board straight away; the simulator cannot tap it.
        _sheet = State(initialValue: lobbyMode ? .lobby : nil)
    }

    var body: some View {
        ZStack {
            CosmicBackground()
            if let gameMode {
                GameView(
                    mode: gameMode,
                    online: online,
                    lobby: lobby,
                    tuning: tuning,
                    profile: profile,
                    diagnosticsOverride: diagnosticsPreview
                ) {
                    self.gameMode = nil
                }
                .id(gameMode)
                .transition(.opacity.combined(with: .scale(scale: 1.03)))
            } else if showOnboarding {
                OnboardingFlow(profile: profile, entitlements: entitlements) { launch in
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
            lobby.localHull = profile.selectedHull
            if diagnosticsPreview == nil {
                online.authenticate()
            }
        }
        .onChange(of: profile.selectedHull) { _, hull in
            online.localHull = hull
            lobby.localHull = hull
        }
        .onChange(of: online.isMatchReady) { _, ready in
            if ready {
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
                SettingsView(tuning: tuning, replayIntro: {
                    sheet = nil
                    showOnboarding = true
                }).presentationDetents([.large])
            case .hangar:
                HangarSheet(profile: profile, entitlements: entitlements)
            case .lobby:
                LobbyView(lobby: lobby, online: online)
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
        case .solo, .doubles: .solo
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
    case difficulty, tutorial, settings, hangar, invite, lobby
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
                    Label(online.status.label, systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(statusColor).lineLimit(1)
                }
                .font(.system(size: min(58, geometry.size.height * 0.13), weight: .black, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 12) {
                    MenuButton(title: "SOLO FLIGHT", subtitle: "ROOKIE • PILOT • ACE", icon: "person.fill") { sheet = .difficulty }
                    MenuButton(title: "QUICK MATCH", subtitle: "AUTOMATIC ONLINE DUEL", icon: "bolt.horizontal.circle.fill") { online.startQuickMatch() }
                    MenuButton(title: "LOBBY", subtitle: "WHO'S ONLINE • LIVE DUELS • BRACKETS", icon: "person.3.fill") { sheet = .lobby }
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
    let exit: () -> Void

    @State private var session: GameSession
    @State private var showPause = false
    @State private var showLeaveConfirmation = false
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
        exit: @escaping () -> Void
    ) {
        self.mode = mode
        self.online = online
        self.lobby = lobby
        self.tuning = tuning
        self.profile = profile
        self.diagnosticsOverride = diagnosticsOverride
        self.exit = exit
        let configuration = switch mode {
        case .solo, .doubles: tuning.configuration
        case .online: SimulationConfiguration.online
        case .warmup: SimulationConfiguration.warmup
        }
        _session = State(initialValue: GameSession(
            mode: mode,
            online: online,
            lobby: lobby,
            configuration: configuration,
            setsToWin: tuning.setsToWin,
            localHull: profile.selectedHull,
            rivalHull: profile.rivalHull()
        ))
    }

    var body: some View {
        ZStack {
            SpriteView(scene: session.scene, options: [.ignoresSiblingOrder])
                .ignoresSafeArea().accessibilityHidden(true)
            VStack(spacing: 0) {
                if mode == .warmup {
                    WarmupHUD(session: session, online: online) { showLeaveConfirmation = true }
                } else {
                    MatchHUD(
                        state: session.state,
                        allowedBounces: allowedBounces,
                        allowedTouches: allowedTouches,
                        online: mode == .online && diagnosticsOverride == nil ? online : nil,
                        actionLabel: mode == .online ? "Leave online match" : "Pause match",
                        actionIcon: mode == .online ? "xmark" : "pause.fill"
                    ) {
                        if mode == .online {
                            showLeaveConfirmation = true
                        } else {
                            session.togglePause()
                            showPause = true
                        }
                    }
                }
                if mode == .online {
                    GameCenterDiagnosticsPanel(
                        diagnostics: diagnosticsOverride ?? online.diagnosticsSnapshot
                    )
                    .padding(.top, 4)
                }
                if mode != .warmup {
                    HStack {
                        if localHomeSide == .orange { Spacer() }
                        TeamSideBadge(team: localTeam)
                        if localHomeSide == .cyan { Spacer() }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 4)
                }
                TouchControls(torque: $session.torque, thrust: $session.thrust, fire: $session.fire,
                              largeControls: largeControls, leftHanded: leftHanded)
            }
            // Takes no space and never hit-tests, so a hardware keyboard flies
            // the ship without displacing the thumb controls.
            KeyboardControls(
                torque: $session.torque,
                thrust: $session.thrust,
                fire: $session.fire,
                onCommand: keyCommandHandler
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            if session.state.match.phase == .countdown { CountdownView(value: session.countdown) }
            if session.state.match.phase == .serve, let text = session.lastPointText {
                Text(text)
                    .font(.system(size: 30, weight: .black, design: .rounded)).tracking(2)
                    .padding(.horizontal, 24).padding(.vertical, 13)
                    .background(.black.opacity(0.66), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.35)))
            }
            if session.state.match.phase == .finished {
                ResultsOverlay(state: session.state, localTeam: localTeam, exit: leaveGame)
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
            // Apple's picker was cancelled under the bay: nothing is pending, so
            // there is nothing to warm up for.
            if mode == .warmup, case .ready = status { exit() }
        }
        .onChange(of: tuning.snapshot) { _, _ in
            session.applyTuning(tuning.configuration)
        }
        .onChange(of: online.remoteHulls) { _, hulls in
            // The peer profiles can land after the session is built.
            if mode == .online {
                for (seat, hull) in hulls {
                    session.scene.setHull(hull, for: seat)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            session.setApplicationActive(phase == .active)
        }
        .sheet(isPresented: $showPause, onDismiss: { session.resume() }) {
            PauseView(
                tuning: tuning,
                restartDrop: { session.restartRally(with: tuning.configuration) },
                resume: { showPause = false; session.resume() },
                exit: { showPause = false; leaveGame() }
            )
            .presentationDetents([.large])
            .interactiveDismissDisabled()
        }
    }

    private var localTeam: Team { online.localTeam ?? .cyan }

    private var allowedBounces: Int {
        switch mode {
        case .solo, .doubles: tuning.allowedBouncesPerHit
        case .online, .warmup: 3
        }
    }

    private var allowedTouches: Int {
        switch mode {
        case .solo, .doubles: tuning.allowedTouchesPerSide
        case .online, .warmup: 3
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
            // Only meaningful on the results card, where it is the one button.
            if session.state.match.phase == .finished { leaveGame() }
        }
    }

    private func leaveGame() {
        switch mode {
        case .online:
            lobby.hostDuelAbandoned()
            online.leaveMatch()
        case .warmup: online.cancelMatchmaking()
        case .solo, .doubles: break
        }
        exit()
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
                Label(online.status.label, systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption2.weight(.bold)).foregroundStyle(statusColor).lineLimit(1)
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
    let team: Team

    var body: some View {
        let color = team == .cyan ? Color.cyan : .orange
        Text("YOU • \(team.rawValue.uppercased())")
            .font(.caption2.monospaced().weight(.black))
            .tracking(1.2)
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(.black.opacity(0.42), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.7), lineWidth: 1.5))
            .accessibilityLabel("Your side: \(team.rawValue.capitalized)")
    }
}

private struct MatchHUD: View {
    let state: WorldState
    let allowedBounces: Int
    let allowedTouches: Int
    let online: OnlineMatchCoordinator?
    let actionLabel: String
    let actionIcon: String
    let action: () -> Void

    var body: some View {
        HStack {
            score(
                team: .cyan,
                value: state.match.score.cyan,
                bounces: state.match.floorContacts.cyan,
                touches: state.match.shipTouches.cyan
            )
            Spacer()
            VStack(spacing: 2) {
                Text(formatLabel).font(.caption2.monospaced().weight(.semibold)).foregroundStyle(.white.opacity(0.55))
                if state.match.setsToWin > 1 { setPips }
                if let online {
                    Label(online.status.label, systemImage: signalIcon)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(statusColor)
                }
            }
            Spacer()
            score(
                team: .orange,
                value: state.match.score.orange,
                bounces: state.match.floorContacts.orange,
                touches: state.match.shipTouches.orange
            )
            Button(action: action) {
                Image(systemName: actionIcon).frame(width: 42, height: 42).background(.black.opacity(0.45), in: Circle())
            }
            .accessibilityLabel(actionLabel).accessibilityIdentifier("match-action-button")
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

    /// One pip per set a side needs, filled as they take them, cyan on the
    /// left and orange on the right.
    private var setPips: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<state.match.setsToWin, id: \.self) { index in
                    Circle().fill(index < state.match.sets.cyan ? Color.cyan : .white.opacity(0.18)).frame(width: 6, height: 6)
                }
            }
            HStack(spacing: 3) {
                ForEach(0..<state.match.setsToWin, id: \.self) { index in
                    Circle().fill(index < state.match.sets.orange ? Color.orange : .white.opacity(0.18)).frame(width: 6, height: 6)
                }
            }
        }
        .accessibilityLabel("Sets \(state.match.sets.cyan) to \(state.match.sets.orange)")
    }

    private func score(team: Team, value: Int, bounces: Int, touches: Int) -> some View {
        let tint = team == .cyan ? Color.cyan : .orange
        return HStack(spacing: 12) {
            Image(systemName: team == .cyan ? "minus" : "diamond.fill").foregroundStyle(tint)
            Text(value.formatted()).font(.system(size: 36, weight: .black, design: .rounded).monospacedDigit())
            // Touches are the harder limit, so they read as bars above the
            // softer bounce dots rather than competing with them.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    ForEach(0..<allowedTouches, id: \.self) { index in
                        Capsule()
                            .fill(index < touches ? tint : .white.opacity(0.16))
                            .frame(width: 9, height: 4)
                    }
                }
                HStack(spacing: 4) {
                    ForEach(0..<allowedBounces, id: \.self) { index in
                        Circle()
                            .fill(index < bounces ? tint.opacity(0.75) : .white.opacity(0.16))
                            .frame(width: 7, height: 7)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(team.rawValue) score \(value), \(touches) of \(allowedTouches) touches used, "
                + "\(bounces) of \(allowedBounces) bounces used"
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

private struct CountdownView: View {
    let value: Int
    var body: some View {
        VStack(spacing: 8) {
            Text(value > 0 ? value.formatted() : "DROP").font(.system(size: 74, weight: .black, design: .rounded)).contentTransition(.numericText())
            Text("NEUTRAL CENTER DROP").font(.caption.monospaced().weight(.bold)).tracking(2).foregroundStyle(.white.opacity(0.6))
        }
        .accessibilityElement(children: .combine).accessibilityIdentifier("countdown")
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
                    TutorialCard(number: "02b", icon: "bolt.fill", title: "FIRE", text: "Tap to fire a bolt from the nose. It knocks the ball along the line you are pointing and counts as one of your touches. Bolts fly the whole court but you can only fire from your own half, and they never hurt a ship.")
                    TutorialCard(number: "03", icon: "keyboard", title: "KEYBOARD", text: "On a Mac, or with a keyboard attached, fly with A and D to steer and W or up arrow to thrust, with Space to fire. The arrow keys steer too. Escape or P pauses, return confirms — the whole match runs without the screen. Touch and keys work together.")
                    TutorialCard(number: "04", icon: "volleyball.fill", title: "SCORE", text: "The goal hangs from the roof, dead centre, and it is a portal. The face on your side is yours to defend: a ball that goes in through it is a point for the other side. Get the ball into their half, lifted, and into the face over there — or make them put it into their own. Clip the hard rounded bottom and it just bounces. Three touches a trip, one bounce a touch.")
                    TutorialCard(number: "05", icon: "tray.and.arrow.down.fill", title: "THE LIP", text: "A ledge juts out under each face and tilts inward: a ball that lands on the lip rolls straight into the portal. Skim the ball under the cap so it drops onto the far lip, and it is in. Above the goal the roof bulges with the same curve as the corners, so nothing rides the ceiling into the mouth. Neither the lip nor the bulge counts as a bounce.")
                    TutorialCard(number: "06", icon: "arrow.left.and.right.circle.fill", title: "CROSS", text: "Fly under the goal, or straight through the portal itself, to reach the opponent’s side — the net stops the ball, never your hull, so you can sit in the mouth and defend. You can fly as far as the colored MAX CROSS line.")
                    TutorialCard(number: "07", icon: "burst.fill", title: "NO WRECKS", text: "Nothing destroys your ship. Ground, walls, ceiling, the roof bulge and the other ship all rebound. Points are won on the ball alone: a goal, a third touch, or a second bounce.")
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
    var replayIntro: (() -> Void)?
    @AppStorage("largeControls") private var largeControls = false
    @AppStorage("leftHanded") private var leftHanded = false
    @AppStorage("haptics") private var haptics = true
    var body: some View {
        NavigationStack {
            Form {
                Toggle("Large controls", isOn: $largeControls)
                Toggle("Swap controls for left-handed play", isOn: $leftHanded)
                Toggle("Haptics", isOn: $haptics)
                LabeledContent("Reduced Motion", value: "Follows iOS Accessibility")
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
                Section("Developer") {
                    NavigationLink("Flight Tuning") {
                        FlightTuningView(tuning: tuning)
                    }
                }
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

private struct TuningSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(value.formatted(.number.precision(.fractionLength(2))))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(value.formatted(.number.precision(.fractionLength(2))))
        }
    }
}

private struct PauseView: View {
    @Bindable var tuning: FlightTuningStore
    let restartDrop: () -> Void
    let resume: () -> Void
    let exit: () -> Void
    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("PAUSED").font(.largeTitle).fontWeight(.black)
                Button("Resume", action: resume).buttonStyle(.borderedProminent).tint(.cyan).accessibilityIdentifier("resume-button")
                NavigationLink("Flight Tuning") {
                    FlightTuningView(tuning: tuning, restartDrop: restartDrop)
                }
                .buttonStyle(.bordered)
                Button("Exit Match", role: .destructive, action: exit).buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("pause-screen")
        }
    }
}

private struct ResultsOverlay: View {
    let state: WorldState
    let localTeam: Team
    let exit: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Text(didLocalPlayerWin ? "YOU WIN" : "YOU LOSE")
                .font(.caption.monospaced().bold()).tracking(3)
            if state.match.setsToWin > 1 {
                Text("\(state.match.sets.cyan)  —  \(state.match.sets.orange)").font(.system(size: 58, weight: .black, design: .rounded).monospacedDigit())
                Text("SETS · LAST SET \(state.match.score.cyan)–\(state.match.score.orange)")
                    .font(.caption2.monospaced().weight(.semibold)).foregroundStyle(.secondary)
            } else {
                Text("\(state.match.score.cyan)  —  \(state.match.score.orange)").font(.system(size: 58, weight: .black, design: .rounded).monospacedDigit())
            }
            Button("Return to Hangar", action: exit).buttonStyle(.borderedProminent).tint(.cyan)
        }
        .padding(30).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26)).accessibilityIdentifier("results-screen")
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
