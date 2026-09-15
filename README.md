# ASTROSPIKE

ASTROSPIKE is a free-to-play, landscape-only iPhone and iPad arena game for iOS 18 and later. Every mode and every rule is free; the only in-app purchases are four cosmetic hulls, which change nothing about how a ship flies, bounces or scores. Two momentum-driven landers volley a fast, highly elastic luminous ball around a single centre net that hangs from the roof, trying to lift it up and drive it through the net itself — a portal the ball vanishes into.

## Project layout

- `ASTROSPIKE/` — SwiftUI app shell, SpriteKit renderer, touch controls, feedback, Game Center transport, and fixed-step display driver.
- `ASTROSPIKECore/` — deterministic `SIMD2<Double>` simulation, arena geometry, match rules, AI, binary wire protocol, prediction reconciliation, and reconnect state machine.
- `ASTROSPIKECoreTests/` — physics, collision, scoring, AI, networking, performance, and soak tests.
- `ASTROSPIKEUITests/` — landscape home, tutorial/settings, solo, and pause flows.
- `ASTROSPIKE/ASTROSPIKE.storekit` — local StoreKit prices for the premium hulls. Attached to the scheme's
  Run action only, so **Product ▸ Run from Xcode** exercises the real purchase path without App Store Connect.
  It is not copied into the shipped bundle, and `xcodebuild test` does not pick it up.
- `project.yml` — XcodeGen source of truth for the Xcode 26.6 project.

SpriteKit only renders immutable `WorldState` snapshots. It does not own physics, scoring, AI, or network authority.

## Solo AI

`AIController` flies a lander under exactly the player's constraints: thrust is on or off along the nose, and the nose turns at a fixed rate. Each decision rolls the ball forward through the arena, takes the first arrival on its own half it can set up behind in time, waits a run-up along the line of the shot it wants, then drives through the ball to send it back across the net. Difficulty changes reaction cadence, aim error, and how hard the ship drives through contact — never the physics.

## Rules

- The prototype controls are canonical: the left thumb holds either directional rotation control, while the right thumb holds the constant-thrust control.
- Lunar-style flight tuning is canonical: gravity is `-2` arena units/s², main thrust is a constant `5.5` arena units/s², and the full-input rotation rate is `3` rad/s.
- Linear momentum persists without stabilization. Rotation applies only while a direction is held and stops immediately on release, leaving the ship at its current angle.
- The net is the goal, and it is a portal rather than a wall. One slab, dead centre, hanging from the roof. The face on your side is the goal you defend: a ball that goes in through it passes through, disappears, and is a point for the other side. To score you get the ball into the far half and up into the face over there -- lifted and driven on purpose, since the top of the arena is where a ball never wanders by itself -- or you make the other side put it into their own.
- The bottom of the net is hard and neutral. Clipping the cap from below rebounds the ball and never scores, so a toss straight up is a miss, not a cheap goal. The cap alternates its nudge by rally, which favours neither half and stops a ball pogoing under it.
- A lip juts out under each face and tilts inward. A ball that lands on a lip rolls into the portal, so a shot skimmed under the cap that drops onto the far lip is a goal. It is the one soft surface in the arena, and it never counts as a bounce.
- The roof bulges over the net with the same curve as the corners, so a ball riding the ceiling into the middle is thrown down and away rather than fed into the goal. The bulge is solid and never counts as a bounce.
- Ships fly straight through the net, lips and all. The portal is a target for the ball, never a wall for a hull -- defending it means sitting in the mouth.
- The floor and ceiling meet the outer walls through flattened elliptical arcs. They are wide and shallow, so a stray ball is nudged back toward the middle rather than spun around a bowl.
- A ship contact always pushes the ball clear of the hull, so the ball can never be carried, ridden, or hovered with.
- Nothing in the arena destroys a ship. The ground, the roof bulge, the outer walls, the ceiling, and the other ship are all rebounds.
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
- Hosting is role-based: the inviter hosts; an invitee never hosts; in automatch the lowest `gamePlayerID` hosts.
- Inputs are sent unreliably every two simulation ticks (~60 Hz at 120 Hz sim).
- Host snapshots are sent unreliably every six ticks (~20 Hz).
- Lifecycle and scoring events are sent reliably.
- Guests predict their local ship and reconcile by blend-or-snap against host snapshots.
- A disconnect opens a 120-second seat-hold window. Reconnection triggers a reliable full resync; expiry finishes the match by forfeit.

The implementation follows Apple's [real-time data exchange](https://developer.apple.com/documentation/gamekit/exchanging-data-between-players-in-real-time-games) and [matchmaking](https://developer.apple.com/documentation/gamekit/gkmatchmakerviewcontroller) guidance.

## Verification artifacts

- `artifacts/screenshots/home.png` — simulator home screen.
- `artifacts/screenshots/physical-gameplay-landscape.png` — signed build running on a physical iPhone, including the Metal performance HUD.
- `docs/PHYSICAL-MULTIPLAYER-CHECKLIST.md` — two-device sandbox Game Center acceptance checklist.

The `--demo` debug launch argument starts a Pilot-vs-Pilot match for unattended rendering and capture. `--results-win` and `--results-lose` open a finished Rookie match on the results card so the rematch buttons can be exercised without playing through. `--online-diagnostics-preview` mounts the Game Center diagnostics HUD so UI tests can still read it; live Release matches keep that HUD off. They do not change release gameplay.
