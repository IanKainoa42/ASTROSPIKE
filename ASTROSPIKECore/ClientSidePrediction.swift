import Foundation

/// Manages client-side prediction: local inputs are applied instantly, then
/// reconciled when server updates arrive. This eliminates input lag.
@MainActor
final class ClientSidePredictionManager {
    /// History of local inputs (tick -> input), kept for reconciliation.
    private var inputHistory: [UInt64: PlayerInput] = [:]

    /// Local predicted game state.
    private(set) var predictedState: ShipPhysicsState

    /// Authoritative state from server.
    private(set) var authoritativeState: ShipPhysicsState

    /// Displayed state (smoothed between predicted and authoritative).
    private(set) var displayState: ShipPhysicsState

    /// Physics engine for simulation.
    let physicsEngine: DeterministicPhysicsEngine

    /// Current local tick counter.
    private(set) var localTick: UInt64 = 0

    /// Maximum ticks to roll forward when reconciling (safety limit).
    let maxRollForwardTicks: UInt64 = 24

    /// Smoothing parameter for interpolation (0.0 = snap, 1.0 = smooth).
    var smoothingAlpha: Double = 0.1

    /// Callback when reconciliation occurs.
    var onReconciliation: ((error: CGPoint) -> Void)?

    init(physicsEngine: DeterministicPhysicsEngine, initialState: ShipPhysicsState) {
        self.physicsEngine = physicsEngine
        self.predictedState = initialState
        self.authoritativeState = initialState
        self.displayState = initialState
    }

    // MARK: - Local Input & Prediction

    /// Apply a local input and immediately predict its effect (no network latency).
    ///
    /// Parameters:
    ///   - input: The player's input command
    ///   - deltaTime: Physics time step
    func applyLocalInput(_ input: PlayerInput, deltaTime: Double) {
        let tick = localTick
        inputHistory[tick] = input

        // Apply locally immediately (client-side prediction)
        predictedState = physicsEngine.step(
            state: predictedState,
            thrust: input.thrust,
            torque: input.torque,
            deltaTime: deltaTime
        )

        // Smooth toward predicted state (can optionally show prediction)
        updateDisplayState()

        localTick += 1

        // Clean up very old history to prevent memory bloat
        let cutoff = tick > 128 ? tick - 128 : 0
        for tick in inputHistory.keys where tick < cutoff {
            inputHistory.removeValue(forKey: tick)
        }
    }

    // MARK: - Server Reconciliation

    /// Called when an authoritative server state arrives.
    ///
    /// Strategy:
    /// 1. Accept the authoritative state
    /// 2. Check if we're ahead of the server (local tick > server tick)
    /// 3. If yes and within rollForward limit, re-simulate with our stored inputs
    /// 4. Reconcile differences in position/velocity
    ///
    /// Parameters:
    ///   - authoritativeState: The server's current state
    ///   - serverTick: The tick this state corresponds to
    func reconcileWithAuthoritative(
        authoritativeState: ShipPhysicsState,
        serverTick: UInt64
    ) {
        self.authoritativeState = authoritativeState

        let ticksBehind = localTick > serverTick ? localTick - serverTick : 0

        if ticksBehind > maxRollForwardTicks {
            // Too far behind; just snap to server state
            predictedState = authoritativeState
            inputHistory.removeAll()
        } else if ticksBehind > 0 {
            // Roll forward: replay our inputs on top of server state
            var rolledState = authoritativeState
            for tick in serverTick..<localTick {
                guard let input = inputHistory[tick] else { continue }
                // Use a fixed deltaTime for determinism (match server)
                rolledState = physicsEngine.step(
                    state: rolledState,
                    thrust: input.thrust,
                    torque: input.torque,
                    deltaTime: 1.0 / 60.0  // Adjust to match your server's step rate
                )
            }

            // Calculate reconciliation error
            let positionError = rolledState.position - authoritativeState.position
            onReconciliation?(error: positionError)

            // Apply a soft correction: blend our prediction with server reality
            predictedState = reconcile(
                predicted: rolledState,
                authoritative: authoritativeState,
                alpha: 0.5  // 50% blend toward server state
            )
        } else {
            // We're in sync; just use server state
            predictedState = authoritativeState
        }

        updateDisplayState()
    }

