# Shipping the hull purchases

The code path is done and in the app. What is left is App Store Connect work
and one manual verification pass that cannot be automated (see below).

App: **ASTROSPIKE**, Apple ID `6805938755`, bundle `com.iankainoa.ASTROSPIKE`.

## 1. Paid Applications Agreement — do this first

**Business ▸ Agreements** must show the Paid Applications Agreement as
*Active*, with banking and tax forms complete. Until it is, `Product.products(for:)`
returns an empty array even in a real sandbox, and the hangar will correctly
say "Hull packs aren't on sale yet." This can take days, so start it before
anything else.

## 2. Create four non-consumables

**Monetization ▸ In-App Purchases ▸ Create**, type **Non-Consumable**. The
identifiers are pinned by a test (`HullStoreTests.productIDsArePinned`) and
must match byte for byte:

| Product ID | Reference name |
|---|---|
| `com.iankainoa.ASTROSPIKE.hull.bulwark` | ASTROSPIKE Bulwark Hull |
| `com.iankainoa.ASTROSPIKE.hull.wraith` | ASTROSPIKE Wraith Hull |
| `com.iankainoa.ASTROSPIKE.hull.hornet` | ASTROSPIKE Hornet Hull |
| `com.iankainoa.ASTROSPIKE.hull.comet` | ASTROSPIKE Comet Hull |

### Localization — English (U.S.), copy-paste

App Store Connect caps the IAP **display name at 30 characters** and the
**description at 45**, so these are not the longer blurbs in
`ASTROSPIKE/ASTROSPIKE.storekit`. The cosmetic-only claim does not fit in 45
characters; it lives in the review notes and the app description instead.

**Bulwark Hull** (12/30, 41/45)

```
Bulwark Hull
```

```
Cosmetic skin. Shield nose, engine skids.
```

**Wraith Hull** (11/30, 42/45)

```
Wraith Hull
```

```
Cosmetic skin. Faceted diamond, no curves.
```

**Hornet Hull** (11/30, 40/45)

```
Hornet Hull
```

```
Cosmetic skin. Twin booms, porthole pod.
```

**Comet Hull** (10/30, 39/45)

```
Comet Hull
```

```
Cosmetic skin. Round pod on three fins.
```

### Review notes — paste the same block into all four

```
Cosmetic ship skin. Hulls change the ship's appearance only: they do not
change flight, thrust, collision or scoring. The simulation uses one shared
collision fixture for every hull, so online play is unaffected by what the
player owns. Every game mode and every rule is available without any purchase.

To reach it: launch the app, tap HANGAR on the main menu, tap a padlocked
hull in the grid, then tap the UNLOCK button under the preview. RESTORE
PURCHASES sits at the bottom of the same screen.
```

Each product also needs, or it parks in *Missing Metadata*:

- **Price** — **$0.99 each**. The local StoreKit config matches, but the code
  never hardcodes a price; it renders `product.displayPrice`, so the number in
  ASC is the one that ships.
- **Availability** — all territories.
- **Review screenshot** — 640×920 or larger. Take it from the Hangar with the
  hull previewed and the UNLOCK button visible.

**Family Sharing: off.** The code treats a revocation as a lock, so turning it
on later is safe, but it is not tested.

First-time in-app purchases must be submitted **with an app version**, not on
their own. Attach all four to the 1.0 submission.

## 3. App information

- **App Store ▸ Pricing** — the app itself stays **Free**. The IAPs make the
  listing read "Free · Offers In-App Purchases" on their own.

### Description — closing paragraph, copy-paste

```
Optional: four cosmetic hulls are available as one-time purchases. They change
how your ship looks and nothing else — every hull flies, bounces and scores
identically, online and solo. Every mode and every rule in ASTROSPIKE is free.
```

### App Review notes — copy-paste

