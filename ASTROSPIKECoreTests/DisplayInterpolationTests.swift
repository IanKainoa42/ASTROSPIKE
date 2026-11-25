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

    @Test("A bolt blends with its own earlier self when an older bolt has just died")
    func boltsPairByID() {
        func bolt(_ id: UInt64, x: Double) -> BoltState {
            BoltState(id: id, owner: .cyan, position: SIMD2(x, 0), velocity: SIMD2(1, 0), ticksRemaining: 10)
        }
        let earlier = WorldState(
            ships: [.cyan: ShipState(position: .zero, angle: 0)],
            bolts: [bolt(0, x: -1), bolt(1, x: 0.5)]
        )
        var later = earlier
        later.tick = 1
        // Bolt 0 died, bolt 1 flew on, bolt 2 was fired.
        later.bolts = [bolt(1, x: 1), bolt(2, x: 0.25)]

        let blended = DisplayInterpolation.between(earlier, later, alpha: 0.5)
        #expect(blended.bolts.map(\.id) == [1, 2])
        #expect(blended.bolts[0].position == SIMD2(0.75, 0))
        #expect(blended.bolts[1].position == SIMD2(0.25, 0))
    }
}