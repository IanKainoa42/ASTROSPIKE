import ASTROSPIKECore
import SwiftUI
import UIKit

struct TouchControls: View {
    enum Loadout: Equatable {
        case ship
        case racer
    }

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
    /// What the pads are flying. Both fly the same ship; the circuit just has
    /// no cannon, and its beam pad burns out of the tail instead. The same
    /// four thumb positions serve both, so nobody hunts for a trigger that
    /// does nothing.
    var loadout: Loadout = .ship

    @State private var leftPressed = false
    @State private var rightPressed = false
    @State private var thrustPressed = false
    @State private var firePressed = false
    @State private var tractorPressed = false
    /// Ian places the pads himself: Settings → Arrange pads, then drag them
    /// in the bay. Offsets from the drawn default, in points, per pad.
    @AppStorage("arrangePads") private var arranging = false
    @AppStorage("padOffsets2") private var padOffsetsData = Data()

    /// Where Ian dragged the pads on the Mac window (build 34, ~1323x1000 pt, 262 pt engine
    /// margin); the layout math below is the anchor, these ride on top after scaling to the
    /// current window (x by engine-margin width, y by height). Saved drags stack on these.
    private static let bakedReference = CGSize(width: 262, height: 1000)
    private static let bakedOffsets: [String: CGSize] = [
        "steering": CGSize(width: 129, height: -38),
        "tractor": CGSize(width: -109, height: -303),
        "fire": CGSize(width: -49, height: -280),
        "thrust": CGSize(width: -123, height: -246),
    ]
    @State private var dragging: [String: CGSize] = [:]

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

