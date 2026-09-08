import ASTROSPIKECore
import SwiftUI
import UIKit

struct TouchControls: View {
    @Binding var torque: Double
    @Binding var thrust: Bool
    @Binding var fire: Bool
    let largeControls: Bool
    let leftHanded: Bool

    @State private var leftPressed = false
    @State private var rightPressed = false
    @State private var thrustPressed = false
    @State private var firePressed = false

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
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                ControlZone(
                    icon: "rotate.left",
                    label: "Rotate left",
                    identifier: "rotate-left-control",
                    tint: .cyan,
                    active: leftPressed,
                    chrome: steeringChrome,
                    edgeOffset: steeringEdgeOffset,
                    pressChanged: nil
                )
                ControlZone(
                    icon: "rotate.right",
                    label: "Rotate right",
                    identifier: "rotate-right-control",
                    tint: .cyan,
                    active: rightPressed,
                    chrome: steeringChrome,
                    edgeOffset: steeringEdgeOffset,
                    pressChanged: nil
                )
            }

            // Trim slider needle indicator across the bottom chrome
            trimSliderIndicator
                .padding(.bottom, 16)
                .allowsHitTesting(false)

            // Touch capture for continuous slide/trim and pegged edge hold
            SteeringCapture(
                onTorque: { newTorque in
                    torque = newTorque
                },
                onActive: { left, right in
                    leftPressed = left
                    rightPressed = right
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var trimSliderIndicator: some View {
        let totalWidth: CGFloat = (steeringChrome.width * 2) - 36
        let maxOffset: CGFloat = totalWidth / 2 - 20
        // Torque: +1 is left, -1 is right
        let currentOffset: CGFloat = CGFloat(-torque) * maxOffset
        let isPegged = abs(torque) >= 0.98

        return ZStack {
            // Track
            Capsule()
                .fill(Color.white.opacity(0.08))
                .frame(width: totalWidth, height: 4)
            // Center detent
            Rectangle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 2, height: 8)
            // Sliding needle
            Capsule()
                .fill(Color.cyan.opacity(abs(torque) > 0 ? (isPegged ? 1.0 : 0.85) : 0.25))
                .frame(width: isPegged ? 28 : 20, height: 6)
                .shadow(color: .cyan.opacity(abs(torque) > 0 ? 0.8 : 0), radius: isPegged ? 6 : 3)
                .offset(x: currentOffset)
                .animation(.easeOut(duration: 0.08), value: torque)
        }
    }

    /// Fire sits above thrust so the same resting thumb pushes down to fly and
    /// lifts slightly to fire. Both are held with the same thumb, so the
    /// hint chrome sits low where it rests.
    private var thrustZone: some View {
        VStack(spacing: 0) {
            firePad
            thrustPad
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var thrustPad: some View {
        ControlZone(
            icon: "flame.fill",
            label: "Thrust",
            identifier: "thrust-control",
            tint: .orange,
            active: thrustPressed,
            chrome: thrustChrome,
            edgeOffset: thrustEdgeOffset,
            pressChanged: setThrustPressed
        )
    }

    private var firePad: some View {
        ControlZone(
            icon: "bolt.fill",
            label: "Fire",
            identifier: "fire-control",
            tint: .yellow,
            active: firePressed,
            chrome: fireChrome,
            edgeOffset: thrustEdgeOffset,
            pressChanged: setFirePressed
        )
    }

    private var steeringChrome: CGSize {
        largeControls ? CGSize(width: 132, height: 132) : CGSize(width: 104, height: 108)
    }
    private var thrustChrome: CGSize {
        largeControls ? CGSize(width: 132, height: 148) : CGSize(width: 108, height: 122)
    }
    private var fireChrome: CGSize {
        largeControls ? CGSize(width: 104, height: 118) : CGSize(width: 84, height: 96)
    }

    /// Nudges the drawn chrome (not the touch zone, which stays full-bleed)
    /// a little further toward the screen's physical edge so the arena in
    /// the middle stays clearer.
    private let edgeNudge: CGFloat = 14
    private var steeringEdgeOffset: CGFloat { leftHanded ? edgeNudge : -edgeNudge }
    private var thrustEdgeOffset: CGFloat { leftHanded ? -edgeNudge : edgeNudge }

    private func setThrustPressed(_ pressed: Bool) {
        thrustPressed = pressed
        thrust = pressed
    }

    private func setFirePressed(_ pressed: Bool) {
        firePressed = pressed
        fire = pressed
    }

    private func clearInput() {
        leftPressed = false
        rightPressed = false
        thrustPressed = false
        firePressed = false
        torque = 0
        thrust = false
        fire = false
    }
}

private struct ControlZone: View {
    let icon: String
    let label: String
    let identifier: String
    let tint: Color
    let active: Bool
    let chrome: CGSize
    var edgeOffset: CGFloat = 0
    let pressChanged: ((Bool) -> Void)?

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
                .offset(x: edgeOffset)
                .padding(.bottom, 14)
            if let pressChanged {
                // Fills the zone, so this is what actually receives the touch.
                PressCapture(pressChanged: pressChanged)
                    .accessibilityHidden(true)
            }
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

private struct SteeringCapture: UIViewRepresentable {
    let onTorque: (Double) -> Void
    let onActive: (Bool, Bool) -> Void

    func makeUIView(context: Context) -> SteeringCaptureView {
        let view = SteeringCaptureView()
        view.isMultipleTouchEnabled = true
        view.isAccessibilityElement = false
        view.onTorqueChanged = onTorque
        view.onActiveChanged = onActive
        return view
    }

    func updateUIView(_ view: SteeringCaptureView, context: Context) {
        view.onTorqueChanged = onTorque
        view.onActiveChanged = onActive
    }
}

private final class SteeringCaptureView: UIView {
    var onTorqueChanged: ((Double) -> Void)?
    var onActiveChanged: ((Bool, Bool) -> Void)?

    private var activeTouchID: ObjectIdentifier?
    private var touchAnchor: CGPoint = .zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard activeTouchID == nil, let touch = touches.first else { return }
        let id = ObjectIdentifier(touch)
        activeTouchID = id
        touchAnchor = touch.location(in: self)
        updateTorque(for: touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let activeID = activeTouchID,
              let touch = touches.first(where: { ObjectIdentifier($0) == activeID }) else { return }
        updateTorque(for: touch)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard let activeID = activeTouchID,
              touches.contains(where: { ObjectIdentifier($0) == activeID }) else { return }
        releaseTouch()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        guard let activeID = activeTouchID,
              touches.contains(where: { ObjectIdentifier($0) == activeID }) else { return }
        releaseTouch()
    }

    private func updateTorque(for touch: UITouch) {
        let current = touch.location(in: self)
        let deltaX = current.x - touchAnchor.x
        let deadZone: CGFloat = 6.0
        let pegThreshold: CGFloat = 42.0

        if abs(deltaX) > deadZone {
            let magnitude = Double(min(1.0, max(0.0, (abs(deltaX) - deadZone) / (pegThreshold - deadZone))))
            let analogTorque: Double = 0.18 + 0.82 * (magnitude * magnitude)
            if deltaX < 0 {
                // Dragging left -> Rotate left (positive torque)
                let t = min(1.0, analogTorque)
                onTorqueChanged?(t)
                onActiveChanged?(true, false)
            } else {
                // Dragging right -> Rotate right (negative torque)
                let t = -min(1.0, analogTorque)
                onTorqueChanged?(t)
                onActiveChanged?(false, true)
            }
        } else {
            // Stationary tap: check which half of the steering container was tapped
            let midX = bounds.width / 2
            if touchAnchor.x < midX {
                onTorqueChanged?(1.0)
                onActiveChanged?(true, false)
            } else {
                onTorqueChanged?(-1.0)
                onActiveChanged?(false, true)
            }
        }
    }

    private func releaseTouch() {
        activeTouchID = nil
        onTorqueChanged?(0.0)
        onActiveChanged?(false, false)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window == nil else { return }
        releaseTouch()
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
        updateTrackedTouches(touches) { pressTracker.began($0) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        updateTrackedTouches(touches) { pressTracker.ended($0) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        updateTrackedTouches(touches) { pressTracker.cancelled($0) }
    }

    private func updateTrackedTouches(_ touches: Set<UITouch>, _ update: (ObjectIdentifier) -> Void) {
        touches.forEach { update(ObjectIdentifier($0)) }
        pressChanged?(pressTracker.isPressed)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window == nil else { return }
        pressTracker.cancelAll()
        pressChanged?(false)
    }
}
