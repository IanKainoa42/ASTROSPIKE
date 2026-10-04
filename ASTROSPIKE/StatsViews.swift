import ASTROSPIKECore
import GameKit
import SwiftUI

/// The local pilot's match in six numbers, under the score on the results
/// card. A number that beat the pilot's best is lit and tagged BEST.
struct MatchStatLine: View {
    let stats: MatchStats
    let seat: Seat
    let newBests: Set<StatBoard>

    var body: some View {
        HStack(spacing: 14) {
            ForEach(StatBoard.allCases, id: \.self) { board in
                let value = board.value(in: stats, for: seat)
                let isBest = newBests.contains(board)
                VStack(spacing: 2) {
                    Text(value.formatted())
                        .font(.title3.monospacedDigit().weight(.black))
                        .foregroundStyle(isBest ? Color.yellow : (value > 0 ? .white : .secondary))
                    // The label stays put so a lit column still says what
                    // it counts; the star marks the new best.
                    HStack(spacing: 2) {
                        if isBest { Image(systemName: "star.fill") }
                        Text(board.shortLabel)
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(isBest ? Color.yellow : .secondary)
                    .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(board.shortLabel.capitalized) \(value)\(isBest ? ", new best" : "")")
            }
            // Saves have no leaderboard (yet), so no BEST tag: just the count.
            let saves = stats[seat].saves
            VStack(spacing: 2) {
                Text(saves.formatted())
                    .font(.title3.monospacedDigit().weight(.black))
                    .foregroundStyle(saves > 0 ? .white : .secondary)
                Text("SAVES")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Saves \(saves)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("results-stats")
    }
}

extension StatBoard {
    var shortLabel: String {
        switch self {
        case .goals: "GOALS"
        case .boltGoals: "BOLT"
        case .slamDunks: "SLAMS"
        case .zaps: "ZAPS"
        case .longestRally: "RALLY"
        }
    }

    var detail: String {
        switch self {
        case .goals: "Goals you put in, any way at all."
        case .boltGoals: "Goals off one of your bolts."
        case .slamDunks: "Hold the ball in your beam, then bolt it through the goal."
        case .zaps: "Bolts you land on an enemy hull."
        case .longestRally: "Most times one point crossed the centre line."
        }
    }
}

/// The break between sets: who took it (the title carries the set count)
/// and both sides' match in numbers, while the ships swap ends.
struct SetBreakBoard: View {
    let title: String?
    let stats: MatchStats
    /// Nil for a spectator: the board then reads CYAN and ORANGE.
    let localTeam: Team?
    let seconds: Int

    private var left: Team { localTeam ?? .cyan }
    private var right: Team { left.opponent }

    private static let rows: [(label: String, value: (PilotStats) -> Int)] = [
        ("GOALS", \.goals),
        ("BOLT GOALS", \.boltGoals),
        ("SLAM DUNKS", \.slamDunks),
        ("ZAPS", \.zaps),
        ("SAVES", \.saves),
        ("CLOSE SAVES", \.closeSaves),
    ]

    var body: some View {
        VStack(spacing: 10) {
            if let title {
                Text(title).font(.system(size: 20, weight: .black, design: .rounded)).tracking(2)
            }
            Grid(horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text(name(left)).foregroundStyle(tint(left))
                    Text(name(right)).foregroundStyle(tint(right))
                }
                .font(.system(size: 11, weight: .black, design: .monospaced))
                ForEach(Self.rows, id: \.label) { row in
                    GridRow {
                        Text(row.label)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                        Text(row.value(stats.total(for: left)).formatted())
                        Text(row.value(stats.total(for: right)).formatted())
                    }
                    .font(.system(size: 17, weight: .black, design: .rounded).monospacedDigit())
                }
            }
            Text("LONGEST RALLY \(stats.longestRally) CROSSINGS")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            Text("SWITCH SIDES · \(seconds)")
                .font(.caption.monospaced().weight(.bold)).tracking(2)
                .foregroundStyle(.white.opacity(0.7))
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 26).padding(.vertical, 16)
        .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.25)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("set-break-board")
    }

    private func tint(_ team: Team) -> Color { team == .cyan ? .cyan : .orange }

    private func name(_ team: Team) -> String {
        guard let localTeam else { return team == .cyan ? "CYAN" : "ORANGE" }
        return team == localTeam ? "YOU" : "RIVAL"
    }
}

/// STATS on the home screen: the pilot's best match on every board, kept on
/// this device, and the way into the Game Center leaderboards.
struct StatsSheet: View {
    @State private var bests = StatsReporter.bests
    @State private var practiceBests = StatsReporter.practiceBests
    private var signedIn: Bool { GKLocalPlayer.local.isAuthenticated }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        GKAccessPoint.shared.trigger(state: .leaderboards) {}
                    } label: {
                        Label("GAME CENTER LEADERBOARDS", systemImage: "trophy.fill")
                            .font(.callout.monospaced().weight(.bold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .disabled(!signedIn)
                    .accessibilityIdentifier("stats-leaderboards")
                } footer: {
                    if !signedIn {
                        Text("Sign in to Game Center in the Settings app to post your bests and see everyone else's.")
                    }
                }
                Section {
                    ForEach(StatBoard.allCases, id: \.self) { board in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(board.title.uppercased())
                                    .font(.caption.monospaced().weight(.bold))
                                Text(board.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(bests[board].map { $0.formatted() } ?? "—")
                                .font(.title3.monospacedDigit().weight(.black))
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("YOUR BEST MATCH")
                } footer: {
                    Text("Solo, doubles and online matches count. Practice and the warm-up bay do not.")
                }
                Section {
                    ForEach(PracticeBoard.allCases, id: \.self) { board in
                        HStack(spacing: 12) {
                            Text(board.title.uppercased())
                                .font(.caption.monospaced().weight(.bold))
                            Spacer()
                            Text(practiceBests[board].map { $0.formatted() } ?? "—")
                                .font(.title3.monospacedDigit().weight(.black))
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("YOUR BEST PRACTICE")
                } footer: {
                    Text("Practice and the warm-up bay post when you leave.")
                }
            }
            .navigationTitle("Stats")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// The plays being called right now, top centre over the court. Each
/// capsule is the colour of the side that made the play.
struct PlayFeed: View {
    let callouts: [PlayCallout]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(callouts) { callout in
                Text(callout.text)
                    .font(.system(size: 13, weight: .black, design: .monospaced)).tracking(1.2)
                    .lineLimit(1)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(callout.team == .cyan ? Color.cyan : Color.orange, in: Capsule())
                    .accessibilityIdentifier("play-call")
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: callouts)
        .allowsHitTesting(false)
    }
}
