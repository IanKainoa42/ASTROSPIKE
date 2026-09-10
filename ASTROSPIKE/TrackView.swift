import ASTROSPIKECore
import SpriteKit
import SwiftUI

/// The mini circuit. The same ship, the same arena box and the same gravity
/// as a match -- a very different job: a wide corridor flown against one pace
/// ship, with the railing as the only opponent that never makes a mistake.
/// By default the loop never ends, so the pilot leaves when they are done.
struct TrackView: View {
    let flight: FlightTuningSnapshot
    @Bindable var tuning: TrackTuningStore
    let exit: () -> Void

    @State private var session: TrackSession
    @State private var showLeaveConfirmation = false
    @AppStorage("largeControls") private var largeControls = false
    @AppStorage("leftHanded") private var leftHanded = false
    @AppStorage("haptics") private var haptics = true
    @Environment(\.scenePhase) private var scenePhase

    init(
        flight: FlightTuningSnapshot,
        tuning: TrackTuningStore,
        hulls: [TrackSeat: Hull],
        exit: @escaping () -> Void
    ) {
        self.flight = flight
        self.tuning = tuning
        self.exit = exit
        _session = State(
            initialValue: TrackSession(
                flight: flight,
                tuning: tuning.snapshot,
                hulls: hulls
            )
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                SpriteView(scene: session.scene, options: [.ignoresSiblingOrder])
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    TrackHUD(
                        session: session,
                        pause: { if !session.isPaused { session.togglePause() } },
                        leave: { showLeaveConfirmation = true }
                    )
                    TouchControls(
                        torque: $session.torque,
                        thrust: $session.thrust,
                        fire: .constant(false),
                        tractor: $session.retro,
                        largeControls: largeControls,
                        leftHanded: leftHanded,
                        arenaFrame: Self.arenaFrame(in: geometry),
                        windowFrame: TouchControls.windowFrame(in: geometry),
                        loadout: .racer
                    )
                }
                KeyboardControls(
                    torque: $session.torque,
                    thrust: $session.thrust,
                    fire: .constant(false),
                    tractor: $session.retro,
                    onCommand: nil
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)

                if session.state.phase == .countdown {
                    CountdownView(value: max(1, Int(session.countdownSecondsRemaining.rounded(.up))))
                }
                if session.state.phase == .finished {
                    RaceResultsOverlay(
                        session: session,
                        again: { session.restart() },
                        exit: exit
                    )
                }
                if session.isPaused, session.state.phase != .finished {
                    RacePauseOverlay(
                        tuning: tuning,
                        resume: applyAndResume,
                        restart: { session.apply(tuning.snapshot) },
                        leave: { showLeaveConfirmation = true }
                    )
                }
            }
            .accessibilityIdentifier("track-screen")
            .confirmationDialog(
                "Leave the Circuit?",
                isPresented: $showLeaveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Leave Race", role: .destructive) { session.stop(); exit() }
                Button("Keep Driving", role: .cancel) {}
            }
            .onAppear {
                FeedbackCenter.shared.hapticsEnabled = haptics
                session.start()
            }
            .onDisappear { session.stop() }
            .accessibilityAction(named: "Pause race") {
                if !session.isPaused { session.togglePause() }
            }
            .onChange(of: scenePhase) { _, phase in
                session.setApplicationActive(phase == .active)
            }
        }
    }

    /// Sliders only bite on a fresh grid: the corridor's width decides where
    /// the grid is and where the railing sits, so changing it mid-lap would
    /// put ships inside walls. Untouched sliders just resume.
    private func applyAndResume() {
        if tuning.snapshot == session.tuning {
            session.resume()
        } else {
            session.apply(tuning.snapshot)
        }
    }

    /// The circuit sits in the court's screen box, so the pads land in the
    /// same margins they do in a match.
    private static func arenaFrame(in geometry: GeometryProxy) -> CGRect {
        let safe = geometry.frame(in: .global)
        let insets = geometry.safeAreaInsets
        let window = CGRect(
            x: safe.minX - insets.leading,
            y: safe.minY - insets.top,
            width: safe.width + insets.leading + insets.trailing,
            height: safe.height + insets.top + insets.bottom
        )
        let rect = ArenaScene.arenaRect(in: window.size)
        return CGRect(
            x: window.midX + rect.minX,
            y: window.midY + rect.minY,
            width: rect.width,
            height: rect.height
        )
    }
}

