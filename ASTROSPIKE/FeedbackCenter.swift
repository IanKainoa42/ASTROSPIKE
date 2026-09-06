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

    func point(team: Team) {
        SpatialAudioCenter.shared.play(
            frequency: team == .cyan ? 720 : 520,
            duration: 0.22,
            positionX: team == .cyan ? -1 : 1
        )
        guard hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func win() {
        SpatialAudioCenter.shared.play(frequency: 880, duration: 0.34, positionX: 0)
        guard hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
