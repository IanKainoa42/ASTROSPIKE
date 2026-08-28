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
}
