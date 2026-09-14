# Physical multiplayer acceptance checklist

This is the final manual gate. Use two physical iOS 18+ devices signed into separate sandbox Game Center accounts.

## Setup

- [ ] Install the same signed build on both devices.
- [ ] Confirm the devices use separate sandbox Game Center accounts.
- [ ] Keep both devices in landscape and disable Low Power Mode.

## Quick Match

- [ ] Start Quick Match on both devices.
- [ ] Confirm both enter the same three-count and center drop.
- [ ] Once gameplay begins, leave the in-game `GC DIAGNOSTICS` panel expanded on both devices.
- [ ] Confirm `PLAYER` shows a different Game Center display name on each device.
- [ ] In `GC DIAGNOSTICS`, confirm the devices show opposite `SIDE` values, exactly one `ROLE: HOST`, and exactly one `ROLE: GUEST`.
- [ ] Confirm both panels show `LINK: STABLE`, `MATCH: READY`, a numeric `PING`, and `RETRY: —`.
- [ ] Play through a goal and a third-bounce point, plus ship and ball rebounds from the center barrier.
- [ ] After a point, confirm only the ball reappears above the conceding side; both ships retain position, momentum, and live controls during the brief serve hold, with no reset or three-count.
- [ ] Confirm score, bounce pips, serve release, and match result agree on both devices.

## Friend invitation

- [ ] Send a Game Center invitation from device A to device B.
- [ ] Accept on device B and complete one rally.
- [ ] Confirm both diagnostics panels return to `MATCH: READY` and identify the same host/guest split used for the rally.
- [ ] Confirm neither device offers same-device multiplayer.

## Recovery and forfeit

- [ ] During a rally, disconnect device B briefly (well under two minutes).
- [ ] Confirm the connected device shows `LINK: RECONNECTING` while `RETRY` counts down from 120 seconds.
- [ ] Confirm both pause, B is reinvited, and reconnection returns `LINK: STABLE`, clears `RETRY`, and performs a full resync plus three-count.
- [ ] Repeat, keeping B disconnected beyond two minutes.
- [ ] Confirm the countdown expires, device A wins by forfeit, the link no longer reports stable, and both leave the live match cleanly.
- [ ] Background and foreground each app once during a match and confirm state remains synchronized.

## Performance

- [ ] Confirm a sustained 60 fps on the oldest supported device.
- [ ] If ProMotion is available, confirm optional 120 fps does not alter simulation outcomes.
- [ ] Play 20 matches and confirm memory returns to a stable baseline after each result screen.
- [ ] Record the successful Quick Match, invitation, reconnect, and forfeit flows.
