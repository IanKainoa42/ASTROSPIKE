import UIKit

/// Input command from the player (gamepad, touch, or keyboard).
struct PlayerInput: Equatable, Codable {
    /// Steering torque (-1.0 to 1.0, where negative = counterclockwise rotation).
    var torque: Double

    /// Engine thrust engaged?
    var thrust: Bool

    /// Fire/shoot engaged?
    var fire: Bool

    /// Network tick this input corresponds to (for server reconciliation).
    var tick: UInt64

    init(tick: UInt64 = 0, torque: Double = 0, thrust: Bool = false, fire: Bool = false) {
        self.tick = tick
        self.torque = max(-1.0, min(1.0, torque))
        self.thrust = thrust
        self.fire = fire
    }

    /// Idle input (no actions, typically for remote players when no data received).
    static func idle(tick: UInt64) -> PlayerInput {
        PlayerInput(tick: tick)
    }
}

/// Processes raw touch/gesture input and converts it to normalized player input.
/// Handles both analog stick simulation and discrete button presses.
@MainActor
final class TouchInputHandler: NSObject, UIGestureRecognizerDelegate {
    /// Analog value representing steering torque.
    private(set) var currentTorque: Double = 0.0

    /// Whether thrust button is currently pressed.
    private(set) var thrustPressed: Bool = false

    /// Whether fire button is currently pressed.
    private(set) var firePressed: Bool = false

    /// Whether tractor button is currently pressed (alternate action).
    private(set) var tractorPressed: Bool = false

    /// Callback fired when input state changes.
    var onInputChanged: (@MainActor () -> Void)?

    // MARK: - Touch Tracking

    private var touchTrackingPoints: [UITouch: CGPoint] = [:]
    private let gestureHandler = GestureInputHandler()

    override init() {
        super.init()
        setupGestureRecognizers()
    }

    /// Current player input state as a single struct.
    var currentInput: PlayerInput {
        PlayerInput(
            torque: currentTorque,
            thrust: thrustPressed,
            fire: firePressed
        )
    }

    /// Reset all input state to idle.
    func reset() {
        currentTorque = 0.0
        thrustPressed = false
        firePressed = false
        tractorPressed = false
        touchTrackingPoints.removeAll()
    }

    // MARK: - Setup

    private func setupGestureRecognizers() {
        // Subclass-friendly: override this or add recognizers to a view externally.
    }

    // MARK: - Touch Handling

    /// Register touch points for steering simulation.
    /// Call this from your UIView's touchesBegan.
    func handleTouchesBegan(_ touches: Set<UITouch>, in view: UIView) {
        for touch in touches {
            let location = touch.location(in: view)
            touchTrackingPoints[touch] = location
            updateTorqueFromTouches(in: view)
        }
        onInputChanged?()
    }

    /// Update touch positions for steering.
    /// Call this from your UIView's touchesMoved.
    func handleTouchesMoved(_ touches: Set<UITouch>, in view: UIView) {
        for touch in touches {
            let location = touch.location(in: view)
            touchTrackingPoints[touch] = location
        }
        updateTorqueFromTouches(in: view)
        onInputChanged?()
    }

    /// Remove touch tracking.
    /// Call this from your UIView's touchesEnded.
    func handleTouchesEnded(_ touches: Set<UITouch>, in view: UIView) {
        for touch in touches {
            touchTrackingPoints.removeValue(forKey: touch)
        }
        updateTorqueFromTouches(in: view)
        onInputChanged?()
    }

    /// Handle touch cancellation (e.g., system gesture).
    func handleTouchesCancelled(_ touches: Set<UITouch>, in view: UIView) {
        for touch in touches {
            touchTrackingPoints.removeValue(forKey: touch)
        }
        updateTorqueFromTouches(in: view)
        onInputChanged?()
    }

    // MARK: - Steering Calculation

    private func updateTorqueFromTouches(in view: UIView) {
        guard !touchTrackingPoints.isEmpty else {
            currentTorque = 0.0
            return
        }

        let viewBounds = view.bounds
        var totalTorque: Double = 0.0
        var touchCount = 0

        for (_, position) in touchTrackingPoints {
            // Normalize position: -1.0 (left) to 1.0 (right)
            let normalizedX = Double(position.x) / Double(viewBounds.width) * 2.0 - 1.0
            totalTorque += normalizedX
            touchCount += 1
        }

        currentTorque = totalTorque / Double(max(1, touchCount))
        currentTorque = max(-1.0, min(1.0, currentTorque))
    }

    // MARK: - Button Handling

    /// Set thrust button state.
    func setThrust(_ pressed: Bool) {
        guard thrustPressed != pressed else { return }
        thrustPressed = pressed
        onInputChanged?()
    }

    /// Set fire button state.
    func setFire(_ pressed: Bool) {
        guard firePressed != pressed else { return }
        firePressed = pressed
        onInputChanged?()
    }

