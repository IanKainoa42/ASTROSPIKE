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
    let width: Double = 400

    private func torqueSweep(anchorX: Double, to endX: Double, steps: Int = 240) -> [Double] {
        let center = curve.virtualCenter(anchorX: anchorX, width: width)
        return (0...steps).map { i in
            let x = anchorX + (endX - anchorX) * Double(i) / Double(steps)
            return curve.torque(x: x, virtualCenter: center)
        }
    }

    @Test("A press on either half starts at half torque")
    func pressStartsAtHalf() {
        let left = curve.virtualCenter(anchorX: 100, width: width)
        let right = curve.virtualCenter(anchorX: 300, width: width)
        #expect(abs(curve.torque(x: 100, virtualCenter: left) - 0.5) < 1e-9)
        #expect(abs(curve.torque(x: 300, virtualCenter: right) + 0.5) < 1e-9)
    }

    @Test("Half holds for every press but the outermost sliver of pad")
    func pressStartsAtHalfAcrossThePad() {
        // Inside the band, exactly half. Outside it -- the last `sharpenTravel`
        // points at either edge -- there is no pad left to slide into, so the
        // press starts hotter rather than starting unpeggable. Nowhere does it
        // start below half or above full.
        for step in 0...400 {
            let anchorX = Double(step)
            let center = curve.virtualCenter(anchorX: anchorX, width: width)
            let magnitude = abs(curve.torque(x: anchorX, virtualCenter: center))
            #expect(magnitude >= 0.5 - 1e-9)
            #expect(magnitude <= 1 + 1e-9)
            if anchorX >= curve.sharpenTravel + 1, anchorX <= width - curve.sharpenTravel - 1 {
                #expect(abs(magnitude - 0.5) < 1e-9)
            }
        }
    }

    @Test("Full deflection is reachable from any press on the pad")
    func fullDeflectionIsReachableFromAnywhere() {
        for step in 0...400 {
            let anchorX = Double(step)
            let center = curve.virtualCenter(anchorX: anchorX, width: width)
            // Slide to the outer edge of whichever half was touched.
            let outerEdge: Double = anchorX < width / 2 ? 0 : width
            // Within an ulp: at the clamped edge the reachable |u| lands a hair
            // under 1 in double arithmetic, which is full deflection.
            #expect(abs(curve.torque(x: outerEdge, virtualCenter: center)) > 1 - 1e-9)
        }
    }

    @Test("Sliding deeper into the turn strengthens it to full, then holds")
    func slidingIntoTheTurnReachesFull() {
        let values = torqueSweep(anchorX: 140, to: 0)
        for (previous, next) in zip(values, values.dropFirst()) {
            #expect(next >= previous - 1e-12)
        }
        #expect(abs(values.first! - 0.5) < 1e-9)
        #expect(values.last! > 1 - 1e-9)
        // Anchored right, dragging further right mirrors it.
        let right = curve.virtualCenter(anchorX: 260, width: width)
        var previous = curve.torque(x: 260, virtualCenter: right)
        #expect(abs(previous + 0.5) < 1e-9)
        for x in stride(from: 260.0, through: 400.0, by: 2.0) {
            let value = curve.torque(x: x, virtualCenter: right)
            #expect(value <= previous + 1e-12)
            previous = value
        }
        #expect(previous < -1 + 1e-9)
    }

    @Test("Room to sharpen is exactly sharpenTravel, whatever gamma is")
    func sharpenTravelSurvivesGamma() {
        for gamma in [1.0, 1.5, 2.0, 3.0] {
            let curve = SteeringCurve(sharpenTravel: 30, initialTorque: 0.5, gamma: gamma)
            let center = curve.virtualCenter(anchorX: 200, width: 600)
            #expect(abs(curve.torque(x: 200, virtualCenter: center) - 0.5) < 1e-9)
            let atStop = curve.torque(x: 200 - curve.sharpenTravel, virtualCenter: center)
            #expect(abs(atStop - 1) < 1e-9)
            // A hair short of the stop is a hair short of full.
            #expect(curve.torque(x: 200 - curve.sharpenTravel + 0.5, virtualCenter: center) < 1)
        }
    }

    @Test("Jitter while holding a press barely moves the torque")
    func jitterDoesNotLurch() {
        let center = curve.virtualCenter(anchorX: 100, width: width)
        for drift in stride(from: -8.0, through: 8.0, by: 0.5) {
            let value = curve.torque(x: 100 + drift, virtualCenter: center)
            #expect(abs(value - 0.5) < 0.12)
        }
    }

    @Test("Torque falls monotonically as the finger slides back")
    func sweepIsMonotonic() {
        let values = torqueSweep(anchorX: 100, to: 360)
        for (previous, next) in zip(values, values.dropFirst()) {
            #expect(next <= previous + 1e-12)
        }
        #expect(abs(values.first! - 0.5) < 1e-9)
        #expect(values.last! < -1 + 1e-9)
    }

    @Test("The sweep crosses zero with no jump")
    func crossingZeroIsContinuous() {
        let values = torqueSweep(anchorX: 100, to: 360, steps: 2000)
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
        let center = curve.virtualCenter(anchorX: 200, width: width)
        let halfway = curve.torque(x: center - curve.span / 2, virtualCenter: center)
        #expect(halfway > 0.2)
        #expect(halfway < 0.3)
        let linear = SteeringCurve(sharpenTravel: 30, initialTorque: 0.5, gamma: 1)
        let linearCenter = linear.virtualCenter(anchorX: 200, width: width)
        let midpoint = linear.torque(x: linearCenter - linear.span / 2, virtualCenter: linearCenter)
        #expect(abs(midpoint - 0.5) < 1e-9)
    }
}
