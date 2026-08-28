import Testing
@testable import ASTROSPIKECore

@Suite("Flight control mapping")
struct FlightControlMappingTests {
    @Test("Left and right control zones rotate in their labeled directions")
    func labeledDirectionsMapToMatchingTorque() {
        #expect(FlightControlMapping.torque(for: .left) == 1)
        #expect(FlightControlMapping.torque(for: .right) == -1)
    }

    @Test("Thrust remains active without either rotation control")
    func thrustDoesNotRequireRotation() {
        let input = FlightControlMapping.input(
            tick: 12,
            leftPressed: false,
            rightPressed: false,
            thrustPressed: true
        )

        #expect(input.torque == 0)
        #expect(input.thrust)
    }

    @Test("Releasing one control does not wait for another control's finger")
    func controlsTrackOnlyTheirOwnTouches() {
        var leftControl = ControlPressTracker<Int>()
        var thrustControl = ControlPressTracker<Int>()

        leftControl.began(101)
        thrustControl.began(202)
        leftControl.ended(101)

        #expect(!leftControl.isPressed)
        #expect(thrustControl.isPressed)
    }

    @Test("A control stays pressed until its last local finger ends")
    func controlTracksMultipleLocalTouches() {
        var control = ControlPressTracker<Int>()
        control.began(101)
        control.began(102)

        control.ended(101)
        #expect(control.isPressed)

        control.cancelled(102)
        #expect(!control.isPressed)
    }
}