    /// Set tractor button state.
    func setTractor(_ pressed: Bool) {
        guard tractorPressed != pressed else { return }
        tractorPressed = pressed
        onInputChanged?()
    }

    /// Update torque directly (from analog joystick input, for example).
    func setTorque(_ value: Double) {
        let clamped = max(-1.0, min(1.0, value))
        guard currentTorque != clamped else { return }
        currentTorque = clamped
        onInputChanged?()
    }
}

/// Handles gesture-based input (swipes, taps, long presses).
final class GestureInputHandler: NSObject, UIGestureRecognizerDelegate {
    var onSwipe: ((UISwipeGestureRecognizer.Direction) -> Void)?
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?

    /// Add gesture recognizers to a target view.
    func installIn(_ view: UIView) {
        // Swipe gestures for steering
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right, .up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            swipe.direction = direction
            swipe.delegate = self
            view.addGestureRecognizer(swipe)
        }

        // Tap for fire
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.delegate = self
        view.addGestureRecognizer(tap)

        // Long press for tractor
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.delegate = self
        view.addGestureRecognizer(longPress)
    }

    @objc private func handleSwipe(_ recognizer: UISwipeGestureRecognizer) {
        guard recognizer.state == .recognized else { return }
        onSwipe?(recognizer.direction)
    }

    @objc private func handleTap() {
        onTap?()
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        onLongPress?()
    }
}

/// Keyboard-based input handler for development/testing on macOS/iPad with keyboard.
@MainActor
final class KeyboardInputHandler {
    private(set) var currentTorque: Double = 0.0
    private(set) var thrustPressed: Bool = false
    private(set) var firePressed: Bool = false
    private(set) var tractorPressed: Bool = false

    private var pressedKeys: Set<UIKeyboardHIDUsage> = []

    var onInputChanged: (@MainActor () -> Void)?

    var currentInput: PlayerInput {
        PlayerInput(
            torque: currentTorque,
            thrust: thrustPressed,
            fire: firePressed
        )
    }

    func handleKeyPress(_ key: UIKeyboardHIDUsage) {
        pressedKeys.insert(key)
        updateFromKeys()
    }

    func handleKeyRelease(_ key: UIKeyboardHIDUsage) {
        pressedKeys.remove(key)
        updateFromKeys()
    }

    private func updateFromKeys() {
        // WASD controls: A/D for steering, W for thrust, Space for fire
        var newTorque: Double = 0.0

        if pressedKeys.contains(.keyboardA) {
            newTorque -= 1.0
        }
        if pressedKeys.contains(.keyboardD) {
            newTorque += 1.0
        }

        currentTorque = newTorque
        thrustPressed = pressedKeys.contains(.keyboardW)
        firePressed = pressedKeys.contains(.keyboardSpacebar)
        tractorPressed = pressedKeys.contains(.keyboardLeftShift)

        onInputChanged?()
    }

    func reset() {
        pressedKeys.removeAll()
        currentTorque = 0.0
        thrustPressed = false
        firePressed = false
        tractorPressed = false
    }
}

/// Gamepad (MFi controller) input handler.
@MainActor
final class GamepadInputHandler: NSObject {
    private(set) var currentInput: PlayerInput = .idle(tick: 0)
    var onInputChanged: (@MainActor () -> Void)?

    private var currentGamepad: GCGamepad?

    override init() {
        super.init()
        setupGamepadNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupGamepadNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(gamepadDidConnect),
            name: NSNotification.Name.GCControllerDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(gamepadDidDisconnect),
            name: NSNotification.Name.GCControllerDidDisconnect,
            object: nil
        )
    }

    @objc private func gamepadDidConnect(notification: NSNotification) {
        guard let gamepad = notification.object as? GCGamepad else { return }
        attachGamepad(gamepad)
    }

    @objc private func gamepadDidDisconnect(notification: NSNotification) {
        currentGamepad = nil
    }

    private func attachGamepad(_ gamepad: GCGamepad) {
        currentGamepad = gamepad

        // Left analog stick for steering
        gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
            var input = self?.currentInput ?? .idle(tick: 0)
            input.torque = Double(xValue)
            self?.currentInput = input
            self?.onInputChanged?()
        }

        // Right trigger for thrust
        gamepad.rightTrigger.valueChangedHandler = { [weak self] _, value, _ in
            var input = self?.currentInput ?? .idle(tick: 0)
            input.thrust = value > 0.5
            self?.currentInput = input
            self?.onInputChanged?()
        }

        // A button for fire
        gamepad.buttonA.pressedChangedHandler = { [weak self] _, value, pressed in
            var input = self?.currentInput ?? .idle(tick: 0)
            input.fire = pressed
            self?.currentInput = input
            self?.onInputChanged?()
        }
    }

    func reset() {
        currentInput = .idle(tick: 0)
    }
}
