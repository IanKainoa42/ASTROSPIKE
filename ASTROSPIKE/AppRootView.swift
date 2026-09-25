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
        // `--doubles` drops straight into a two-a-side match, for sim checks.
        let doublesMode = arguments.contains("--doubles")
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
            : doublesMode ? .doubles(.pilot)
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
                    },
                    inviteToTable: { sheet = .tableInvite }
                ) {
                    self.gameMode = nil
                }
                // A new online table needs a new session, not the last one's.
                .id([AnyHashable(gameMode), AnyHashable(gameMode == .online ? online.seatingGeneration : 0)])
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
                // A host asking more pilots to its table keeps its sheet: the
                // next duel being seated is not a reason to lose the picks.
                if sheet != .tableInvite { sheet = nil }
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
            case .doubles:
                DoublesSheet(online: online) { difficulty in
                    sheet = nil
                    gameMode = .doubles(difficulty)
                } teamUp: { teamUp in
                    sheet = nil
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        online.presentFriendInvite(teamUp: teamUp)
                    }
                }
                .presentationDetents([.large])
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
            case .tableInvite:
                InviteSheet(online: online, format: .addToTable) { _ in }
                    .presentationDetents([.medium, .large])
            case .invite:
                InviteSheet(online: online) { teamUp in
                    sheet = nil
                    // Let the sheet finish dismissing before Game Center's own
                    // picker takes the top of the stack.
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        online.presentFriendInvite(teamUp: teamUp)
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
    case difficulty, doubles, tutorial, settings, hangar, invite, tableInvite, lobby, modes
    var id: String { rawValue }
}

/// DOUBLES asks one question first: who flies beside you. A bot wingman
/// drops into the difficulty picker; a friend goes to the team-up invite
/// with TEAM UP already chosen.
private struct DoublesSheet: View {
    let online: OnlineMatchCoordinator
    let chooseBot: (AIDifficulty) -> Void
    let teamUp: (_ teamUp: Bool) -> Void
    @State private var wingman: Wingman?

    private enum Wingman { case bot, friend }

    var body: some View {
        switch wingman {
        case nil:
            VStack(alignment: .leading, spacing: 16) {
                Text("WHO FLIES BESIDE YOU?").font(.title.bold())
                Text("Two a side on the big court, two balls in play.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    choice("BOT WINGMAN", detail: "A bot on your wing against two bots. Pick their level next.",
                           icon: "cpu", identifier: "doubles-bot") { wingman = .bot }
                    choice("A FRIEND", detail: "Invite a pilot to your side. Bots fill the far half, or invite three.",
                           icon: "person.2.wave.2.fill", identifier: "doubles-friend") { wingman = .friend }
                }
            }
            // No identifier on the container: it would shadow the two
            // buttons' own, and the test that drives this sheet keys on those.
            .padding(28)
        case .bot:
            DifficultyPicker(title: "CHOOSE THE RIVAL PAIR", choose: chooseBot)
        case .friend:
            InviteSheet(online: online, teamUp: true, openPicker: teamUp)
        }
    }

    private func choice(_ title: String, detail: String, icon: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.title)
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 140)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered).tint(.cyan)
        .accessibilityIdentifier(identifier)
    }
}

/// How the invited pilots play.
private enum InviteFormat: Hashable {
    /// One pilot, across the net.
    case duel
    /// Up to three on your side against bots, or two a side.
    case teamUp
    /// Ask up to five at once. The first to join flies you; everyone after
    /// watches from the bench and plays the winner.
    case openTable
    /// The host of a running open table asking more pilots to the bench.
    case addToTable

    /// How many pilots can be picked in one go. A duel invites on the tap.
    var pickLimit: Int {
        switch self {
        case .duel: 1
        case .teamUp: 3
        case .openTable, .addToTable: OpenTable.maxInvitees
        }
    }
}

private struct InviteSheet: View {
    let online: OnlineMatchCoordinator
    let openPicker: (_ teamUp: Bool) -> Void
    @State private var format: InviteFormat
    @State private var picked: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    init(online: OnlineMatchCoordinator, format: InviteFormat = .duel, openPicker: @escaping (_ teamUp: Bool) -> Void) {
        self.online = online
        self.openPicker = openPicker
        _format = State(initialValue: format)
    }

