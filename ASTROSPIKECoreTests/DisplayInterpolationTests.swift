import Foundation
import Testing
@testable import ASTROSPIKECore

@Suite("Display interpolation")
struct DisplayInterpolationTests {
    @Test("Ship and ball positions blend at the midpoint")
    func midpoint() {
        let earlier = WorldState(
            ships: [
                .cyan: ShipState(position: SIMD2(0, 0), angle: 0),
                .orange: ShipState(position: SIMD2(1, 0), angle: 0),
            ],
            ball: BallState(position: SIMD2(-0.5, 0.2))
        )
        var later = earlier
        later.tick = 1
        later.ships[.cyan]?.position = SIMD2(1, 0)
        later.ships[.orange]?.position = SIMD2(2, 0)
        later.ball.position = SIMD2(0.5, 0.2)

        let blended = DisplayInterpolation.between(earlier, later, alpha: 0.5)
        #expect(blended.tick == 1)
        #expect(blended.ships[.cyan]?.position == SIMD2(0.5, 0))
        #expect(blended.ships[.orange]?.position == SIMD2(1.5, 0))
        #expect(blended.ball.position == SIMD2(0, 0.2))
    }

    @Test("Alpha at one returns the later state unchanged")
    func endpoints() {
        let earlier = WorldState(ships: [.cyan: ShipState(position: .zero, angle: 0)])
        var later = earlier
        later.ships[.cyan]?.position = SIMD2(2, 2)

        #expect(DisplayInterpolation.between(earlier, later, alpha: 1) == later)
        #expect(DisplayInterpolation.between(earlier, later, alpha: 0) == earlier)
    }
}