import ASTROSPIKECore
import SpriteKit
import SwiftUI

struct AppRootView: View {
    @State private var online = OnlineMatchCoordinator()
    @State private var tuning = FlightTuningStore()
    @State private var gameMode: GameMode?
    @State private var sheet: MenuSheet?
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
            reconnectSeconds: 7
        ) : nil
        _gameMode = State(initialValue: diagnosticsPreviewMode ? .online : (demoMode ? .solo(.pilot) : nil))
    }

    var body: some View {
        ZStack {
            CosmicBackground()
            if let gameMode {
                GameView(
                    mode: gameMode,
                    online: online,
                    tuning: tuning,
                    diagnosticsOverride: diagnosticsPreview
                ) {
                    self.gameMode = nil
                }
                .transition(.opacity.combined(with: .scale(scale: 1.03)))
            } else {
                HomeView(online: online, sheet: $sheet) { mode in
                    withAnimation(.easeOut(duration: 0.25)) { gameMode = mode }
                }
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if diagnosticsPreview == nil {
                online.authenticate()
            }
        }
        .onChange(of: online.isMatchReady) { _, ready in
            if ready { withAnimation { gameMode = .online } }
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
                SettingsView(tuning: tuning).presentationDetents([.large])
            }
        }
    }
}

private enum MenuSheet: String, Identifiable {
    case difficulty, tutorial, settings
    var id: String { rawValue }
}

private struct HomeView: View {
    let online: OnlineMatchCoordinator
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
                    Label(online.status.label, systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(statusColor).lineLimit(1)
                }
                .font(.system(size: min(58, geometry.size.height * 0.13), weight: .black, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 12) {
                    MenuButton(title: "SOLO FLIGHT", subtitle: "ROOKIE • PILOT • ACE", icon: "person.fill") { sheet = .difficulty }
                    MenuButton(title: "QUICK MATCH", subtitle: "AUTOMATIC ONLINE DUEL", icon: "bolt.horizontal.circle.fill") { online.presentQuickMatch() }
                    MenuButton(title: "INVITE A FRIEND", subtitle: "GAME CENTER", icon: "person.2.wave.2.fill") { online.presentFriendInvite() }
                    HStack(spacing: 12) {
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
        default: .white.opacity(0.6)
        }
    }
}

private struct GameView: View {
    let mode: GameMode
    let online: OnlineMatchCoordinator
    let tuning: FlightTuningStore
    let diagnosticsOverride: OnlineDiagnosticsSnapshot?
    let exit: () -> Void

    @State private var session: GameSession
    @State private var showPause = false
    @AppStorage("largeControls") private var largeControls = false
    @AppStorage("leftHanded") private var leftHanded = false
    @AppStorage("haptics") private var haptics = true
    @Environment(\.scenePhase) private var scenePhase

    init(
        mode: GameMode,
        online: OnlineMatchCoordinator,
        tuning: FlightTuningStore,
        diagnosticsOverride: OnlineDiagnosticsSnapshot? = nil,
        exit: @escaping () -> Void
    ) {
        self.mode = mode
        self.online = online
        self.tuning = tuning
        self.diagnosticsOverride = diagnosticsOverride
        self.exit = exit
        let configuration = switch mode {
        case .solo: tuning.configuration
        case .online: SimulationConfiguration()
        }
        _session = State(initialValue: GameSession(
            mode: mode,
            online: online,
            configuration: configuration
        ))
    }

    var body: some View {
        ZStack {
            SpriteView(scene: session.scene, options: [.ignoresSiblingOrder])
                .ignoresSafeArea().accessibilityHidden(true)
            VStack(spacing: 0) {
                MatchHUD(
                    state: session.state,
                    allowedBounces: allowedBounces,
                    online: mode == .online && diagnosticsOverride == nil ? online : nil
                ) {
                    session.togglePause(); showPause = true
                }
                if mode == .online {
                    GameCenterDiagnosticsPanel(
                        diagnostics: diagnosticsOverride ?? online.diagnosticsSnapshot
                    )
                    .padding(.top, 4)
                }
                HStack {
                    if localHomeSide == .orange { Spacer() }
                    TeamSideBadge(team: localTeam)
                    if localHomeSide == .cyan { Spacer() }
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
                Spacer()
                TouchControls(torque: $session.torque, thrust: $session.thrust,
                              largeControls: largeControls, leftHanded: leftHanded)
            }
            if session.state.match.phase == .countdown { CountdownView(value: session.countdown) }
            if session.state.match.phase == .serve, let text = session.lastPointText {
                Text(text)
                    .font(.system(size: 30, weight: .black, design: .rounded)).tracking(2)
                    .padding(.horizontal, 24).padding(.vertical, 13)
                    .background(.black.opacity(0.66), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.35)))
            }
            if session.state.match.phase == .finished { ResultsOverlay(state: session.state, exit: exit) }
        }
        .accessibilityIdentifier("game-screen")
        .onAppear { FeedbackCenter.shared.hapticsEnabled = haptics; session.start() }
        .onDisappear { session.stop() }
        .onChange(of: tuning.snapshot) { _, _ in
            session.applyTuning(tuning.configuration)
        }
        .onChange(of: scenePhase) { _, phase in
            session.setApplicationActive(phase == .active)
        }
        .sheet(isPresented: $showPause, onDismiss: { session.resume() }) {
            PauseView(
                tuning: tuning,
                restartDrop: { session.restartRally(with: tuning.configuration) },
                resume: { showPause = false; session.resume() },
                exit: { showPause = false; exit() }
            )
            .presentationDetents([.large])
            .interactiveDismissDisabled()
        }
    }

