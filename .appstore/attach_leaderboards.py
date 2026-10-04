"""Attach the per-match leaderboards to the next App Store version.

1.0 is live, so new leaderboards ride a version through review. This:
  1. makes appStoreVersion VERSION if it does not exist,
  2. turns Game Center on for it (a gameCenterAppVersion),
  3. opens a draft review submission (NOT submitted) holding each board's
     PREPARE_FOR_SUBMISSION leaderboard version, plus the app version.

Submitting stays a human step in App Store Connect once a build is picked.
Safe to re-run: every step looks before it creates.

Run:  python3 .appstore/attach_leaderboards.py
"""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shots import api, APP  # noqa: E402
from leaderboards import DETAIL, existing  # noqa: E402

VERSION = "1.0.1"


def app_version():
    out = api("GET", f"/v1/apps/{APP}/appStoreVersions?filter[platform]=IOS&filter[versionString]={VERSION}")
    if out["data"]:
        v = out["data"][0]
        print(f"version {VERSION} exists ({v['id']}, {v['attributes']['appStoreState']})")
        return v["id"]
    v = api("POST", "/v1/appStoreVersions", {"data": {
        "type": "appStoreVersions",
        "attributes": {"platform": "IOS", "versionString": VERSION},
        "relationships": {"app": {"data": {"type": "apps", "id": APP}}},
    }})["data"]
    print(f"version {VERSION} made ({v['id']})")
    return v["id"]


def game_center_on(version_id):
    out = api("GET", f"/v1/gameCenterDetails/{DETAIL}/gameCenterAppVersions?include=appStoreVersion&limit=50")
    for gc in out["data"]:
        if gc["relationships"]["appStoreVersion"]["data"]["id"] == version_id:
            print(f"game center already on for {VERSION} ({gc['id']})")
            return
    gc = api("POST", "/v1/gameCenterAppVersions", {"data": {
        "type": "gameCenterAppVersions",
        "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}},
    }})["data"]
    print(f"game center on for {VERSION} ({gc['id']})")


def draft_submission():
    out = api("GET", f"/v1/apps/{APP}/reviewSubmissions?filter[platform]=IOS&filter[state]=READY_FOR_REVIEW&limit=5")
    if out["data"]:
        print(f"draft submission exists ({out['data'][0]['id']})")
        return out["data"][0]["id"]
    s = api("POST", "/v1/reviewSubmissions", {"data": {
        "type": "reviewSubmissions",
        "attributes": {"platform": "IOS"},
        "relationships": {"app": {"data": {"type": "apps", "id": APP}}},
    }})["data"]
    print(f"draft submission made ({s['id']})")
    return s["id"]


def add_item(sub_id, kind, rel_type, obj_id, have):
    if obj_id in have:
        print(f"       {kind} already in draft")
        return
    api("POST", "/v1/reviewSubmissionItems", {"data": {
        "type": "reviewSubmissionItems",
        "relationships": {
            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub_id}},
            kind: {"data": {"type": rel_type, "id": obj_id}},
        },
    }})
    print(f"       {kind} {obj_id} added")


def main():
    version_id = app_version()
    game_center_on(version_id)
    sub_id = draft_submission()
    items = api("GET", f"/v1/reviewSubmissions/{sub_id}/items?limit=50"
                       "&include=appStoreVersion,gameCenterLeaderboardVersion")
    have = {r["data"]["id"] for i in items["data"] for r in i["relationships"].values()
            if isinstance(r, dict) and isinstance(r.get("data"), dict)}
    for vendor, board_id in sorted(existing().items()):
        versions = api("GET", f"/v2/gameCenterLeaderboards/{board_id}/versions?limit=10")["data"]
        pending = [v for v in versions if v["attributes"]["state"] == "PREPARE_FOR_SUBMISSION"]
        if not pending:
            print(f"skip   {vendor}: no version waiting ({[v['attributes']['state'] for v in versions]})")
            continue
        print(f"board  {vendor}")
        add_item(sub_id, "gameCenterLeaderboardVersion", "gameCenterLeaderboardVersions", pending[0]["id"], have)
    print("app version")
    add_item(sub_id, "appStoreVersion", "appStoreVersions", version_id, have)


if __name__ == "__main__":
    main()
