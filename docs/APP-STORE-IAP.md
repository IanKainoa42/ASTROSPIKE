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

| Product ID | Reference name | Display name |
|---|---|---|
| `com.iankainoa.ASTROSPIKE.hull.bulwark` | ASTROSPIKE Bulwark Hull | Bulwark Hull |
| `com.iankainoa.ASTROSPIKE.hull.wraith` | ASTROSPIKE Wraith Hull | Wraith Hull |
| `com.iankainoa.ASTROSPIKE.hull.hornet` | ASTROSPIKE Hornet Hull | Hornet Hull |
| `com.iankainoa.ASTROSPIKE.hull.comet` | ASTROSPIKE Comet Hull | Comet Hull |

Each one needs, or it parks in *Missing Metadata*:

- **Price** — the local config assumes $1.99 each, but the code never hardcodes
  a price; it renders `product.displayPrice`, so ASC is free to disagree.
- **Availability** — all territories.
- **Localization** (English (U.S.)) — display name and description. Use the
  copy in `ASTROSPIKE/ASTROSPIKE.storekit`; every description ends with
  "Cosmetic only — every hull flies and bounces identically," which is both
  true and the answer to the obvious review question.
- **Review screenshot** — 640×920 or larger. Take it from the Hangar with the
  hull previewed and the UNLOCK button visible.
- **Review notes** — "Cosmetic ship skin. Hulls do not change flight,
  collision or scoring; the simulation uses one shared collision fixture for
  every hull, so online play is unaffected."

**Family Sharing: off.** The code treats a revocation as a lock, so turning it
on later is safe, but it is not tested.

First-time in-app purchases must be submitted **with an app version**, not on
their own. Attach all four to the 1.0 submission.

## 3. App information

- **App Store ▸ Pricing** — the app itself stays **Free**. The IAPs make the
  listing read "Free · Offers In-App Purchases" on their own.
- **Description** — say what the purchases are and are not. Suggested closing
  paragraph: "Optional: four cosmetic hulls are available as one-time
  purchases. They change how your ship looks and nothing else — every hull
  flies, bounces and scores identically, online and solo."
- **App Review notes** — repeat the cosmetic-only claim and point the reviewer
  at Hangar ▸ any locked hull ▸ UNLOCK, and at **RESTORE PURCHASES** in the
  same screen.

## 4. Manual verification — required, not optional

StoreKit Testing is attached to the scheme's **Run** action, which
`xcodebuild test` does not use; `SKTestSession` returns zero products under
headless `xcodebuild test` even for a known-good configuration file, so there
is no automated purchase test. Run this by hand in Xcode before submitting:

```
[ ]  1. Product ▸ Run (simulator or device). Menu ▸ HANGAR.
[ ]  2. Tap a premium hull (Bulwark). The button reads UNLOCK • $1.99 — a real price, not placeholder text.
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
