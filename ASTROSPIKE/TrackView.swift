import ASTROSPIKECore
import SpriteKit
import SwiftUI

/// The mini circuit. The same ship, the same arena box and the same gravity
/// as a match -- a very different job: three laps down a wide corridor
/// against one pace ship, with the railing as the only opponent that never
/// makes a mistake.
struct TrackView: View {
    let flight: FlightTuningSnapshot
    let exit: () -> Void

    @State private var session: TrackSession
    @State private var showLeaveConfirmation = false
    @AppStorage("largeControls") private var largeControls = false
    @AppStorage("leftHanded") private var leftHanded = false
    @AppStorage("haptics") private var haptics = true
    @Environment(\.scenePhase) private var scenePhase

    init(flight: FlightTuningSnapshot, exit: @escaping () -> Void) {
        self.flight = flight
        self.exit = exit
        _session = State(initialValue: TrackSession(flight: flight))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                SpriteView(scene: session.scene, options: [.ignoresSiblingOrder])
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    TrackHUD(session: session) { showLeaveConfirmation = true }
                    TouchControls(
                        torque: $session.torque,
                        thrust: $session.thrust,
                        fire: .constant(false),
                        tractor: $session.retro,
                        largeControls: largeControls,
                        leftHanded: leftHanded,
                        arenaFrame: Self.arenaFrame(in: geometry),
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
            .onChange(of: scenePhase) { _, phase in
                session.setApplicationActive(phase == .active)
            }
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
    let leave: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button(action: leave) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.45), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.25)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Leave race")
            .accessibilityIdentifier("leave-race")

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
            Text("LAP \(min(session.lapsToWin, (car?.lapsCompleted ?? 0) + 1))/\(session.lapsToWin)")
                .font(.system(size: 17, weight: .black, design: .rounded))
                .monospacedDigit()
            Text(Self.clock(car?.bestLapSeconds))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
        }
        .accessibilityElement(children: .combine)
    }

    /// Only on screen while it is costing something, so the driver connects it
    /// to the scrape that caused it.
    @ViewBuilder private var penaltyBadge: some View {
        if let car = session.state.cars[.player], car.isStunned {
            Text("RAIL · +\(String(format: "%.1f", car.penaltySeconds))s")
                .font(.system(size: 13, weight: .black, design: .rounded)).tracking(1)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.red.opacity(0.8), in: Capsule())
        }
    }

    static func clock(_ seconds: Double?) -> String {
        guard let seconds else { return "BEST --.--" }
        return String(format: "BEST %.2f", seconds)
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
                Text("PENALTIES \(String(format: "%.1f", session.player?.penaltySeconds ?? 0))s")
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