    /// Soft reconciliation: blend predicted state with authoritative when they disagree.
    /// This prevents snappy corrections and provides smooth gameplay.
    private func reconcile(
        predicted: ShipPhysicsState,
        authoritative: ShipPhysicsState,
        alpha: Double
    ) -> ShipPhysicsState {
        let a = max(0, min(1, alpha))

        return ShipPhysicsState(
            position: CGPoint(
                x: predicted.position.x * (1 - a) + authoritative.position.x * a,
                y: predicted.position.y * (1 - a) + authoritative.position.y * a
            ),
            velocity: CGPoint(
                x: predicted.velocity.x * (1 - a) + authoritative.velocity.x * a,
                y: predicted.velocity.y * (1 - a) + authoritative.velocity.y * a
            ),
            rotation: predicted.rotation * (1 - a) + authoritative.rotation * a,
            angularVelocity: predicted.angularVelocity * (1 - a) + authoritative.angularVelocity * a
        )
    }

    // MARK: - Display State

    /// Update display state with smooth interpolation between predicted and authoritative.
    private func updateDisplayState() {
        displayState = ShipPhysicsState(
            position: CGPoint(
                x: predictedState.position.x * smoothingAlpha + authoritativeState.position.x * (1 - smoothingAlpha),
                y: predictedState.position.y * smoothingAlpha + authoritativeState.position.y * (1 - smoothingAlpha)
            ),
            velocity: CGPoint(
                x: predictedState.velocity.x * smoothingAlpha + authoritativeState.velocity.x * (1 - smoothingAlpha),
                y: predictedState.velocity.y * smoothingAlpha + authoritativeState.velocity.y * (1 - smoothingAlpha)
            ),
            rotation: predictedState.rotation * smoothingAlpha + authoritativeState.rotation * (1 - smoothingAlpha),
            angularVelocity: predictedState.angularVelocity * smoothingAlpha + authoritativeState.angularVelocity * (1 - smoothingAlpha)
        )
    }

    /// Get the last N frames of input history (for debugging/network transmission).
    func recentInputs(count: Int) -> [PlayerInput] {
        let startTick = localTick > UInt64(count) ? localTick - UInt64(count) : 0
        return (startTick..<localTick).compactMap { inputHistory[$0] }
    }

    /// Reset to a known state (on disconnect/reconnect).
    func reset(to state: ShipPhysicsState) {
        predictedState = state
        authoritativeState = state
        displayState = state
        inputHistory.removeAll()
        localTick = 0
    }
}

/// Server-side reconciliation: validates and applies corrections to client state.
/// Used by the host to apply corrections to guest's predicted state.
struct ServerReconciler {
    /// Maximum position delta before snapping instead of blending.
    let maxBlendDistance: Double = 5.0

    /// Reconcile a client's predicted state with the server's authoritative version.
    /// This is called when the client's prediction diverges from server reality.
    ///
    /// Parameters:
    ///   - predicted: Client's predicted state
    ///   - authoritative: Server's authoritative state
    ///
    /// Returns: Reconciled state (either blended or snapped)
    func reconcile(
        predicted: ShipPhysicsState,
        authoritative: ShipPhysicsState
    ) -> ShipPhysicsState {
        let positionError = predicted.position - authoritative.position
        let distance = positionError.magnitude

        if distance > maxBlendDistance {
            // Large divergence: snap to server state
            return authoritative
        } else if distance > 0.1 {
            // Moderate divergence: blend smoothly
            let alpha = distance / maxBlendDistance
            return ShipPhysicsState(
                position: CGPoint(
                    x: predicted.position.x * (1 - alpha) + authoritative.position.x * alpha,
                    y: predicted.position.y * (1 - alpha) + authoritative.position.y * alpha
                ),
                velocity: CGPoint(
                    x: predicted.velocity.x * (1 - alpha) + authoritative.velocity.x * alpha,
                    y: predicted.velocity.y * (1 - alpha) + authoritative.velocity.y * alpha
                ),
                rotation: predicted.rotation,
                angularVelocity: predicted.angularVelocity
            )
        } else {
            // Small error: accept prediction as-is
            return predicted
        }
    }
}
