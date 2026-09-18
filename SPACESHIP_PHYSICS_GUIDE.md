# Spaceship Physics & Prediction System Guide

A production-ready Swift implementation for indie sports-action games featuring deterministic physics, client-side prediction, and server reconciliation for online multiplayer.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                       GameLoopManager                         │
│  (CADisplayLink 60/120 FPS, fixed timestep integration)      │
└────────┬────────────────────────────────┬───────────────────┘
         │                                │
    ┌────▼────────┐            ┌─────────▼──────────┐
    │  InputHandler │            │ ClientSidePrediction │
    │  (Touch/     │            │ Manager            │
    │   Gamepad)   │            │ (Instant feedback)  │
    └────┬────────┘            └─────────┬──────────┘
         │                                │
         └────────────┬───────────────────┘
                      │
              ┌───────▼────────┐
              │ Physics Engine │
              │ (Deterministic)│
              │ (Wall bouncing)│
              └───────┬────────┘
                      │
         ┌────────────┴────────────┐
         │                         │
    ┌────▼─────┐          ┌────────▼──────┐
    │ Predicted │          │ Authoritative │
    │   State   │          │    State      │
    └───────────┘          └────────┬──────┘
                                    │
                        ┌───────────▼─────────┐
                        │ Server Reconciliation│
                        │ (Roll-forward/blend)│
                        └─────────────────────┘
```

## Components

### 1. SpaceshipPhysics.swift

**Core deterministic physics simulation.**

#### Key Types:

- **`ShipPhysicsState`** – Immutable snapshot of ship state (position, velocity, rotation, angular velocity)
- **`ArenaPhysicsGeometry`** – Arena bounds and collision parameters
- **`DeterministicPhysicsEngine`** – Physics simulation with:
  - Linear motion (gravity, thrust, damping)
  - Angular motion (torque, spin)
  - Wall collision/reflection using proper ricochet math
  - Fully deterministic (same inputs = same outputs, always)

#### Usage Example:

```swift
let arena = ArenaPhysicsGeometry(width: 20, height: 20)
let engine = DeterministicPhysicsEngine(arena: arena)

var state = ShipPhysicsState(position: .zero, velocity: .zero)

// Step the physics (50 ms at 60 FPS)
state = engine.step(
    state: state,
    thrust: true,      // Engine on
    torque: 0.5,       // Turn right
    deltaTime: 1.0/60.0
)

// Result: new position, velocity, rotation after 1 frame
```

### 2. InputHandling.swift

**Converts touch, gamepad, and keyboard input to normalized player commands.**

#### Key Types:

- **`PlayerInput`** – Single input frame with torque, thrust, fire, and tick
- **`TouchInputHandler`** – Processes UITouch events into analog steering + button presses
- **`GamepadInputHandler`** – MFi controller (D-pad, analog stick, triggers, buttons)
- **`KeyboardInputHandler`** – WASD + Space for development on Mac/iPad
- **`GestureInputHandler`** – Swipes, taps, long-press for alternative controls

#### Usage Example:

```swift
let inputHandler = TouchInputHandler()

// Integrate with UIView touch events
override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    inputHandler.handleTouchesBegan(touches, in: self)
}

// Get current input state
let input = inputHandler.currentInput  // PlayerInput(torque: 0.3, thrust: true, fire: false)
```

### 3. ClientSidePrediction.swift

**Applies local inputs instantly (no network latency), reconciles when server updates arrive.**

#### Key Types:

- **`ClientSidePredictionManager`** – Manages local prediction, history, and reconciliation
- **`ServerReconciler`** – Server-side: validates and blends client predictions

#### How It Works:

1. **Local Input** → Applied instantly to predicted state (player sees immediate response)
2. **Input History** → Stored locally (last 128 ticks)
3. **Server Update** → Arrives ~50ms later with authoritative state
4. **Reconciliation** → Roll forward from server state using stored inputs
5. **Display** → Smoothly blend predicted and authoritative states

#### Usage Example:

```swift
let prediction = ClientSidePredictionManager(
    physicsEngine: engine,
    initialState: ShipPhysicsState()
)

