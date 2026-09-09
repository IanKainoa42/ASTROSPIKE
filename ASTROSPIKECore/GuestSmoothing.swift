import Foundation
import simd

/// Hides the guest's snapshot corrections. Every authoritative snapshot moves
/// the ball and the rival ship to where the host says they are; drawn raw,
/// each arrival is a visible hop. Instead the difference between what was on
/// screen and the corrected state is kept as an offset that decays over a
/// few frames, so the picture slides onto the truth rather than jumping.
/// A correction bigger than `snapDistance` is a real desync and snaps.
public struct GuestSmoothing: Sendable {
    public var decayRate: Double
    public var snapDistance: Double
    private var ballOffset = SIMD2<Double>(repeating: 0)
    private var shipOffsets: [Seat: SIMD2<Double>] = [:]

    public init(decayRate: Double = 14, snapDistance: Double = 0.25) {
        self.decayRate = decayRate
        self.snapDistance = snapDistance
    }

    public var ballError: Double { simd_length(ballOffset) }

    /// Records the gap between the frame on screen and the corrected state.
    /// The local ship is left alone: prediction and reconciliation own it.
    public mutating func capture(displayed: WorldState, corrected: WorldState, excluding local: Seat?) {
        ballOffset = clamped(displayed.ball.position - corrected.ball.position)
        for (seat, ship) in corrected.ships where seat != local {
            guard let shown = displayed.ships[seat] else { continue }
            shipOffsets[seat] = clamped(shown.position - ship.position)
        }
    }

    public mutating func decay(dt: Double) {
        let factor = exp(-decayRate * max(0, dt))
        ballOffset *= factor
        for seat in shipOffsets.keys { shipOffsets[seat]! *= factor }
    }

    public mutating func reset() {
        ballOffset = .zero
        shipOffsets = [:]
    }

    public func apply(to state: WorldState) -> WorldState {
        var shown = state
        shown.ball.position += ballOffset
        for (seat, offset) in shipOffsets { shown.ships[seat]?.position += offset }
        return shown
    }

    private func clamped(_ offset: SIMD2<Double>) -> SIMD2<Double> {
        simd_length(offset) > snapDistance ? .zero : offset
    }
}
