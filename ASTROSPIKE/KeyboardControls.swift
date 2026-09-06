import ASTROSPIKECore
import SwiftUI
import UIKit

/// Hardware-keyboard flying, for Mac Catalyst and any iPad or iPhone with a
/// keyboard attached. Invisible and untouchable: it never hit-tests, so the
/// touch controls underneath keep working and the two can be used together.
struct KeyboardControls: UIViewRepresentable {
    @Binding var torque: Double
    @Binding var thrust: Bool
    @Binding var fire: Bool
    /// Match commands (pause, confirm). Nil while a sheet is up, so the keys
    /// fall through to the system and Escape still dismisses what is on screen.
    var onCommand: ((FlightControlCommand) -> Void)?

    func makeUIView(context: Context) -> KeyboardCaptureView {
        let view = KeyboardCaptureView()
        view.inputChanged = apply
        view.commandFired = onCommand
        return view
    }

    func updateUIView(_ view: KeyboardCaptureView, context: Context) {
        view.inputChanged = apply
        view.commandFired = onCommand
    }

    private func apply(_ held: Set<FlightControlAction>) {
        let input = KeyboardControlMapping.input(tick: 0, held: held)
        torque = input.torque
        thrust = input.thrust
        fire = input.fire
    }
}

final class KeyboardCaptureView: UIView {
    var inputChanged: ((Set<FlightControlAction>) -> Void)?
    var commandFired: ((FlightControlCommand) -> Void)?
    private var held: Set<FlightControlAction> = []

    override var canBecomeFirstResponder: Bool { true }

    /// Never claim a touch. First-responder status is independent of hit
    /// testing, so the view can own the keyboard while every tap falls through
    /// to the controls behind it.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            releaseAll()
        } else {
            becomeFirstResponder()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !update($0, pressed: true) }
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !update($0, pressed: false) }
        if !unhandled.isEmpty {
            super.pressesEnded(unhandled, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !update($0, pressed: false) }
        if !unhandled.isEmpty {
            super.pressesCancelled(unhandled, with: event)
        }
    }

    /// Losing focus never delivers the matching key-up, so a held key would
    /// stick the ship on full thrust. Let go of everything instead.
    override func resignFirstResponder() -> Bool {
        releaseAll()
        return super.resignFirstResponder()
    }

    /// Returns whether the press was ours.
    @discardableResult
    private func update(_ press: UIPress, pressed: Bool) -> Bool {
        guard let code = press.key?.keyCode.rawValue else { return false }

        if let action = KeyboardControlMapping.action(forKeyCode: code) {
            if pressed {
                held.insert(action)
            } else {
                held.remove(action)
            }
            inputChanged?(held)
            return true
        }

        // Commands fire once, on the way down, and only while someone is
        // listening -- otherwise Escape belongs to whatever sheet is showing.
        if let commandFired, let command = KeyboardControlMapping.command(forKeyCode: code) {
            if pressed {
                // Steering is not held through a pause.
                held.removeAll()
                inputChanged?(held)
                commandFired(command)
            }
            return true
        }
        return false
    }

    private func releaseAll() {
        guard !held.isEmpty else { return }
        held.removeAll()
        inputChanged?(held)
    }
}