private struct TrackHUD: View {
    let session: TrackSession
    let pause: () -> Void
    let leave: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button(action: leave) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.45), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.25)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Leave race")
            .accessibilityIdentifier("leave-race")

            // An endless loop has no finish to reach, so the way out and the
            // way into the settings both have to be on screen the whole time.
            Button(action: pause) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.45), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.25)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pause and open race settings")
            .accessibilityIdentifier("pause-race")

            carColumn(seat: .player, name: "YOU", tint: .cyan)
            Spacer(minLength: 0)
            penaltyBadge
            Spacer(minLength: 0)
            carColumn(seat: .rival, name: "PACE SHIP", tint: .orange)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .foregroundStyle(.white)
    }

    private func carColumn(seat: TrackSeat, name: String, tint: Color) -> some View {
        let car = session.state.cars[seat]
        return VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(size: 10, weight: .heavy, design: .rounded)).tracking(1.5)
                .foregroundStyle(tint)
            Text(lapLabel(for: car))
                .font(.system(size: 17, weight: .black, design: .rounded))
                .monospacedDigit()
            Text(Self.clock(car?.bestLapSeconds))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
        }
        .accessibilityElement(children: .combine)
    }

    /// An endless loop counts up; a flagged one counts down to the flag.
    private func lapLabel(for car: CarState?) -> String {
        let onLap = (car?.lapsCompleted ?? 0) + 1
        guard !session.isEndless else { return "LAP \(onLap)" }
        return "LAP \(min(session.lapsToWin, onLap))/\(session.lapsToWin)"
    }

    /// Only on screen while the hull is actually arcing, so the pilot connects
    /// the lost power to the scrape that caused it rather than to a bug. The
    /// pads still answer the whole time -- that is the point of the badge.
    @ViewBuilder private var penaltyBadge: some View {
        if let car = session.state.cars[.player], car.isDamaged {
            Label(
                "HULL DAMAGED · \(String(format: "%.1f", session.damageSecondsRemaining))s",
                systemImage: "bolt.fill"
            )
            .font(.system(size: 13, weight: .black, design: .rounded)).tracking(1)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.blue.opacity(0.75), in: Capsule())
            .accessibilityIdentifier("damage-badge")
        }
    }

    static func clock(_ seconds: Double?) -> String {
        guard let seconds else { return "BEST --.--" }
        return String(format: "BEST %.2f", seconds)
    }
}

/// Paused, on the circuit. This is also the only way into the race sliders
/// mid-run and -- on an endless loop, where no flag ever falls -- one of the
/// two ways out, so it is reachable from the HUD at all times.
private struct RacePauseOverlay: View {
    @Bindable var tuning: TrackTuningStore
    let resume: () -> Void
    let restart: () -> Void
    let leave: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            NavigationStack {
                RaceTuningView(tuning: tuning, restart: restart)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Resume", action: resume)
                                .accessibilityIdentifier("resume-race")
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button("Leave", role: .destructive, action: leave)
                                .accessibilityIdentifier("leave-race-paused")
                        }
                    }
            }
            .frame(maxWidth: 620, maxHeight: 460)
            .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.25)))
            .padding(20)
        }
        .accessibilityIdentifier("race-pause")
    }
}

private struct RaceResultsOverlay: View {
    let session: TrackSession
    let again: () -> Void
    let exit: () -> Void

    var body: some View {
        let won = session.state.winner == .player
        VStack(spacing: 16) {
            Text(won ? "CHEQUERED FLAG" : "PACE SHIP WINS")
                .font(.system(size: 30, weight: .black, design: .rounded)).tracking(2)
                .foregroundStyle(won ? .cyan : .orange)
            VStack(spacing: 4) {
                Text(TrackHUD.clock(session.player?.bestLapSeconds))
                Text("LAPS \(session.player?.lapsCompleted ?? 0)")
            }
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.75))
            HStack(spacing: 12) {
                Button("RACE AGAIN", action: again)
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                Button("LEAVE", action: exit)
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .font(.system(size: 14, weight: .bold, design: .rounded))
        }
        .padding(28)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.25)))
        .accessibilityIdentifier("race-results")
    }
}
