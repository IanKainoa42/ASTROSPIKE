import ASTROSPIKECore
import SwiftUI
import UIKit

struct TouchControls: View {
    @Binding var torque: Double
    @Binding var thrust: Bool
    @Binding var fire: Bool
    @Binding var tractor: Bool
    let largeControls: Bool
    let leftHanded: Bool
    /// The court's frame in global coordinates. The pads live in the margins
    /// either side of it: a thumb never has to reach past the court's edge
    /// and never covers the play.
    let arenaFrame: CGRect

    @State private var leftPressed = false
    @State private var rightPressed = false
    @State private var thrustPressed = false
    @State private var firePressed = false
    @State private var tractorPressed = false

    /// A margin narrower than this cannot hold a pad; the old full-bleed
    /// split (steer left, engine right) takes over, as on a portrait phone.
    private let minimumMargin: CGFloat = 60

    var body: some View {
        GeometryReader { geometry in
            let local = geometry.frame(in: .global)
            let leftMargin = max(0, arenaFrame.minX - local.minX)
            let rightMargin = max(0, local.maxX - arenaFrame.maxX)
            let steeringWidth = leftHanded ? rightMargin : leftMargin
            let engineWidth = leftHanded ? leftMargin : rightMargin
            if steeringWidth >= minimumMargin, engineWidth >= minimumMargin {
                marginLayout(
                    local: local,
                    steeringWidth: steeringWidth,
                    engineWidth: engineWidth
                )
            } else {
                fullBleedLayout
            }
        }
        .accessibilityElement(children: .contain)
        .onDisappear { clearInput() }
    }

    // MARK: Margin layout

    /// One row of pads along the bottom, each hand anchored in its screen
    /// corner: thrust sits right in the corner, fire next to it overlapping
    /// the court's edge from outside, and the tractor pad just inside the
    /// court. Steering does the same on the other side, straddling that edge.
    private func marginLayout(local: CGRect, steeringWidth: CGFloat, engineWidth: CGFloat) -> some View {
        let edge: CGFloat = 6
        let gap: CGFloat = 8
        let slop: CGFloat = 16
        let bottom = local.height - edge

        let thrust = thrustChrome
        let fire = fireChrome
        let steering = CGSize(
            width: max(steeringChrome.width, steeringWidth + steeringOverlap - edge),
            height: steeringChrome.height
        )

        // Right-handed: engine pads march inward from the right corner.
        var thrustX = local.width - edge - thrust.width / 2
        var fireX = thrustX - thrust.width / 2 - gap - fire.width / 2
        var tractorX = fireX - fire.width / 2 - gap - fire.width / 2
        var steeringX = edge + steering.width / 2
        if leftHanded {
            thrustX = local.width - thrustX
            fireX = local.width - fireX
            tractorX = local.width - tractorX
            steeringX = local.width - steeringX
        }

        return ZStack(alignment: .topLeading) {
            steeringPad(chrome: steering)
                .frame(width: steering.width + slop, height: steering.height + slop)
                .position(x: steeringX, y: bottom - (steering.height + slop) / 2)
            tractorPad(chrome: fire)
                .frame(width: fire.width + slop, height: fire.height + slop)
                .position(x: tractorX, y: bottom - (fire.height + slop) / 2)
            ControlZone(
                icon: "bolt.fill", label: "Fire", identifier: "fire-control", tint: .yellow,
                active: firePressed, chrome: fire, bottomPadding: 0,
                pressChanged: setFirePressed
            )
            .frame(width: fire.width + slop, height: fire.height + slop)
            .position(x: fireX, y: bottom - (fire.height + slop) / 2)
            ControlZone(
                icon: "flame.fill", label: "Thrust", identifier: "thrust-control", tint: .orange,
                active: thrustPressed, chrome: thrust, bottomPadding: 0,
                pressChanged: setThrustPressed
            )
            .frame(width: thrust.width + slop, height: thrust.height + slop)
            .position(x: thrustX, y: bottom - (thrust.height + slop) / 2)
        }
    }

    /// How far the steering pad reaches past the court's edge into the play.
    private let steeringOverlap: CGFloat = 28

