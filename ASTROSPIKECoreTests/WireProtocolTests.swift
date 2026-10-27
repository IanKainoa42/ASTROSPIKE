import Foundation
import Testing
@testable import ASTROSPIKECore

@Suite("Wire protocol")
struct WireProtocolTests {
    @Test("Input messages survive a binary round trip")
    func inputRoundTrip() throws {
        let envelope = WireEnvelope(
            sequence: 42,
            payload: .input(seat: .cyan, value: PlayerInput(tick: 91, torque: -0.75, thrust: true))
        )

        let decoded = try WireCodec().decode(WireCodec().encode(envelope))

        #expect(decoded == envelope)
    }

    @Test("Live serve state survives a Game Center snapshot round trip")
    func serveSnapshotRoundTrip() throws {
        let state = WorldState(
            tick: 314,
            ships: [
                .cyan: ShipState(position: SIMD2(-0.31, 0.42), angle: 0.8),
                .orange: ShipState(position: SIMD2(0.57, -0.12), angle: 2.1),
            ],
            ball: BallState(position: SIMD2(0.48, 0.60), spin: -12.5),
            match: MatchRuleState(score: Score(cyan: 3, orange: 2), phase: .serve),
            serveTicksRemaining: 73,
            sidesSwapped: true,
            setBreak: true
        )
        let envelope = WireEnvelope(sequence: 18, payload: .snapshot(state))

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

    @Test("A held throttle expires when its pilot goes quiet")
    func heldInputExpires() {
        var buffer = RemoteInputBuffer()
        let burning = PlayerInput(tick: 12, torque: 0, thrust: true)
        buffer.accept(burning, at: 10)

        #expect(buffer.current(at: 10.4, expiringAfter: 0.5) == burning)
        #expect(buffer.current(at: 10.5, expiringAfter: 0.5) == nil)

        // A fresh packet puts the throttle back under the pilot's thumb.
        buffer.accept(PlayerInput(tick: 14, torque: 0, thrust: true), at: 10.6)
        #expect(buffer.current(at: 10.9, expiringAfter: 0.5)?.tick == 14)
    }

    @Test("A pilot who goes quiet mid-burn coasts instead of riding the ceiling")
    func expiredInputStopsTheBurn() {
        let burning = PlayerInput(tick: 0, torque: 0, thrust: true)
        var buffer = RemoteInputBuffer()
        buffer.accept(burning, at: 0)

        var pinned = SimulationEngine.testing()
        var released = SimulationEngine.testing()
        let dt = pinned.configuration.stepDuration

        for tick in 0 ..< 200 {
            let idle = PlayerInput.idle(tick: UInt64(tick))
            let aged = buffer.current(at: Double(tick) * dt, expiringAfter: 0.5) ?? idle
            pinned.step(inputs: [.cyan: idle, .orange: burning])
            released.step(inputs: [.cyan: idle, .orange: aged])
        }

        let stuck = pinned.state.ships[.orange]!
        let coasting = released.state.ships[.orange]!
        // The bug: the host kept flying the last packet it ever got, so the
        // ship burned all the way up and stayed there.
        #expect(stuck.position.y > 0.55)
        #expect(coasting.position.y < stuck.position.y)
        #expect(coasting.velocity.y < 0)
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

    @Test("A small blend keeps the saber, the stun and the knock")
    func reconciliationKeepsTheSwing() {
        var authoritative = ShipState(
            position: SIMD2(0, 0), angle: 1.2, tractorActive: true, stunTicks: 40, stunGuardTicks: 80, knockSpin: 3
        )
        authoritative.saber.drawn = 1
        authoritative.saber.move = .spike
        authoritative.saber.moveTime = 0.1
        authoritative.saber.startAngle = 1.2
        authoritative.saber.turn = -1
        authoritative.saber.flickCount = 4
        var predicted = authoritative
        predicted.position.x = 0.05
        predicted.angle = 0.4
        predicted.stunTicks = 0
        predicted.knockSpin = 0
        predicted.saber = SaberState()
        let reconciler = StateReconciler()
        // Still stunned: the guest's steered position is not where it is.
        let stunned = reconciler.reconcile(predicted: predicted, authoritative: authoritative)
        #expect(stunned.position == authoritative.position)
        #expect(stunned.saber.move == .spike)
        #expect(stunned.saber.flickCount == 4)
        #expect(stunned.stunTicks == 40)
        #expect(stunned.knockSpin == 3)

        authoritative.stunTicks = 0
        let swinging = reconciler.reconcile(predicted: predicted, authoritative: authoritative)
        #expect(abs(swinging.position.x - 0.0375) < 0.000_000_001)
        #expect(swinging.saber.move == .spike)
        #expect(swinging.saber.moveTime == 0.1)
        #expect(swinging.saber.flickCount == 4)
        #expect(swinging.angle == 1.2, "the spike owns the nose")
        #expect(swinging.knockSpin == 3)
        #expect(swinging.tractorActive)
        #expect(swinging.stunGuardTicks == 80)
    }

    @Test("Older and duplicate snapshots cannot replace newer authority")
    func staleSnapshotSuppression() {
        var gate = AuthoritativeSnapshotGate()

        let first = gate.accept(tick: 42)
        let older = gate.accept(tick: 41)
        let duplicate = gate.accept(tick: 42)
        let newer = gate.accept(tick: 43)
        #expect(first)
        #expect(!older)
        #expect(!duplicate)
        #expect(newer)
    }

    @Test("A full resync establishes a new snapshot baseline")
    func resyncResetsSnapshotBaseline() {
        var gate = AuthoritativeSnapshotGate()
        let initial = gate.accept(tick: 80)
        #expect(initial)

        gate.reset(to: 12)

        let duplicate = gate.accept(tick: 12)
        let next = gate.accept(tick: 13)
        #expect(!duplicate)
        #expect(next)
    }

    @Test("Delayed reliable events cannot replay after a newer event")
    func reliableEventSequenceSuppression() {
        var gate = MonotonicSequenceGate()

        let first = gate.accept(sequence: 10)
        let delayed = gate.accept(sequence: 8)
        let duplicate = gate.accept(sequence: 10)
        let next = gate.accept(sequence: 14)

        #expect(first)
        #expect(!delayed)
        #expect(!duplicate)
        #expect(next)
    }
}
