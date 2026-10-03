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

    /// Ships.json is edited by hand in the Ship Workshop; anything it
    /// exports must stay inside HullLook.limits.
    @Test("Every hull and concept look stays inside the workshop's limits")
    func valuesInRange() {
        let limits = HullLook.limits
        let designs = Hull.allCases.map { ShipDesigns.design(for: $0) } + ShipDesigns.file.concepts
        for design in designs {
            let look = design.look
            for rgb in [look.primary, look.secondary, look.flame, look.flameCore, look.smoke] {
                #expect(rgb.min() >= 0 && rgb.max() <= 1, "\(design.id)")
            }
            #expect(limits.smokeSize.contains(look.smokeSize), "\(design.id) smokeSize")
            #expect(limits.smokeLife.contains(look.smokeLife), "\(design.id) smokeLife")
            #expect(limits.smokeOpacity.contains(look.smokeOpacity), "\(design.id) smokeOpacity")
            #expect(limits.smokeAmount.contains(look.smokeAmount), "\(design.id) smokeAmount")
            #expect(limits.flameLength.contains(look.flameLength), "\(design.id) flameLength")
            #expect(limits.flicker.contains(look.flicker), "\(design.id) flicker")
            #expect(limits.nozzles.contains(look.nozzles), "\(design.id) nozzles")
            #expect(limits.nozzleSpacing.contains(look.nozzleSpacing), "\(design.id) nozzleSpacing")
            #expect(limits.nozzleY.contains(look.nozzleY), "\(design.id) nozzleY")
            #expect(limits.exhaustWidth.contains(design.exhaustWidth), "\(design.id) exhaustWidth")
        }
    }

    @Test("Hornet keeps its twin nozzles; every other hull has one on the keel")
    func nozzles() {
        #expect(Hull.hornet.look.nozzleOffsets == [-17, 17])
        for hull in Hull.allCases where hull != .hornet {
            #expect(hull.look.nozzleOffsets == [0], "\(hull)")
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
