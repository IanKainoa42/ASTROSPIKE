import ASTROSPIKECore
import UIKit

@MainActor
final class FeedbackCenter {
    static let shared = FeedbackCenter()
    var hapticsEnabled = true

    func impact(positionX: Float = 0) {
        SpatialAudioCenter.shared.play(frequency: 145, duration: 0.08, positionX: positionX)
        guard hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.65)
    }

    /// Menu selection tick: haptic only, no tone.
    func tap() {
        guard hapticsEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func point(team: Team, reason: PointReason = .goal) {
        // A goal has its own recorded fanfare; everything else that ends a
        // rally -- a bounce, a touch limit, a crash -- keeps the short tone,
        // because those happen several times a set and a fanfare would wear
        // out long before the match did.
        if reason == .goal {
            SoundBank.shared.play(.goal, positionX: team == .cyan ? -0.4 : 0.4)
        } else {
            SpatialAudioCenter.shared.play(
                frequency: team == .cyan ? 720 : 520,
                duration: 0.22,
                positionX: team == .cyan ? -1 : 1
            )
        }
        guard hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// A ship pushed past its own MAX CROSS line into the far half.
    func crossedOffside(team: Team, positionX: Double) {
        SoundBank.shared.play(.offside(team), positionX: Float(positionX), volume: 0.85)
        guard hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.5)
    }

    func win() {
        SpatialAudioCenter.shared.play(frequency: 880, duration: 0.34, positionX: 0)
        guard hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