    private var localTeam: Team { online.localTeam ?? .cyan }

    private var allowedBounces: Int {
        switch mode {
        case .solo: tuning.allowedBouncesPerHit
        case .online: 2
        }
    }

    private var localHomeSide: Team {
        session.state.ships[localTeam]?.homeSide ?? localTeam
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
    let online: OnlineMatchCoordinator?
    let pause: () -> Void

    var body: some View {
        HStack {
            score(team: .cyan, value: state.match.score.cyan, bounces: state.match.floorContacts.cyan)
            Spacer()
            VStack(spacing: 2) {
                Text("FIRST TO 7 • WIN BY 2").font(.caption2.monospaced().weight(.semibold)).foregroundStyle(.white.opacity(0.55))
                if let online {
                    Label(online.status.label, systemImage: signalIcon).font(.caption2.weight(.bold)).foregroundStyle(.green)
                }
            }
            Spacer()
            score(team: .orange, value: state.match.score.orange, bounces: state.match.floorContacts.orange)
            Button(action: pause) {
                Image(systemName: "pause.fill").frame(width: 42, height: 42).background(.black.opacity(0.45), in: Circle())
            }
            .accessibilityLabel("Pause match").accessibilityIdentifier("pause-button")
        }
        .padding(.horizontal, 24).padding(.top, 10)
    }

    private func score(team: Team, value: Int, bounces: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: team == .cyan ? "minus" : "diamond.fill").foregroundStyle(team == .cyan ? .cyan : .orange)
            Text(value.formatted()).font(.system(size: 36, weight: .black, design: .rounded).monospacedDigit())
            HStack(spacing: 4) {
                ForEach(0..<allowedBounces, id: \.self) { index in
                    Circle().fill(index < bounces ? (team == .cyan ? Color.cyan : .orange) : .white.opacity(0.16)).frame(width: 8, height: 8)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(team.rawValue) score \(value), \(bounces) of \(allowedBounces) bounces used")
    }

    private var signalIcon: String {
        guard let ping = online?.pingMilliseconds else { return "wifi" }
        return ping < 80 ? "wifi" : ping < 160 ? "wifi.exclamationmark" : "exclamationmark.triangle"
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
                    TutorialCard(number: "02", icon: "flame.fill", title: "THRUST", text: "Hold for steady main-engine acceleration. There is no auto-leveling and no brake.")
                    TutorialCard(number: "03", icon: "volleyball.fill", title: "SCORE", text: "Bank the ball off the center net and down into the opponent’s compact goal. Each ship hit refreshes your floor-bounce allowance.")
                    TutorialCard(number: "04", icon: "arrow.left.and.right.circle.fill", title: "CROSS", text: "Clear the low net to enter the opponent’s side. You can fly as far as the colored MAX CROSS line.")
                    TutorialCard(number: "05", icon: "burst.fill", title: "DANGER", text: "You explode if you touch the net from their side, cross their MAX CROSS line, hit the ground, or collide with the other ship. Side walls and the ceiling rebound safely.")
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
                        "Bounces per hit: \(tuning.allowedBouncesPerHit)",
                        value: $tuning.allowedBouncesPerHit,
                        in: 1 ... 5
                    )
                    Text("Applies to solo matches. Online matches use two bounces per hit for both players.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Developer") {
                    NavigationLink("Flight Tuning") {
                        FlightTuningView(tuning: tuning)
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
                            TuningSlider(title: "Drop height", value: $tuning.ballDropHeight, range: 0.25 ... 0.72, step: 0.01)
                            TuningSlider(title: "Drop speed", value: $tuning.ballDropSpeed, range: 0 ... 0.8, step: 0.01)
                        }
                    }
                    GroupBox("Match Rule") {
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
    let exit: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Text("MATCH COMPLETE").font(.caption.monospaced().bold()).tracking(3)
            Text("\(state.match.score.cyan)  —  \(state.match.score.orange)").font(.system(size: 58, weight: .black, design: .rounded).monospacedDigit())
            Button("Return to Hangar", action: exit).buttonStyle(.borderedProminent).tint(.cyan)
        }
        .padding(30).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26)).accessibilityIdentifier("results-screen")
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
        Button(action: action) { Label(title, systemImage: icon).font(.caption.weight(.bold)).frame(maxWidth: .infinity, minHeight: 44).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 13)) }
            .buttonStyle(.plain).accessibilityIdentifier(title.lowercased().replacingOccurrences(of: " ", with: "-"))
    }
}

private struct TeamMarkRow: View {
    var body: some View {
        HStack(spacing: 14) { Label("CYAN", systemImage: "minus").foregroundStyle(.cyan); Text("VS").foregroundStyle(.white.opacity(0.35)); Label("ORANGE", systemImage: "diamond.fill").foregroundStyle(.orange) }
            .font(.caption.monospaced().bold())
    }
}

private struct CosmicBackground: View {
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
