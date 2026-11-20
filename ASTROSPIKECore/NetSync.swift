import Foundation

/// Defines the synchronization policies for the online match.
public struct SyncPolicy {
    /// How often the local player sends input.
    public static let inputFrequency: Int = 2
    /// How often the host sends a snapshot.
    public static let snapshotCadence: Int = 4
    /// The logic for determining how to map remote inputs to the current tick.
    /// This is mostly handled by `GuestClock.remoteTick`.
    public static func remoteInput(for seat: Seat, tick: UInt64) -> PlayerInput? {
        // This is just a placeholder to ensure the function exists in the policy.
        // The actual logic is in GuestPrediction.swift.
        return nil
    }
}

