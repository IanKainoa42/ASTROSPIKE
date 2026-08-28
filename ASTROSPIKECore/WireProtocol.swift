import Foundation
import simd

public enum WirePayload: Codable, Equatable, Sendable {
    case input(team: Team, value: PlayerInput)
    case snapshot(WorldState)
    case event(SimulationEvent)
    case ready
    case ping(nanoseconds: UInt64)
    case resync(WorldState)
}

public struct WireEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion: UInt16 = 3

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
            homeSide: authoritative.homeSide
        )
    }
}
