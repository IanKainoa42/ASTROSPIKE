# Physical multiplayer acceptance checklist

This is the final manual gate. Use two physical iOS 18+ devices signed into separate sandbox Game Center accounts.

## Setup

- [ ] Install the same signed build on both devices.
- [ ] Confirm each device shows a different Game Center player name.
- [ ] Keep both devices in landscape and disable Low Power Mode.

## Quick Match

- [ ] Start Quick Match on both devices.
- [ ] Confirm both enter the same three-count and center drop.
- [ ] Confirm exactly one peer reports host authority.
- [ ] Play through a goal, a third-bounce point, a ship crash, and a net death.
- [ ] Confirm score, bounce pips, resets, and match result agree on both devices.

## Friend invitation

- [ ] Send a Game Center invitation from device A to device B.
- [ ] Accept on device B and complete one rally.
- [ ] Confirm neither device offers same-device multiplayer.

## Recovery and forfeit

- [ ] During a rally, disconnect device B for fewer than ten seconds.
- [ ] Confirm both pause, B is reinvited, and reconnection performs a full resync plus three-count.
- [ ] Repeat, keeping B disconnected beyond ten seconds.
- [ ] Confirm device A wins by forfeit and both leave the live match cleanly.
- [ ] Background and foreground each app once during a match and confirm state remains synchronized.

## Performance

- [ ] Confirm a sustained 60 fps on the oldest supported device.
- [ ] If ProMotion is available, confirm optional 120 fps does not alter simulation outcomes.
- [ ] Play 20 matches and confirm memory returns to a stable baseline after each result screen.
- [ ] Record the successful Quick Match, invitation, reconnect, and forfeit flows.
