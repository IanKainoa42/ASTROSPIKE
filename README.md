# ASTROSPIKE

ASTROSPIKE is a free, landscape-only iPhone and iPad arena game for iOS 18 and later. Two momentum-driven landers volley a fast, highly elastic luminous ball across a lethal center boundary toward compact back-to-back goals beside the center net.

## Project layout

- `ASTROSPIKE/` — SwiftUI app shell, SpriteKit renderer, touch controls, feedback, Game Center transport, and fixed-step display driver.
- `ASTROSPIKECore/` — deterministic `SIMD2<Double>` simulation, arena geometry, match rules, AI, binary wire protocol, prediction reconciliation, and reconnect state machine.
- `ASTROSPIKECoreTests/` — physics, collision, scoring, AI, networking, performance, and soak tests.
- `ASTROSPIKEUITests/` — landscape home, tutorial/settings, solo, and pause flows.
- `project.yml` — XcodeGen source of truth for the Xcode 26.6 project.

SpriteKit only renders immutable `WorldState` snapshots. It does not own physics, scoring, AI, or network authority.

## Rules

- The prototype controls are canonical: the left thumb holds either directional rotation control, while the right thumb holds the constant-thrust control.
- Lunar-style flight tuning is canonical: gravity is `-2` arena units/s², main thrust is a constant `5.5` arena units/s², and the full-input rotation rate is `3` rad/s.
- Linear momentum persists without stabilization. Rotation applies only while a direction is held and stops immediately on release, leaving the ship at its current angle.
- Each goal opens toward its defender's side with its back against the center net; a downward return from the net into the pocket scores.
- The low net rebounds the ball. Ships may clear it and fly into the opponent’s side as far as that side’s halfway marker.
- Touching the net from the opponent’s side or crossing beyond the halfway marker destroys the intruding ship.
- Ground contact destroys a ship. Ship-to-ship contact destroys both ships; outer walls and the ceiling remain safe rebounds.
- A goal, third floor bounce on one side, ground crash, net contact, or over-crossing awards one point.
- Crossing the center plane resets only the entered side's bounce count.
- Simultaneous ship deaths replay the rally. A goal or third bounce outranks a death in the same simulation step.
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
