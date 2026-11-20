import Foundation

/// How often an online match talks, in ticks. Both ends must agree.
public enum SyncPolicy {
    /// The local pilot sends input every this many ticks.
    public static let inputFrequency: UInt64 = 2
    /// The host sends a snapshot every this many ticks.
    public static let snapshotCadence: UInt64 = 4
}
