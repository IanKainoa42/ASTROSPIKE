import CoreGraphics
import Foundation

/// Core physics data structures and deterministic physics simulation.
/// All physics operations are deterministic and can be replayed identically.

// MARK: - Vector Types
extension CGPoint {
    /// Add two points (vector addition).
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    /// Subtract two points (vector subtraction).
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    /// Scale a point by a scalar.
    static func * (point: CGPoint, scalar: Double) -> CGPoint {
        CGPoint(x: point.x * scalar, y: point.y * scalar)
    }

    static func * (scalar: Double, point: CGPoint) -> CGPoint {
        point * scalar
    }

    /// Dot product of two vectors.
    func dot(_ other: CGPoint) -> Double {
        x * other.x + y * other.y
    }

    /// Magnitude (length) of the vector.
    var magnitude: Double {
        sqrt(x * x + y * y)
    }

    /// Normalized unit vector.
    var normalized: CGPoint {
        let mag = magnitude
        guard mag > 0 else { return .zero }
        return self * (1.0 / mag)
    }

    /// Perpendicular vector (rotated 90 degrees counterclockwise).
    var perpendicular: CGPoint {
        CGPoint(x: -y, y: x)
    }
}

// MARK: - Ship Physics State
/// Immutable snapshot of a ship's physics state.
struct ShipPhysicsState: Equatable, Codable {
    /// Position in arena coordinates (center of ship).
    var position: CGPoint

    /// Velocity vector (units per second).
    var velocity: CGPoint

    /// Angular rotation in radians.
    var rotation: Double

    /// Angular velocity in radians per second.
    var angularVelocity: Double

    /// Ship radius for collision detection.
    let radius: Double = 0.5

    init(
        position: CGPoint = .zero,
        velocity: CGPoint = .zero,
        rotation: Double = 0,
        angularVelocity: Double = 0
    ) {
        self.position = position
        self.velocity = velocity
        self.rotation = rotation
        self.angularVelocity = angularVelocity
    }
}

// MARK: - Arena Geometry
/// Defines arena boundaries for wall collision detection.
struct ArenaPhysicsGeometry {
    /// Half-width of the arena.
    let halfWidth: Double

    /// Half-height of the arena.
    let halfHeight: Double

    /// Damping factor for velocity after bounce (0.0 = no bounce, 1.0 = perfect).
    let bounceDamping: Double = 0.92

    init(width: Double, height: Double) {
        self.halfWidth = width / 2
        self.halfHeight = height / 2
    }

    /// Check if position is within arena bounds.
    func isInBounds(_ position: CGPoint) -> Bool {
        position.x > -halfWidth && position.x < halfWidth &&
            position.y > -halfHeight && position.y < halfHeight
    }

    /// Get the closest wall to a position (for reflection calculations).
    func closestWall(to position: CGPoint) -> WallSide {
        let distLeft = position.x + halfWidth
        let distRight = halfWidth - position.x
        let distTop = halfHeight - position.y
        let distBottom = position.y + halfHeight

        let minDist = min(distLeft, distRight, distTop, distBottom)

        switch minDist {
        case distLeft: return .left
        case distRight: return .right
        case distTop: return .top
        default: return .bottom
        }
    }
}

enum WallSide {
    case left
    case right
    case top
    case bottom

    /// Normal vector pointing away from the wall (into the arena).
    var normal: CGPoint {
        switch self {
        case .left: return CGPoint(x: 1, y: 0)
        case .right: return CGPoint(x: -1, y: 0)
        case .top: return CGPoint(x: 0, y: -1)
        case .bottom: return CGPoint(x: 0, y: 1)
        }
    }
}

// MARK: - Physics Engine
/// Deterministic physics simulator with client-side prediction support.
struct DeterministicPhysicsEngine {
    let arena: ArenaPhysicsGeometry

    /// Gravitational acceleration (down the Y axis). Negative = downward.
    let gravity: Double = -9.8

    /// Thrust acceleration when engine is engaged.
    let thrustAcceleration: Double = 25.0

    /// Max rotational acceleration.
    let rotationalAcceleration: Double = 12.0

    /// Friction/damping on velocity.
    let linearDamping: Double = 0.98

    /// Friction/damping on angular velocity.
    let angularDamping: Double = 0.95

    /// Radius for collision detection during wall bouncing.
    let shipRadius: Double = 0.5

    init(arena: ArenaPhysicsGeometry) {
        self.arena = arena
    }