```
ASTROSPIKE is free to play in full. There is no gated content, no consumable
currency and no subscription.

The four in-app purchases are cosmetic ship skins (Bulwark, Wraith, Hornet,
Comet). They change the ship's appearance only — not flight, thrust, collision
or scoring. The physics simulation uses one shared collision fixture for every
hull, so a player who buys nothing is never at a disadvantage online.

To test a purchase: launch the app, tap HANGAR on the main menu, tap a
padlocked hull in the grid, then tap UNLOCK under the preview. RESTORE
PURCHASES is at the bottom of the same screen and works without an account.

No sign-in is required to play. Online duels use Game Center; solo play,
practice and the hangar all work signed out.
```

## 4. Manual verification — in Sandbox, after step 2

**Local StoreKit Testing does not work on this Mac.** Not under `xcodebuild
test` and not under Product ▸ Run either. Verified 2026-09-10 on two runtimes
(iOS 26.5 / Xcode 26.6 and iOS 27 / Xcode 27): the `.storekit` file is
delivered to the simulator's Octane store
(`…/Documents/Persistence/Octane/com.iankainoa.ASTROSPIKE/Configuration.storekit`),
`storekitd` logs `Initialized with server XcodeTest(file://…)` — and then
routes the product request to the live Media API anyway:

```
Requesting products from Media API using in-app-purchasables endpoint
Some requested products were not found: …hull.bulwark, …comet, …hornet, …wraith
Found 0 IAP(s) / Ignoring empty product response
```

So the request is correct and the catalogue is empty. **Prices will appear as
soon as the four ASC records in step 2 exist** — nothing in the app needs to
change. Do the pass below in **Sandbox on a real device** once they are live,
signed in with a Sandbox Apple Account (Settings ▸ Developer ▸ Sandbox Account).

```
[ ]  1. Launch from TestFlight or a device build. Menu ▸ HANGAR.
[ ]  2. Tap a premium hull (Bulwark). The button reads UNLOCK • $0.99 — a real price, not placeholder text.
[ ]  3. Tap UNLOCK. Approve. The button becomes FLY THE BULWARK, and the tile loses its padlock.
[ ]  4. Tap FLY THE BULWARK, close the hangar, start a solo match. The Bulwark is on court.
[ ]  5. Force-quit and relaunch. The Bulwark is still unlocked and still selected.
[ ]  6. Settings ▸ Developer ▸ Sandbox Account ▸ Clear Purchase History, then delete the app.
[ ]  7. Reinstall. Bulwark is locked again. Tap RESTORE PURCHASES — it unlocks, and the banner says "Restored 1 hull."
[ ]  8. Tap RESTORE PURCHASES again with nothing new to find. The banner says so rather than doing nothing.
[ ]  9. Decline the purchase sheet instead of approving it. A visible message appears and the hull stays locked.
[ ] 10. Turn on Airplane Mode, cold-launch, open the hangar. The locked hull shows a tappable retry with a reason — never a blank panel.
```

Steps 9 and 10 are the App Review 2.1(a) shape that rejected HitRate 1.7: a
button that changes nothing when its path fails. Do not skip them.

Steps 1 and 10 (and the restore-failure banner) were verified headlessly on the
simulator on 2026-09-10 against an empty catalogue: the locked tile reads
"LOCKED • PREMIUM / Hull packs aren't on sale yet", and cancelling the Apple
Account sheet surfaces "Restore failed: Request Canceled". The rest needs live
records.

**Review screenshot caveat:** the four captures in
`AppStoreScreenshots/iap-review/` show the locked state, not a price, because
of the above. Re-shoot them from a Sandbox device after step 2 and before
attaching them to the IAP records.

## How the code is wired

- `ASTROSPIKECore/HullStore.swift` — loads products, buys, restores, and
  listens to `Transaction.updates` for approvals, other devices and refunds.
- `ASTROSPIKECore/Hulls.swift` — `HullEntitlements` is the offline cache.
  It is additive from StoreKit and only ever revokes on an explicit
  revocation, so a cold launch cannot strip a paid hull.
- `ASTROSPIKE/HangarView.swift` — the buy button, the restore button and the
  message banner. Every locked state renders something: a price, a spinner, or
  a tappable reason.
- `ASTROSPIKE/AppRootView.swift` — starts the listener for the app's lifetime
  and drops a refunded pilot back onto the Lancet.
