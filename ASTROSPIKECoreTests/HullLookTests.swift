import Foundation
import simd
import Testing
@testable import ASTROSPIKECore

/// Build 117: every hull has its own bolts, beam, flame and smoke.
@Suite("Hull looks")
struct HullLookTests {
    @Test("Every hull's bolt and beam are its own")
    func shapesAreUnique() {
        let looks = Hull.allCases.map(\.look)
        #expect(Set(looks.map { "\($0.bolt)" }).count == Hull.allCases.count)
        #expect(Set(looks.map { "\($0.beam)" }).count == Hull.allCases.count)
    }

    @Test("No two hulls share a beam colour")
    func coloursAreDistinct() {
        let hulls = Hull.allCases
        for (i, a) in hulls.enumerated() {
            for b in hulls[(i + 1)...] {
                #expect(simd_distance(a.look.primary, b.look.primary) > 0.2, "\(a) vs \(b)")
            }
        }
    }

    @Test("Every colour is a colour and every scale is positive")
    func valuesInRange() {
        for hull in Hull.allCases {
            let look = hull.look
            for rgb in [look.primary, look.secondary, look.flame, look.flameCore, look.smoke] {
                #expect(rgb.min() >= 0 && rgb.max() <= 1, "\(hull)")
            }
            #expect(look.smokeSize > 0 && look.smokeLife > 0 && look.smokeOpacity > 0 && look.flameLength > 0)
            #expect((0 ... 0.5).contains(look.flicker), "\(hull) flicker")
        }
    }

    /// The bolt carries its shooter so a guest draws it in the right look;
    /// the rules still read the team.
    @Test("A fired bolt remembers which ship fired it")
    func boltCarriesSeat() throws {
        var engine = SimulationEngine.testing()
        engine.configureRoster(Seat.doubles)
        engine.beginPlay()
        engine.state.ships[.wing(.cyan)]!.fireCooldownTicks = 0
        let fireTick = engine.state.tick
        engine.step(inputs: [.wing(.cyan): PlayerInput(tick: fireTick, torque: 0, thrust: false, fire: true)])
        let bolt = try #require(engine.state.bolts.first)
        #expect(bolt.seat == .wing(.cyan))
        #expect(bolt.owner == .cyan)
    }
}
