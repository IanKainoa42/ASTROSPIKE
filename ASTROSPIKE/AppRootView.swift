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
    /// Incoming invites whose banner the pilot closed. They stay in INVITES;
    /// only the banner goes.
    @State private var shelvedInvites: Set<String> = []
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
        // `--arena diamond` picks the court the way the Settings picker does,
        // so each layout can be screenshotted without working the sheet.
        if let flag = arguments.firstIndex(of: "--arena"), arguments.indices.contains(flag + 1),
           let layout = ArenaLayout(rawValue: arguments[flag + 1]) {
            let store = FlightTuningStore()
            store.arenaLayout = layout
            _tuning = State(initialValue: store)
        }
        let warmupMode = arguments.contains("--warmup")
        let practiceMode = arguments.contains("--practice")
        // `--ffa 3` / `--ffa 4` drops onto the free-for-all field.
        let freeForAllPilots = arguments.firstIndex(of: "--ffa")
            .flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil }
        // `--astroball 2` / `--astroball 4` drops onto the volleyball court.
        let astroballPilots = arguments.firstIndex(of: "--astroball")
            .flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil }
        _resultsPreviewWinner = State(
            initialValue: arguments.contains("--results-win") ? .cyan
                : arguments.contains("--results-lose") ? .orange
                : nil
        )
        _gameMode = State(initialValue: diagnosticsPreviewMode ? .online
            : warmupMode ? .warmup
            : practiceMode ? .practice
            : resultsPreview ? .solo(.rookie)
            : doublesMode ? .doubles(.pilot)
            : freeForAllPilots.map { GameMode.freeForAll(pilots: $0, .pilot) }
            ?? astroballPilots.map { GameMode.astroball(pilots: $0, .pilot) }
            ?? (demoMode ? .solo(.pilot) : nil))
        // Automation and UI tests land on the home screen; a fresh install lands
        // on the intro.
        let lobbyMode = arguments.contains("--lobby")
        // `--track` drops straight onto the circuit, for the same reason
        // `--warmup` drops into the bay: the simulator cannot work a sheet.
        let trackMode = arguments.contains("--track")
        _showTrack = State(initialValue: trackMode)
        let bypass = demoMode || warmupMode || practiceMode || diagnosticsPreviewMode || lobbyMode || trackMode
            || freeForAllPilots != nil || astroballPilots != nil
            || resultsPreview
            || arguments.contains("--skip-onboarding")
        _showOnboarding = State(initialValue: !bypass && !PilotProfileStore().hasCompletedOnboarding)
        // `--lobby` opens the board straight away; the simulator cannot tap it.
        _sheet = State(initialValue: lobbyMode ? .lobby : nil)
        #if DEBUG
        // `--invite-preview` puts a sample ask in the inbox: no simulator can
        // receive one, and the banner and INVITES both need screenshots.
        if arguments.contains("--invite-preview") { _lobby = State(initialValue: LobbyService(previewInvites: true)) }
        #endif
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
                HomeView(online: online, profile: profile, invitesWaiting: lobby.standingInviteInbox.count, sheet: $sheet) { mode in
                    withAnimation(.easeOut(duration: 0.25)) { gameMode = mode }
                }
                .transition(.opacity)
            }
            if showsReturnBanner, let ticket = online.returnTicket {
                ReturnToMatchBanner(ticket: ticket) {
                    online.returnToMatch()
                } dismiss: {
                    withAnimation(.easeOut(duration: 0.2)) { online.forgetReturn() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if let invite = bannerInvite {
                IncomingInviteBanner(invite: invite) {
                    shelvedInvites.insert(invite.id)
                    lobby.answerStandingInvite(invite, accept: true, using: online)
                } later: {
                    withAnimation(.easeOut(duration: 0.2)) { _ = shelvedInvites.insert(invite.id) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: bannerInvite?.id)
        // Invites arrive in the app, not only as Apple's banner: while the
        // pilot is on the menus or in the bay, look for new asks and for an
        // answer to the one this pilot is waiting on.
        .task(id: isWatchingInvites) {
            guard isWatchingInvites else { return }
            while !Task.isCancelled {
                await lobby.refresh()
                lobby.watchInGameInvite(using: online)
                try? await Task.sleep(for: .seconds(LobbyService.pollSeconds))
            }
        }
        .onChange(of: online.meetingTag) { _, _ in syncLobbyActivity() }
        // The pilot asked said no on Apple's banner: close the standing ask
        // behind it, or the lobby keeps showing it as waiting.
        .onChange(of: online.refusedInvite) { _, refusal in
            if let refusal { lobby.liveInviteRefused(refusal) }
        }
        // Holding a dropped pilot's chair: watch for them searching their
        // way back in, and open the chair to them when they are.
        .task(id: isWatchingReturns) {
            guard isWatchingReturns else { return }
            while !Task.isCancelled {
                await lobby.refresh()
                lobby.watchSeatReturns(using: online)
                try? await Task.sleep(for: .seconds(LobbyService.pollSeconds))
            }
        }
        .preferredColorScheme(.dark)
        .task {
            online.localHull = profile.selectedHull
            online.preferredTuning = tuning.snapshot
            lobby.localHull = profile.selectedHull
            if diagnosticsPreview == nil {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--return-preview") { online.previewReturn() }
                if ProcessInfo.processInfo.arguments.contains("--joining-preview") {
                    online.previewMatchmaking(headline: PlayerNetworkCopy.Matchmaking.joining("Ian"))
                    return
                }
                if ProcessInfo.processInfo.arguments.contains("--inviting-preview") {
                    online.previewMatchmaking(
                        headline: PlayerNetworkCopy.Matchmaking.waiting(for: ["Noa"]),
                        waitingOn: "gc:preview-out"
                    )
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
            case .active:
                lobby.start()
                online.cameBack()
            case .background:
                // Suspended mid-match, the link goes and the others hold the
                // chair. Keep what it takes to come back to it.
                if gameMode == .online { online.stepAway() }
                lobby.stop()
            default: break
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .duel, .doubles, .freeForAll, .astroball:
                GameSheet(game: item, online: online, lobby: lobby) { pilots, difficulty in
                    sheet = nil
                    gameMode = switch item {
                    case .doubles: .doubles(difficulty)
                    case .freeForAll: .freeForAll(pilots: pilots, difficulty)
                    case .astroball: .astroball(pilots: pilots, difficulty)
                    default: .solo(difficulty)
                    }
                } quickMatch: {
                    sheet = nil
                    online.startQuickMatch()
                } openLobby: {
                    sheet = .lobby
                } openPicker: { format in
                    sheet = nil
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        online.presentFriendInvite(format: format)
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
                InviteSheet(online: online, lobby: lobby, format: .addToTable) { _ in }
                    .presentationDetents([.medium, .large])
            case .stats:
                StatsSheet()
                    .presentationDetents([.medium, .large])
            case .invite:
                InviteSheet(online: online, lobby: lobby) { format in
                    sheet = nil
                    // Let the sheet finish dismissing before Game Center's own
                    // picker takes the top of the stack.
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        online.presentFriendInvite(format: format)
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
        case .solo, .doubles, .practice, .astroball, .basketball, .freeForAll: .solo
        case nil: if case .matching = online.status { .matching } else { .idle }
        }
        // While hosting an in-game invite, the presence names it: that is
        // how the guest's JOIN knows to meet this pilot in the pool.
        lobby.setActivity(activity, matchID: activity == .playing ? lobby.hostedDuel?.id
                          : activity == .matching ? online.meetingTag : nil)
    }

    private var isWatchingReturns: Bool {
        scenePhase == .active && online.holdGroup != nil
    }

    /// RETURN TO MATCH on the menus, while the chair is still held.
    private var showsReturnBanner: Bool {
        guard gameMode == nil, sheet == nil, !showOnboarding, !showTrack, online.canReturnToMatch else { return false }
        if case .matching = online.status { return false }
        return true
    }

    private var isWatchingInvites: Bool {
        scenePhase == .active && !showTrack && (gameMode == nil || gameMode == .warmup)
    }

    /// The newest ask the pilot has not closed, while they are on the home
    /// screen with nothing over it.
    private var bannerInvite: StandingInvite? {
        guard gameMode == nil, sheet == nil, !showOnboarding, !showTrack, !showsReturnBanner else { return nil }
        if case .matching = online.status { return nil }
        return lobby.standingInviteInbox.first { !shelvedInvites.contains($0.id) }
    }

    /// The host puts the duel on the lobby's board as soon as the table is
    /// seated. Doubles is recorded as its two leads; the ring has no sides
    /// for the board, so it is not put up.
    private func announceHostedDuel() {
        let names = online.seatedPilotNames
        guard !online.isFreeForAll,
              let cyanID = online.seating.first(where: { $0.value == .cyan })?.key,
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
    case duel, doubles, freeForAll, astroball, tutorial, settings, hangar, invite, tableInvite, lobby, modes, stats
    var id: String { rawValue }
}

/// Every game asks the same one question: who you play. Bots (their level,
/// and how many where that varies), friends over Game Center, or for a duel
/// anyone online. The rules live in HOW TO FLY, not here.
private struct GameSheet: View {
    let game: MenuSheet
    let online: OnlineMatchCoordinator
    let lobby: LobbyService
    let startBots: (_ pilots: Int, AIDifficulty) -> Void
    let quickMatch: () -> Void
    let openLobby: () -> Void
    let openPicker: (_ format: OnlineFormat) -> Void
    @State private var who: Who?
    @State private var pilots: Int

    private enum Who { case bots, friends }

    init(
        game: MenuSheet, online: OnlineMatchCoordinator, lobby: LobbyService,
        startBots: @escaping (_ pilots: Int, AIDifficulty) -> Void,
        quickMatch: @escaping () -> Void, openLobby: @escaping () -> Void,
        openPicker: @escaping (_ format: OnlineFormat) -> Void
    ) {
        self.game = game
        self.online = online
        self.lobby = lobby
        self.startBots = startBots
        self.quickMatch = quickMatch
        self.openLobby = openLobby
        self.openPicker = openPicker
        _pilots = State(initialValue: game == .freeForAll ? 3 : 2)
    }

    /// Identifier stem; the UI tests key on these.
    private var key: String {
        switch game {
        case .doubles: "doubles"
        case .freeForAll: "ffa"
        case .astroball: "astroball"
        default: "duel"
        }
    }

    private var title: String {
        switch game {
        case .doubles: "DOUBLES"
        case .freeForAll: "ASTROPUCK"
        case .astroball: "ASTROBALL"
        default: "DUEL"
        }
    }

    private var tagline: String {
        switch game {
        case .doubles: "Two a side on the big court, two balls in play."
        case .freeForAll: "Three or four pilots on an air-hockey ring. Five lives each; the last one flying wins."
        case .astroball: "Volleyball in zero-g. Three touches a side; let the ball touch your zone and the point goes across."
        default: "One on one across the court."
        }
    }

    private var botsDetail: String {
        switch game {
        case .doubles: "A bot on your wing against two bots."
        case .freeForAll: "Every other chair a bot."
        case .astroball: "One on one, or two a side with a bot beside you."
        default: "A bot across the court."
        }
    }

    private var friendsDetail: String {
        switch game {
        case .doubles: "Invite a pilot to your side. Bots fill the far half, or invite three."
        case .freeForAll, .astroball: "Invite up to three. Bots fill the seats nobody takes."
        default: "Invite a pilot, or answer an invite."
        }
    }

    var body: some View {
        switch who {
        case nil:
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.title.bold())
                Text(tagline).font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    choice("VS BOTS", detail: botsDetail, icon: "cpu", identifier: "\(key)-bots") { who = .bots }
                    choice("WITH FRIENDS", detail: friendsDetail, icon: "person.2.wave.2.fill", identifier: "\(key)-friends") { who = .friends }
                    if game == .duel {
                        choice("ANYONE ONLINE", detail: "Matched with the next pilot looking.",
                               icon: "bolt.horizontal.circle.fill", identifier: "duel-anyone", action: quickMatch)
                    }
                }
                if game == .duel {
                    Button(action: openLobby) {
                        Label("LOBBY · WHO'S ONLINE, LIVE DUELS, BRACKETS", systemImage: "person.3.fill")
                            .font(.caption.monospaced().weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("duel-lobby")
                }
            }
            // No identifier on the container: it would shadow the buttons'
            // own, and the tests that drive this sheet key on those.
            .padding(28)
        case .bots:
            VStack(alignment: .leading, spacing: 16) {
                if game == .freeForAll || game == .astroball {
                    Text(title).font(.title.bold())
                    Picker("Pilots", selection: $pilots) {
                        if game == .freeForAll {
                            Text("3 PILOTS").tag(3)
                            Text("4 PILOTS").tag(4)
                        } else {
                            Text("1 V 1").tag(2)
                            Text("2 V 2").tag(4)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("\(key)-pilots")
                }
                DifficultyPicker(title: game == .duel ? "CHOOSE YOUR RIVAL" : "CHOOSE THE BOTS") { startBots(pilots, $0) }
                    .padding(-28)
                    .padding(.top, game == .freeForAll || game == .astroball ? 28 : 0)
            }
            .padding(28)
        case .friends:
            switch game {
            case .doubles: InviteSheet(online: online, format: .teamUp, openPicker: openPicker)
            case .freeForAll: InviteSheet(online: online, format: .freeForAll, openPicker: openPicker)
            case .astroball: InviteSheet(online: online, format: .astroball, openPicker: openPicker)
            default: InviteSheet(online: online, lobby: lobby, openPicker: openPicker)
            }
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

/// Free-for-all colours, as the court draws them.
@MainActor private func freeForAllColor(_ seat: Seat) -> Color {
    Color(uiColor: ArenaScene.freeForAllColor(for: seat))
}

/// One chip per pilot, in seat order: colour, name, lives.
@MainActor private struct FreeForAllHUD: View {
    let state: WorldState
    let localSeat: Seat?
    /// Who each seat is: a pilot's name online, the seat's colour for a bot.
    let name: @MainActor (Seat) -> String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let field = state.freeForAll {
                ForEach(field.bays, id: \.self) { seat in
                    chip(seat, lives: field.lives[seat] ?? 0)
                }
            }
            Spacer()
            Button(action: action) {
                Image(systemName: "pause.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.45), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.25)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pause match")
            .accessibilityIdentifier("match-action-button")
        }
        .padding(.horizontal, 24).padding(.top, 10)
    }

    private func chip(_ seat: Seat, lives: Int) -> some View {
        let color = freeForAllColor(seat)
        let out = lives <= 0
        return HStack(spacing: 5) {
            Text(seat == localSeat ? "YOU" : name(seat))
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .lineLimit(1)
            if out {
                Text("OUT").font(.system(size: 10, weight: .black, design: .monospaced))
            } else {
                HStack(spacing: 2) {
                    ForEach(0 ..< FreeForAllState.startingLives, id: \.self) { index in
                        Circle()
                            .fill(index < lives ? color : .white.opacity(0.15))
                            .frame(width: 6, height: 6)
                    }
                }
            }
        }
        .foregroundStyle(out ? .white.opacity(0.4) : color)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(.black.opacity(0.5), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(out ? 0.2 : seat == localSeat ? 0.9 : 0.4), lineWidth: seat == localSeat ? 1.5 : 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name(seat)), \(out ? "out" : "\(lives) lives")")
    }
}

/// The free-for-all's last card: the field in finishing order. Also shown
/// the moment the local pilot is knocked out, with WATCH to see the rest.
@MainActor private struct FreeForAllResults: View {
    let state: WorldState
    let localSeat: Seat?
    /// Who each seat is: a pilot's name online, the seat's colour for a bot.
    let name: @MainActor (Seat) -> String
    /// First out first.
    let knockedOut: [Seat]
    /// Whose numbers the stat line shows; nil hides it (the bench).
    var statSeat: Seat? = nil
    /// Boards this match set a personal best on.
    var newBests: Set<StatBoard> = []
    let watch: (() -> Void)?
    /// Nil online: the ring cannot be re-seated from one board.
    let playAgain: (() -> Void)?
    let exit: () -> Void

    private var standings: [Seat] {
        guard let field = state.freeForAll else { return [] }
        let flying = field.standing
        return flying + knockedOut.reversed().filter { !flying.contains($0) }
    }

    private var title: String {
        if let winner = state.freeForAll?.winner {
            return winner == localSeat ? "YOU WIN" : "\(name(winner)) WINS"
        }
        return "YOU'RE OUT"
    }

    var body: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.system(size: 34, weight: .black, design: .rounded)).tracking(2)
            VStack(spacing: 6) {
                ForEach(Array(standings.enumerated()), id: \.element) { place, seat in
                    HStack {
                        Text(Self.ordinal(place + 1)).frame(width: 44, alignment: .leading)
                        Text(seat == localSeat ? "YOU" : name(seat)).lineLimit(1)
                        Spacer()
                        if state.freeForAll?.isOut(seat) == false, state.freeForAll?.winner == nil {
                            Text("FLYING").foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 15, weight: .black, design: .monospaced))
                    .foregroundStyle(freeForAllColor(seat))
                }
            }
            .frame(maxWidth: 280)
            // The pilot's own match in numbers, once it is over: while they
            // watch the rest of the field the book is still being written.
            if let statSeat, state.match.phase == .finished {
                MatchStatLine(stats: state.stats, seat: statSeat, newBests: newBests)
            }
            HStack(spacing: 12) {
                if let watch {
                    Button("WATCH", action: watch).buttonStyle(.bordered).tint(.white)
                        .accessibilityIdentifier("ffa-watch")
                }
                if let playAgain {
                    Button("PLAY AGAIN", action: playAgain).buttonStyle(.borderedProminent).tint(.cyan)
                        .accessibilityIdentifier("ffa-play-again")
                }
                if playAgain == nil {
                    Button("EXIT", action: exit).buttonStyle(.borderedProminent).tint(.cyan)
                        .accessibilityIdentifier("ffa-exit")
                } else {
                    Button("EXIT", action: exit).buttonStyle(.bordered).tint(.white)
                        .accessibilityIdentifier("ffa-exit")
                }
            }
            .font(.headline)
        }
        .padding(28)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.2)))
        .accessibilityIdentifier("ffa-results")
    }

    static func ordinal(_ n: Int) -> String {
        switch n {
        case 1: "1ST"
        case 2: "2ND"
        case 3: "3RD"
        default: "\(n)TH"
        }
    }
}

/// How the invited pilots play.
private enum InviteFormat: Hashable {
    /// One pilot, across the net.
    case duel
    /// Up to three on your side against bots, or two a side.
    case teamUp
    /// Up to three round the ring with you, bots in the chairs nobody takes.
    case freeForAll
    /// Up to three on the volleyball court with you, bots in the seats
    /// nobody takes.
    case astroball
    /// Ask up to five at once. The first to join flies you; everyone after
    /// watches the game in progress and flies the next: three is two
    /// against one and a bot, four is two a side.
    case openTable
    /// The host of a running open table asking more pilots to the bench.
    case addToTable

    /// How many pilots can be picked in one go. A duel invites on the tap.
    var pickLimit: Int {
        switch self {
        case .duel: 1
        case .teamUp, .freeForAll, .astroball: 3
        case .openTable, .addToTable: OpenTable.maxInvitees
        }
    }

    /// What the match is called as on the wire. A table is seated as duels.
    var online: OnlineFormat {
        switch self {
        case .teamUp: .teamUp
        case .freeForAll: .freeForAll
        case .astroball: .astroball
        case .duel, .openTable, .addToTable: .duel
        }
    }
}

private struct InviteSheet: View {
    let online: OnlineMatchCoordinator
    /// The INVITES hub: asks waiting on this pilot, asks out, and who is in
    /// the app now. Nil for team-up and free-for-all, which only send.
    var lobby: LobbyService?
    /// Apple's picker, for the format on show.
    let openPicker: (_ format: OnlineFormat) -> Void
    @State private var format: InviteFormat
    @State private var picked: Set<String> = []
    /// ASTROBALL only: who your friends fly with.
    @State private var astroballSides = AstroballSides.versus
    @Environment(\.dismiss) private var dismiss

    init(online: OnlineMatchCoordinator, lobby: LobbyService? = nil, format: InviteFormat = .duel, openPicker: @escaping (_ format: OnlineFormat) -> Void) {
        self.online = online
        self.lobby = lobby
        self.openPicker = openPicker
        _format = State(initialValue: format)
    }

    private var isPicking: Bool { format != .duel }

    /// Room left at a running table; the whole limit otherwise.
    private var pickLimit: Int {
        guard format == .addToTable, let table = online.openTable else { return format.pickLimit }
        return max(0, OpenTable.maxPilots - table.pilots.count)
    }

    private var guidance: String {
        switch format {
        case .duel: "Pick a pilot. If they are in the app it rings in game; if not, the ask keeps for a day and Game Center taps them."
        case .teamUp: "Pick up to three. The first flies beside you against two bots; four pilots make it two a side."
        case .freeForAll: "Pick up to three. Everyone gets a net and five lives on the ring; two of you fly against a bot, four fill the ring. Your ring settings fly on every phone."
        case .astroball: switch astroballSides {
            case .versus: "Pick up to three. Two a side: one friend flies across the net and you each get a bot on your wing; bots take any empty seat. Your ASTROBALL settings fly on every phone."
            case .together: "Pick up to three. The first flies on your side against two bots; four pilots make it two a side. Your ASTROBALL settings fly on every phone."
            case .duel: "Pick one for a duel across the net. Two or three make it two a side, a bot in any empty seat. Your ASTROBALL settings fly on every phone."
            }
        case .openTable: "Pick up to five. The first to join starts a duel with you; anyone after watches the game in progress, then everyone flies the next: three is two against one and a bot, four is two a side. Past four, winners stay on."
        case .addToTable: "They watch the game in progress and fly the next one. Past four pilots, they wait their turn on the bench."
        }
    }

    private var title: String {
        switch format {
        case .duel: lobby == nil ? "INVITE A PILOT" : "INVITES"
        case .teamUp: "TEAM UP"
        case .freeForAll: "ASTROPUCK"
        case .astroball: "ASTROBALL"
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
                            Text("RING").tag(InviteFormat.freeForAll)
                            Text("BALL").tag(InviteFormat.astroball)
                            Text("OPEN TABLE").tag(InviteFormat.openTable)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("invite-format")
                    }
                    if format == .astroball {
                        Picker("Sides", selection: $astroballSides) {
                            Text("1 V 1").tag(AstroballSides.duel)
                            Text("2 V 2").tag(AstroballSides.versus)
                            Text("TEAM UP").tag(AstroballSides.together)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("invite-astroball-sides")
                    }
                    Text(guidance)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let lobby, format != .addToTable {
                    InviteHubSections(lobby: lobby, online: online)
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
                            guard isPicking else {
                                // Through the lobby, so a pilot who is in the
                                // app gets it in game, not as Apple's banner.
                                if let lobby {
                                    lobby.inviteAnytime(pilotID: player.gamePlayerID, name: player.displayName, using: online)
                                } else {
                                    online.invite([player])
                                }
                                return
                            }
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
                        .accessibilityIdentifier(format == .teamUp ? "invite-team-up-send"
                            : format == .freeForAll ? "invite-free-for-all-send"
                            : format == .astroball ? "invite-astroball-send" : "invite-open-table-send")
                    } footer: {
                        if format == .openTable {
                            Text("Everyone gets the invite at once, so nobody waits on the slowest phone.")
                        }
                    }
                }
                // Apple's picker seats whoever it returns in one go, so it
                // has no bench to put a late arrival on.
                if format == .duel || format == .teamUp || format == .freeForAll || format == .astroball {
                    Section {
                        Button { openPicker(onlineFormat) } label: {
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

    private var onlineFormat: OnlineFormat {
        guard format == .astroball else { return format.online }
        return switch astroballSides {
        case .duel: .astroball
        case .versus: .astroballDoubles
        case .together: .astroballTeamUp
        }
    }

    private var sendLabel: String {
        guard !picked.isEmpty else { return format == .teamUp ? "PICK A TEAMMATE" : "PICK PILOTS" }
        switch format {
        case .teamUp: return "SEND TEAM-UP (\(picked.count))"
        case .freeForAll: return "SEND ASTROPUCK (\(picked.count))"
        case .astroball: return "SEND ASTROBALL (\(picked.count))"
        case .addToTable: return "INVITE TO THE TABLE (\(picked.count))"
        case .duel, .openTable: return "OPEN THE TABLE (\(picked.count))"
        }
    }

    private func send() {
        let players = online.inviteCandidates(forTable: format == .addToTable)
            .filter { picked.contains($0.gamePlayerID) }
        switch format {
        case .duel: break
        case .teamUp: online.invite(players, format: .teamUp)
        case .freeForAll: online.invite(players, format: .freeForAll)
        case .astroball: online.invite(players, format: onlineFormat)
        case .openTable: online.openTable(inviting: players)
        case .addToTable:
            online.inviteToTable(players)
            dismiss()
        }
    }
}

/// ASTROBALL invites: a duel, a friend across the net, or a friend beside you.
private enum AstroballSides { case duel, versus, together }

/// The in-game half of INVITES: answer what is waiting, see what is out,
/// and ask whoever is in the app right now.
private struct InviteHubSections: View {
    let lobby: LobbyService
    let online: OnlineMatchCoordinator

    var body: some View {
        let inbox = lobby.standingInviteInbox
        let outbox = lobby.standingInviteOutbox
        let localID = lobby.localID ?? ""
        let pilots = lobby.snapshot.onlinePilots(at: .now, friends: lobby.friends, excluding: localID)
        if let word = lobby.inviteNotice {
            Section {
                Label(word, systemImage: "person.crop.circle.badge.xmark")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("invites-notice")
            }
        }
        if !inbox.isEmpty {
            Section("WAITING ON YOU · \(inbox.count)") {
                ForEach(inbox) { invite in
                    StandingInviteRow(invite: invite, isWaitingOnMe: true) {
                        lobby.answerStandingInvite(invite, accept: true, using: online)
                    } decline: {
                        lobby.answerStandingInvite(invite, accept: false, using: online)
                    }
                }
            }
            .accessibilityIdentifier("invites-incoming")
        }
        if !outbox.isEmpty {
            Section("SENT · \(outbox.count)") {
                ForEach(outbox) { invite in
                    StandingInviteRow(invite: invite, isWaitingOnMe: false) {} decline: {
                        Task { await lobby.withdrawStandingInvite(invite) }
                    }
                }
            }
            .accessibilityIdentifier("invites-sent")
        }
        if !pilots.isEmpty {
            Section("IN THE APP NOW · \(pilots.count)") {
                ForEach(pilots) { pilot in
                    PilotRow(
                        pilot: pilot,
                        isFriend: lobby.friends.contains(pilot.id),
                        duel: lobby.snapshot.liveMatches(at: .now).first { $0.involves(pilot.id) },
                        isInvited: lobby.hasStandingInvite(to: pilot.id)
                    ) { format in
                        lobby.inviteAnytime(pilotID: pilot.id, name: pilot.name, format: format, using: online)
                    }
                }
            }
        }
    }
}

/// An ask that arrived while the pilot was on the home screen. JOIN answers
/// it; the X only puts the banner away, and the ask stays in INVITES.
/// The match this pilot left is still holding their chair.
private struct ReturnToMatchBanner: View {
    let ticket: SeatReturnTicket
    let rejoin: () -> Void
    let dismiss: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = ticket.secondsLeft(at: context.date)
            HStack(spacing: 14) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.title2.weight(.bold)).foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VS \(ticket.opponentNames.joined(separator: " & ").uppercased())")
                        .font(.headline.weight(.black)).lineLimit(1)
                    Text(left > 0 ? "YOUR CHAIR IS HELD · \(left)s" : "THE HOLD RAN OUT")
                        .font(.caption2.monospaced().weight(.bold)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 12)
                Button(action: left > 0 ? rejoin : dismiss) {
                    Text(left > 0 ? "RETURN TO MATCH" : "OK")
                        .font(.callout.weight(.bold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent).tint(.cyan)
                .accessibilityIdentifier("return-banner-rejoin")
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.callout.weight(.bold)).frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered).tint(.secondary)
                .accessibilityLabel("Leave the match")
                .accessibilityIdentifier("return-banner-dismiss")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: 560)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.cyan.opacity(0.45)))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("return-banner")
    }
}

private struct IncomingInviteBanner: View {
    let invite: StandingInvite
    let join: () -> Void
    let later: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            HullBadge(hull: invite.hostHull, team: .orange).frame(width: 34, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(invite.hostName.uppercased()).font(.headline.weight(.black))
                Text("WANTS A \(invite.matchLabel)").font(.caption2.monospaced().weight(.bold)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 12)
            Button(action: join) {
                Label("JOIN", systemImage: "bolt.horizontal.fill").font(.callout.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent).tint(.cyan)
            .accessibilityIdentifier("invite-banner-join")
            Button(action: later) {
                Image(systemName: "xmark").font(.callout.weight(.bold)).frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered).tint(.secondary)
            .accessibilityLabel("Not now")
            .accessibilityIdentifier("invite-banner-later")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: 460)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.cyan.opacity(0.45)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("invite-banner")
    }
}

/// Landscape windows narrower than this inside the safe area get the tight
/// layouts: iPhone Duo's folded outer display (595pt; its 678pt window
/// loses 83 to the camera). Every iPhone since the 11 is 734 or wider.
/// A width, not a size class: the Duo's displays are both compact.
private let narrowWindowWidth: CGFloat = 700

private struct HomeView: View {
    let online: OnlineMatchCoordinator
    let profile: PilotProfileStore
    /// Asks waiting on this pilot, shown on the INVITES tile.
    var invitesWaiting = 0
    @Binding var sheet: MenuSheet?
    let startGame: (GameMode) -> Void

    var body: some View {
        GeometryReader { geometry in
            // iPhone Duo's inner display turned on its side hands the app a
            // portrait window (see OrientationPolicy): the brand stacks over
            // the menu there instead of both squeezing into one short row.
            let portrait = geometry.size.height > geometry.size.width
            // iPhone Duo's folded outer display is 595pt wide inside the
            // safe area (an iPhone 17 is 734): the wordmark drops to two
            // lines and the menu tightens so both still sit side by side.
            let narrow = !portrait && geometry.size.width < narrowWindowWidth
            let hPad = narrow ? 20 : max(36, geometry.size.width * 0.07)
            let vPad = narrow ? 16 : max(24, geometry.size.height * 0.08)
            Group {
                if portrait {
                    VStack(alignment: .leading, spacing: 10) {
                        // The title font stays on the brand: the menu rows
                        // leave their chevron to inherit, and 58pt is too much.
                        brandBlock(narrow: false).font(titleFont(for: geometry, narrow: false))
                        Spacer(minLength: 18)
                        menu(narrow: false).frame(maxWidth: 430)
                        Spacer(minLength: 18)
                        hullBlock(narrow: false)
                    }
                } else {
                    let spacing = narrow ? 16 : min(52, geometry.size.width * 0.055)
                    // The menu takes its width first and the brand gets the
                    // rest: the title scales down, the menu tiles never
                    // truncate. The brand keeps 220pt (176 on the Duo's
                    // outer display: ASTRO on one 48pt line), enough for
                    // the tagline on one line.
                    let menuWidth = min(430, geometry.size.width - hPad * 2 - spacing - (narrow ? 176 : 220))
                    HStack(spacing: spacing) {
                        VStack(alignment: .leading, spacing: 10) {
                            brandBlock(narrow: narrow)
                            Spacer()
                            hullBlock(narrow: narrow)
                        }
                        .font(titleFont(for: geometry, narrow: narrow))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        menu(narrow: narrow).frame(width: menuWidth)
                    }
                }
            }
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
        }
    }

    private func titleFont(for geometry: GeometryProxy, narrow: Bool) -> Font {
        .system(size: min(narrow ? 48 : 58, geometry.size.height * (narrow ? 0.11 : 0.13)),
                weight: .black, design: .rounded)
    }

    /// Title, tagline and the two team marks.
    private func brandBlock(narrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if narrow {
                // On one line beside the menu the wordmark would shrink to
                // half its size; two lines keep it big.
                VStack(alignment: .leading, spacing: -8) {
                    Text("ASTRO").foregroundStyle(.cyan)
                    Text("SPIKE").foregroundStyle(.orange)
                }
                .lineLimit(1).minimumScaleFactor(0.9)
            } else {
                (Text("ASTRO").foregroundStyle(.cyan) + Text("SPIKE").foregroundStyle(.orange))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .allowsTightening(true)
            }
            Text("ZERO-G. ONE NET. NO BRAKES.")
                .font(narrow ? .caption2.weight(.bold) : .caption.weight(.bold))
                .tracking(narrow ? 1.6 : 2.4)
                .lineLimit(narrow ? 2 : 1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.white.opacity(0.62))
            Spacer().frame(height: narrow ? 8 : 14)
            TeamMarkRow()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    /// The hangar button and the Game Center status line.
    private func hullBlock(narrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { sheet = .hangar } label: {
                HStack(spacing: 12) {
                    HullBadge(hull: profile.selectedHull, team: .cyan).frame(width: 48, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("YOUR HULL").font(.caption2.monospaced().weight(.bold)).tracking(2)
                            .foregroundStyle(.white.opacity(0.5))
                        Text(profile.selectedHull.spec.name.uppercased())
                            .font(.headline.weight(.black)).tracking(1).foregroundStyle(.cyan)
                            .lineLimit(1).minimumScaleFactor(0.7)
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
                .foregroundStyle(statusColor).lineLimit(2)
        }
    }

    private func menu(narrow: Bool) -> some View {
        VStack(spacing: narrow ? 10 : 12) {
            // Pick the game; its sheet asks who you play.
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    MenuButton(title: "DUEL", subtitle: "ONE ON ONE", icon: "person.fill", narrow: narrow, tile: true) { sheet = .duel }
                    MenuButton(title: "DOUBLES", subtitle: "TWO A SIDE", icon: "person.2.fill", narrow: narrow, tile: true) { sheet = .doubles }
                }
                GridRow {
                    MenuButton(title: "ASTROPUCK", subtitle: "3-4 PILOTS", icon: "person.3.fill", narrow: narrow, tile: true) { sheet = .freeForAll }
                    MenuButton(title: "ASTROBALL", subtitle: "VOLLEYBALL", icon: "volleyball.fill", narrow: narrow, tile: true) { sheet = .astroball }
                }
            }
            // Only when someone is waiting on an answer: asking lives in
            // each game's WITH FRIENDS.
            if invitesWaiting > 0 {
                MenuButton(
                    title: "INVITES",
                    subtitle: "\(invitesWaiting) WAITING ON YOU",
                    icon: "envelope.badge.fill",
                    narrow: narrow
                ) { sheet = .invite }
            }
            if online.canRematch {
                MenuButton(
                    title: "REMATCH",
                    subtitle: rematchSubtitle,
                    icon: "arrow.triangle.2.circlepath",
                    narrow: narrow
                ) { online.rematch() }
            }
            // One row: a second row of tiles ran off the bottom of an
            // iPhone in landscape (SETTINGS and STATS were half cut).
            HStack(spacing: 8) {
                SmallMenuButton(title: "PRACTICE", icon: "scope") { startGame(.practice) }
                SmallMenuButton(title: "HANGAR", icon: "airplane.circle") { sheet = .hangar }
                SmallMenuButton(title: "HOW TO FLY", icon: "questionmark.circle") { sheet = .tutorial }
                SmallMenuButton(title: "SETTINGS", icon: "slider.horizontal.3") { sheet = .settings }
                SmallMenuButton(title: "STATS", icon: "trophy") { sheet = .stats }
            }
        }
    }

    private var statusColor: Color {
        switch online.status {
        case .connected, .ready: .green
        case .failed: .orange
        case .authenticating, .matching, .reconnecting: .yellow
        case .signedOut: .white.opacity(0.6)
        }
    }

    private var rematchSubtitle: String {
        let names = online.lastMatchOpponents.map(\.displayName)
        if names.isEmpty { return "RE-INVITE LAST OPPONENT" }
        if names.count == 1 { return "DUEL \(names[0].uppercased()) AGAIN" }
        return "PLAY \(names.joined(separator: ", ").uppercased()) AGAIN"
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
    /// Knocked out of a free-for-all and chose to watch the rest.
    @State private var watchingField = false
    @State private var showLeaveConfirmation = false
    /// `--emote-tray` opens it on arrival, for layout screenshots.
    @State private var emoteTrayOpen = ProcessInfo.processInfo.arguments.contains("--emote-tray")
    /// Set when the local side scores, so the emote button invites a taunt.
    @State private var emoteNudge = false
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
        case .solo, .doubles, .freeForAll, .astroball: tuning.configuration
        case .basketball: SimulationConfiguration.basketball(from: tuning.configuration)
        // The host's sliders reach the guest with the seating plan; the host
        // seeded them from its own store, so both read the same numbers.
        case .online: online.format.isAstroball
            ? .astroball(from: online.hostTuning.configuration, tuning: online.hostTuning.astroball)
            : online.hostTuning.configuration
        case .warmup, .practice: SimulationConfiguration.warmup(from: tuning.configuration)
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
                if mode.isBay {
                    WarmupHUD(session: session, online: mode == .warmup ? online : nil) {
                        // A search that already ended (every invite refused)
                        // has nothing left to cancel: no dialog, just out.
                        if mode == .warmup, case .failed = online.status { leaveGame() } else { showLeaveConfirmation = true }
                    }
                } else if session.isFreeForAll {
                    FreeForAllHUD(state: session.state, localSeat: session.localSeat, name: session.callSign) {
                        if mode.isOffline {
                            if !session.isPaused { session.togglePause() }
                            showPause = true
                        } else {
                            // Online there is no pause: the ring plays on.
                            showLeaveConfirmation = true
                        }
                    }
                } else {
                    MatchHUD(
                        state: session.state,
                        localTeam: localTeam,
                        allowedBounces: allowedBounces,
                        touchLimits: session.touchLimits,
                        // The diagnostics preview is a staged snapshot with
                        // no Game Center behind it; handing the HUD the live
                        // coordinator would print GAME CENTER OFFLINE under it.
                        online: mode == .online && diagnosticsOverride == nil ? online : nil,
                        teamNames: courtNames,
                        spectating: isSpectating,
                        narrow: geometry.size.width < narrowWindowWidth,
                        actionLabel: table != nil ? "Leave the table"
                            : mode == .online ? "Leave online match" : "Pause match",
                        actionIcon: mode == .online ? "xmark" : "pause.fill",
                        emote: showsEmoteButton ? EmoteButtonState(
                            readyAt: session.emoteReadyAt,
                            nudge: emoteNudge,
                            isOpen: emoteTrayOpen
                        ) {
                            emoteTrayOpen.toggle()
                            emoteNudge = false
                        } : nil
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
                    holdButton
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
                                  playerTint: session.teamHues.color(localTeam),
                                  saberChanged: { session.saber = $0 },
                                  saberFlicked: { session.flickSaber($0) })
                }
            }
            // ASTROBALL's touches and bounces, big, down each screen edge by
            // that side's half: the dots beside the score were too small to
            // read mid-rally.
            if !mode.isBay, !session.isFreeForAll, let limits = session.touchLimits {
                let left = session.state.team(onHalfAt: -1)
                HStack {
                    VolleyRail(state: session.state, team: left, touchLimit: limits[left], allowedBounces: allowedBounces)
                    Spacer()
                    VolleyRail(state: session.state, team: left.opponent, touchLimit: limits[left.opponent], allowedBounces: allowedBounces)
                }
                // Out past the safe area, most of the way to the glass: the
                // island's notch is only the outer ~40% of the inset.
                .padding(.leading, max(6, geometry.safeAreaInsets.leading * 0.62))
                .padding(.trailing, max(6, geometry.safeAreaInsets.trailing * 0.62))
                .padding(.top, 58)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(.container, edges: .horizontal)
                .allowsHitTesting(false)
            }
            // Takes no space and never hit-tests, so a hardware keyboard flies
            // the ship without displacing the thumb controls.
            KeyboardControls(
                torque: $session.torque,
                thrust: $session.thrust,
                fire: $session.fire,
                tractor: $session.tractor,
                onCommand: keyCommandHandler,
                saberChanged: { session.saber = $0 },
                saberFlicked: { session.flickSaber($0) }
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            if emoteTrayOpen, showsEmoteButton {
                EmoteTray(readyAt: session.emoteReadyAt) { emote in
                    if session.playEmote(emote) { emoteTrayOpen = false }
                }
                .padding(.top, 54).padding(.trailing, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
            }
            if session.state.match.phase == .countdown { CountdownView(value: session.countdown) }
            if !session.callouts.isEmpty, session.setBreakCountdown == nil {
                PlayFeed(callouts: session.callouts)
                    .padding(.top, 64)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            if let seconds = session.setBreakCountdown {
                SetBreakBoard(
                    title: session.lastPointText,
                    stats: session.state.stats,
                    localTeam: isSpectating ? nil : localTeam,
                    seconds: seconds
                )
            } else if session.state.match.phase == .serve {
                VStack(spacing: 8) {
                    if let text = session.lastPointText {
                        // Painted the colour of the side the point paid, so
                        // the words never say whose it was.
                        let paid = session.lastPointTeam.map { session.teamHues.color($0) }
                        Text(text)
                            .font(.system(size: 26, weight: .black, design: .rounded)).tracking(2)
                            .foregroundStyle(paid == nil ? .white : .black)
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(paid ?? .black.opacity(0.66), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.35)))
                    }
                    if !session.isFreeForAll {
                    let servingSide = session.state.team(onHalfAt: session.state.serveDriftSign)
                    let isLocalServe = !isSpectating && servingSide == localTeam
                    let serveColor = session.teamHues.color(servingSide)
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
            }
            if let linkFailure, session.state.match.phase != .finished {
                LinkLostOverlay(
                    message: linkFailure,
                    rejoin: linkLostRejoin,
                    exit: leaveGame
                )
            }
            if session.isFreeForAll {
                let finished = session.state.match.phase == .finished
                let localOut = session.state.freeForAll?.isOut(session.localSeat) == true
                if finished || (localOut && !watchingField) {
                    FreeForAllResults(
                        state: session.state,
                        localSeat: isSpectating ? nil : session.localSeat,
                        name: session.callSign,
                        knockedOut: session.knockedOut,
                        statSeat: session.keepsStats ? session.localSeat : nil,
                        newBests: session.newBests,
                        watch: finished ? nil : { watchingField = true },
                        playAgain: mode.isOffline ? {
                            watchingField = false
                            playAgain()
                        } : nil,
                        exit: leaveGame
                    )
                }
            } else if session.state.match.phase == .finished {
                ResultsOverlay(
                    state: session.state,
                    localTeam: localTeam,
                    plan: resultsPlan,
                    names: courtNames,
                    spectating: isSpectating,
                    table: tableCard,
                    notice: linkFailure,
                    canRematch: mode == .online && online.canRematch && table == nil,
                    rematchOpponentNames: online.lastMatchOpponents.map(\.displayName),
                    statSeat: session.keepsStats ? session.localSeat : nil,
                    newBests: session.newBests,
                    playAgain: playAgain,
                    challenge: challengeNext,
                    rematch: rematchOpponent,
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
                    },
                    ring: mode.isFreeForAll
                        ? (tuning.configuration.maximumThrustAcceleration, { _ in session.applyTuning(tuning.configuration) })
                        : nil
                )
            }
        }
        .accessibilityIdentifier("game-screen")
        .confirmationDialog(
            leaveTitle,
            isPresented: $showLeaveConfirmation,
            titleVisibility: .visible
        ) {
            if let ask = askBehindTheWait {
                // Leaving the bay is one thing; the ask is another. Keeping
                // it is the invite-once, join-later the lobby promised;
                // withdrawing it clears both phones.
                Button("Withdraw Invite", role: .destructive) {
                    Task { await lobby.withdrawStandingInvite(ask) }
                    leaveGame()
                }
                Button("Keep Invite", action: leaveGame)
            } else {
                Button(leaveButton, role: .destructive, action: leaveGame)
            }
            Button(mode == .warmup ? "Keep Warming Up" : mode == .practice ? "Keep Practising" : isSpectating ? "Keep Watching" : "Keep Playing", role: .cancel) {}
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
            // Leaving the app pauses and raises the card; coming back leaves
            // both as they are, so the match waits for Resume instead of
            // playing on under the card or restarting the instant it shows.
            guard phase != .active, mode.isOffline, session.state.match.phase != .finished else { return }
            session.pauseForBackground()
            showPause = true
        }
        .onChange(of: session.state.match.score[localTeam]) { old, new in
            // A point for our side invites a taunt; the nudge lapses with
            // the serve rather than glowing all rally.
            guard showsEmoteButton, new > old else { return }
            emoteNudge = true
            Task {
                try? await Task.sleep(for: .seconds(4))
                emoteNudge = false
            }
        }
        .onChange(of: session.state.match.phase) { _, phase in
            if phase == .finished { emoteTrayOpen = false }
        }
        .animation(.easeOut(duration: 0.15), value: emoteTrayOpen)
        .environment(\.teamHues, session.teamHues)
        }
    }

    private var showsEmoteButton: Bool {
        !mode.isBay && !isSpectating && session.canEmote
            && session.state.match.phase != .finished
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
    /// the pilots change every game and OPPONENT says nothing. A pilot alone
    /// on a side of a doubles court is flying with a bot: IAN + BOT.
    private var courtNames: [Team: String]? {
        guard table != nil else { return nil }
        var names: [Team: String] = [:]
        for team in [Team.cyan, .orange] {
            var side = [Seat.lead(team), Seat.wing(team)]
                .compactMap { seat in online.seating.first { $0.value == seat }?.key }
                .map { online.pilotName($0).uppercased() }
            guard !side.isEmpty else { continue }
            if session.isDoubles, side.count == 1 { side.append("BOT") }
            names[team] = side.joined(separator: " + ")
        }
        return names
    }

    /// The bench's place in line; for the pilots flying, who is waiting.
    private func bannerText(for table: OpenTable) -> String {
        if let line = online.benchLine { return "WATCHING · \(line)" }
        if isSpectating { return online.isTableHost ? "WATCHING · YOU'RE HOSTING" : "WATCHING" }
        if table.queue.isEmpty {
            return table.court.count > 2 ? "OPEN TABLE · PARTNERS ROTATE" : "OPEN TABLE · WINNER STAYS ON"
        }
        return "OPEN TABLE · \(table.queue.count) WAITING"
    }

    /// The pill is painted the serving side's colour, so it never says
    /// YOUR or CPU; a pilot's name still shows online.
    private func serveText(_ servingSide: Team, isLocal: Bool) -> String {
        if !isLocal, let name = courtNames?[servingSide] { return "\(name) SERVES" }
        return "SERVE"
    }

    /// The results card's view of the table: who flies next and who has won.
    private var tableCard: TableCard? {
        guard let table else { return nil }
        let localID = online.localPlayerID
        func name(_ id: String) -> String { id == localID ? "YOU" : online.pilotName(id).uppercased() }
        let nextLine: String = if let next = table.nextCourt {
            "NEXT · \(OpenTable.matchup(of: next, name: name))"
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

    /// The standing ask behind the bay's wait, if any: the leave dialog
    /// then asks whether it keeps.
    private var askBehindTheWait: StandingInvite? {
        mode == .warmup ? lobby.standingInvite(behind: online.meetingTag) : nil
    }

    private var leaveTitle: String {
        if let ask = askBehindTheWait { return "Stop Waiting for \(ask.guestName)?" }
        if mode == .warmup { return "Leave the Bay?" }
        if mode == .practice { return "Leave Practice?" }
        if table != nil { return online.isTableHost ? "Close the Table?" : "Leave the Table?" }
        return "Leave Match?"
    }

    private var leaveButton: String {
        if mode == .warmup { return "Cancel Invite" }
        if mode == .practice { return "Leave" }
        if table != nil { return online.isTableHost ? "Close Table" : "Leave Table" }
        return "Leave Match"
    }

    private var leaveMessage: String {
        if let ask = askBehindTheWait {
            let hours = max(1, Int((ask.expiresAt.timeIntervalSinceNow / 3600).rounded(.up)))
            return "Keep it and \(ask.guestName) can still join from the app for the next \(hours)h. Withdrawing takes it back on both phones."
        }
        if mode == .warmup { return "Leaving withdraws the invite or search." }
        if mode == .practice { return "Your longest keep-up and hoops post to Game Center." }
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
        case .solo, .doubles, .freeForAll, .astroball: tuning.allowedBouncesPerHit
        // The hoop court has no faults at all.
        case .basketball, .online, .warmup, .practice: 3
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

    /// RETURN TO MATCH on the link-lost card, while the chair is held.
    private var linkLostRejoin: (() -> Void)? {
        guard mode == .online, online.canReturnToMatch else { return nil }
        return returnToMatch
    }

    /// While a chair is held. The phone that left gets the way back in: the
    /// others hold its chair, and calling them back would cross their call.
    /// Everyone else -- and the table's host, even watching -- can chase
    /// the pilot who dropped.
    @ViewBuilder private var holdButton: some View {
        if !isSpectating, online.returnTicket != nil {
            Button(action: returnToMatch) {
                Label("RETURN TO MATCH", systemImage: "arrow.uturn.backward.circle.fill")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .padding(.top, 6)
            .accessibilityIdentifier("return-to-match-button")
        } else if !isSpectating || online.isTableHost {
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
    }

    /// Leaves the arena for the menus and searches the way back in from
    /// there; the host's resync rebuilds the match when it lands.
    private func returnToMatch() {
        lobby.hostDuelAbandoned()
        exit()
        online.returnToMatch()
    }

    private func leaveGame() {
        switch mode {
        case .online:
            lobby.hostDuelAbandoned()
            // Walking out mid-match still leaves a held chair behind.
            if session.state.match.phase != .finished { online.stepAway() }
            online.leaveMatch()
        case .warmup: online.cancelMatchmaking()
        case .solo, .doubles, .practice, .astroball, .basketball, .freeForAll: break
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

    private func rematchOpponent() {
        guard mode == .online, online.canRematch else { return }
        leaveGame()
        Self.rematch(online: online, lobby: lobby)
    }

    /// One rival goes through the lobby, the way a friend invite does: they
    /// are almost certainly still in the app, so it lands as the in-game
    /// row rather than Apple's banner, and the bay opens once the search is
    /// out. A raw Game Center re-invite from the results card left the
    /// inviter on the main menu. Several rivals still go through Game Center.
    static func rematch(online: OnlineMatchCoordinator, lobby: LobbyService) {
        let rivals = online.lastMatchOpponents
        if rivals.count == 1, let rival = rivals.first {
            lobby.inviteAnytime(pilotID: rival.gamePlayerID, name: rival.displayName, format: online.lastMatchFormat, using: online)
        } else {
            online.rematch()
        }
    }
}

/// The bay's scoreboard: a keep-up streak, hoops popped, goals scored, and
/// the state of the invite in the middle where the match rules would be.
private struct WarmupHUD: View {
    let session: GameSession
    /// Nil in practice: no invite is out, so there is no link to report.
    let online: OnlineMatchCoordinator?
    let leave: () -> Void

    var body: some View {
        // Top-aligned: centred, the PRACTICE title dropped onto the court's
        // collar on the Duo's squarer displays.
        HStack(alignment: .top) {
            stat(title: "KEEP-UP", value: session.state.match.shipTouches.cyan,
                 detail: "BEST \(session.bestKeepUp)", tint: .cyan)
            Spacer()
            VStack(spacing: 3) {
                Text(online == nil ? "PRACTICE" : "WARM-UP BAY").font(.caption2.monospaced().weight(.bold)).tracking(2)
                    .foregroundStyle(.white.opacity(0.55))
                if let online { BayLinkStatus(online: online) }
            }
            // A container, not one combined element: the log button inside
            // it has to stay reachable.
            .accessibilityElement(children: .contain)
            Spacer()
            stat(title: "HOOPS", value: session.ringsPopped,
                 detail: "GOALS \(session.state.match.score.cyan)", tint: .yellow)
            Button(action: leave) {
                Image(systemName: "xmark").frame(width: 42, height: 42).background(.black.opacity(0.45), in: Circle())
            }
            .accessibilityLabel(online == nil ? "Leave practice" : "Leave warm-up bay").accessibilityIdentifier("match-action-button")
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
}

/// The invite's progress, under the bay's title while a friend is answering.
private struct BayLinkStatus: View {
    let online: OnlineMatchCoordinator

    @State private var isShowingLog = false

    var body: some View {
        Group {
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
        .sheet(isPresented: $isShowingLog) {
            LinkLogView(transcript: online.linkTranscript(), events: online.eventLog)
        }
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

extension EnvironmentValues {
    /// The match's side colours: cyan and orange, or ASTROBALL's draw.
    @Entry var teamHues = TeamHues()
}

extension TeamHue {
    var color: Color {
        switch self {
        case .cyan: .cyan
        case .orange: .orange
        default: Color(red: rgb.x, green: rgb.y, blue: rgb.z)
        }
    }
}

extension TeamHues {
    func color(_ team: Team) -> Color { self[team].color }
}

/// One side's ASTROBALL meter on its screen edge: a box per touch the side
/// may spend (filled as they go, the last one ringed white once it is all
/// that is left), then an arrow per bounce.
private struct VolleyRail: View {
    @Environment(\.teamHues) private var hues
    let state: WorldState
    let team: Team
    let touchLimit: Int
    let allowedBounces: Int

    var body: some View {
        let tint = hues.color(team)
        let touches = min(state.match.shipTouches[team], touchLimit)
        let bounces = min(state.match.floorContacts[team], allowedBounces)
        VStack(spacing: 4) {
            Text("HITS")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(tint)
            ForEach(0..<touchLimit, id: \.self) { index in
                let spent = index < touches
                let isLast = index == touchLimit - 1 && touches == touchLimit - 1
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(spent ? tint : .white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(isLast ? .white : tint.opacity(spent ? 1 : 0.45), lineWidth: isLast ? 2.5 : 1.5)
                    )
                    .overlay(Text("\(index + 1)")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundStyle(spent ? .black : tint.opacity(0.7)))
                    .frame(width: 30, height: 23)
            }
            Rectangle().fill(.white.opacity(0.2)).frame(width: 22, height: 1).padding(.vertical, 2)
            ForEach(0..<allowedBounces, id: \.self) { index in
                Image(systemName: "arrow.down")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(index < bounces ? tint : .white.opacity(0.2))
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 5)
        .background(.black.opacity(0.4), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(hues[team].name.capitalized): \(touches) of \(touchLimit) hits, \(bounces) of \(allowedBounces) bounces")
        .accessibilityIdentifier("hud-volley-rail")
    }
}

private struct MatchHUD: View {
    @Environment(\.teamHues) private var hues
    let state: WorldState
    let localTeam: Team
    let allowedBounces: Int
    /// ASTROBALL's touch limit a side, to meter against `shipTouches`; nil
    /// where touches are free.
    var touchLimits: SideCounts? = nil
    let online: OnlineMatchCoordinator?
    /// Each colour's pilot by name, at an open table.
    var teamNames: [Team: String]? = nil
    /// Watching from the bench: neither side is YOU.
    var spectating = false
    /// A window too narrow for the scores, the format chip and the buttons
    /// at full size (iPhone Duo folded): the chip shrinks and the row
    /// hugs the edges, so the chip stays on one line clear of the score.
    var narrow = false
    let actionLabel: String
    let actionIcon: String
    var emote: EmoteButtonState? = nil
    let action: () -> Void

    /// The scoreboard sits the way the court does: each side's score over its
    /// own half, so it changes ends with the teams between sets.
    private var leftTeam: Team { state.team(onHalfAt: -1) }

    var body: some View {
        HStack(spacing: narrow ? 4 : nil) {
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
            if let emote { EmoteButton(state: emote) }
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
        .padding(.horizontal, narrow ? 14 : 24).padding(.top, 10)
    }

    private var formatLabel: String {
        switch state.match.setsToWin {
        case 2: "BEST OF 3 • SETS TO \(MatchRules.setTarget)"
        case 3: "BEST OF 5 • SETS TO \(MatchRules.setTarget)"
        default: "FIRST TO \(MatchRules.setTarget) • WIN BY 2"
        }
    }

    private var rulesChip: some View {
        let isServe = state.match.phase == .serve
        return Text(formatLabel)
            .font(.system(size: narrow ? 10 : 12, weight: .black, design: .monospaced))
            .tracking(narrow ? 0.8 : 1.2)
            .lineLimit(1).minimumScaleFactor(0.85)
            .foregroundStyle(isServe ? .white : .white.opacity(0.85))
            .padding(.horizontal, narrow ? 8 : 11)
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
                        Circle().fill(index < state.match.sets[team] ? tint(team) : .white.opacity(0.18))
                            .frame(width: 6, height: 6)
                    }
                }
            }
        }
        .accessibilityLabel("Sets: you \(state.match.sets[localTeam]), rival \(state.match.sets[localTeam.opponent])")
    }

    private func tint(_ team: Team) -> Color { hues.color(team) }

    /// Names the side and what the next point takes. Carries the team tint
    /// as a filled capsule so it reads from across the room mid-rally.
    private func stakeCallout(_ headline: (team: Team, stake: Stake)) -> some View {
        let tint = hues.color(headline.team)
        let word = headline.stake == .matchPoint ? "MATCH POINT" : "SET POINT"
        let side = hues[headline.team].name
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
        let tint = tint(team)
        let value = state.match.score[team]
        let bounces = state.match.floorContacts[team]
        let touches = min(state.match.shipTouches[team], touchLimits?[team] ?? 0)
        let stake = state.match.stake(for: team)
        let isLocal = !spectating && team == localTeam
        // A pilot's name online; offline the colour alone says whose side.
        let tag = teamNames?[team]
        let side: String = if isLocal {
            "Your side, "
        } else if let name = teamNames?[team] {
            "\(name)'s side, "
        } else {
            "Rival side, "
        }
        return HStack(spacing: narrow ? 8 : 12) {
            VStack(spacing: 3) {
                Image(systemName: team == .cyan ? "minus" : "diamond.fill").foregroundStyle(tint)
                    .accessibilityIdentifier(isLocal ? "hud-you-tag" : "hud-opponent-tag")
                if let tag {
                    Text(tag)
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: narrow ? 64 : 76)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(tint, in: Capsule())
                }
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
            // Down arrows are bounces spent this possession. ASTROBALL meters
            // touches and bounces on its edge rails (`VolleyRail`) instead.
            if touchLimits == nil {
                HStack(spacing: 1) {
                    ForEach(0..<allowedBounces, id: \.self) { index in
                        Image(systemName: "arrow.down")
                            .foregroundStyle(index < bounces ? tint.opacity(0.75) : .white.opacity(0.16))
                    }
                }
                .font(.system(size: 10, weight: .black))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            side
                + "\(team.rawValue) score \(value), \(bounces) of \(allowedBounces) bounces used"
                + (touchLimits.map { ", \(touches) of \($0[team]) touches used" } ?? "")
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
                    TutorialCard(number: "01", icon: "arrow.left.and.right", title: "STEER", text: "Press left or right to rotate, and slide your thumb outward for a harder turn. Release to stop turning; your ship keeps its current angle and flight momentum.")
                    TutorialCard(number: "02", icon: "flame.fill", title: "THRUST", text: "Hold for steady main-engine acceleration. There is no auto-leveling and no brake. The exhaust is a real jet: a ball sitting in your plume gets shoved down it, so you can hover under a dropping ball to cushion it or blast one away. That is not a touch.")
                    TutorialCard(number: "03", icon: "bolt.fill", title: "FIRE", text: "Tap to fire a bolt from the nose. It knocks the ball along the line you are pointing and is not a touch. Bolts fly the whole court, and you can fire from anywhere short of the MAX CROSS line (the coloured line on their half you cannot fly past), but not from the ground. A bolt that hits an enemy hull knocks it about: shoved, stunned or spun, as the host picks.")
                    TutorialCard(number: "04", icon: "arrow.down.to.line.compact", title: "PULL", text: "Hold to reel the ball in with the tractor beam. It reaches anywhere on the court and pulls enemy hulls too. Keep holding once the ball lands on your hull and it locks there: swing it, pump it, let go to throw it. Score within a second of letting go and it is a SLAM DUNK. The lock breaks on the ground, a rival's touch, any bolt, or drawing the saber.")
                    TutorialCard(number: "05", icon: "line.diagonal", title: "SABER", text: "Hold to draw a blade from the nose; let go to sheathe it. The ball comes off the blade along the angle it met it, so the pace is your swing. Flick the pad fast while holding: left or right spins the hull a full turn, up is a dink, down a spike. Drawing it breaks a beam lock. In ASTROBALL a blade hit is a touch.")
                    TutorialCard(number: "06", icon: "keyboard", title: "KEYBOARD", text: "On a Mac, or with a keyboard attached, fly with A and D to steer, W or up arrow to thrust, Space to fire and S or down arrow to pull. The arrow keys steer too. Hold Shift for the saber and flick it with the arrows or WASD. Escape or P pauses, return confirms — the whole match runs without the screen. Touch and keys work together.")
                    TutorialCard(number: "07", icon: "volleyball.fill", title: "SCORE", text: "The goal hangs from the roof, dead centre, and it is a portal. The face on your side is yours to defend: a ball that goes in through it is a point for the other side. Get the ball into their half, lifted, and into the face over there — or make them put it into their own. Clip the hard rounded bottom and it just bounces. Touch it as often as you like; three bounces on your floor between touches, and the fourth is theirs.")
                    TutorialCard(number: "08", icon: "tray.and.arrow.down.fill", title: "THE LIP", text: "A ledge juts out under each face and tilts inward: a ball that lands on the lip rolls straight into the portal. Skim the ball under the cap so it drops onto the far lip, and it is in. Above the goal the roof bulges with the same curve as the corners, so nothing rides the ceiling into the mouth. Neither the lip nor the bulge counts as a bounce.")
                    TutorialCard(number: "09", icon: "arrow.left.and.right.circle.fill", title: "CROSS", text: "Fly under the goal, or straight through the portal itself, to reach the opponent’s side — the net stops the ball, never your hull, so you can sit in the mouth and defend. You can fly as far as the colored MAX CROSS line.")
                    TutorialCard(number: "10", icon: "burst.fill", title: "NO WRECKS", text: "Nothing destroys your ship. Ground, walls, ceiling, the roof bulge and the other ship all rebound. Points are won on the ball alone: a goal or a fourth bounce. Touches are unlimited. After every set the teams switch sides and keep their colours, so everyone plays both halves.")
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
    @AppStorage(GameSession.muteEmotesKey) private var muteEmotes = false
    @State private var arrangingControls = false
    @AppStorage(PadLayout.key) private var padLayout = PadLayout.diamond
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
                Picker("Engine pads", selection: $padLayout) {
                    Text("Diamond").tag(PadLayout.diamond)
                    Text("Classic").tag(PadLayout.classic)
                }
                .accessibilityIdentifier("pad-layout")
                Button {
                    arrangingControls = true
                } label: {
                    Label("Arrange Touch Controls", systemImage: "hand.draw.fill")
                }
                .accessibilityIdentifier("arrange-controls")
                Button("Reset pad layout") {
                    UserDefaults.standard.removeObject(forKey: "padOffsets2")
                    UserDefaults.standard.removeObject(forKey: "padOffsetsDiamond")
                }
                Toggle("Haptics", isOn: $haptics)
                Toggle("Music", isOn: $music)
                Toggle("Hide other pilots' emotes", isOn: $muteEmotes)
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
                    Picker("Arena", selection: $tuning.arenaLayout) {
                        ForEach(ArenaLayout.allCases, id: \.self) { layout in
                            Text(layout.title).tag(layout)
                        }
                    }
                    .accessibilityIdentifier("arena-layout")
                    if tuning.arenaLayout == .bumpers {
                        TuningSlider(
                            title: "Peg pull",
                            value: $tuning.pegPull,
                            range: FlightTuningSnapshot.pegPullRange,
                            step: 0.05,
                            readout: { $0.formatted(.number.precision(.fractionLength(2))) + "x" }
                        )
                        .accessibilityIdentifier("peg-pull")
                    }
                    Picker("Bolt hit", selection: $tuning.boltHit) {
                        ForEach(BoltHit.allCases, id: \.self) { hit in
                            Text(hit.title).tag(hit)
                        }
                    }
                    .accessibilityIdentifier("bolt-hit")
                    TuningSlider(
                        title: "Beam lock",
                        value: $tuning.beamLock,
                        range: FlightTuningSnapshot.beamLockRange,
                        step: 0.05,
                        readout: { $0.formatted(.number.precision(.fractionLength(2))) + " s" }
                    )
                    .accessibilityIdentifier("beam-lock")
                    TuningSlider(
                        title: "Beam swing",
                        value: $tuning.beamSwing,
                        range: FlightTuningSnapshot.beamSwingRange,
                        step: 0.05,
                        readout: { $0.formatted(.number.precision(.fractionLength(2))) + "x" }
                    )
                    .accessibilityIdentifier("beam-swing")
                    Text("Touches are unlimited. Bounces apply to solo matches; online uses three. Match length, arena, peg pull, bolt hit, beam lock and beam swing apply to solo and doubles matches and to any online match you host. Bolt hit is what an enemy bolt does to a hull: shove it, stun its controls for a moment, or spin it round. Beam lock is how long the beam holds the ball before it locks on: you and the ball then turn as one body until you let go. Let go sooner and it flies on in. The lock breaks if your hull touches the ground, if the ball touches the ground, a goal or a ledge, if another hull touches the ball, or if any bolt hits you or the ball, and no goal takes a locked ball: let go and throw it. A goal within a second of your beam letting go is your slam dunk, unless another pilot played the ball in between. The catch keeps the ball's run as swing; beam swing is how hard the stick pumps it while locked. Let go at speed to whip the ball off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    RingTuningControls(thrust: tuning.configuration.maximumThrustAcceleration)
                } header: {
                    Text("ASTROPUCK")
                } footer: {
                    Text(RingTuningControls.footer)
                }
                Section {
                    AstroballTuningControls()
                } header: {
                    Text("ASTROBALL")
                } footer: {
                    Text(AstroballTuningControls.footer)
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
        .fullScreenCover(isPresented: $arrangingControls) {
            ControlLayoutEditor()
        }
        .accessibilityIdentifier("settings-screen")
    }
}

/// The match's pads over an empty court, ready to drag: the very
/// `TouchControls` a match draws, in the same frame, with arranging on.
/// Its banner's DONE puts them back to work and closes this.
struct ControlLayoutEditor: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("arrangePads") private var arranging = false
    @AppStorage("largeControls") private var largeControls = false
    @AppStorage("leftHanded") private var leftHanded = false
    @State private var torque = 0.0
    @State private var thrust = false
    @State private var fire = false
    @State private var tractor = false

    /// Stands in for the match HUD over the pads, so they land where a
    /// match puts them.
    private static let hudHeight: CGFloat = 54

    var body: some View {
        GeometryReader { geometry in
            let window = TouchControls.windowFrame(in: geometry)
            let centred = ArenaScene.arenaRect(in: window.size)
            let arena = centred.offsetBy(dx: window.midX, dy: window.midY)
            ZStack(alignment: .topLeading) {
                // The court: the pads should leave it clear.
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.white.opacity(0.35), lineWidth: 2)
                    .frame(width: arena.width, height: arena.height)
                    .position(
                        x: arena.midX - geometry.frame(in: .global).minX,
                        y: arena.midY - geometry.frame(in: .global).minY
                    )
                    .allowsHitTesting(false)
                VStack(spacing: 0) {
                    Color.clear.frame(height: Self.hudHeight)
                    TouchControls(
                        torque: $torque,
                        thrust: $thrust,
                        fire: $fire,
                        tractor: $tractor,
                        largeControls: largeControls,
                        leftHanded: leftHanded,
                        arenaFrame: arena,
                        windowFrame: window,
                        saberChanged: { _ in },
                        saberFlicked: { _ in }
                    )
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { arranging = true }
        .onChange(of: arranging) { _, on in
            if !on { dismiss() }
        }
        .onDisappear { arranging = false }
        .accessibilityIdentifier("control-layout-editor")
    }
}

/// ASTROBALL's knobs, written straight to the pilot's defaults. A host's
/// settings ride the seating plan, so they fly on every phone.
struct AstroballTuningControls: View {
    @State private var tuning = AstroballTuning.stored()

    static let footer = "Solo touches is how many times a side flown by one pilot may play the ball before it has to be over: one touch and over, up to three. A side of two always gets three. In a row is how many times one pilot may play it running: two by default, so a double is fine and a triple gives the point away. Hull and bolts both count. Net touch is what flying into the top half of the net costs: Off, Stun (a second with dead controls, the default) or Point (your side loses it). There are two zones, each a stretch of each half's wall path (by default the floor nearest the net out to 28%, and a small target 7% to 13% up the side wall), from the foot of the net (0) along the floor, round the corner and up the side wall to the roof (1): the ball touching your zone gives the other side the point. Wall bounce is how much speed the ball keeps off the walls, roof and corners; lower soaks a spike up. Floor bounce is the same for the floor, and is never livelier than the walls, so a ball that lands stays down; the floor corners blend from one to the other. The MAX CROSS line rises from the top of the net and leans over the far half by the lean; fly past it and it slings you back. Takes effect next match, and online when you host."

    private var court: ArenaGeometry { .astroball(doubles: false) }

    var body: some View {
        Picker("Solo touches", selection: $tuning.soloTouches) {
            ForEach(Array(AstroballTuning.soloTouchesRange), id: \.self) { Text("\($0)").tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(AstroballTuning.soloTouchesKey)
        Picker("In a row", selection: $tuning.inARow) {
            ForEach(Array(AstroballTuning.inARowRange), id: \.self) { Text("\($0)").tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(AstroballTuning.inARowKey)
        Picker("Net touch", selection: $tuning.netTouch) {
            ForEach(NetTouch.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(AstroballTuning.netTouchKey)
        TuningSlider(title: "Zone from", value: $tuning.zoneStart, range: 0 ... 1, step: 0.01,
                     readout: { court.wallPathPlace(at: $0) })
            .accessibilityIdentifier(AstroballTuning.zoneStartKey)
        TuningSlider(title: "Zone to", value: $tuning.zoneEnd, range: 0 ... 1, step: 0.01,
                     readout: { court.wallPathPlace(at: $0) })
            .accessibilityIdentifier(AstroballTuning.zoneEndKey)
        TuningSlider(title: "Zone 2 from", value: $tuning.zone2Start, range: 0 ... 1, step: 0.01,
                     readout: { court.wallPathPlace(at: $0) })
            .accessibilityIdentifier(AstroballTuning.zone2StartKey)
        TuningSlider(title: "Zone 2 to", value: $tuning.zone2End, range: 0 ... 1, step: 0.01,
                     readout: { court.wallPathPlace(at: $0) })
            .accessibilityIdentifier(AstroballTuning.zone2EndKey)
        TuningSlider(title: "Wall bounce", value: $tuning.wallBounce, range: AstroballTuning.wallBounceRange, step: 0.01,
                     readout: { "\(Int(($0 * 100).rounded()))%" })
            .accessibilityIdentifier(AstroballTuning.wallBounceKey)
        TuningSlider(title: "Floor bounce", value: $tuning.floorBounce, range: AstroballTuning.floorBounceRange, step: 0.01,
                     readout: { "\(Int((min($0, tuning.clampedWallBounce) * 100).rounded()))%" })
            .accessibilityIdentifier(AstroballTuning.floorBounceKey)
        TuningSlider(title: "MAX CROSS lean", value: $tuning.crossLean, range: AstroballTuning.crossLeanRange, step: 0.01)
            .accessibilityIdentifier(AstroballTuning.crossLeanKey)
        Button("Reset ASTROBALL to default") { tuning = AstroballTuning() }
            .disabled(tuning == AstroballTuning())
            .onChange(of: tuning) { _, tuning in tuning.store() }
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

/// Every free-for-all knob, one slider each, written straight to the
/// pilot's defaults. `changed` hears every move, so the pause card can put
/// it into the match under the pilot's thumb.
struct RingTuningControls: View {
    /// The Thrust slider's top push, for the speed readout.
    let thrust: Double
    var changed: (RingTuning) -> Void = { _ in }
    @State private var tuning = RingTuning.stored()

    static let footer = "Thrust and hull drag set how the ring flies: speed builds toward thrust / drag, and lower drag glides further. MAX CROSS push and brake are how hard a rival's line shoves you back and how much speed it steals; the line is how far out each rival's arc stands. Bump height is how far each goal's bump rises off the rim, as a share of the ring's radius (0 puts the goals flush in a plain round rim); bump width is how broad its bell is. Fire rate is the seconds between your bolts on the ring, apart from the duel's. The centre bumper stands in the middle when it is on, and the face-off drops just clear of it. Goal guards stand a round bumper in front of every goal; sliding, it rides a track across the mouth and stays wherever a hull, the beam or a bolt shoves it, and starts each point where Guard across puts it; stood still, Guard distance and Guard across are where it stays. Two balls puts a second one in play; a goal re-drops only the one that went in. Gravity tilts the table out to the rim. All of it applies the moment you resume."

    var body: some View {
        ForEach(RingTuning.knobs.filter { !RingTuning.guardKnobKeys.contains($0.key) }) { knob in
            slider(knob)
            if knob.keyPath == \RingTuning.hullDrag {
                let top = thrust * tuning.speed / max(0.01, tuning.hullDrag)
                let half = log(2) / max(0.01, tuning.hullDrag)
                Text("Top speed \(top.formatted(.number.precision(.fractionLength(2)))), half of it in \(half.formatted(.number.precision(.fractionLength(1)))) s")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Toggle("Centre bumper", isOn: Binding(
            get: { tuning.centreBumper },
            set: { tuning.centreBumper = $0 }
        ))
        .accessibilityIdentifier(RingTuning.centreBumperKey)
        Toggle("Two balls", isOn: Binding(
            get: { tuning.twoBalls },
            set: { tuning.twoBalls = $0 }
        ))
        .accessibilityIdentifier(RingTuning.twoBallsKey)
        Toggle("Goal guards", isOn: Binding(
            get: { tuning.goalGuards },
            set: { tuning.goalGuards = $0 }
        ))
        .accessibilityIdentifier(RingTuning.goalGuardsKey)
        if tuning.goalGuards {
            Toggle("Guards slide", isOn: Binding(
                get: { tuning.guardsSlide },
                set: { tuning.guardsSlide = $0 }
            ))
            .accessibilityIdentifier(RingTuning.guardsSlideKey)
            ForEach(RingTuning.knobs.filter { RingTuning.guardKnobKeys.contains($0.key) }) { knob in
                slider(knob)
            }
        }
        Button("Reset ring to default") { tuning = RingTuning() }
            .disabled(tuning == RingTuning())
            .onChange(of: tuning) { _, tuning in
                tuning.store()
                changed(tuning)
            }
    }

    private func slider(_ knob: RingTuning.Knob) -> some View {
        TuningSlider(
            title: knob.title,
            value: Binding(
                get: { tuning[keyPath: knob.keyPath] },
                set: { tuning[keyPath: knob.keyPath] = $0 }
            ),
            range: knob.range,
            step: knob.step,
            readout: { knob.percent ? "\(Int(($0 * 100).rounded()))%" : knob.degrees ? "\(Int($0.rounded()))°" : knob.seconds ? "\($0.formatted(.number.precision(.fractionLength(2)))) s" : $0.formatted(.number.precision(.fractionLength(2))) }
        )
        .accessibilityIdentifier(knob.key)
    }
}

/// Paused, on the court. Resume, drop a fresh ball, or leave. On the ring it
/// also opens every ring slider, live: what you set is what you fly on
/// resume.
private struct CourtPauseOverlay: View {
    let restartDrop: () -> Void
    let resume: () -> Void
    let quit: () -> Void
    /// Present on the ring: the Thrust slider's push, and where a moved
    /// ring slider goes.
    var ring: (thrust: Double, changed: (RingTuning) -> Void)? = nil
    @State private var tuningRing = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            if let ring, tuningRing {
                VStack(spacing: 10) {
                    HStack {
                        Text("TUNE THE RING")
                            .font(.headline.weight(.black)).tracking(3)
                        Spacer()
                        Button("Done") { tuningRing = false }
                            .buttonStyle(.borderedProminent).tint(.cyan)
                            .accessibilityIdentifier("ring-tuning-done")
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            RingTuningControls(thrust: ring.thrust, changed: ring.changed)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(20)
                .frame(maxWidth: 460)
                .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.25)))
                .padding(16)
                .foregroundStyle(.white)
            } else {
                VStack(spacing: 18) {
                    Text("PAUSED")
                        .font(.title2.weight(.black)).tracking(4)
                        .foregroundStyle(.white)
                    Button("Resume", action: resume)
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        .accessibilityIdentifier("resume-button")
                    if ring != nil {
                        Button {
                            tuningRing = true
                        } label: {
                            Label("Tune the Ring", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("tune-ring")
                    }
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
        }
        .accessibilityIdentifier("pause-screen")
    }
}

/// The match is over and it was the network that ended it. One statement of
/// what happened, one way out.
private struct LinkLostOverlay: View {
    let message: String
    /// RETURN TO MATCH, while the others still hold this pilot's chair.
    var rejoin: (() -> Void)?
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
            if let rejoin {
                Button(action: rejoin) {
                    Label("RETURN TO MATCH", systemImage: "arrow.uturn.backward.circle.fill")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent).tint(.cyan)
                .accessibilityIdentifier("link-lost-return")
                Button("BACK TO MENU", action: exit).buttonStyle(.bordered).tint(.orange)
            } else {
                Button("BACK TO MENU", action: exit).buttonStyle(.borderedProminent).tint(.orange)
            }
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
    @Environment(\.teamHues) private var hues
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
    /// Whether a rematch with the same opponent(s) is available.
    var canRematch = false
    /// The opponent names for the rematch button subtitle.
    var rematchOpponentNames: [String] = []
    /// Whose numbers the stat line shows; nil hides it (the bench, the bay).
    var statSeat: Seat? = nil
    /// Boards this match set a personal best on.
    var newBests: Set<StatBoard> = []
    let playAgain: () -> Void
    let challenge: () -> Void
    var rematch: () -> Void = {}
    var inviteMore: () -> Void = {}
    let exit: () -> Void

    /// YOU on your side and RIVAL on theirs, or both pilots' names.
    private var sidesLabel: String {
        guard let names else { return "YOU — RIVAL" }
        let mine = spectating ? names[localTeam] ?? hues[localTeam].name : "YOU"
        return "\(mine) — \(names[localTeam.opponent] ?? "RIVAL")"
    }

    private var headline: String {
        guard spectating else { return didLocalPlayerWin ? "YOU WIN" : "YOU LOSE" }
        let winner = state.match.winner
            ?? (state.match.score.cyan >= state.match.score.orange ? Team.cyan : .orange)
        return "\(names?[winner] ?? hues[winner].name) WINS"
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
            if let statSeat {
                MatchStatLine(stats: state.stats, seat: statSeat, newBests: newBests)
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
            // Friend-first: rematch above other options for online matches.
            if canRematch {
                Button(rematchButtonLabel, action: rematch)
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .accessibilityIdentifier("results-rematch")
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
    }

    private var rematchButtonLabel: String {
        if rematchOpponentNames.isEmpty { return "REMATCH" }
        if rematchOpponentNames.count == 1 {
            return "REMATCH \(rematchOpponentNames[0].uppercased())"
        }
        return "REMATCH"
    }

    private func scoreLine(_ tally: Score) -> some View {
        let rival = localTeam.opponent
        let label: String = if spectating {
            "\(names?[localTeam] ?? hues[localTeam].name.capitalized) \(tally[localTeam]), \(names?[rival] ?? hues[rival].name.capitalized) \(tally[rival])"
        } else {
            "You \(tally[localTeam]), rival \(tally[rival])"
        }
        return HStack(spacing: 18) {
            Text(tally[localTeam].formatted()).foregroundStyle(hues.color(localTeam))
            Text("—").foregroundStyle(.secondary)
            Text(tally[rival].formatted()).foregroundStyle(hues.color(rival))
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
/// line, or for the pilots flying, how many are waiting to fly.
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
    /// A third of the width: icon over title, no chevron, and the title
    /// shrinks before it truncates.
    var compact = false
    /// Shorter rows for a window with little height to spare (iPhone Duo
    /// folded), so the menu still ends above the bottom edge.
    var narrow = false
    /// A home-grid game tile: icon over title over subtitle, no chevron, so
    /// ASTROPUCK fits half the menu width without truncating.
    var tile = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            if tile {
                VStack(spacing: 4) {
                    Image(systemName: icon).font(.title2).frame(height: narrow ? 24 : 30)
                    Text(title).font(.headline.weight(.black)).tracking(1).lineLimit(1).minimumScaleFactor(0.6)
                    Text(subtitle).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.52)).lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10).padding(.vertical, narrow ? 8 : 12).frame(minHeight: narrow ? 76 : 96)
                .contentShape(RoundedRectangle(cornerRadius: 18))
                .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12)))
            } else if compact {
                VStack(alignment: .leading, spacing: 2) {
                    Image(systemName: icon).font(.body.weight(.semibold)).frame(height: 20)
                    // A fixed size that fits SOLO FLIGHT in a 100pt tile (430pt
                    // menu); a scaled subheadline left DOUBLES a size bigger
                    // than its three neighbours.
                    Text(title).font(.system(size: narrow ? 11 : 13, weight: .black)).lineLimit(1).minimumScaleFactor(0.6)
                    Text(subtitle).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.52)).lineLimit(1).minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 8).frame(minHeight: 68)
                .contentShape(RoundedRectangle(cornerRadius: 18))
                .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12)))
            } else {
                row
            }
        }
        .buttonStyle(.plain).accessibilityIdentifier(title.lowercased().replacingOccurrences(of: " ", with: "-"))
    }

    private var row: some View {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.title2).frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline.weight(.black)).tracking(1).lineLimit(1).minimumScaleFactor(0.6)
                    Text(subtitle).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.52)).lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
            }
            .padding(.horizontal, 20).frame(minHeight: narrow ? 56 : 68)
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12)))
    }
}

private struct SmallMenuButton: View {
    let title: String, icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .labelStyle(TileLabelStyle())
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 13))
                .contentShape(Rectangle())
        }
            .buttonStyle(.plain).accessibilityIdentifier(title.lowercased().replacingOccurrences(of: " ", with: "-"))
    }
}

/// Icon over title, so five tiles fit one row on an iPhone in landscape.
/// A Label (not a bare VStack) keeps the button's identifier visible to UI tests.
private struct TileLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 4) {
            configuration.icon.font(.body.weight(.semibold)).frame(height: 22)
            configuration.title.font(.system(size: 9, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
        }
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

struct EmoteButtonState {
    let readyAt: Date
    /// Our side just scored: the button glows to invite a taunt.
    let nudge: Bool
    let isOpen: Bool
    let toggle: () -> Void
}

/// Opens the emote tray. A ring drains round it while the cooldown runs.
private struct EmoteButton: View {
    let state: EmoteButtonState

    var body: some View {
        Button(action: state.toggle) {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let remaining = max(0, state.readyAt.timeIntervalSince(context.date))
                Image(systemName: state.isOpen ? "xmark" : "face.smiling.inverse")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(state.nudge ? .yellow : .white)
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.45), in: Circle())
                    .overlay(Circle().stroke(state.nudge ? .yellow : .white.opacity(0.25), lineWidth: state.nudge ? 2 : 1))
                    .overlay(
                        Circle()
                            .trim(from: 0, to: remaining / EmoteCooldown.interval)
                            .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    )
                    .shadow(color: state.nudge ? .yellow.opacity(0.8) : .clear, radius: 8)
                    .scaleEffect(state.nudge ? 1.1 : 1)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .padding(.trailing, 8)
        .accessibilityLabel(state.isOpen ? "Close emotes" : "Emotes")
        .accessibilityIdentifier("emote-button")
        .animation(.easeOut(duration: 0.3), value: state.nudge)
    }
}

/// The emotes, one tap each. Picking one closes the tray. While the
/// cooldown runs the tray stays open, dimmed, with the seconds left on it,
/// so a tap that cannot play yet still visibly answers.
private struct EmoteTray: View {
    let readyAt: Date
    let play: (Emote) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let remaining = readyAt.timeIntervalSince(context.date)
            tray(coolingDown: remaining > 0)
                .overlay {
                    if remaining > 0 {
                        Text("READY IN \(Int(remaining.rounded(.up)))s")
                            .font(.system(size: 13, weight: .black, design: .rounded))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.black.opacity(0.7), in: Capsule())
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private func tray(coolingDown: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(Emote.allCases, id: \.self) { emote in
                Button { play(emote) } label: {
                    VStack(spacing: 1) {
                        Image(systemName: emote.symbol)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(height: 24)
                        Text(emote.name.uppercased())
                            .font(.system(size: 7, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    .frame(width: 50, height: 48)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.2)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(coolingDown)
                .opacity(coolingDown ? 0.4 : 1)
                .accessibilityLabel(emote.name)
                .accessibilityIdentifier("emote-\(emote.rawValue)")
            }
        }
        .padding(6)
        .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}
