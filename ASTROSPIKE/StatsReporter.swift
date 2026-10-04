import ASTROSPIKECore
import Foundation
import GameKit

/// Sends a finished match's numbers to the per-match Game Center boards and
/// keeps the pilot's own bests on the device, so the results card can say
/// NEW BEST whether or not Game Center is signed in.
@MainActor
enum StatsReporter {
    private static let bestsKey = "matchStatBests"

    /// The pilot's best single match on each board, as kept on this device.
    static var bests: [StatBoard: Int] {
        let raw = UserDefaults.standard.dictionary(forKey: bestsKey) as? [String: Int] ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            StatBoard(rawValue: key).map { ($0, value) }
        })
    }

    /// Records the match and returns the boards it set a new best on.
    @discardableResult
    static func report(_ stats: MatchStats, for seat: Seat) -> Set<StatBoard> {
        let submissions = StatBoard.submissions(from: stats, for: seat)
        var bests = bests
        var beaten: Set<StatBoard> = []
        for (board, value) in submissions where value > bests[board, default: 0] {
            bests[board] = value
            beaten.insert(board)
        }
        UserDefaults.standard.set(
            Dictionary(uniqueKeysWithValues: bests.map { ($0.key.rawValue, $0.value) }),
            forKey: bestsKey
        )

        guard GKLocalPlayer.local.isAuthenticated else { return beaten }
        // One call per board: submitScore hands the same value to every id
        // in its list. Game Center keeps the best for each board itself.
        for (board, value) in submissions {
            let id = board.rawValue
            Task {
                do {
                    try await GKLeaderboard.submitScore(
                        value, context: 0, player: GKLocalPlayer.local, leaderboardIDs: [id]
                    )
                } catch {
                    print("STATS: \(id) submit failed: \(error.localizedDescription)")
                }
            }
        }
        return beaten
    }
}
