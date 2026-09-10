import Foundation
import simd

public enum WirePayload: Codable, Equatable, Sendable {
    case input(seat: Seat, value: PlayerInput)
    case snapshot(WorldState)
    case event(SimulationEvent)
    case ready
    /// Which hull the sender flies, so the peers can draw it. Cosmetic only.
    case profile(seat: Seat, hull: Hull)
    /// The host's seating plan, Game Center player ID to seat, and the host's
    /// sliders, physics and format. Guests fly exactly this rather than
    /// negotiating or reading their own settings.
    case seating(plan: [String: Seat], tuning: FlightTuningSnapshot)
    case ping(nanoseconds: UInt64)
    case resync(WorldState)
}

public struct WireEnvelope: Codable, Equatable, Sendable {
    // 4: MatchRuleState gained shipTouches and PointReason gained touchLimit.
    // 5: WirePayload gained profile(team:hull:).
    // 6: PlayerInput gained fire, ShipState gained fireCooldownTicks,
    //    WorldState gained bolts and nextBoltID.
    // 7: Ships, inputs and profiles keyed by Seat; seating payload for doubles.
    // 9: Host election is by role (inviter hosts, invitee never). A build 25
    //    invitee with a lower player ID seats itself as host too, so the two
    //    builds must refuse each other instead of silently double-hosting.
    // 10: seating carries setsToWin; a dropped pilot's chair is held for two
    //     minutes and a surviving guest takes over hosting, so a build 27
    //     peer would forfeit a match this build is still holding open.
    // 11: seating carries the host's whole FlightTuningSnapshot, not just
    //     setsToWin, so every board flies the host's sliders.
    // 12: PlayerInput gained tractor, ShipState gained tractorActive.
    // 13: ShipState gained ballTouchCooldownTicks -- a ball rattling between a
    //     hull and a wall now spends one touch instead of the whole allowance,
    //     so a build 51 peer would call a fault this build plays through.
    public static let currentVersion: UInt16 = 13

    public var version: UInt16
    public var sequence: UInt64
    public var payload: WirePayload

    public init(
        version: UInt16 = WireEnvelope.currentVersion,
        sequence: UInt64,
        payload: WirePayload
    ) {
        self.version = version
        self.sequence = sequence
        self.payload = payload
    }
}

public enum WireProtocolError: Error, Equatable, Sendable {
    case unsupportedVersion(UInt16)
    case malformed
}

public struct WireCodec: Sendable {
    public init() {}

    public func encode(_ envelope: WireEnvelope) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(envelope)
    }

    public func decode(_ data: Data) throws -> WireEnvelope {
        let envelope: WireEnvelope
        do {
            envelope = try PropertyListDecoder().decode(WireEnvelope.self, from: data)
        } catch {
            throw WireProtocolError.malformed
        }
        guard envelope.version == WireEnvelope.currentVersion else {
            throw WireProtocolError.unsupportedVersion(envelope.version)
        }
        return envelope
    }
}

public struct RemoteInputBuffer: Sendable {
    public private(set) var latest: PlayerInput?

    public init() {}

    @discardableResult
    public mutating func accept(_ input: PlayerInput) -> Bool {
        guard latest == nil || input.tick > latest!.tick else { return false }
        latest = input
        return true
    }
}

public struct AuthoritativeSnapshotGate: Sendable {
    private var latestTick: UInt64?

    public init() {}

    @discardableResult
    public mutating func accept(tick: UInt64) -> Bool {
        guard latestTick == nil || tick > latestTick! else { return false }
        latestTick = tick
        return true
    }

    public mutating func reset(to tick: UInt64? = nil) {
        latestTick = tick
    }
}

public struct MonotonicSequenceGate: Sendable {
    private var latestSequence: UInt64?

    public init() {}

    @discardableResult
    public mutating func accept(sequence: UInt64) -> Bool {
        guard latestSequence == nil || sequence > latestSequence! else { return false }
        latestSequence = sequence
        return true
    }

    public mutating func reset() {
        latestSequence = nil
    }
}

public struct StateReconciler: Sendable {
    public var snapDistance: Double
    public var blendFraction: Double

    public init(snapDistance: Double = 0.30, blendFraction: Double = 0.25) {
        self.snapDistance = snapDistance
        self.blendFraction = max(0, min(1, blendFraction))
    }

    public func reconcile(predicted: ShipState, authoritative: ShipState) -> ShipState {
        guard simd_distance(predicted.position, authoritative.position) <= snapDistance else {
            return authoritative
        }
        let retained = 1 - blendFraction
        return ShipState(
            position: predicted.position * retained + authoritative.position * blendFraction,
            velocity: predicted.velocity * retained + authoritative.velocity * blendFraction,
            angle: predicted.angle * retained + authoritative.angle * blendFraction,
            angularVelocity: predicted.angularVelocity * retained
                + authoritative.angularVelocity * blendFraction,
            isDestroyed: authoritative.isDestroyed,
            thrustLevel: authoritative.thrustLevel,
            homeSide: authoritative.homeSide,
            fireCooldownTicks: authoritative.fireCooldownTicks,
            ballTouchCooldownTicks: authoritative.ballTouchCooldownTicks
        )
    }
}
