#!/usr/bin/env python3
"""Ships.json <-> Ship Workshop.

    python3 scripts/ships.py import ~/Downloads/Ships.json   check an export, write it into both games, rebuild the workshop
    python3 scripts/ships.py build                           rebuild the workshop from the game's Ships.json
    python3 scripts/ships.py check                           check Ships.json is valid, canonical and the same in both games

ASTROSPIKECore/Ships.json is the one source of truth for every ship's drawing:
the eight hulls, then the hundred concepts. The workshop page is generated
from tools/ship-workshop/src (Codex's workshop, untouched, plus game-link.js)
with that file baked in, so it opens by double-click with no server.

AstroCross (~/Projects/WARBLE) flies the same eight hulls and keeps a copy at
WARBLECore/Ships.json. Import writes both; never edit the copy by hand.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHIPS = ROOT / "ASTROSPIKECore" / "Ships.json"
SRC = ROOT / "tools" / "ship-workshop" / "src"
OUT = ROOT / "tools" / "ship-workshop" / "ASTROSPIKE Ship Workshop.html"
ASTROCROSS = ROOT.parent / "WARBLE" / "WARBLECore" / "Ships.json"

HULLS = ["lancet", "anvil", "manta", "kestrel", "bulwark", "wraith", "hornet", "comet"]
CONCEPT_GROUPS = ["Racing", "Utility", "Bioforms", "Retro", "Cinema"]
BOLTS = ["needle", "slug", "wave", "chevron", "block", "shard", "twin", "orb"]
BEAMS = ["dashes", "pulses", "ripples", "chevrons", "heavy", "glitch", "twin", "sparkle"]
SMOKES = ["vapour", "soot", "bubbles", "wisps", "glitter"]
# Mirrors HullLook.limits in ASTROSPIKECore/HullLook.swift.
LIMITS = {
    "smokeSize": (0.2, 3.0), "smokeLife": (0.2, 3.0), "smokeOpacity": (0.1, 2.0), "smokeAmount": (0.0, 3.0),
    "flameLength": (0.3, 2.5), "flicker": (0.0, 0.5), "nozzles": (1, 3), "nozzleSpacing": (0.0, 40.0),
    "nozzleY": (-19.0, 0.0), "exhaustWidth": (0.3, 3.0),
}
COLOURS = ["primary", "secondary", "flame", "flameCore", "smoke"]
LOOK_KEYS = COLOURS + ["bolt", "beam", "smokeStyle", "smokeSize", "smokeLife", "smokeOpacity", "smokeAmount",
                       "flameLength", "flicker", "nozzles", "nozzleSpacing", "nozzleY"]
DESIGN_KEYS = ["id", "name", "role", "blurb", "exhaustWidth", "outline", "look"]


def fail(message):
    sys.exit(f"Ships file rejected: {message}")


def number(value, where):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        fail(f"{where} is not a number")
    return value


def check_points(points, where, minimum):
    if not isinstance(points, list) or not minimum <= len(points) <= 256:
        fail(f"{where} needs {minimum}...256 points")
    for x, y in points:
        number(x, where), number(y, where)
        if not (-22 <= x <= 22 and -19 <= y <= 30):
            fail(f"{where} point {x},{y} is outside the hull envelope x -22...22, y -19...30")


def check_design(design, expected_id, names):
    where = expected_id
    if design.get("id") != expected_id:
        fail(f"expected {expected_id}, found {design.get('id')} -- ships must stay in game order")
    for key in ["name", "role", "blurb"]:
        if not isinstance(design.get(key), str) or not design[key].strip():
            fail(f"{where} has no {key}")
    if design["name"] in names:
        fail(f"two ships are both called {design['name']}")
    names.add(design["name"])
    low, high = LIMITS["exhaustWidth"]
    if not low <= number(design.get("exhaustWidth"), where) <= high:
        fail(f"{where} exhaustWidth must be {low}...{high}")
    outline = design.get("outline") or {}
    check_points(outline.get("silhouette"), f"{where} silhouette", 3)
    for detail in outline.get("details", []):
        check_points(detail.get("points"), f"{where} detail", 2)
        if not isinstance(detail.get("closed"), bool):
            fail(f"{where} detail has no closed flag")
    look = design.get("look") or {}
    for key in COLOURS:
        rgb = look.get(key)
        if not isinstance(rgb, list) or len(rgb) != 3 or not all(0 <= number(c, where) <= 1 for c in rgb):
            fail(f"{where} {key} must be three numbers 0...1")
    for key, choices in [("bolt", BOLTS), ("beam", BEAMS), ("smokeStyle", SMOKES)]:
        if look.get(key) not in choices:
            fail(f"{where} {key} must be one of {', '.join(choices)}")
    for key, (low, high) in LIMITS.items():
        if key == "exhaustWidth":
            continue
        if not low <= number(look.get(key), where) <= high:
            fail(f"{where} {key} must be {low}...{high}")
    if not isinstance(look["nozzles"], int):
        fail(f"{where} nozzles must be a whole number")


def check(data):
    if data.get("schema") != "astro-ships" or data.get("version") != 1:
        fail("not an astro-ships v1 file (use Download for game in the Game tab)")
    names = set()
    hulls, concepts = data.get("hulls"), data.get("concepts")
    if not isinstance(hulls, list) or len(hulls) != len(HULLS):
        fail("needs exactly the eight hulls")
    if not isinstance(concepts, list) or len(concepts) != 100:
        fail("needs exactly one hundred concepts")
    for design, hull in zip(hulls, HULLS):
        check_design(design, hull, names)
    for index, design in enumerate(concepts):
        check_design(design, f"concept-{index + 1:03d}", names)


def num(value):
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return json.dumps(value)


def inline(value):
    if isinstance(value, list):
        return "[" + ", ".join(inline(v) for v in value) + "]"
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return num(value)
    return json.dumps(value, ensure_ascii=False)


def canonical(data):
    """One stable layout: a ship per block, every point list on one line, so
    a change in the workshop shows up as a small readable diff."""
    out = ['{', '  "schema": "astro-ships",', '  "version": 1,']
    for section in ["hulls", "concepts"]:
        out.append(f'  "{section}": [')
        blocks = []
        for design in data[section]:
            lines = ["    {"]
            fields = []
            for key in DESIGN_KEYS[:5]:
                fields.append(f'      "{key}": {inline(design[key])}')
            outline = design["outline"]
            details = ",\n".join(
                f'          {{"points": {inline(d["points"])}, "closed": {json.dumps(d["closed"])}}}'
                for d in outline.get("details", [])
            )
            fields.append(
                '      "outline": {\n'
                f'        "silhouette": {inline(outline["silhouette"])},\n'
                + ('        "details": [\n' + details + "\n        ]\n" if details else '        "details": []\n')
                + "      }"
            )
            look = ",\n".join(f'        "{k}": {inline(design["look"][k])}' for k in LOOK_KEYS)
            fields.append('      "look": {\n' + look + "\n      }")
            lines.append(",\n".join(fields))
            lines.append("    }")
            blocks.append("\n".join(lines))
        out.append(",\n".join(blocks))
        out.append("  ]," if section == "hulls" else "  ]")
    out.append("}")
    return "\n".join(out) + "\n"


def build():
    data = json.loads(SHIPS.read_text())
    check(data)
    html = (SRC / "codex-workshop.html").read_text()
    link = (SRC / "game-link.js").read_text()
    css = (SRC / "game-link.css").read_text()
    presets = [
        {"name": d["name"], "group": "Original hulls", "points": d["outline"]["silhouette"],
         "details": d["outline"]["details"], "gameId": d["id"]}
        for d in data["hulls"]
    ] + [
        {"name": d["name"], "group": CONCEPT_GROUPS[i // 20], "points": d["outline"]["silhouette"],
         "details": d["outline"]["details"], "gameId": d["id"]}
        for i, d in enumerate(data["concepts"])
    ]
    # Codex's page declares its starter shapes on one line; the game's ships
    # replace them so the workshop always opens on what the game draws.
    html, count = re.subn(r"^const PRESETS=\[.*\];$", lambda _: "const PRESETS=" + json.dumps(presets) + ";",
                          html, count=1, flags=re.M)
    if count != 1:
        sys.exit("Could not find the PRESETS line in codex-workshop.html")
    payload = json.dumps(data, separators=(",", ":")).replace("</", "<\\/")
    tail = f"<script>window.ASTROSPIKE_SHIPS={payload};\n{link}</script><style>{css}</style>"
    if "</html>" not in html:
        sys.exit("codex-workshop.html has no </html>")
    html = html.replace("</html>", tail + "</html>", 1)
    html = re.sub(r"<title>[^<]*</title>", "<title>ASTROSPIKE Ship Workshop</title>", html, count=1)
    OUT.write_text(html)
    print(f"Built {OUT.relative_to(ROOT)}")


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "build"
    if command == "import":
        if len(sys.argv) < 3:
            sys.exit("usage: ships.py import <downloaded Ships.json>")
        data = json.loads(pathlib.Path(sys.argv[2]).expanduser().read_text())
        check(data)
        text = canonical(data)
        for game, path in [("ASTROSPIKE", SHIPS), ("AstroCross", ASTROCROSS)]:
            if not path.parent.is_dir():
                sys.exit(f"{game} is not at {path.parent}; nothing written")
        for game, path in [("ASTROSPIKE", SHIPS), ("AstroCross", ASTROCROSS)]:
            changed = not path.exists() or path.read_text() != text
            path.write_text(text)
            print(f"{game} Ships.json {'updated' if changed else 'unchanged'}")
        build()
    elif command == "build":
        build()
    elif command == "check":
        data = json.loads(SHIPS.read_text())
        check(data)
        if SHIPS.read_text() != canonical(data):
            sys.exit("Ships.json is valid but not in canonical layout; run ships.py import on it")
        if not ASTROCROSS.exists() or ASTROCROSS.read_text() != SHIPS.read_text():
            sys.exit(f"AstroCross's copy differs: run ships.py import {SHIPS.relative_to(ROOT)}")
        print("Ships.json OK in both games")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
