import SwiftUI

struct TouchControls: View {
    @Binding var torque: Double
    @Binding var thrust: Bool
    let largeControls: Bool
    let leftHanded: Bool

    var body: some View {
        HStack {
            if leftHanded { thrustButton; Spacer(); torqueControl }
            else { torqueControl; Spacer(); thrustButton }
        }
        .padding(.horizontal, largeControls ? 44 : 28)
        .padding(.bottom, largeControls ? 30 : 20)
        .accessibilityElement(children: .contain)
    }

    private var torqueControl: some View {
        ZStack {
            Circle().fill(.black.opacity(0.32))
            Circle().stroke(.cyan.opacity(0.65), lineWidth: 2)
            Capsule().fill(.white.opacity(0.75)).frame(width: 3, height: 24)
                .rotationEffect(.degrees(torque * 58))
            HStack {
                Image(systemName: "rotate.left")
                Spacer()
                Image(systemName: "rotate.right")
            }
            .padding(15)
            .foregroundStyle(.cyan)
        }
        .frame(width: controlSize, height: controlSize)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let center = controlSize / 2
                    torque = max(-1, min(1, (value.location.x - center) / (center * 0.72)))
                }
                .onEnded { _ in torque = 0 }
        )
        .accessibilityLabel("Rotational torque")
        .accessibilityValue(torque.formatted(.number.precision(.fractionLength(1))))
        .accessibilityIdentifier("torque-control")
    }

    private var thrustButton: some View {
        ZStack {
            Circle().fill(thrust ? Color.orange.opacity(0.46) : .black.opacity(0.32))
            Circle().stroke(.orange.opacity(0.8), lineWidth: thrust ? 5 : 2)
            Image(systemName: "flame.fill")
                .font(.system(size: largeControls ? 38 : 30, weight: .bold))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, isActive: thrust)
        }
        .frame(width: controlSize, height: controlSize)
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

    private var controlSize: CGFloat { largeControls ? 116 : 92 }
}
