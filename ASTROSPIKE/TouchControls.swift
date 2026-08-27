import SwiftUI

struct TouchControls: View {
    @Binding var torque: Double
    @Binding var thrust: Bool
    let largeControls: Bool
    let leftHanded: Bool

    var body: some View {
        HStack {
            if leftHanded { thrustButton; Spacer(); steeringControl }
            else { steeringControl; Spacer(); thrustButton }
        }
        .padding(.horizontal, largeControls ? 28 : 18)
        .padding(.bottom, largeControls ? 20 : 14)
        .accessibilityElement(children: .contain)
    }

    private var steeringControl: some View {
        HStack(spacing: largeControls ? 14 : 10) {
            steeringButton(direction: -1, symbol: "chevron.left", label: "Rotate left")
            steeringButton(direction: 1, symbol: "chevron.right", label: "Rotate right")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("torque-control")
    }

    private func steeringButton(direction: Double, symbol: String, label: String) -> some View {
        let isPressed = torque == direction
        return ZStack {
            Circle().fill(isPressed ? Color.cyan.opacity(0.30) : .black.opacity(0.28))
            Circle().stroke(.cyan.opacity(isPressed ? 0.95 : 0.62), lineWidth: isPressed ? 4 : 2)
            Image(systemName: symbol)
                .font(.system(size: largeControls ? 30 : 24, weight: .black))
                .foregroundStyle(.cyan)
        }
        .frame(width: steeringSize, height: steeringSize)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in torque = direction }
                .onEnded { _ in if torque == direction { torque = 0 } }
        )
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(direction < 0 ? "rotate-left-control" : "rotate-right-control")
    }

    private var thrustButton: some View {
        ZStack {
            Circle().fill(thrust ? Color.orange.opacity(0.46) : .black.opacity(0.32))
            Circle().stroke(.orange.opacity(0.8), lineWidth: thrust ? 5 : 2)
            Image(systemName: "arrow.up")
                .font(.system(size: largeControls ? 36 : 29, weight: .black))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, isActive: thrust)
        }
        .frame(width: thrustSize, height: thrustSize)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in thrust = true }
                .onEnded { _ in thrust = false }
        )
        .accessibilityLabel("Thrust")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("thrust-control")
    }

    private var steeringSize: CGFloat { largeControls ? 78 : 64 }
    private var thrustSize: CGFloat { largeControls ? 94 : 80 }
}