    /// Single deterministic physics step. All operations are order-independent
    /// and reproducible with identical input.
    ///
    /// Parameters:
    ///   - state: Current ship state
    ///   - thrust: Is the engine engaged?
    ///   - torque: Steering input (-1.0 to 1.0, where negative = counterclockwise)
    ///   - deltaTime: Time step in seconds (typically 1/60 or 1/120)
    ///
    /// Returns: Updated ship state after physics simulation
    func step(
        state: ShipPhysicsState,
        thrust: Bool,
        torque: Double,
        deltaTime: Double
    ) -> ShipPhysicsState {
        var newState = state

        // Apply thrust in the direction the ship is facing
        if thrust {
            let thrustVector = CGPoint(
                x: cos(state.rotation) * thrustAcceleration,
                y: sin(state.rotation) * thrustAcceleration
            )
            newState.velocity = newState.velocity + thrustVector * deltaTime
        }

        // Apply gravity
        newState.velocity = newState.velocity + CGPoint(x: 0, y: gravity) * deltaTime

        // Apply linear damping
        newState.velocity = newState.velocity * linearDamping

        // Update position
        newState.position = newState.position + newState.velocity * deltaTime

        // Apply rotational input
        let clampedTorque = max(-1.0, min(1.0, torque))
        newState.angularVelocity = clampedTorque * rotationalAcceleration

        // Apply angular damping
        newState.angularVelocity = newState.angularVelocity * angularDamping

        // Update rotation
        newState.rotation = newState.rotation + newState.angularVelocity * deltaTime

        // Handle wall collisions with ricochet reflection
        newState = handleWallCollisions(newState)

        return newState
    }

    /// Handle wall bouncing and ricochet reflection using proper physics.
    /// This implements realistic ball-bouncing mechanics.
    private func handleWallCollisions(_ state: ShipPhysicsState) -> ShipPhysicsState {
        var newState = state
        let margin = shipRadius

        // Check each wall and apply reflection if necessary
        let wallChecks: [(boundary: Double, wallSide: WallSide, velocityComponent: KeyPath<ShipPhysicsState, Double>)] = [
            (-arena.halfWidth, .left, \.velocity.x),
            (arena.halfWidth, .right, \.velocity.x),
            (arena.halfHeight, .top, \.velocity.y),
            (-arena.halfHeight, .bottom, \.velocity.y),
        ]

        for (boundary, wall, component) in wallChecks {
            let isVertical = wall == .left || wall == .right
            let position = isVertical ? newState.position.x : newState.position.y

            if isVertical {
                // Vertical wall collision (left or right)
                if (wall == .left && position < -arena.halfWidth + margin) ||
                   (wall == .right && position > arena.halfWidth - margin) {
                    // Push back into bounds
                    newState.position.x = wall == .left ?
                        -arena.halfWidth + margin :
                        arena.halfWidth - margin

                    // Reflect velocity in X direction
                    newState.velocity.x = -newState.velocity.x * arena.bounceDamping

                    // Kill rotational momentum slightly on impact
                    newState.angularVelocity *= 0.95
                }
            } else {
                // Horizontal wall collision (top or bottom)
                if (wall == .bottom && position < -arena.halfHeight + margin) ||
                   (wall == .top && position > arena.halfHeight - margin) {
                    // Push back into bounds
                    newState.position.y = wall == .bottom ?
                        -arena.halfHeight + margin :
                        arena.halfHeight - margin

                    // Reflect velocity in Y direction
                    newState.velocity.y = -newState.velocity.y * arena.bounceDamping

                    // Kill rotational momentum slightly on impact
                    newState.angularVelocity *= 0.95
                }
            }
        }

        return newState
    }
}

// MARK: - Physics Prediction
/// Predicts future ship state for client-side prediction without waiting for server.
struct PhysicsPrediction {
    let engine: DeterministicPhysicsEngine

    /// Predict the ship state after a given number of simulation steps.
    ///
    /// Parameters:
    ///   - initialState: Current ship state
    ///   - inputs: Input commands for each step (thrust, torque)
    ///   - deltaTime: Time step per simulation
    ///   - steps: Number of steps to predict
    ///
    /// Returns: Predicted ship state
    func predict(
        from initialState: ShipPhysicsState,
        inputs: [(thrust: Bool, torque: Double)],
        deltaTime: Double
    ) -> ShipPhysicsState {
        var state = initialState
        for input in inputs {
            state = engine.step(
                state: state,
                thrust: input.thrust,
                torque: input.torque,
                deltaTime: deltaTime
            )
        }
        return state
    }
}
