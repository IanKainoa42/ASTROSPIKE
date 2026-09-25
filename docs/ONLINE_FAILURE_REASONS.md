# Online Failure Reasons

This document catalogs every failure reason in the online matchmaking, invite, handshake, and connection flow. Each failure surfaces a **specific, player-friendly message** — never a generic "connection failed".

## Design Principles

1. **Specific over generic**: Every failure has its own reason enum case
2. **Actionable copy**: Messages tell the player what to do next
3. **No jargon**: No GK codes, error numbers, or engineer terminology
4. **Identify who needs to act**: Wire/version mismatches say who needs to update
5. **Name the pilot**: Invite failures include the other player's name

## Failure Reason Catalog

### Authentication Failures

| Reason | Message | When it happens |
|--------|---------|-----------------|
| `gameCenterNotAuthenticated` | "Sign in to Game Center in Settings" | GK says not signed in and won't prompt again |
| `gameCenterAuthInProgress` | "Still signing in to Game Center" | Auth handler running |
| `gameCenterUserDenied` | "Game Center permission was declined" | User denied GK permission |
| `gameCenterCommunicationsFailure` | "Couldn't reach Game Center" | Network/service issue |
| `gameCenterSignInTimeout` | "Game Center didn't respond. Try again." | 15s sign-in watchdog fired |
| `gameCenterOther` | "Couldn't reach Game Center. Try again." | Unrecognized GK error |

### Screen Time / Restrictions

| Reason | Message | When it happens |
|--------|---------|-----------------|
| `multiplayerRestricted` | "Multiplayer is restricted by Screen Time" | `isMultiplayerGamingRestricted` is true |
| `invitationsDisabled` | "Invites are turned off in Screen Time" | GK `.invitationsDisabled` |
| `restrictedToAutomatch` | "Friend invites aren't available" | GK `.restrictedToAutomatch` |

### Matchmaking Failures

| Reason | Message | When it happens |
|--------|---------|-----------------|
| `matchmakerUnavailable` | "Matchmaker couldn't open. Try again." | GKMatchmakerViewController nil or no presenter |
| `matchmakingCancelled` | "Search cancelled" | User cancelled or GK `.cancelled` |
| `noMatchReturned` | "Couldn't start the match. Try again." | `findMatch` returned nil without error |
| `connectTimeout` | "No one joined. Try inviting again." | 30s timeout, no peers connected |
| `handshakeTimeout` | "Opponent connected but didn't respond" | Peer connected but no `.ready` in 20s |

### Invite Response Failures

| Reason | Message | When it happens |
|--------|---------|-----------------|
| `inviteDeclined(pilotName)` | "{name} declined the invite" | Recipient explicitly declined |
| `inviteFailed(pilotName)` | "Invite to {name} didn't arrive" | Delivery failed |
| `inviteIncompatibleRemote(pilotName)` | "{name} needs to update ASTROSPIKE" | Recipient on old/incompatible version |
| `inviteUnableToConnect(pilotName)` | "Couldn't connect to {name}" | Network issue on recipient end |
| `inviteNoAnswer(pilotName)` | "{name} didn't answer" | No response within timeout |
| `allInvitesRefused(lastPilotName, lastReason)` | (varies by reason) | All recipients refused/failed |

### Wire Protocol Mismatch

| Reason | Message | When it happens |
|--------|---------|-----------------|
| `wireVersionMismatch(remote < local)` | "{name} needs to update ASTROSPIKE" | Remote on older wire version |
| `wireVersionMismatch(remote > local)` | "Update ASTROSPIKE to play with {name}" | We're on older wire version |

### Mid-Match Failures

| Reason | Message | When it happens |
|--------|---------|-----------------|
| `networkSendFailed` | "Network send failed. Reconnecting…" | Reliable send threw |
| `matchFailed(underlyingMessage)` | (underlying or "The match ended unexpectedly") | GKMatch delegate error |
| `opponentForfeited` | "Opponent left the match" | Seat hold expired (120s) |
| `tableClosed(hostName)` | "{name} closed the table" | The host of an open table left, went silent while watching, or never seated the next duel. Only the host can seat a duel, so the table ends for everyone. |
| `matchNotConnected` | "Lost the match connection" | GK `.matchNotConnected` |
| `connectionTimeout` | "Connection timed out" | GK `.connectionTimeout` |

### Invite Acceptance Failures

| Reason | Message | When it happens |
|--------|---------|-----------------|
| `inviteJoinFailed(underlyingMessage)` | (underlying or "Couldn't join the match. Try again.") | `match(for: invite)` failed |
| `couldNotOpenInvitation` | "Couldn't open the invitation" | `match(for: invite)` returned nil |

## Notice Reasons (Non-Terminal)

These surface as a yellow notice in the warm-up bay but don't end the match:

| Reason | Message | When it happens |
|--------|---------|-----------------|
| `wireVersionMismatch` | "{NAME} NEEDS TO UPDATE" or "YOU NEED TO UPDATE TO PLAY WITH {NAME}" | Packets from incompatible peer |
| `inviteResponse` | "{NAME} · {status}" | Invite response (declined, no answer, etc.) |

## Adding a New Failure Reason

1. Add a case to `OnlineFailureReason` in `ASTROSPIKECore/OnlineFailureReason.swift`
2. Add the player-facing message in the `message` computed property
3. Add a test in `ASTROSPIKECoreTests/OnlineFailureReasonTests.swift`
4. Add a row to this catalog
5. Wire it in `OnlineMatchCoordinator.swift` where the failure occurs

## Testing

Run the failure reason tests:

```bash
swift test --filter OnlineFailureReasonTests
```

The tests verify:
- Every reason has a non-empty message
- No message contains GK codes or engineer jargon
- Messages are consistent with this catalog
- Conversion functions work correctly