    init(online: OnlineMatchCoordinator, teamUp: Bool, openPicker: @escaping (_ teamUp: Bool) -> Void) {
        self.init(online: online, format: teamUp ? .teamUp : .duel, openPicker: openPicker)
    }

    private var isPicking: Bool { format != .duel }

    /// Room left at a running table; the whole limit otherwise.
    private var pickLimit: Int {
        guard format == .addToTable, let table = online.openTable else { return format.pickLimit }
        return max(0, OpenTable.maxPilots - table.pilots.count)
    }

    private var guidance: String {
        switch format {
        case .duel: "Pick a pilot. You fly in the warm-up bay while they answer."
        case .teamUp: "Pick up to three. The first flies beside you against two bots; four pilots make it two a side."
        case .openTable: "Pick up to five. The first to join starts a duel with you; everyone after watches from the bench and plays the winner. Winner stays on."
        case .addToTable: "They join the back of the bench and play the winner when their turn comes."
        }
    }

    private var title: String {
        switch format {
        case .duel: "INVITE A PILOT"
        case .teamUp: "TEAM UP"
        case .openTable: "OPEN TABLE"
        case .addToTable: "INVITE TO THE TABLE"
        }
    }

    var body: some View {
        NavigationStack {
            let candidates = online.inviteCandidates(forTable: format == .addToTable)
            List {
                Section {
                    if format != .addToTable {
                        Picker("Match", selection: $format) {
                            Text("DUEL").tag(InviteFormat.duel)
                            Text("TEAM UP").tag(InviteFormat.teamUp)
                            Text("OPEN TABLE").tag(InviteFormat.openTable)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("invite-format")
                    }
                    Text(guidance)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("RECENT PILOTS AND FRIENDS") {
                    if candidates.isEmpty {
                        if online.isLoadingInvitees {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text(format == .addToTable
                                 ? "Everyone you know is already here."
                                 : "Nobody yet. Use the Game Center picker below.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(candidates, id: \.gamePlayerID) { player in
                        let isPicked = picked.contains(player.gamePlayerID)
                        Button {
                            guard isPicking else { online.invite([player]); return }
                            if isPicked {
                                picked.remove(player.gamePlayerID)
                            } else if picked.count < pickLimit {
                                picked.insert(player.gamePlayerID)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.cyan)
                                Text(player.displayName).font(.headline)
                                Spacer()
                                Image(systemName: isPicking ? (isPicked ? "checkmark.circle.fill" : "circle") : "paperplane.fill")
                                    .foregroundStyle(isPicked ? .cyan : .secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isPicking ? "Pick \(player.displayName)" : "Invite \(player.displayName)")
                        .accessibilityAddTraits(isPicked ? .isSelected : [])
                    }
                }
                if isPicking {
                    Section {
                        Button(action: send) {
                            Label(sendLabel, systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .disabled(picked.isEmpty)
                        .accessibilityIdentifier(format == .teamUp ? "invite-team-up-send" : "invite-open-table-send")
                    } footer: {
                        if format == .openTable {
                            Text("Everyone gets the invite at once, so nobody waits on the slowest phone.")
                        }
                    }
                }
                // Apple's picker seats whoever it returns in one go, so it
                // has no bench to put a late arrival on.
                if format == .duel || format == .teamUp {
                    Section {
                        Button { openPicker(format == .teamUp) } label: {
                            Label("Game Center picker", systemImage: "person.2.wave.2.fill")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("invite-picker-fallback")
                    } footer: {
                        Text("Apple's picker reaches anyone, but it is a modal sheet: no bay while you wait.")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: format) { _, _ in picked = [] }
        .task { online.loadInvitees() }
        .accessibilityIdentifier("invite-screen")
    }

    private var sendLabel: String {
        guard !picked.isEmpty else { return format == .teamUp ? "PICK A TEAMMATE" : "PICK PILOTS" }
        switch format {
        case .teamUp: return "SEND TEAM-UP (\(picked.count))"
        case .addToTable: return "INVITE TO THE TABLE (\(picked.count))"
        case .duel, .openTable: return "OPEN THE TABLE (\(picked.count))"
        }
    }

    private func send() {
        let players = online.inviteCandidates(forTable: format == .addToTable)
            .filter { picked.contains($0.gamePlayerID) }
        switch format {
        case .duel: break
        case .teamUp: online.invite(players, teamUp: true)
        case .openTable: online.openTable(inviting: players)
        case .addToTable:
            online.inviteToTable(players)
            dismiss()
        }
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
                    // Side by side: a fifth full-width row pushes the bottom
                    // of the menu off an iPhone in landscape.
                    HStack(spacing: 12) {
                        MenuButton(title: "SOLO FLIGHT", subtitle: "ONE ON ONE", icon: "person.fill", compact: true) { sheet = .difficulty }
                        MenuButton(title: "DOUBLES", subtitle: "BOT OR FRIEND ON YOUR WING", icon: "person.2.fill", compact: true) { sheet = .doubles }
                    }
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
    /// The host of an open table asking more pilots to the bench.
    let inviteToTable: () -> Void
    let exit: () -> Void
    @State private var session: GameSession
    /// The table this arena was built for, fixed with the session. At an
    /// open table the next duel is a new arena on the same match, and the
    /// old one going away must not take the match with it.
    @State private var builtGeneration: Int
    @State private var showPause = false
    @State private var showLeaveConfirmation = false
    /// Why the link ended, when it ended for a reason the seat hold does not
    /// cover. Non-nil puts a card over the arena instead of leaving the pilot
    /// flying a match that is already over.
    @State private var linkFailure: String?
    @AppStorage("largeControls") private var largeControls = false
    @AppStorage("leftHanded") private var leftHanded = false
    @AppStorage("haptics") private var haptics = true
    @AppStorage(Soundscape.enabledKey) private var music = true
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
        inviteToTable: @escaping () -> Void = {},
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
        self.inviteToTable = inviteToTable
        self.exit = exit
        _builtGeneration = State(initialValue: online.seatingGeneration)
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
                        // The diagnostics preview is a staged snapshot with
                        // no Game Center behind it; handing the HUD the live
                        // coordinator would print GAME CENTER OFFLINE under it.
                        online: mode == .online && diagnosticsOverride == nil ? online : nil,
                        teamNames: courtNames,
                        spectating: isSpectating,
                        actionLabel: table != nil ? "Leave the table"
                            : mode == .online ? "Leave online match" : "Pause match",
                        actionIcon: mode == .online ? "xmark" : "pause.fill"
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
                // The table's host chases a dropped pilot even while watching.
                if mode == .online, !isSpectating || online.isTableHost, case .reconnecting = online.status {
                    let cooldown = online.reinviteCooldownSecondsRemaining
                    Button {
                        online.reinviteDroppedPilots()
                    } label: {
                        Label(
                            cooldown.map { "INVITE SENT · \($0)s" } ?? "RE-INVITE PILOT",
                            systemImage: cooldown == nil
                                ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill"
                        )
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(cooldown == nil ? .yellow : .white.opacity(0.4))
                    .disabled(cooldown != nil)
                    .padding(.top, 6)
                    .accessibilityIdentifier("reinvite-button")
                }
                if mode != .warmup {
                    let left = session.state.team(onHalfAt: -1)
                    let right = left.opponent
                    let you = session.state.ships.count > 2 ? "YOU + ALLY" : "YOU"
                    HStack {
                        TeamSideBadge(
                            title: sideTitle(left, you: you),
                            team: left,
                            isLocal: !isSpectating && left == localTeam
                        )
                        Spacer()
                        TeamSideBadge(
                            title: sideTitle(right, you: you),
                            team: right,
                            isLocal: !isSpectating && right == localTeam
                        )
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 4)
                }
                if let table, session.state.match.phase != .finished {
                    OpenTableBanner(text: bannerText(for: table), isWatching: isSpectating)
                        .padding(.top, 6)
                }
                if isSpectating {
                    // The bench has no ship to fly: the court is the show.
                    Spacer()
                } else {
                    TouchControls(torque: $session.torque, thrust: $session.thrust, fire: $session.fire,
                                  tractor: $session.tractor,
                                  largeControls: largeControls, leftHanded: leftHanded,
                                  arenaFrame: Self.arenaFrame(in: geometry),
                                  windowFrame: TouchControls.windowFrame(in: geometry),
                                  playerTint: localTeam == .cyan ? .cyan : .orange)
                }
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
                    let isLocalServe = !isSpectating && servingSide == localTeam
                    let serveColor = servingSide == .cyan ? Color.cyan : Color.orange
                    HStack(spacing: 6) {
                        Image(systemName: "tennisball.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text(serveText(servingSide, isLocal: isLocalServe))
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
                    names: courtNames,
                    spectating: isSpectating,
                    table: tableCard,
                    notice: linkFailure,
                    playAgain: playAgain,
                    challenge: challengeNext,
                    inviteMore: inviteToTable,
                    exit: leaveGame
                )
            }
            if showPause {
                CourtPauseOverlay(
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
            leaveTitle,
            isPresented: $showLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button(leaveButton, role: .destructive, action: leaveGame)
            Button(mode == .warmup ? "Keep Warming Up" : isSpectating ? "Keep Watching" : "Keep Playing", role: .cancel) {}
        } message: {
            Text(leaveMessage)
        }
        .onAppear {
            FeedbackCenter.shared.hapticsEnabled = haptics
            Soundscape.shared.enabled = music
            session.start()
        }
        .onDisappear {
            session.stop()
            // At an open table the next duel rebuilds the arena on the same
            // match; only the arena of the table still being played leaves.
            if mode == .online, online.seatingGeneration == builtGeneration { online.leaveMatch() }
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
            // Online runs on the host's numbers, which arrived with the
            // seating plan. Now that the court is cut from the ball, a local
            // slider would move one side's goal mouth and nobody else's.
            guard mode != .online else { return }
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

    /// The open table this arena is a duel at, if any.
    private var table: OpenTable? { mode == .online ? online.openTable : nil }

    /// Watching from the bench. Fixed when the arena is built: the next
    /// duel gets an arena of its own.
    private var isSpectating: Bool { session.isSpectator }

    /// Who flies each colour, by Game Center name, at an open table -- where
    /// the pilots change every duel and OPPONENT says nothing.
    private var courtNames: [Team: String]? {
        guard table != nil else { return nil }
        var names: [Team: String] = [:]
        for (id, seat) in online.seating where !seat.isWing {
            names[seat.team] = online.pilotName(id).uppercased()
        }
        return names
    }

    /// The bench's place in line; for the pilots flying, who is waiting.
    private func bannerText(for table: OpenTable) -> String {
        if let line = online.benchLine { return "WATCHING · \(line)" }
        if isSpectating { return online.isTableHost ? "WATCHING · YOU'RE HOSTING" : "WATCHING" }
        if table.queue.isEmpty { return "OPEN TABLE · WINNER STAYS ON" }
        return "OPEN TABLE · \(table.queue.count) WAITING"
    }

    private func serveText(_ servingSide: Team, isLocal: Bool) -> String {
        if isLocal { return "YOUR SERVE" }
        if let name = courtNames?[servingSide] { return "\(name) SERVES" }
        return mode == .online ? "OPPONENT SERVE" : "CPU SERVE"
    }

    private func sideTitle(_ team: Team, you: String) -> String {
        if !isSpectating, team == localTeam { return you }
        if let name = courtNames?[team] { return name }
        return mode == .online ? "OPPONENT" : "CPU"
    }

    /// The results card's view of the table: who flies next and who has won.
    private var tableCard: TableCard? {
        guard let table else { return nil }
        let localID = online.localPlayerID
        func name(_ id: String) -> String { id == localID ? "YOU" : online.pilotName(id).uppercased() }
        let next = table.nextDuel
        let nextLine: String = if next.count == 2 {
            "NEXT · \(next.map(name).joined(separator: " V "))"
                + (online.intermissionSecondsRemaining.map { " · \($0)s" } ?? "")
        } else {
            online.isTableHost ? "WAITING FOR A CHALLENGER" : "WAITING ON THE HOST"
        }
        return TableCard(
            nextLine: nextLine,
            standings: table.standings.prefix(4).map { (name: name($0.playerID), wins: $0.wins) },
            isHost: online.isTableHost,
            // How the host's INVITE MORE went: the bay that usually shows
            // this is long gone.
            inviteNotice: online.isTableHost ? online.inviteNotice : nil
        )
    }

    private var leaveTitle: String {
        if mode == .warmup { return "Leave the Bay?" }
        if table != nil { return online.isTableHost ? "Close the Table?" : "Leave the Table?" }
        return "Leave Match?"
    }

    private var leaveButton: String {
        if mode == .warmup { return "Cancel Invite" }
        if table != nil { return online.isTableHost ? "Close Table" : "Leave Table" }
        return "Leave Match"
    }

    private var leaveMessage: String {
        if mode == .warmup { return "Leaving withdraws the invite or search." }
        if table != nil {
            if online.isTableHost { return "Closing the table ends it for everyone sitting at it." }
            return isSpectating || session.state.match.phase == .finished
                ? "You'll give up your place in line."
                : "Leaving forfeits this duel and your place in line."
        }
        return "Leaving disconnects you from the current Game Center match."
    }

    private var allowedBounces: Int {
        switch mode {
        case .solo, .doubles: tuning.allowedBouncesPerHit
        // Volleyball's floor is live and the hoop court has no faults at all;
        // both come off `SimulationConfiguration`, not the pilot's sliders.
        case .volleyball: 0
        case .basketball, .online, .warmup: 3
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
            // At an open table the loop is the table, and it carries on alone.
            if session.state.match.phase == .finished, table == nil {
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

    @State private var isShowingLog = false

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
                        .font(.caption2.weight(.bold)).foregroundStyle(statusColor)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                // The newest line of the link log, live, where the waiting
                // actually happens. A pilot sitting on JOINING MAYA… for a
                // minute should be able to see that the invite went out,
                // that she accepted, and what the app is waiting on now --
                // without the match having to fail first. Tapping opens the
                // whole transcript, which is the thing worth sending back
                // when something goes wrong on hardware.
                if let latest = online.eventLog.last {
                    Button { isShowingLog = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "list.bullet.rectangle").font(.system(size: 9))
                            Text(latest)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .lineLimit(1).minimumScaleFactor(0.6)
                        }
                        .foregroundStyle(.white.opacity(0.66))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .frame(maxWidth: 360)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Latest link event: \(latest). Open link log")
                    .accessibilityIdentifier("warmup-link-event")
                }
                if let notice = online.inviteNotice {
                    // Why nothing is happening, not a footnote about it. A
                    // build mismatch used to arrive here as one clipped
                    // yellow line between two scoreboards, which is the same
                    // as not saying it at all -- so it wraps, and it is
                    // boxed like the headline above it.
                    Text(notice)
                        .font(.caption2.monospaced().weight(.bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3).minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.7), lineWidth: 1))
                        .frame(maxWidth: 340)
                        .accessibilityIdentifier("invite-notice")
                }
            }
            // A container, not one combined element: the log button inside
            // it has to stay reachable.
            .accessibilityElement(children: .contain)
            .sheet(isPresented: $isShowingLog) {
                LinkLogView(transcript: online.linkTranscript(), events: online.eventLog)
            }
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
    let online: OnlineMatchCoordinator?
    /// Each colour's pilot by name, at an open table.
    var teamNames: [Team: String]? = nil
    /// Watching from the bench: neither side is YOU.
    var spectating = false
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
        let stake = state.match.stake(for: team)
        let isLocal = !spectating && team == localTeam
        let tag: String = isLocal ? "YOU" : (teamNames?[team] ?? (online == nil ? "CPU" : "OPP"))
        let side: String = if isLocal {
            "Your side, "
        } else if let name = teamNames?[team] {
            "\(name)'s side, "
        } else {
            "Rival side, "
        }
        return HStack(spacing: 12) {
            VStack(spacing: 3) {
                Image(systemName: team == .cyan ? "minus" : "diamond.fill").foregroundStyle(tint)
                Text(tag)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: 76)
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
            // Down arrows are bounces spent this possession. Touches are
            // free, so there is nothing to meter for them.
            HStack(spacing: 1) {
                ForEach(0..<allowedBounces, id: \.self) { index in
                    Image(systemName: "arrow.down")
                        .foregroundStyle(index < bounces ? tint.opacity(0.75) : .white.opacity(0.16))
                }
            }
            .font(.system(size: 10, weight: .black))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            side
                + "\(team.rawValue) score \(value), \(bounces) of \(allowedBounces) bounces used"
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
                    detail: "The net stands up out of the floor and covers the bottom half of the arena. Nothing goes through it — play it over the top. Touch it as often as you like, but the first time the ball touches the ground the rally is over."
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
    var title = "CHOOSE YOUR RIVAL"
    let choose: (AIDifficulty) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title.bold())
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
                    TutorialCard(number: "04", icon: "volleyball.fill", title: "SCORE", text: "The goal hangs from the roof, dead centre, and it is a portal. The face on your side is yours to defend: a ball that goes in through it is a point for the other side. Get the ball into their half, lifted, and into the face over there — or make them put it into their own. Clip the hard rounded bottom and it just bounces. Touch it as often as you like; three bounces on your floor between touches, and the fourth is theirs.")
                    TutorialCard(number: "05", icon: "tray.and.arrow.down.fill", title: "THE LIP", text: "A ledge juts out under each face and tilts inward: a ball that lands on the lip rolls straight into the portal. Skim the ball under the cap so it drops onto the far lip, and it is in. Above the goal the roof bulges with the same curve as the corners, so nothing rides the ceiling into the mouth. Neither the lip nor the bulge counts as a bounce.")
                    TutorialCard(number: "06", icon: "arrow.left.and.right.circle.fill", title: "CROSS", text: "Fly under the goal, or straight through the portal itself, to reach the opponent’s side — the net stops the ball, never your hull, so you can sit in the mouth and defend. You can fly as far as the colored MAX CROSS line.")
                    TutorialCard(number: "07", icon: "burst.fill", title: "NO WRECKS", text: "Nothing destroys your ship. Ground, walls, ceiling, the roof bulge and the other ship all rebound. Points are won on the ball alone: a goal or a fourth bounce. Touches are unlimited. After every set the teams switch sides and keep their colours, so everyone plays both halves.")
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
    @AppStorage(Soundscape.enabledKey) private var music = true
    @AppStorage("arrangePads") private var arrangePads = false
    @AppStorage(SteeringCurve.sensitivityKey) private var steeringSensitivity = 1.0
    @AppStorage(ShipHitbox.perHullKey) private var hullShapedHitboxes = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TuningSlider(
                        title: "Turning sensitivity",
                        value: $steeringSensitivity,
                        range: SteeringCurve.sensitivityRange,
                        step: 0.05,
                        readout: { "\(Int(($0 * 100).rounded()))%" }
                    )
                    .accessibilityIdentifier("turning-sensitivity")
                    Button("Reset to default") { steeringSensitivity = 1 }
                        .disabled(steeringSensitivity == 1)
                } header: {
                    Text("Steering")
                } footer: {
                    Text("Higher turns harder the moment you press the steering pad and needs less slide to reach a full turn. Top turning speed is the same at every setting.")
                }
                Toggle("Large controls", isOn: $largeControls)
                Toggle("Swap controls for left-handed play", isOn: $leftHanded)
                Toggle("Cluster controls to thumb side", isOn: $clusterControls)
                Toggle("Arrange pads (drag them in a match)", isOn: $arrangePads)
                Button("Reset pad layout") { UserDefaults.standard.removeObject(forKey: "padOffsets2") }
                Toggle("Haptics", isOn: $haptics)
                Toggle("Music", isOn: $music)
                    .onChange(of: music) { _, on in Soundscape.shared.enabled = on }
                LabeledContent("Reduced Motion", value: "Follows iOS Accessibility")
                Section("Match Rules") {
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
                    Text("Touches are unlimited. Bounces apply to solo matches; online uses three. Match length applies to solo matches and to any online match you host.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let replayIntro {
                    Section("Intro") {
                        Button("Replay intro", action: replayIntro)
                            .accessibilityIdentifier("replay-intro")
                    }
                }
                Section("Team symbols") { Label("Cyan uses a bar", systemImage: "minus"); Label("Orange uses a diamond", systemImage: "diamond.fill") }
                Section {
                    Toggle("Hull-shaped hitboxes", isOn: $hullShapedHitboxes)
                        .accessibilityIdentifier("hull-shaped-hitboxes")
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Off: every hull hits the ball with the Lancet's shape. On: each hull hits with its own outline. Takes effect next match; online matches always use the shared shape.")
                }
            }.navigationTitle("Settings")
        }
        .accessibilityIdentifier("settings-screen")
    }
}

/// The circuit's own sliders, in `RaceTuningView`. The court's flight
/// sliders are gone: the ship and ball are baked, and only the match rules
/// in Settings are a pilot's to change.
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

/// Paused, on the court. Resume, drop a fresh ball, or leave. The flight
/// sliders that used to live here are gone with the rest of the developer
/// tuning; the match flies the baked physics.
private struct CourtPauseOverlay: View {
    let restartDrop: () -> Void
    let resume: () -> Void
    let quit: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            VStack(spacing: 18) {
                Text("PAUSED")
                    .font(.title2.weight(.black)).tracking(4)
                    .foregroundStyle(.white)
                Button("Resume", action: resume)
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .accessibilityIdentifier("resume-button")
                Button("Restart Drop", action: restartDrop)
                    .buttonStyle(.bordered)
                Button("Quit", role: .destructive, action: quit)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("quit-match-paused")
            }
            .padding(28)
            .frame(maxWidth: 360)
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

/// The results card's view of an open table.
private struct TableCard {
    /// Who flies next and how soon, or what the table is waiting on.
    let nextLine: String
    /// Wins at this table, most first.
    let standings: [(name: String, wins: Int)]
    let isHost: Bool
    let inviteNotice: String?
}

private struct ResultsOverlay: View {
    let state: WorldState
    let localTeam: Team
    let plan: ResultsPlan
    /// Each colour's pilot by name, at an open table.
    var names: [Team: String]? = nil
    /// Watched from the bench: the card names the winner instead of YOU.
    var spectating = false
    /// Present at an open table: the next duel is coming, so the card says
    /// who is up instead of offering the menu.
    var table: TableCard? = nil
    /// Why the link ended, if it did.
    var notice: String? = nil
    let playAgain: () -> Void
    let challenge: () -> Void
    var inviteMore: () -> Void = {}
    let exit: () -> Void

    /// YOU on your side and RIVAL on theirs, or both pilots' names.
    private var sidesLabel: String {
        guard let names else { return "YOU — RIVAL" }
        let mine = spectating ? names[localTeam] ?? "CYAN" : "YOU"
        return "\(mine) — \(names[localTeam.opponent] ?? "RIVAL")"
    }

    private var headline: String {
        guard spectating else { return didLocalPlayerWin ? "YOU WIN" : "YOU LOSE" }
        let winner = state.match.winner
            ?? (state.match.score.cyan >= state.match.score.orange ? Team.cyan : .orange)
        return "\(names?[winner] ?? winner.rawValue.uppercased()) WINS"
    }

    var body: some View {
        VStack(spacing: 14) {
            Text(headline)
                .font(.caption.monospaced().bold()).tracking(3)
            // Yours first, in your colour, whichever colour you flew.
            if state.match.setsToWin > 1 {
                scoreLine(state.match.sets)
                Text("\(sidesLabel) · SETS · LAST SET \(state.match.score[localTeam])–\(state.match.score[localTeam.opponent])")
                    .font(.caption2.monospaced().weight(.semibold)).foregroundStyle(.secondary)
            } else {
                scoreLine(state.match.score)
                Text(sidesLabel)
                    .font(.caption2.monospaced().weight(.semibold)).foregroundStyle(.secondary)
            }
            if let notice {
                Text(notice.uppercased())
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            if let table {
                tableSection(table)
            } else {
                standardButtons
            }
        }
        .padding(30).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("results-screen")
    }

    /// Who is up next and the night's wins, with the table's own way out.
    private func tableSection(_ table: TableCard) -> some View {
        VStack(spacing: 10) {
            Text(table.nextLine)
                .font(.subheadline.monospaced().weight(.black)).tracking(1)
                .foregroundStyle(.yellow)
                .lineLimit(1).minimumScaleFactor(0.6)
                .accessibilityIdentifier("table-next-duel")
            if !table.standings.isEmpty {
                Text(table.standings.map { "\($0.name) \($0.wins)" }.joined(separator: " · "))
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .accessibilityLabel("Wins tonight: " + table.standings.map { "\($0.name) \($0.wins)" }.joined(separator: ", "))
            }
            if let inviteNotice = table.inviteNotice {
                Text(inviteNotice)
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(.orange)
                    .lineLimit(2).minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("table-invite-notice")
            }
            HStack(spacing: 10) {
                if table.isHost {
                    Button("INVITE MORE", action: inviteMore)
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        .accessibilityIdentifier("table-invite-more")
                }
                Button(table.isHost ? "CLOSE TABLE" : "LEAVE TABLE", action: exit)
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .accessibilityIdentifier("table-leave")
            }
        }
    }

    @ViewBuilder private var standardButtons: some View {
        VStack(spacing: 14) {
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
    }

    private func scoreLine(_ tally: Score) -> some View {
        let rival = localTeam.opponent
        let label: String = if spectating {
            "\(names?[localTeam] ?? "Cyan") \(tally[localTeam]), \(names?[rival] ?? "Orange") \(tally[rival])"
        } else {
            "You \(tally[localTeam]), rival \(tally[rival])"
        }
        return HStack(spacing: 18) {
            Text(tally[localTeam].formatted()).foregroundStyle(localTeam == .cyan ? Color.cyan : .orange)
            Text("—").foregroundStyle(.secondary)
            Text(tally[rival].formatted()).foregroundStyle(rival == .cyan ? Color.cyan : .orange)
        }
        .font(.system(size: 58, weight: .black, design: .rounded).monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var didLocalPlayerWin: Bool {
        if let winner = state.match.winner { return winner == localTeam }
        return state.match.score[localTeam] > state.match.score[localTeam.opponent]
    }
}

/// One line under the side badges at an open table: the bench's place in
/// line, or for the pilots flying, how many are waiting to play the winner.
private struct OpenTableBanner: View {
    let text: String
    let isWatching: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isWatching ? "eye.fill" : "person.3.fill")
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(size: 12, weight: .black, design: .monospaced)).tracking(1.2)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(isWatching ? .black : .yellow)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(isWatching ? Color.yellow : Color.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().stroke(.yellow.opacity(isWatching ? 0 : 0.7), lineWidth: 1))
        .accessibilityIdentifier("open-table-banner")
    }
}

private struct MenuButton: View {
    let title: String, subtitle: String, icon: String
    /// Half-width: no chevron, and the title shrinks before it truncates.
    var compact = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 10 : 16) {
                Image(systemName: icon).font(.title2).frame(width: compact ? 28 : 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline.weight(.black)).tracking(compact ? 0 : 1).lineLimit(1).minimumScaleFactor(0.6)
                    Text(subtitle).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.52)).lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
                if !compact { Image(systemName: "chevron.right") }
            }
            .padding(.horizontal, compact ? 14 : 20).frame(minHeight: 68)
            .contentShape(RoundedRectangle(cornerRadius: 18))
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