    private func steeringPad(chrome: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(leftPressed || rightPressed ? Color.cyan.opacity(0.13) : .black.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.cyan.opacity(leftPressed || rightPressed ? 0.34 : 0.10),
                                lineWidth: leftPressed || rightPressed ? 2 : 1)
                )
                .overlay(
                    VStack(spacing: 10) {
                        HStack(spacing: 4) {
                            Image(systemName: "rotate.left")
                                .font(.system(size: leftPressed ? 26 : 22, weight: .semibold))
                                .foregroundStyle(Color.cyan.opacity(leftPressed ? 0.82 : 0.28))
                            Spacer(minLength: 0)
                            Image(systemName: "rotate.right")
                                .font(.system(size: rightPressed ? 26 : 22, weight: .semibold))
                                .foregroundStyle(Color.cyan.opacity(rightPressed ? 0.82 : 0.28))
                        }
                        .padding(.horizontal, 10)
                        trimSliderIndicator(width: chrome.width - 24)
                    }
                )
                .frame(width: chrome.width, height: chrome.height)
            SteeringCapture(
                onTorque: { torque = $0 },
                onActive: { left, right in leftPressed = left; rightPressed = right }
            )
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Steer")
        .accessibilityValue(leftPressed ? "Rotating left" : rightPressed ? "Rotating right" : "Idle")
        .accessibilityIdentifier("steering-control")
    }

    private func tractorPad(chrome: CGSize) -> some View {
        ControlZone(
            icon: "arrow.down.to.line.compact", label: "Tractor beam", identifier: "tractor-control",
            tint: .purple, active: tractorPressed, chrome: chrome, bottomPadding: 12,
            pressChanged: setTractorPressed
        )
    }

    // MARK: Full-bleed fallback

    private var fullBleedLayout: some View {
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
    }

    /// A dead strip down the middle so a stray thumb over the arena does nothing.
    private var neutralGap: some View {
        Color.clear.frame(width: largeControls ? 24 : 36)
    }

    private var steeringZones: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                ControlZone(
                    icon: "rotate.left", label: "Rotate left", identifier: "rotate-left-control",
                    tint: .cyan, active: leftPressed, chrome: steeringChrome, pressChanged: nil
                )
                ControlZone(
                    icon: "rotate.right", label: "Rotate right", identifier: "rotate-right-control",
                    tint: .cyan, active: rightPressed, chrome: steeringChrome, pressChanged: nil
                )
            }
            trimSliderIndicator(width: steeringChrome.width * 2 - 36)
                .padding(.bottom, 16)
                .allowsHitTesting(false)
            SteeringCapture(
                onTorque: { torque = $0 },
                onActive: { left, right in leftPressed = left; rightPressed = right }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Fire over thrust, and the beam over fire, all for the one thumb.
    private var thrustZone: some View {
        VStack(spacing: 0) {
            tractorPad(chrome: fireChrome)
            ControlZone(
                icon: "bolt.fill", label: "Fire", identifier: "fire-control", tint: .yellow,
                active: firePressed, chrome: fireChrome, pressChanged: setFirePressed
            )
            ControlZone(
                icon: "flame.fill", label: "Thrust", identifier: "thrust-control", tint: .orange,
                active: thrustPressed, chrome: thrustChrome, pressChanged: setThrustPressed
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Shared

    private func trimSliderIndicator(width totalWidth: CGFloat) -> some View {
        let maxOffset: CGFloat = totalWidth / 2 - 12
        // Torque: +1 is left, -1 is right
        let currentOffset: CGFloat = CGFloat(-torque) * maxOffset
        let isPegged = abs(torque) >= 0.98

        return ZStack {
            Capsule()
                .fill(Color.white.opacity(0.08))
                .frame(width: totalWidth, height: 4)
            Rectangle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 2, height: 8)
            Capsule()
                .fill(Color.cyan.opacity(abs(torque) > 0 ? (isPegged ? 1.0 : 0.85) : 0.25))
                .frame(width: isPegged ? 24 : 16, height: 6)
                .shadow(color: .cyan.opacity(abs(torque) > 0 ? 0.8 : 0), radius: isPegged ? 6 : 3)
                .offset(x: currentOffset)
                .animation(.easeOut(duration: 0.08), value: torque)
        }
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

    private func setThrustPressed(_ pressed: Bool) {
        thrustPressed = pressed
        thrust = pressed
    }

    private func setFirePressed(_ pressed: Bool) {
        firePressed = pressed
        fire = pressed
    }

    private func setTractorPressed(_ pressed: Bool) {
        tractorPressed = pressed
        tractor = pressed
    }

    private func clearInput() {
        leftPressed = false
        rightPressed = false
        thrustPressed = false
        firePressed = false
        tractorPressed = false
        torque = 0
        thrust = false
        fire = false
        tractor = false
    }
}

private struct ControlZone: View {
    let icon: String
    let label: String
    let identifier: String
    let tint: Color
    let active: Bool
    let chrome: CGSize
    var bottomPadding: CGFloat = 14
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
                .padding(.bottom, bottomPadding)
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
