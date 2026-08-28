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

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if leftHanded {
                thrustZone
                Spacer()
                steeringZones
            } else {
                steeringZones
                Spacer()
                thrustZone
            }
        }
        .padding(.horizontal, largeControls ? 34 : 24)
        .padding(.bottom, largeControls ? 24 : 16)
        .accessibilityElement(children: .contain)
        .onDisappear { clearInput() }
    }

    private var steeringZones: some View {
        HStack(spacing: 4) {
            ControlZone(
                icon: "rotate.left",
                label: "Rotate left",
                identifier: "rotate-left-control",
                tint: .cyan,
                active: leftPressed,
                width: steeringZoneWidth,
                height: zoneHeight,
                pressChanged: setLeftPressed
            )
            ControlZone(
                icon: "rotate.right",
                label: "Rotate right",
                identifier: "rotate-right-control",
                tint: .cyan,
                active: rightPressed,
                width: steeringZoneWidth,
                height: zoneHeight,
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
            width: thrustZoneWidth,
            height: zoneHeight,
            pressChanged: setThrustPressed
        )
    }

    private var steeringZoneWidth: CGFloat { largeControls ? 132 : 104 }
    private var thrustZoneWidth: CGFloat { largeControls ? 170 : 140 }
    private var zoneHeight: CGFloat { largeControls ? 132 : 108 }

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
    let width: CGFloat
    let height: CGFloat
    let pressChanged: (Bool) -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(active ? tint.opacity(0.13) : .black.opacity(0.08))
            RoundedRectangle(cornerRadius: 20)
                .stroke(tint.opacity(active ? 0.34 : 0.10), lineWidth: active ? 2 : 1)
            Image(systemName: icon)
                .font(.system(size: active ? 30 : 25, weight: .semibold))
                .foregroundStyle(tint.opacity(active ? 0.82 : 0.28))
            PressCapture(pressChanged: pressChanged)
                .accessibilityHidden(true)
        }
        .frame(width: width, height: height)
        .contentShape(RoundedRectangle(cornerRadius: 20))
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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        pressChanged?(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        if event?.allTouches?.allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) != false {
            pressChanged?(false)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        pressChanged?(false)
    }
}
