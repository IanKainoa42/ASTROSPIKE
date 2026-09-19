"""Register the four premium hull in-app purchases on App Store Connect.

For each hull: a non-consumable, its en-US localization, a USD 0.99 price
schedule, worldwide territory availability, and the App Review screenshot
(hangar.png, sitting next to this file).

Safe to re-run. Every step checks for what already exists and skips it, so a
partial failure can be resumed by running the script again.

Run:  python3 .appstore/iap.py
"""
import json, os, sys, hashlib, urllib.request, urllib.error

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shots import api, APP, BASE, tok  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SHOT = os.path.join(HERE, "hangar.png")

REVIEW = (
    "Cosmetic ship skin, sold separately. Reach it from the main menu: tap HANGAR, "
    "then tap the locked hull tile and buy it. Hulls only change how the ship looks. "
    "Flight, physics and scoring are identical for every hull, online and solo."
)

HULLS = [
    ("bulwark", "Bulwark Hull", "Armoured brick hull. Cosmetic only."),
    ("wraith", "Wraith Hull", "Stealth kite hull. Cosmetic only."),
    ("hornet", "Hornet Hull", "Twin boom hull. Cosmetic only."),
    ("comet", "Comet Hull", "Pod racer hull. Cosmetic only."),
]


def probe(path):
    """GET that returns None on any HTTP error instead of exiting.

    Used for "does this already exist?" checks, where a 404 or 409 is an
    answer rather than a failure.
    """
    req = urllib.request.Request(BASE + path, headers={"Authorization": f"Bearer {tok()}"})
    try:
        raw = urllib.request.urlopen(req).read()
        return json.loads(raw) if raw else {}
    except urllib.error.HTTPError:
        return None


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def upload(operations, blob):
    for op in operations:
        chunk = blob[op["offset"]:op["offset"] + op["length"]]
        req = urllib.request.Request(op["url"], data=chunk, method=op["method"])
        for header in op["requestHeaders"]:
            req.add_header(header["name"], header["value"])
        try:
            urllib.request.urlopen(req)
        except urllib.error.HTTPError as e:
            print("UPLOAD FAIL", e.code, e.read().decode()[:400])
            sys.exit(1)


blob = open(SHOT, "rb").read()
size = len(blob)
checksum = md5(SHOT)

# Territory availability is its own resource on the v2 API; there is no
# `availableInAllTerritories` attribute on inAppPurchases. Fetch the full list
# once and hand every territory to each product.
territories = []
url = "/v1/territories?limit=200"
while url:
    page = api("GET", url)
    territories += [t["id"] for t in page["data"]]
    nxt = page.get("links", {}).get("next")
    url = nxt.replace(BASE, "") if nxt else None
print(f"{len(territories)} territories")

for slug, display, description in HULLS:
    product_id = f"com.iankainoa.ASTROSPIKE.hull.{slug}"

    existing = probe(f"/v1/apps/{APP}/inAppPurchasesV2?filter[productId]={product_id}&limit=1")
    if existing and existing.get("data"):
        iap_id = existing["data"][0]["id"]
        print(f"{product_id} -> {iap_id} (already exists)")
    else:
        created = api("POST", "/v2/inAppPurchases", {"data": {
            "type": "inAppPurchases",
            "attributes": {
                "name": display,
                "productId": product_id,
                "inAppPurchaseType": "NON_CONSUMABLE",
                "reviewNote": REVIEW,
                "familySharable": False,
            },
            "relationships": {"app": {"data": {"type": "apps", "id": APP}}},
        }})
        iap_id = created["data"]["id"]
        print(f"{product_id} -> {iap_id} (created)")

    locs = probe(f"/v2/inAppPurchases/{iap_id}/inAppPurchaseLocalizations?limit=50")
    have_en = locs and any(l["attributes"]["locale"] == "en-US" for l in locs.get("data", []))
    if have_en:
        print("  localization en-US already set")
    else:
        api("POST", "/v1/inAppPurchaseLocalizations", {"data": {
            "type": "inAppPurchaseLocalizations",
            "attributes": {"locale": "en-US", "name": display, "description": description},
            "relationships": {"inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": iap_id}}},
        }})
        print("  localization en-US")

    schedule = probe(f"/v2/inAppPurchases/{iap_id}/iapPriceSchedule")
    if schedule and schedule.get("data"):
        print("  price schedule already set")
    else:
        points = api("GET", f"/v2/inAppPurchases/{iap_id}/pricePoints?filter[territory]=USA&limit=200")
        match = [p for p in points["data"] if p["attributes"]["customerPrice"] == "0.99"]
        if not match:
            print("  NO 0.99 PRICE POINT", [p["attributes"]["customerPrice"] for p in points["data"]][:20])
            sys.exit(1)
        point_id = match[0]["id"]
        api("POST", "/v1/inAppPurchasePriceSchedules", {
            "data": {
                "type": "inAppPurchasePriceSchedules",
                "relationships": {
                    "inAppPurchase": {"data": {"type": "inAppPurchases", "id": iap_id}},
                    "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
                    "manualPrices": {"data": [{"type": "inAppPurchasePrices", "id": "${price}"}]},
                },
            },
            "included": [{
                "type": "inAppPurchasePrices",
                "id": "${price}",
                "attributes": {"startDate": None, "endDate": None},
                "relationships": {"inAppPurchasePricePoint": {
                    "data": {"type": "inAppPurchasePricePoints", "id": point_id}}},
            }],
        })
        print("  price USD 0.99")

    existing_avail = probe(f"/v2/inAppPurchases/{iap_id}/iapAvailability")
    if existing_avail and existing_avail.get("data"):
        print("  availability already set")
    else:
        api("POST", "/v1/inAppPurchaseAvailabilities", {"data": {
            "type": "inAppPurchaseAvailabilities",
            "attributes": {"availableInNewTerritories": True},
            "relationships": {
                "inAppPurchase": {"data": {"type": "inAppPurchases", "id": iap_id}},
                "availableTerritories": {"data": [
                    {"type": "territories", "id": t} for t in territories]},
            },
        }})
        print(f"  available in {len(territories)} territories")

    have_shot = probe(f"/v2/inAppPurchases/{iap_id}/appStoreReviewScreenshot")
    if have_shot and have_shot.get("data"):
        print("  review screenshot already uploaded")
    else:
        shot = api("POST", "/v1/inAppPurchaseAppStoreReviewScreenshots", {"data": {
            "type": "inAppPurchaseAppStoreReviewScreenshots",
            "attributes": {"fileName": f"{slug}-hangar.png", "fileSize": size},
            "relationships": {"inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": iap_id}}},
        }})
        shot_id = shot["data"]["id"]
        upload(shot["data"]["attributes"]["uploadOperations"], blob)
        api("PATCH", f"/v1/inAppPurchaseAppStoreReviewScreenshots/{shot_id}", {"data": {
            "type": "inAppPurchaseAppStoreReviewScreenshots",
            "id": shot_id,
            "attributes": {"uploaded": True, "sourceFileChecksum": checksum},
        }})
        print("  review screenshot uploaded")

print("\nDone. Verify state in App Store Connect, then attach each IAP to version 1.0.")