// Every frame
prediction.applyLocalInput(playerInput, deltaTime: 1.0/60.0)

// When server sends update (every ~100ms)
prediction.reconcileWithAuthoritative(
    authoritativeState: serverState,
    serverTick: 600
)

// Display uses smoothed state
let displayState = prediction.displayState
```

#### Reconciliation Strategies:

- **Small Error** (<0.1 units): Accept prediction as-is
- **Moderate Error** (0.1–5.0 units): Blend smoothly toward server
- **Large Error** (>5.0 units): Snap to server state

### 4. GameLoopManager.swift

**Orchestrates everything: input → physics → rendering, using CADisplayLink.**

#### Key Types:

- **`GameLoopManager`** – Main coordinator
- **`TouchableGameView`** – UIView subclass with integrated touch handling

#### The Game Loop:

```
Display Link Tick (60/120 FPS)
  ├─ Accumulate deltaTime
  ├─ While accumulator >= fixedDeltaTime:
  │   ├─ Get current input (from handlers)
  │   ├─ Step physics (DeterministicPhysicsEngine)
  │   ├─ Apply local prediction
  │   └─ Fire callbacks
  ├─ Update display state
  └─ Render next frame
```

#### Usage Example:

```swift
let gameLoop = GameLoopManager(
    arena: ArenaPhysicsGeometry(width: 20, height: 20),
    initialState: ShipPhysicsState()
)

gameLoop.onPhysicsStep = {
    // Called after each fixed physics step
    updateDisplay(gameLoop.displayState)
}

gameLoop.onNetworkUpdate = { state in
    // Called when server state arrives
    print("Reconciled at tick \(gameLoop.localTick)")
}

gameLoop.start()  // Begins CADisplayLink
```

### 5. PhysicsGameExample.swift

**Complete integration example with SwiftUI UI, network simulator, and debug HUD.**

This demonstrates:
- Full game loop setup
- Touch input integration
- Network latency simulation
- Reconciliation visualization
- Debug statistics display

## Integration Steps

### Step 1: Add to Your Game Loop

Replace or augment your existing physics/input system:

```swift
@MainActor
class GameSession {
    let gameLoop: GameLoopManager
    
    init() {
        self.gameLoop = GameLoopManager(
            arena: ArenaPhysicsGeometry(width: 20, height: 20),
            initialState: ShipPhysicsState(position: CGPoint(x: -8, y: 0))
        )
    }
    
    func start() {
        gameLoop.start()
        gameLoop.onPhysicsStep = { [weak self] in
            self?.updateScene()
        }
    }
    
    func updateScene() {
        let state = gameLoop.displayState
        // Update your SpriteKit/SceneKit scene with state.position, state.rotation
    }
}
```

### Step 2: Connect Input Handling

For touch controls on iOS/Mac Catalyst:

```swift
// In your game view controller
let gameView = TouchableGameView()
gameView.touchInputHandler = gameLoop.inputHandler

