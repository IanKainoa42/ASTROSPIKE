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
    @Binding var tractor: Bool
    /// Match commands (pause, confirm). Nil while a sheet is up, so the keys
    /// fall through to the system and Escape still dismisses what is on screen.
    var onCommand: ((FlightControlCommand) -> Void)?
    /// Shift held and the flicks made under it. Nil outside ASTROBALL, so
    /// Shift and the direction keys behave as they always have there.
    var saberChanged: ((Bool) -> Void)?
    var saberFlicked: ((SaberFlick) -> Void)?

    func makeUIView(context: Context) -> KeyboardCaptureView {
        let view = KeyboardCaptureView()
        view.inputChanged = apply
        view.commandFired = onCommand
        view.saberChanged = saberChanged
        view.saberFlicked = saberFlicked
        return view
    }

    func updateUIView(_ view: KeyboardCaptureView, context: Context) {
        view.inputChanged = apply
        view.commandFired = onCommand
        view.saberChanged = saberChanged
        view.saberFlicked = saberFlicked
    }

    private func apply(_ held: Set<FlightControlAction>) {
        let input = KeyboardControlMapping.input(tick: 0, held: held)
        torque = input.torque
        thrust = input.thrust
        fire = input.fire
        tractor = input.tractor
    }
}

final class KeyboardCaptureView: UIView {
    var inputChanged: ((Set<FlightControlAction>) -> Void)?
    var commandFired: ((FlightControlCommand) -> Void)?
    var saberChanged: ((Bool) -> Void)?
    var saberFlicked: ((SaberFlick) -> Void)?
    private var held: Set<FlightControlAction> = []
    private var saberHeld = false

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

        if let saberChanged, KeyboardControlMapping.isSaberKey(code) {
            saberHeld = pressed
            saberChanged(pressed)
            return true
        }

        // Under Shift a direction key flicks the blade instead of flying. Only
        // the key-down is taken: its key-up falls through below, so a key held
        // before Shift went down is still let go of.
        if pressed, saberHeld, let saberFlicked, let flick = KeyboardControlMapping.saberFlick(forKeyCode: code) {
            saberFlicked(flick)
            return true
        }

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
                releaseSaber()
                commandFired(command)
            }
            return true
        }
        return false
    }

    private func releaseSaber() {
        guard saberHeld else { return }
        saberHeld = false
        saberChanged?(false)
    }

    private func releaseAll() {
        releaseSaber()
        guard !held.isEmpty else { return }
        held.removeAll()
        inputChanged?(held)
    }
}
