"""Register the per-match Game Center leaderboards on App Store Connect.

One classic leaderboard per StatBoard and PracticeBoard case (ASTROSPIKECore/MatchStats.swift):
integer, best score kept, highest first, with an en-US name and unit. The
vendor ids here must match StatBoard's raw values exactly -- a score sent to
an id ASC does not know just goes nowhere.

Safe to re-run: a board whose vendor id already exists is skipped, and a
board with no en-US localization gets one.

Run:  python3 .appstore/leaderboards.py
"""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shots import api  # noqa: E402

DETAIL = "8aad05e7-3960-42a5-b0c2-ec7f3e7116b0"  # the app's gameCenterDetail

BOARDS = [
    ("astrospike.match.goals", "Most Goals in a Match", "goal", "goals"),
    ("astrospike.match.boltgoals", "Most Bolt Goals in a Match", "bolt goal", "bolt goals"),
    ("astrospike.match.slamdunks", "Most Slam Dunks in a Match", "slam dunk", "slam dunks"),
    ("astrospike.match.zaps", "Most Zaps in a Match", "zap", "zaps"),
    ("astrospike.match.longestrally", "Longest Rally", "crossing", "crossings"),
    # PracticeBoard: posted from warm-up and practice, never from a match.
    ("astrospike.practice.keepups", "Longest Keep-Up", "touch", "touches"),
    ("astrospike.practice.hoops", "Most Hoops in One Practice", "hoop", "hoops"),
]


def existing():
    out = api("GET", f"/v1/gameCenterDetails/{DETAIL}/gameCenterLeaderboards?limit=200")
    return {b["attributes"]["vendorIdentifier"]: b["id"] for b in out.get("data", [])}


def main():
    have = existing()
    print("existing:", sorted(have) or "none")
    for vendor, name, singular, plural in BOARDS:
        board_id = have.get(vendor)
        if board_id:
            print(f"skip   {vendor} ({board_id})")
        else:
            out = api("POST", "/v1/gameCenterLeaderboards", {"data": {
                "type": "gameCenterLeaderboards",
                "attributes": {
                    "referenceName": name,
                    "vendorIdentifier": vendor,
                    "defaultFormatter": "INTEGER",
                    "submissionType": "BEST_SCORE",
                    "scoreSortType": "DESC",
                },
                "relationships": {"gameCenterDetail": {"data": {"type": "gameCenterDetails", "id": DETAIL}}},
            }})
            board_id = out["data"]["id"]
            print(f"made   {vendor} ({board_id})")

        locs = api("GET", f"/v1/gameCenterLeaderboards/{board_id}/localizations?limit=50")
        if any(l["attributes"]["locale"] == "en-US" for l in locs.get("data", [])):
            print(f"       en-US already there")
            continue
        api("POST", "/v1/gameCenterLeaderboardLocalizations", {"data": {
            "type": "gameCenterLeaderboardLocalizations",
            "attributes": {
                "locale": "en-US",
                "name": name,
                "formatterSuffixSingular": f" {singular}",
                "formatterSuffix": f" {plural}",
            },
            "relationships": {"gameCenterLeaderboard": {"data": {"type": "gameCenterLeaderboards", "id": board_id}}},
        }})
        print(f"       en-US added")


if __name__ == "__main__":
    main()
