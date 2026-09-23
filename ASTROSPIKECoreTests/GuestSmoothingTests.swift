import Testing
import simd
@testable import ASTROSPIKECore

@Suite("Guest smoothing")
struct GuestSmoothingTests {
    private func world(ball: SIMD2<Double>, orange: SIMD2<Double>) -> WorldState {
        WorldState(
            ships: [
                .cyan: ShipState(position: SIMD2(-0.5, 0), angle: 0, homeSide: .cyan),
                .orange: ShipState(position: orange, angle: 0, homeSide: .orange),
            ],
            ball: BallState(position: ball)
        )
    }

    @Test("A small correction is hidden then decays away")
    func smallCorrectionDecays() {
        var smoothing = GuestSmoothing()
        let shown = world(ball: SIMD2(0.10, 0.10), orange: SIMD2(0.50, 0.00))
        let truth = world(ball: SIMD2(0.14, 0.10), orange: SIMD2(0.53, 0.02))
        smoothing.capture(displayed: shown, corrected: truth, excluding: .cyan)
        let first = smoothing.apply(to: truth)
        #expect(abs(first.ball.position.x - 0.10) < 0.000_001)
        #expect(abs(first.ships[.orange]!.position.x - 0.50) < 0.000_001)
        #expect(abs(first.ships[.cyan]!.position.x + 0.5) < 0.000_001)
        for _ in 0..<30 { smoothing.decay(dt: 1.0 / 60.0) }
        let later = smoothing.apply(to: truth)
        #expect(abs(later.ball.position.x - 0.14) < 0.001)
        #expect(abs(later.ships[.orange]!.position.x - 0.53) < 0.001)
    }

    @Test("A big correction snaps instead of sliding")
    func bigCorrectionSnaps() {
        var smoothing = GuestSmoothing()
        let shown = world(ball: SIMD2(-0.4, 0.10), orange: SIMD2(0.5, 0))
        let truth = world(ball: SIMD2(0.4, 0.10), orange: SIMD2(0.5, 0))
        smoothing.capture(displayed: shown, corrected: truth, excluding: .cyan)
        #expect(smoothing.ballError == 0)
        #expect(abs(smoothing.apply(to: truth).ball.position.x - 0.4) < 0.000_001)
    }

    @Test("Each ball gets its own offset")
    func perBallOffsets() {
        var smoothing = GuestSmoothing()
        var displayed = WorldState(ships: [:], extraBalls: [BallState(position: SIMD2(0.50, 0.10))])
        var corrected = displayed
        displayed.balls[1].position.x += 0.05
        smoothing.capture(displayed: displayed, corrected: corrected, excluding: nil)
        #expect(abs(smoothing.ballError - 0.05) < 1e-9)
        let shown = smoothing.apply(to: corrected)
        #expect(shown.balls[0].position == corrected.balls[0].position)
        #expect(abs(shown.balls[1].position.x - 0.55) < 1e-9)
        // A ball the display never had is not offset, and the count may shrink.
        corrected.balls.removeLast()
        smoothing.capture(displayed: displayed, corrected: corrected, excluding: nil)
        #expect(smoothing.apply(to: corrected).balls.count == 1)
    }
}