// Or for a SwiftUI view containing the game
ZStack {
    GameRenderView(state: gameLoop.displayState)
        .gesture(
            DragGesture()
                .onChanged { gesture in
                    let normalizedX = gesture.location.x / bounds.width * 2 - 1
                    gameLoop.inputHandler.setTorque(Double(normalizedX))
                }
                .onEnded { _ in
                    gameLoop.inputHandler.setTorque(0)
                }
        )
}
```

### Step 3: Handle Network Updates

When your server sends state snapshots:

```swift
// In your online match coordinator
func receiveServerState(_ state: ShipPhysicsState, tick: UInt64) {
    gameLoop.receiveAuthoritativeUpdate(state: state, serverTick: tick)
}
```

### Step 4: Send Local Input to Server

Periodically send the player's input to the server:

```swift
// Every 2-3 frames (skip frames to reduce network overhead)
if gameLoop.localTick % 3 == 0 {
    let input = gameLoop.inputHandler.currentInput
    sendToServer(input)
}
```

## Physics Details

### Deterministic Design

All physics operations use the same order and floating-point operations to ensure:
- **Reproducibility**: Same inputs always produce same outputs
- **Network Compatibility**: Server and client can simulate identically
- **Rollback Safety**: Can replay ticks without losing coherence

### Wall Collision & Ricochet

The physics engine implements proper reflection math:

1. **Boundary Check**: Is ship center within margin of wall?
2. **Reflection**: `velocity.x = -velocity.x * bounceDamping` (or Y for horizontal walls)
3. **Constraint**: Push ship back into bounds
4. **Damping**: `bounceDamping ≈ 0.92` simulates energy loss (realistic bounce)

Example arena: 20×20 units, ship radius 0.5:
- Left wall at x = -10
- Right wall at x = 10
- Collision zone: ±10.5 from center

### Physics Parameters

Tune these in `DeterministicPhysicsEngine` to match your game feel:

```swift
let gravity: Double = -9.8              // Downward acceleration
let thrustAcceleration: Double = 25.0   // Engine power
let rotationalAcceleration: Double = 12.0
let linearDamping: Double = 0.98        // Air friction (1.0 = no damping)
let angularDamping: Double = 0.95
let bounceDamping: Double = 0.92        // Bounce energy retention
```

## Client-Side Prediction Algorithm

### Timeline

```
T=0ms: Player presses thrust
       └─> Applied locally immediately
           Predicted state updates

T=50ms: Server snapshot arrives (network RTT 100ms)
        └─> Authoritative state at T=-50ms
        └─> Reconcile: Roll forward 3 frames with stored inputs
        └─> Blend: predicted ← 80% predicted + 20% authoritative

T=51ms: Next frame rendered with reconciled state
        (No visible snap because of blending)
```

### Input History

```swift
// Stored automatically by ClientSidePredictionManager
localInputHistory[0] = PlayerInput(thrust: false, torque: 0)
localInputHistory[1] = PlayerInput(thrust: true, torque: 0)
localInputHistory[2] = PlayerInput(thrust: true, torque: 0.5)
localInputHistory[3] = PlayerInput(thrust: true, torque: 0.8)
// ... up to 128 ticks
```

When server update arrives at tick 3:
1. Server state at tick 3 is authoritative
2. Local tick is 8
3. Replay inputs 4–8 on server state
4. Blend results with predicted state

### Reconciliation Error

If predicted and authoritative differ by >5 units: snap
If differ by 0.1–5 units: blend with factor = error / maxDistance
If differ by <0.1 units: accept prediction

This prevents visible corrections while maintaining accuracy.

## Network Protocol Integration

### Example: Integrating with GameKit

```swift
// In your OnlineMatchCoordinator
func sendInput(_ input: PlayerInput) {
    var data = Data()
    data.append(contentsOf: withUnsafeBytes(of: input.torque) { $0 })
    data.append(contentsOf: withUnsafeBytes(of: input.thrust) { $0 })
    data.append(contentsOf: withUnsafeBytes(of: input.fire) { $0 })
    
    try? match?.sendData(to: recipientPlayers, with: .reliable, data: data)
}

func receiveRemoteInput(_ data: Data) {
    let torque = data.withUnsafeBytes { $0.load(as: Double.self) }
    let thrust = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Bool.self) }
    // ... etc
}

// Send server state snapshots every ~100ms (6 ticks @ 60 FPS)
func sendStateSnapshot(_ state: ShipPhysicsState) {
    // Encode state to Data
    // Send to all players
}
```

## Debugging & Monitoring

### Enable Debug Logging

```swift
gameLoop.debugLogging = true
// Logs: physics ticks, reconciliation events, input changes
```

### Monitor Reconciliation

```swift
print("Last reconciliation error: \(gameLoop.reconciliationError) units")
print("Current tick: \(gameLoop.localTick)")
print("Predicted vs Authoritative position delta: \(delta)")
```

### Visualize Prediction

In your render code, optionally draw both states:

```swift
// Predicted position (what we think is happening)
drawShip(at: gameLoop.currentPredictedState.position, color: .cyan)

// Authoritative position (what server says)
drawShip(at: gameLoop.currentAuthoritativeState.position, color: .red, alpha: 0.5)

