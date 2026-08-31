# ASTROSPIKE

ASTROSPIKE is a free, landscape-only iPhone and iPad arena game for iOS 18 and later. Two momentum-driven landers volley a fast, highly elastic luminous ball across a lethal center boundary toward compact back-to-back goals beside the center net.

## Project layout

- `ASTROSPIKE/` — SwiftUI app shell, SpriteKit renderer, touch controls, feedback, Game Center transport, and fixed-step display driver.
- `ASTROSPIKECore/` — deterministic `SIMD2<Double>` simulation, arena geometry, match rules, AI, binary wire protocol, prediction reconciliation, and reconnect state machine.
- `ASTROSPIKECoreTests/` — physics, collision, scoring, AI, networking, performance, and soak tests.
- `ASTROSPIKEUITests/` — landscape home, tutorial/settings, solo, and pause flows.
- `project.yml` — XcodeGen source of truth for the Xcode 26.6 project.

SpriteKit only renders immutable `WorldState` snapshots. It does not own physics, scoring, AI, or network authority.

## Solo AI

`AIController` flies a lander under exactly the player's constraints: thrust is on or off along the nose, and the nose turns at a fixed rate. Each decision rolls the ball forward through the arena, takes the first arrival on its own half it can set up behind in time, waits a run-up along the line of the shot it wants, then drives through the ball to send it back across the net. Difficulty changes reaction cadence, aim error, and how hard the ship drives through contact — never the physics.

## Rules

- The prototype controls are canonical: the left thumb holds either directional rotation control, while the right thumb holds the constant-thrust control.
- Lunar-style flight tuning is canonical: gravity is `-2` arena units/s², main thrust is a constant `5.5` arena units/s², and the full-input rotation rate is `3` rad/s.
- Linear momentum persists without stabilization. Rotation applies only while a direction is held and stops immediately on release, leaving the ship at its current angle.
- Each goal opens toward its defender's side with its back against the center net; a downward return from the net into the pocket scores.
- The low net rebounds the ball. It stands a fifth of the arena height, so volleys and ships both clear it comfortably.
- A ship contact always pushes the ball clear of the hull, so the ball can never be carried, ridden, or hovered with.
- Nothing in the arena destroys a ship. The ground, the net, the outer walls, the ceiling, and the other ship are all rebounds.
- Ships may clear the net freely. Past the halfway marker the far half pushes back in proportion to how deep the ship is and bleeds its speed, so crossing is always possible and always costs more the further it goes.
- A goal or a third floor bounce on one side awards one point. Those are the only two ways to score.
- Crossing the center plane resets only the entered side's bounce count.
- First to 7 wins with a two-point lead; 11 is the hard cap.
- After every non-winning point, only the ball respawns above the conceding side. Both ships keep flying under live input during the prototype's 1.35-second serve hold, then the ball drops immediately with no reset or countdown.

## Build and test

Requirements: Xcode 26.6, XcodeGen, iOS 18 or later.

```sh
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer \
  xcodebuild -project ASTROSPIKE.xcodeproj -scheme ASTROSPIKE \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test
```

The checked-in project uses automatic signing for team `WC46K49VFA` and bundle ID `com.iankainoa.ASTROSPIKE`.

## Online architecture

- `GKMatchmakerViewController` provides automatic matching and friend invitations.
- Every peer invokes `chooseBestHostingPlayer`; the selected peer is authoritative.
- Inputs are sent unreliably every four simulation ticks (30 Hz).
- Host snapshots are sent unreliably every six ticks (20 Hz).
- Lifecycle and scoring events are sent reliably.
- Guests predict their local ship and reconcile by blend-or-snap against host snapshots.
- A disconnect opens a ten-second recovery window. Reconnection triggers a reliable full resync; expiry finishes the match by forfeit.

The implementation follows Apple's [real-time data exchange](https://developer.apple.com/documentation/gamekit/exchanging-data-between-players-in-real-time-games) and [matchmaking](https://developer.apple.com/documentation/gamekit/gkmatchmakerviewcontroller) guidance.

## Verification artifacts

- `artifacts/screenshots/home.png` — simulator home screen.
- `artifacts/screenshots/physical-gameplay-landscape.png` — signed build running on a physical iPhone, including the Metal performance HUD.
- `docs/PHYSICAL-MULTIPLAYER-CHECKLIST.md` — two-device sandbox Game Center acceptance checklist.

The `--demo` debug launch argument starts a Pilot-vs-Pilot match for unattended rendering and capture. It does not change release gameplay.
