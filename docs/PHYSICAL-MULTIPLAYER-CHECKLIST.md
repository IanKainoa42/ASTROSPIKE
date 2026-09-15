# Physical multiplayer acceptance checklist

This is the final manual gate. Use two physical iOS 18+ devices signed into separate sandbox Game Center accounts.

## Setup

- [ ] Install the same signed build on both devices.
- [ ] Confirm the devices use separate sandbox Game Center accounts.
- [ ] Keep both devices in landscape and disable Low Power Mode.

## Quick Match

- [ ] Start Quick Match on both devices.
- [ ] Confirm both enter the same three-count and center drop.
- [ ] Once gameplay begins, confirm the MatchHUD link line reads `LINK STABLE` on both devices.
- [ ] Confirm the ships sit on opposite sides (cyan vs orange) by hull color, and that each device’s “your side” badge matches the local ship.
- [ ] Play through a goal and a third-bounce point, plus ship and ball rebounds from the center barrier.
- [ ] After a point, confirm only the ball reappears above the conceding side; both ships retain position, momentum, and live controls during the brief serve hold, with no reset or three-count.
- [ ] Confirm score, bounce pips, serve release, and match result agree on both devices.

## Friend invitation

- [ ] Send a Game Center invitation from device A to device B.
- [ ] Accept on device B and complete one rally.
- [ ] Confirm both MatchHUD link lines return to `LINK STABLE`.
- [ ] Confirm neither device offers same-device multiplayer.

## Recovery and forfeit

- [ ] During a rally, disconnect device B briefly (well under two minutes).
- [ ] Confirm the connected device’s MatchHUD shows `LINK LOST` with a seat-held countdown from 120 seconds.
- [ ] Confirm both pause, B is reinvited, and reconnection returns `LINK STABLE` and performs a full resync plus three-count.
- [ ] Repeat, keeping B disconnected beyond two minutes.
- [ ] Confirm the countdown expires, device A wins by forfeit, the link no longer reports stable, and both leave the live match cleanly.
- [ ] Background and foreground each app once during a match and confirm state remains synchronized.

## Performance

- [ ] Confirm a sustained 60 fps on the oldest supported device.
- [ ] If ProMotion is available, confirm optional 120 fps does not alter simulation outcomes.
- [ ] Play 20 matches and confirm memory returns to a stable baseline after each result screen.
- [ ] Record the successful Quick Match, invitation, reconnect, and forfeit flows.

Debug and `--online-diagnostics-preview` still expose the `GC DIAGNOSTICS` panel for engineer checks. Signed Release/TestFlight builds do not.
