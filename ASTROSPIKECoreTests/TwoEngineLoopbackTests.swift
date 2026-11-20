import Foundation
import Testing
@testable import ASTROSPIKECore

/// A loopback test simulating two engines (Host and Guest) running over a simulated network.
/// This verifies that the Guest's local prediction for its own ship remains consistent
/// even when a "stale" snapshot from the host arrives.
struct TwoEngineLoopbackTests {
    func test_loopback_no_snap() throws {
        // 1. Setup
        let configuration = SimulationConfiguration()
        let arena = ArenaGeometry.standard(ballRadius: configuration.ballRadius)
        
        // The host and guest both run in the same "room"
        let host = SimulationEngine.testing()
        host.updateConfiguration(configuration)
        host.updateArena(arena)
        host.configureRoster(Seat.singles)
        host.beginPlay()
        
        let guest = SimulationEngine(state: host.state, configuration: configuration, arena: arena)
        guest.followsHost = true
        
        // 2. Run for a while
        // We want to establish a steady state where the guest is leading.
        for _ in 0..<100 {
            host.step(inputs: [:])
            guest.step(inputs: [:])
        }
        
        // 3. The specific check
        // The guest is currently at tick T.
        // The host is at tick T-1.
        // We want to ensure that if we receive a snapshot from the host (which is "old" in the Guest's timeline)
        // the Guest's own ship does not "snap" (i.e., its position remains consistent with its own local prediction).
        
        let preSnapPosition = guest.state.ships[.orange]
        
        // Simulate the snapshot application
        // The GuestRollForward.resolve handles the reconciliation.
        let resolution = GuestRollForward.resolve(
            authoritative: host.state,
            predicted: guest.state,
            target: GuestClock.target(
                predicted: guest.state.tick,
                authoritative: host.state.tick,
                roundTripTicks: 24
            ),
            configuration: configuration,
            arena: arena,
            flownSeat: .orange,
            bots: [:],
            localInput: { _ in .idle(tick: 0) },
            remoteInput: { _, _ in .idle(tick: 0) }
        )
        
        let postSnapPosition = resolution.state.ships[.orange]
        
        // The correction should be near zero.
        // A "snap" would mean the position changed significantly.
        let distance = (preSnapPosition!.x - postSnapPosition!.x).squareRoot() +
                       (preSnapPosition!.y - postSnapPosition!.y).squareRoot()
        
        // We allow a tiny bit of drift due to floating point, but not a full "snap"
        // which would be a significant change in the ship's position.
        #expect(distance < 0.01, "The ship snapped by \(distance)")
    }
}