// Displayed position (what user sees, smoothed)
drawShip(at: gameLoop.displayState.position, color: .white)
```

## Performance Considerations

### Fixed Timestep

Using `fixedDeltaTime = 1/60` (not variable dt):
- ✅ Physics is deterministic
- ✅ Easy to replay for reconciliation
- ✅ Predictable CPU usage
- ⚠️ Frame rate can dip below 60 FPS during input processing
- **Solution**: Do input sampling on a separate thread or at fixed intervals

### Memory: Input History

Storing ~128 ticks of input = ~1-2 KB (negligible)

```swift
struct PlayerInput: Codable {  // 32 bytes
    var torque: Double        // 8 bytes
    var thrust: Bool          // 1 byte
    var fire: Bool            // 1 byte
    var tick: UInt64          // 8 bytes
    // Padding: 14 bytes
}
```

### Network Bandwidth

**Per-player, per-second (at 60 FPS with 50% send rate):**
- Local input: 30 packets × ~16 bytes = 480 bytes/sec (~4 kbps)
- Received inputs: Same
- State snapshot (every 100ms): ~64 bytes × 10/sec = 640 bytes/sec (~5 kbps)

**Total**: ~9 kbps per player (negligible on modern networks)

## Testing

### Unit Tests for Physics

```swift
func testWallBounce() {
    let arena = ArenaPhysicsGeometry(width: 20, height: 20)
    let engine = DeterministicPhysicsEngine(arena: arena)
    
    var state = ShipPhysicsState(
        position: CGPoint(x: 9.8, y: 0),
        velocity: CGPoint(x: 5, y: 0)  // Moving right, toward wall at x=10
    )
    
    state = engine.step(state: state, thrust: false, torque: 0, deltaTime: 0.1)
    
    // Should bounce off right wall
    XCTAssertLess(state.position.x, 10)  // Within bounds
    XCTAssertLess(state.velocity.x, 0)   // Now moving left
    XCTAssertGreater(state.velocity.x, -5)  // Damped from original
}
```

### Integration Tests

```swift
func testClientSidePredictionReconciliation() {
    let prediction = ClientSidePredictionManager(...)
    
    // Simulate 5 frames of local input
    let inputs = [(true, 0.0), (true, 0.5), (true, 0.8), (true, 0.8), (true, 0.5)]
    for input in inputs {
        prediction.applyLocalInput(PlayerInput(thrust: input.0, torque: input.1), deltaTime: 0.016)
    }
    
    // Server sends update from 3 frames ago
    let serverState = /* ... */
    prediction.reconcileWithAuthoritative(authoritativeState: serverState, serverTick: 2)
    
    // Should replay inputs 3-4 on server state
    // Reconciliation error should be small
    XCTAssertLess(gameLoop.reconciliationError, 0.5)
}
```

## Troubleshooting

### Issue: Ships jump/snap when server updates arrive

**Cause**: Reconciliation error threshold too high, or blending factor too aggressive

**Solution**:
```swift
prediction.smoothingAlpha = 0.05  // Smoother blending (0.0 = snap, 1.0 = ignore server)
```

### Issue: Physics not deterministic (divergence over time)

**Cause**: Floating-point precision, non-deterministic random values

**Solution**:
- ✅ Use `Double` (not `Float`)
- ✅ Avoid `sqrt()` if possible; use `magnitude²` for comparisons
- ✅ Never use `Date()` or `Int.random()` in physics
- ✅ Use seeded RNG if needed

### Issue: Input lag on wireless

**Cause**: Network latency causing reconciliation delays

**Solution**:
- Ensure client-side prediction is active (inputs applied locally immediately)
- Increase `maxRollForwardTicks` if network is consistently late
- Reduce network packet send rate to improve reliability (fewer packets = fewer losses)

## Further Reading

- GDC Talk: "Fix Your Timestep" (Glenn Fiedler)
- Valve: "Lag Compensation" in Source Engine
- GGPO Framework: rollback-based netcode for fighting games
- Unreal Engine: "Replication Graph" and "Subobject Replication"

## License

This implementation is provided as-is for use in your ASTROSPIKE project.
