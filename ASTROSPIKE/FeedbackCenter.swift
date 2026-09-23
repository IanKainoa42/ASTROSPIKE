import ASTROSPIKECore
import UIKit

@MainActor
final class FeedbackCenter {
    static let shared = FeedbackCenter()
    var hapticsEnabled = true

    // Kept alive and prepared. A cold generator can take tens of milliseconds
    // to spin the engine up, and a control tick that lands late reads as a
    // tick for whatever the thumb did next.
    private let controlTick = UIImpactFeedbackGenerator(style: .soft)
    private let detentTick = UIImpactFeedbackGenerator(style: .rigid)

    private init() {
        controlTick.prepare()
        detentTick.prepare()
    }

    /// A flight-control pad took a press. Soft, because these fire constantly
    /// -- it is confirmation that the pad heard you, not an event.
    func controlPressed() {
        guard hapticsEnabled else { return }
        controlTick.impactOccurred(intensity: 0.7)
        controlTick.prepare()
    }

    /// The steering thumb reached the stop: full deflection, nothing further
    /// out to slide into.
    func steeringStop() {
        guard hapticsEnabled else { return }
        detentTick.impactOccurred(intensity: 0.45)
        detentTick.prepare()
    }

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
        // rally -- a bounce, a crash -- keeps the short tone,
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

    /// A side just came to set or match point. Panned to their end of the
    /// court and pitched by how much is riding on it, so a pilot who never
    /// looks up at the HUD still knows the next rally ends something.
    func stakeRaised(team: Team, stake: Stake) {
        guard stake != .none else { return }
        SpatialAudioCenter.shared.play(
            frequency: stake == .matchPoint ? 990 : 780,
            duration: 0.26,
            positionX: team == .cyan ? -1 : 1
        )
        guard hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    func win() {
        SpatialAudioCenter.shared.play(frequency: 880, duration: 0.34, positionX: 0)
        guard hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func lose() {
        SpatialAudioCenter.shared.play(frequency: 220, duration: 0.42, positionX: 0)
        guard hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
