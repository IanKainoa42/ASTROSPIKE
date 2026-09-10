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

## 4. Manual verification — required, not optional

StoreKit Testing is attached to the scheme's **Run** action, which
`xcodebuild test` does not use; `SKTestSession` returns zero products under
headless `xcodebuild test` even for a known-good configuration file, so there
is no automated purchase test. Run this by hand in Xcode before submitting:

```
[ ]  1. Product ▸ Run (simulator or device). Menu ▸ HANGAR.
[ ]  2. Tap a premium hull (Bulwark). The button reads UNLOCK • $0.99 — a real price, not placeholder text.
[ ]  3. Tap UNLOCK. Approve. The button becomes FLY THE BULWARK, and the tile loses its padlock.
[ ]  4. Tap FLY THE BULWARK, close the hangar, start a solo match. The Bulwark is on court.
[ ]  5. Stop and re-run the app. The Bulwark is still unlocked and still selected.
[ ]  6. Debug ▸ StoreKit ▸ Manage Transactions ▸ delete the transaction, then delete the app from the device.
[ ]  7. Re-run. Bulwark is locked again. Tap RESTORE PURCHASES — it unlocks, and the banner says "Restored 1 hull."
[ ]  8. Tap RESTORE PURCHASES again with nothing new to find. The banner says so rather than doing nothing.
[ ]  9. Editor ▸ enable "Fail Transactions" in the .storekit file, tap UNLOCK. A visible failure message appears and the hull stays locked.
[ ] 10. Turn on Airplane Mode, cold-launch, open the hangar. The locked hull shows a tappable retry with a reason — never a blank panel.
```

Steps 9 and 10 are the App Review 2.1(a) shape that rejected HitRate 1.7: a
button that changes nothing when its path fails. Do not skip them.

Re-run the same pass in **Sandbox** on a real device once the ASC records are
live, using a Sandbox Apple Account (Settings ▸ Developer ▸ Sandbox Account).

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
