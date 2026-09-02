import Testing
@testable import ASTROSPIKECore

@Suite("Keyboard controls")
struct KeyboardControlTests {
    @Test("Both hands can fly: the letter cluster and the arrows agree")
    func lettersAndArrowsMatch() {
        for action in [FlightControlAction.left, .right, .thrust] {
            let codes = KeyboardControlMapping.keyCodes(for: action)
            #expect(codes.count >= 2, "every action needs more than one key")
            for code in codes {
                #expect(KeyboardControlMapping.action(forKeyCode: code) == action)
            }
        }
    }

    @Test("Space thrusts, because that is where a thumb already is")
    func spacebarThrusts() {
        #expect(KeyboardControlMapping.action(forKeyCode: 44) == .thrust)
    }

    @Test("Keys we do not own are left for the responder chain")
    func unmappedKeysAreNotClaimed() {
        // Escape, Q, Tab, Return: system and menu keys must stay untouched.
        for code in [41, 20, 43, 40] {
            #expect(KeyboardControlMapping.action(forKeyCode: code) == nil)
        }
    }

    @Test("No key is wired to two actions at once")
    func mappingIsUnambiguous() {
        var seen: Set<Int> = []
        for action in [FlightControlAction.left, .right, .thrust] {
            for code in KeyboardControlMapping.keyCodes(for: action) {
                #expect(seen.insert(code).inserted, "key \(code) is mapped twice")
            }
        }
    }

    @Test("Held keys steer the same way a thumb does")
    func heldKeysMatchTouchInput() {
        #expect(KeyboardControlMapping.input(tick: 0, held: []).torque == 0)
        #expect(KeyboardControlMapping.input(tick: 0, held: []).thrust == false)

        let left = KeyboardControlMapping.input(tick: 3, held: [.left])
        #expect(left.torque == FlightControlMapping.torque(for: .left))
        #expect(left.tick == 3)

        let right = KeyboardControlMapping.input(tick: 0, held: [.right])
        #expect(right.torque == FlightControlMapping.torque(for: .right))

        // Same as pressing both thumb pads: the ship holds its heading.
        #expect(KeyboardControlMapping.input(tick: 0, held: [.left, .right]).torque == 0)

        let climbing = KeyboardControlMapping.input(tick: 0, held: [.left, .thrust])
        #expect(climbing.thrust)
        #expect(climbing.torque == FlightControlMapping.torque(for: .left))
    }

    @Test("A keyboard produces exactly what the touch mapping would")
    func keyboardAndTouchProduceIdenticalInput() {
        let combinations: [(Set<FlightControlAction>, Bool, Bool, Bool)] = [
            ([], false, false, false),
            ([.left], true, false, false),
            ([.right], false, true, false),
            ([.thrust], false, false, true),
            ([.left, .thrust], true, false, true),
            ([.left, .right, .thrust], true, true, true),
        ]
        for (held, left, right, thrusting) in combinations {
            let keyboard = KeyboardControlMapping.input(tick: 7, held: held)
            let touch = FlightControlMapping.input(
                tick: 7,
                leftPressed: left,
                rightPressed: right,
                thrustPressed: thrusting
            )
            #expect(keyboard == touch)
        }
    }
}
