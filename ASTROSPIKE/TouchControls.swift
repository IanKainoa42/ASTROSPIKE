import ASTROSPIKECore
import SwiftUI
import UIKit

struct TouchControls: View {
    @Binding var torque: Double
    @Binding var thrust: Bool
    let largeControls: Bool
    let leftHanded: Bool

    @State private var leftPressed = false
    @State private var rightPressed = false
    @State private var thrustPressed = false

    // The live area is the whole side of the screen, not the drawn button. A thumb
    // anywhere on the right thrusts; anywhere on the left steers. The chrome is
    // only a hint about where the thumb usually rests.
    var body: some View {
        HStack(spacing: 0) {
            if leftHanded {
                thrustZone
                neutralGap
                steeringZones
            } else {
                steeringZones
                neutralGap
                thrustZone
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .onDisappear { clearInput() }
    }

    /// A dead strip down the middle so a stray thumb over the arena does nothing.
    private var neutralGap: some View {
        Color.clear.frame(width: largeControls ? 24 : 36)
    }

    private var steeringZones: some View {
        HStack(spacing: 0) {
            ControlZone(
                icon: "rotate.left",
                label: "Rotate left",
                identifier: "rotate-left-control",
                tint: .cyan,
                active: leftPressed,
                chrome: steeringChrome,
                pressChanged: setLeftPressed
            )
            ControlZone(
                icon: "rotate.right",
                label: "Rotate right",
                identifier: "rotate-right-control",
                tint: .cyan,
                active: rightPressed,
                chrome: steeringChrome,
                pressChanged: setRightPressed
            )
        }
    }

    private var thrustZone: some View {
        ControlZone(
            icon: "flame.fill",
            label: "Thrust",
            identifier: "thrust-control",
            tint: .orange,
            active: thrustPressed,
            chrome: thrustChrome,
            pressChanged: setThrustPressed
        )
    }

    private var steeringChrome: CGSize {
        largeControls ? CGSize(width: 132, height: 132) : CGSize(width: 104, height: 108)
    }
    private var thrustChrome: CGSize {
        largeControls ? CGSize(width: 200, height: 148) : CGSize(width: 168, height: 122)
    }

    private func setLeftPressed(_ pressed: Bool) {
        leftPressed = pressed
        applyInput(left: pressed, right: rightPressed, thrusting: thrustPressed)
    }

    private func setRightPressed(_ pressed: Bool) {
        rightPressed = pressed
        applyInput(left: leftPressed, right: pressed, thrusting: thrustPressed)
    }

    private func setThrustPressed(_ pressed: Bool) {
        thrustPressed = pressed
        applyInput(left: leftPressed, right: rightPressed, thrusting: pressed)
    }

    private func applyInput(left: Bool, right: Bool, thrusting: Bool) {
        let input = FlightControlMapping.input(
            tick: 0,
            leftPressed: left,
            rightPressed: right,
            thrustPressed: thrusting
        )
        torque = input.torque
        thrust = input.thrust
    }

    private func clearInput() {
        leftPressed = false
        rightPressed = false
        thrustPressed = false
        torque = 0
        thrust = false
    }
}

private struct ControlZone: View {
    let icon: String
    let label: String
    let identifier: String
    let tint: Color
    let active: Bool
    let chrome: CGSize
    let pressChanged: (Bool) -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            // Holding anywhere in the zone tints all of it, so it is obvious that
            // the whole side is the control and not just the drawn rectangle.
            Rectangle()
                .fill(tint.opacity(active ? 0.06 : 0))
            RoundedRectangle(cornerRadius: 20)
                .fill(active ? tint.opacity(0.13) : .black.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(tint.opacity(active ? 0.34 : 0.10), lineWidth: active ? 2 : 1)
                )
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: active ? 30 : 25, weight: .semibold))
                        .foregroundStyle(tint.opacity(active ? 0.82 : 0.28))
                )
                .frame(width: chrome.width, height: chrome.height)
                .padding(.bottom, 14)
            // Fills the zone, so this is what actually receives the touch.
            PressCapture(pressChanged: pressChanged)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(active ? "Pressed" : "Released")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier)
    }
}

private struct PressCapture: UIViewRepresentable {
    let pressChanged: (Bool) -> Void

    func makeUIView(context: Context) -> PressCaptureView {
        let view = PressCaptureView()
        view.isMultipleTouchEnabled = true
        view.isAccessibilityElement = false
        view.pressChanged = pressChanged
        return view
    }

    func updateUIView(_ view: PressCaptureView, context: Context) {
        view.pressChanged = pressChanged
    }
}

private final class PressCaptureView: UIView {
    var pressChanged: ((Bool) -> Void)?
    private var pressTracker = ControlPressTracker<ObjectIdentifier>()

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        touches.forEach { pressTracker.began(ObjectIdentifier($0)) }
        pressChanged?(pressTracker.isPressed)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        touches.forEach { pressTracker.ended(ObjectIdentifier($0)) }
        pressChanged?(pressTracker.isPressed)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        touches.forEach { pressTracker.cancelled(ObjectIdentifier($0)) }
        pressChanged?(pressTracker.isPressed)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window == nil else { return }
        pressTracker.cancelAll()
        pressChanged?(false)
    }
}
