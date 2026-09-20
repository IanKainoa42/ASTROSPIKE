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

## Standing invites (invite once, join later)

Both devices need iCloud signed in, and the `StandingInvite` /
`StandingInviteReply` record types must be imported into the CloudKit
**Production** environment from `CloudKit/ASTROSPIKE.ckdb`. Without that
import these steps fail with a lobby notice rather than doing nothing
quietly — which is the point, but check the notice appears.

- [ ] On device A, open LOBBY and confirm the `INVITE ANYTIME` section lists Game Center friends and recent opponents who are *not* currently online.
- [ ] Force-quit the app on device B. From device A, tap `ASK` next to B's pilot.
- [ ] Confirm device A's row moves to the `INVITES` section reading `ASKED · KEEPS 24H`, and that B no longer appears under `INVITE ANYTIME`.
- [ ] Leave both apps closed for at least five minutes.
- [ ] Open the app on device B, go to LOBBY, and confirm the ask is waiting under `INVITES` as `WANTS A DUEL · KEEPS …H` with `JOIN` and decline buttons.
- [ ] Tap `JOIN` on B with device A's app still **closed**. Confirm device A receives a Game Center invitation notification.
- [ ] Accept on A and confirm both reach `LINK STABLE`.
- [ ] Repeat, tapping the decline (✕) instead. Confirm the row clears on B, and that A's lobby link log records `… DECLINED YOUR INVITE` within one poll.
- [ ] From A, ask B again and then tap `WITHDRAW`. Confirm the row disappears on B within one poll.
- [ ] Ask the same pilot twice in a row and confirm B sees **one** row, not two, with the clock reset.
- [ ] Confirm an unanswered ask is gone from both screens 24 hours later.

## Waiting, timeouts, and the link log

- [ ] Invite a pilot and leave their phone locked. Confirm the warm-up bay keeps `JOINING …` for at least two minutes before giving up — a 30-second `CONNECTION TIMEOUT` here is the old behaviour and a failure.
- [ ] Confirm a Quick Match with nobody available still gives up after about 30 seconds.
- [ ] While waiting in the bay, confirm the line under the invite notice updates live with the newest link event.
- [ ] Tap that line and confirm the full `Link Log` opens, scrolled to the newest entry.
- [ ] Tap Share and confirm the transcript arrives with the header: app version, build, wire version, device, iOS, pilot name, and link state.
- [ ] Repeat from LOBBY via the `LINK LOG · n` row.
- [ ] After a full sign-in → invite → connect → drop → rejoin run, confirm the log still contains the sign-in lines at the top (it holds 250 entries, not 12).

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
