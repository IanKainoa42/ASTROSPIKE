import Foundation

/// The four things a pilot can ask for. Shared by every input surface so a
/// keyboard and a thumb cannot drift apart in what they mean.
public enum FlightControlAction: String, Codable, Hashable, Sendable {
    case left
    case right
    case thrust
    case fire
    case tractor
}

/// Keys that act on the match rather than the ship. Separate from
/// `FlightControlAction` because these fire once on key-down instead of being
/// held, and because a held key must never trigger one.
public enum FlightControlCommand: String, Codable, Hashable, Sendable {
    case pause
    case confirm
}

/// Maps physical keys onto flight actions.
///
/// Keys are identified by USB HID usage code rather than by the character they
/// produce, so the steering cluster keeps its shape on a layout that moves the
/// letters -- WASD stays a triangle under the left hand on AZERTY as it does on
/// QWERTY. `UIKeyboardHIDUsage` is exactly these numbers, so the app layer can
/// pass `press.key?.keyCode.rawValue` straight in without a translation table.
public enum KeyboardControlMapping {
    // USB HID keyboard usage IDs.
    static let keyA = 4
    static let keyD = 7
    static let keyW = 26
    static let keyS = 22
    static let downArrow = 81
    static let spacebar = 44
    static let rightArrow = 79
    static let leftArrow = 80
    static let upArrow = 82
    static let keyP = 19
    static let returnKey = 40
    static let escape = 41
    static let keypadEnter = 88

    /// The action a key drives, or `nil` if the key is not ours to consume --
    /// in which case the caller must pass the press along the responder chain
    /// so system shortcuts keep working.
    public static func action(forKeyCode code: Int) -> FlightControlAction? {
        switch code {
        case keyA, leftArrow: .left
        case keyD, rightArrow: .right
        case keyW, upArrow: .thrust
        case spacebar: .fire
        case keyS, downArrow: .tractor
        default: nil
        }
    }

    /// The match command a key fires, or `nil`. Disjoint from `action` -- a key
    /// never both flies the ship and works the menu.
    public static func command(forKeyCode code: Int) -> FlightControlCommand? {
        switch code {
        case escape, keyP: .pause
        case returnKey, keypadEnter: .confirm
        default: nil
        }
    }

    /// Every key that fires `command`, for on-screen hints and tests.
    public static func keyCodes(for command: FlightControlCommand) -> [Int] {
        switch command {
        case .pause: [escape, keyP]
        case .confirm: [returnKey, keypadEnter]
        }
    }

    /// Every key that drives `action`, for on-screen hints and tests.
    public static func keyCodes(for action: FlightControlAction) -> [Int] {
        switch action {
        case .left: [keyA, leftArrow]
        case .right: [keyD, rightArrow]
        case .thrust: [keyW, upArrow]
        case .fire: [spacebar]
        case .tractor: [keyS, downArrow]
        }
    }

    /// Collapses a set of held keys into an engine input. Holding both steering
    /// directions cancels out, which falls out of `FlightControlMapping` rather
    /// than being special-cased here.
    public static func input(tick: UInt64, held: Set<FlightControlAction>) -> PlayerInput {
        FlightControlMapping.input(
            tick: tick,
            leftPressed: held.contains(.left),
            rightPressed: held.contains(.right),
            thrustPressed: held.contains(.thrust),
            firePressed: held.contains(.fire),
            tractorPressed: held.contains(.tractor)
        )
    }
}