    /// Ian's drawing. Steering owns the whole strip outside the far wall,
    /// L and R halves, full height. On the engine side a thumb cluster
    /// climbs from the bottom corner: thrust sits on the ground with its
    /// inner edge on the wall, the tractor pad directly above it straddling
    /// the wall, and fire up and out toward the screen corner.
    private func marginLayout(local: CGRect, steeringWidth: CGFloat, engineWidth: CGFloat) -> some View {
        let wall = leftHanded ? arenaFrame.minX - local.minX : arenaFrame.maxX - local.minX
        let edge: CGFloat = 6
        let gap: CGFloat = 10
        let slop: CGFloat = 16
        let bottom = local.height - edge
        let bakedScale = CGSize(
            width: min(1, engineWidth / Self.bakedReference.width),
            // Phones (~430 pt tall) keep the pads on the floor; the lift grows with the window.
            height: min(1, max(0, local.height - 400) / (Self.bakedReference.height - 400))
        )
        let thrust = thrustChrome
        let fire = fireChrome

        // Measured outward from the wall (positive = away from the court).
        let thrustOut = thrust.width / 2 + edge
        var tractorOut = fire.width / 2 + edge
        var fireOut = tractorOut + fire.width + gap
        let farthest = engineWidth - edge - fire.width / 2
        if fireOut > farthest {
            fireOut = farthest
            tractorOut = min(tractorOut, fireOut - fire.width - gap)
        }
        let sign: CGFloat = leftHanded ? -1 : 1
        let thrustX = wall + sign * thrustOut
        let tractorX = wall + sign * tractorOut
        let fireX = wall + sign * fireOut

        let thrustY = bottom - (thrust.height + slop) / 2
        let thrustTop = bottom - thrust.height
        let tractorY = thrustTop - gap - (fire.height + slop) / 2
        let fireY = thrustTop + 12 - (fire.height + slop) / 2

        let steeringSpan = steeringWidth + steeringReach
        let steeringX = leftHanded ? local.width - steeringSpan : 0

        return ZStack(alignment: .topLeading) {
            placeable("steering", scale: bakedScale) {
                steeringColumn(width: steeringSpan, height: local.height)
                    .frame(width: steeringSpan, height: local.height)
            }
            .offset(x: steeringX)
            placeable("tractor", scale: bakedScale) {
                tractorPad(chrome: fire)
                    .frame(width: fire.width + slop, height: fire.height + slop)
            }
            .position(x: tractorX, y: tractorY)
            if loadout == .ship {
                placeable("fire", scale: bakedScale) {
                    ControlZone(
                        icon: "bolt.fill", label: "Fire", identifier: "fire-control", tint: .yellow,
                        active: firePressed, chrome: fire, bottomPadding: 0,
                        pressChanged: setFirePressed
                    )
                    .frame(width: fire.width + slop, height: fire.height + slop)
                }
                .position(x: fireX, y: fireY)
            }
            placeable("thrust", scale: bakedScale) {
                ControlZone(
                    icon: "flame.fill", label: "Thrust", identifier: "thrust-control", tint: .orange,
                    active: thrustPressed, chrome: thrust, bottomPadding: 0,
                    pressChanged: setThrustPressed
                )
                .frame(width: thrust.width + slop, height: thrust.height + slop)
            }
            .position(x: thrustX, y: thrustY)
            if arranging {
                Text("DRAG THE PADS · SETTINGS TURNS THIS OFF")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Placing pads by hand

    private var padOffsets: [String: CGSize] {
        get {
            guard let raw = try? JSONDecoder().decode([String: [Double]].self, from: padOffsetsData) else { return [:] }
            return raw.compactMapValues { $0.count == 2 ? CGSize(width: $0[0], height: $0[1]) : nil }
        }
        nonmutating set {
            let raw = newValue.mapValues { [Double($0.width), Double($0.height)] }
            padOffsetsData = (try? JSONEncoder().encode(raw)) ?? Data()
        }
    }

    /// While arranging, the pad stops taking presses and can be dragged
    /// anywhere; its offset from the drawn default persists.
    private func placeable<Pad: View>(_ id: String, scale: CGSize, @ViewBuilder _ pad: () -> Pad) -> some View {
        let raw = Self.bakedOffsets[id] ?? .zero
        let baked = CGSize(width: raw.width * scale.width, height: raw.height * scale.height)
        let saved = padOffsets[id] ?? .zero
        let live = dragging[id] ?? .zero
        return pad()
            .allowsHitTesting(!arranging)
            .overlay {
                if arranging {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture()
                                .onChanged { dragging[id] = $0.translation }
                                .onEnded { value in
                                    var offsets = padOffsets
                                    offsets[id] = CGSize(
                                        width: saved.width + value.translation.width,
                                        height: saved.height + value.translation.height
                                    )
                                    padOffsets = offsets
                                    dragging[id] = nil
                                }
                        )
                }
            }
            .offset(x: baked.width + saved.width + live.width, y: baked.height + saved.height + live.height)
    }

    /// The whole outer strip is the steering surface: press or drag on its
    /// left half to rotate left, right half to rotate right.
    private func steeringColumn(width: CGFloat, height: CGFloat) -> some View {
        let chrome = CGSize(width: max(44, width - 12), height: min(170, height * 0.42))
        return ZStack {
            Rectangle().fill(Color.cyan.opacity(leftPressed || rightPressed ? 0.06 : 0))
            steeringPad(chrome: chrome)
                .offset(y: height * 0.12)
        }
        .contentShape(Rectangle())
    }

    /// How far the steering strip reaches back over the wall into the court.
    /// The margin alone is a narrow ribbon on a phone -- about 150 pt of pad --
    /// and a thumb rolling left and right wants a much broader landing area
    /// than that, so the strip reaches well past the wall. It is the faintest
    /// pad on the screen and sits in the bottom corner, so the court it covers
    /// is court the ball is rarely in.
    private let steeringReach: CGFloat = 190

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
                                .font(.system(size: leftPressed ? 34 : 30, weight: .semibold))
                                .foregroundStyle(Color.cyan.opacity(leftPressed ? 0.82 : 0.28))
                            Spacer(minLength: 0)
                            Image(systemName: "rotate.right")
                                .font(.system(size: rightPressed ? 34 : 30, weight: .semibold))
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
            icon: loadout == .racer ? "arrow.uturn.backward.circle.fill" : "arrow.down.to.line.compact",
            label: loadout == .racer ? "Retro burn" : "Tractor beam",
            identifier: "tractor-control",
            tint: loadout == .racer ? .red : .purple,
            active: tractorPressed, chrome: chrome, bottomPadding: 12,
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
            if loadout == .ship {
                ControlZone(
                    icon: "bolt.fill", label: "Fire", identifier: "fire-control", tint: .yellow,
                    active: firePressed, chrome: fireChrome, pressChanged: setFirePressed
                )
            }
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
