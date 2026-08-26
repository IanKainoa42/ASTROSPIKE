import Foundation
import Testing
@testable import ASTROSPIKECore

@Suite("Wire protocol")
struct WireProtocolTests {
    @Test("Input messages survive a binary round trip")
    func inputRoundTrip() throws {
        let envelope = WireEnvelope(
            sequence: 42,
            payload: .input(team: .cyan, value: PlayerInput(tick: 91, torque: -0.75, thrust: true))
        )

        let decoded = try WireCodec().decode(WireCodec().encode(envelope))

        #expect(decoded == envelope)
    }

    @Test("Unknown protocol versions are rejected")
    func rejectsUnknownVersion() throws {
        let envelope = WireEnvelope(version: 99, sequence: 1, payload: .ready)
        let data = try WireCodec().encode(envelope)

        #expect(throws: WireProtocolError.unsupportedVersion(99)) {
            try WireCodec().decode(data)
        }
    }

    @Test("Stale and reordered inputs cannot replace a newer input")
    func staleInputSuppression() {
        var buffer = RemoteInputBuffer()

        let accepted = buffer.accept(PlayerInput(tick: 12, torque: 1, thrust: true))
        let stale = buffer.accept(PlayerInput(tick: 11, torque: -1, thrust: false))
        let duplicate = buffer.accept(PlayerInput(tick: 12, torque: 0, thrust: false))
        #expect(accepted)
        #expect(!stale)
        #expect(!duplicate)
        #expect(buffer.latest == PlayerInput(tick: 12, torque: 1, thrust: true))
    }

    @Test("Large prediction errors snap while small errors blend")
    func reconciliationPolicy() {
        let authoritative = ShipState(position: SIMD2(0, 0), angle: 0)
        let nearby = ShipState(position: SIMD2(0.05, 0), angle: 0)
        let far = ShipState(position: SIMD2(0.8, 0), angle: 0)
        let reconciler = StateReconciler(snapDistance: 0.30, blendFraction: 0.25)

        #expect(reconciler.reconcile(predicted: far, authoritative: authoritative).position == .zero)
        #expect(abs(reconciler.reconcile(predicted: nearby, authoritative: authoritative).position.x - 0.0375) < 0.000_000_001)
    }
}
