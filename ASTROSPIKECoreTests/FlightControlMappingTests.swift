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

@Suite("Steering curve")
struct SteeringCurveTests {
    let curve = SteeringCurve.standard
    let midX: Double = 200

    private func torqueSweep(anchorX: Double, to endX: Double, steps: Int = 240) -> [Double] {
        let center = curve.virtualCenter(anchorX: anchorX, midX: midX)
        return (0...steps).map { i in
            let x = anchorX + (endX - anchorX) * Double(i) / Double(steps)
            return curve.torque(x: x, virtualCenter: center)
        }
    }

    @Test("A tap on either half pegs its own direction")
    func tapPegsFullDeflection() {
        let left = curve.virtualCenter(anchorX: 60, midX: midX)
        let right = curve.virtualCenter(anchorX: 340, midX: midX)
        #expect(curve.torque(x: 60, virtualCenter: left) == 1)
        #expect(curve.torque(x: 340, virtualCenter: right) == -1)
    }

    @Test("Jitter while holding a tap stays pegged")
    func jitterDoesNotUnpegATap() {
        let center = curve.virtualCenter(anchorX: 60, midX: midX)
        for drift in stride(from: -8.0, through: 8.0, by: 0.5) {
            #expect(curve.torque(x: 60 + drift, virtualCenter: center) == 1)
        }
    }

    @Test("Sliding deeper into the turn never weakens it")
    func slidingIntoTheTurnStaysPegged() {
        // Anchored left, dragging further left holds full left.
        for value in torqueSweep(anchorX: 140, to: 0) {
            #expect(value == 1)
        }
        // Anchored right, dragging further right holds full right.
        let right = curve.virtualCenter(anchorX: 260, midX: midX)
        for x in stride(from: 260.0, through: 400.0, by: 2.0) {
            #expect(curve.torque(x: x, virtualCenter: right) == -1)
        }
    }

    @Test("Torque falls monotonically as the finger slides back")
    func sweepIsMonotonic() {
        let values = torqueSweep(anchorX: 60, to: 320)
        for (previous, next) in zip(values, values.dropFirst()) {
            #expect(next <= previous + 1e-12)
        }
        #expect(values.first == 1)
        #expect(values.last == -1)
    }

    @Test("The sweep crosses zero with no jump")
    func crossingZeroIsContinuous() {
        let values = torqueSweep(anchorX: 60, to: 320, steps: 2000)
        var largestStep: Double = 0
        for (previous, next) in zip(values, values.dropFirst()) {
            largestStep = max(largestStep, abs(next - previous))
        }
        #expect(largestStep < 0.01)
        // Neutral is reachable, not skipped over.
        #expect(values.contains { abs($0) < 0.01 })
    }

    @Test("Gamma stretches the fine-control end without changing the ends")
    func gammaShapesTheRampOnly() {
        let center = curve.virtualCenter(anchorX: 0, midX: midX)
        let halfway = curve.torque(x: center - curve.span / 2, virtualCenter: center)
        #expect(halfway > 0.2)
        #expect(halfway < 0.3)
        let linear = SteeringCurve(span: 60, deadZone: 8, gamma: 1)
        let linearCenter = linear.virtualCenter(anchorX: 0, midX: midX)
        #expect(abs(linear.torque(x: linearCenter - 30, virtualCenter: linearCenter) - 0.5) < 1e-12)
    }
}
