# ASTROSPIKE

ASTROSPIKE is a free, landscape-only iPhone and iPad arena game for iOS 18 and later. Two momentum-driven landers volley a fast, highly elastic luminous ball over a single centre net, trying to drive it flat through the net itself — a portal the ball vanishes into.

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
- The net is the goal, and it is a portal rather than a wall. One slab, dead centre, standing on the floor. Drive the ball into a face and it passes through and disappears -- whoever drove it in takes the point, so you shoot at the face on your own side, flat and low.
- The top of the net is hard and neutral. Clipping the cap rebounds the ball and never scores, so a ball dropped from above is a miss, not a cheap goal. The cap alternates its nudge by rally, which favours neither half and stops a ball settling on the crown.
- Ships collide with the net like a wall, faces included. The portal is a target for the ball, never a tunnel for a hull.
- The floor and ceiling meet the outer walls through flattened elliptical arcs. They are wide and shallow, so a stray ball is nudged back toward the middle rather than spun around a bowl.
- A ship contact always pushes the ball clear of the hull, so the ball can never be carried, ridden, or hovered with.
- Nothing in the arena destroys a ship. The ground, the net, the outer walls, the ceiling, and the other ship are all rebounds.
- Ships may clear the net freely. Past the halfway marker the far half pushes back in proportion to how deep the ship is and bleeds its speed, so crossing is always possible and always costs more the further it goes.
- A goal, a second floor bounce since the last hit, or a fourth touch on one trip awards one point. Those are the only three ways to score.
- Each ship hit refreshes the bounce allowance but not the touch tally, so touch/bounce/touch/bounce is not a way to stall on your own half.
- Crossing the center plane resets the entered side's bounce count and ends the possession for both sides.
- First to 7 wins with a two-point lead; 11 is the hard cap.
- After every non-winning point, only the ball respawns high over the middle, nudged slightly toward the conceding side. Both ships keep flying under live input during the prototype's 1.35-second serve hold, then the ball drops immediately with no reset or countdown.

## Build and test

Requirements: Xcode 26.6, XcodeGen, iOS 18 or later.

```sh
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer \
  xcodebuild -project ASTROSPIKE.xcodeproj -scheme ASTROSPIKE \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test
```

The checked-in project uses automatic signing for team `WC46K49VFA` and bundle ID `com.iankainoa.ASTROSPIKE`.

## TestFlight

Bump `CURRENT_PROJECT_VERSION` in `project.yml` before every upload — App Store Connect rejects a build number it has already seen. Then, on a Mac signed in to the team:

```sh
xcodegen generate
xcodebuild -project ASTROSPIKE.xcodeproj -scheme ASTROSPIKE \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/ASTROSPIKE.xcarchive archive
xcodebuild -exportArchive -archivePath build/ASTROSPIKE.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export
xcrun altool --upload-app -f build/export/ASTROSPIKE.ipa -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
```

`ExportOptions.plist` holds the distribution settings. Xcode's Product ▸ Archive ▸ Distribute App does the same thing through the GUI.

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
