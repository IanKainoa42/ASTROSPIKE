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

        for (board, value) in submissions { submit(value, to: board.rawValue) }
        return beaten
    }

    private static let practiceBestsKey = "practiceBests"

    /// The pilot's best keep-up and best stay in the bay, on this device.
    static var practiceBests: [PracticeBoard: Int] {
        let raw = UserDefaults.standard.dictionary(forKey: practiceBestsKey) as? [String: Int] ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            PracticeBoard(rawValue: key).map { ($0, value) }
        })
    }

    /// Records a stay in the warm-up bay or practice as the pilot leaves it.
    static func reportPractice(keepUp: Int, hoops: Int) {
        let submissions = PracticeBoard.submissions(keepUp: keepUp, hoops: hoops)
        var bests = practiceBests
        for (board, value) in submissions where value > bests[board, default: 0] {
            bests[board] = value
        }
        UserDefaults.standard.set(
            Dictionary(uniqueKeysWithValues: bests.map { ($0.key.rawValue, $0.value) }),
            forKey: practiceBestsKey
        )
        for (board, value) in submissions { submit(value, to: board.rawValue) }
    }

    /// One call per board: submitScore hands the same value to every id in
    /// its list. Game Center keeps the best for each board itself.
    private static func submit(_ value: Int, to id: String) {
        guard GKLocalPlayer.local.isAuthenticated else { return }
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
}
