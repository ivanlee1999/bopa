#!/usr/bin/env python3
"""Generates the `split` conformance vectors into both repos from one source.

The split is the one operation that *rewrites* a reader's notes, and it runs independently on two
devices that may not be able to see each other. If the two apps disagree about which sheet a stroke
belongs to, or about what a derived page id is, the same notebook divides differently on each and
the merge keeps both answers — every page twice. So the expected output is written down once, here,
and both suites run it.

    python3 tools/split-vectors/generate.py            # writes both copies
    ./scripts/couch-vectors-parity.sh                  # proves they match

Appends to `vectors.json` alongside the merge vectors rather than living in its own file, so the
existing parity check covers it and there is one contract, not two.
"""

import base64
import hashlib
import json
import os
import struct
from pathlib import Path

HERE = Path(__file__).resolve().parents[2]
BOPA = HERE / "docs/couch-sync-vectors/vectors.json"

# Defaults to notable's matching worktree — this is usually run from a pair of them, and writing
# into the wrong checkout is how the two copies drift. `NOTABLE_DIR` overrides it, as in
# `scripts/couch-vectors-parity.sh`.
_default_notable = Path(str(HERE).replace("/bopa/", "/notable/", 1))
NOTABLE = (
    Path(os.environ.get("NOTABLE_DIR", _default_notable))
    / "app/src/test/resources/couch-sync-vectors/vectors.json"
)

TS = "2026-08-10T06:00:00Z"
NOW = "2026-08-15T12:00:00Z"
SHEET = {"width": 1400, "height": 1000}


def polyline(values, precision=2):
    """Notable's delta-encoded fixed-point polyline (StrokePointConverter.kt)."""
    out, prev = [], 0
    factor = 10**precision
    for value in values:
        current = int(round(value * factor))
        delta = current - prev
        prev = current
        delta = ~(delta << 1) if delta < 0 else (delta << 1)
        while delta >= 0x20:
            out.append(chr((0x20 | (delta & 0x1F)) + 63))
            delta >>= 5
        out.append(chr(delta + 63))
    return "".join(out).encode()


def encode_points(points):
    """The SB v2 binary, uncompressed, with the pressure channel present."""
    body = b""
    for axis in (0, 1):
        encoded = polyline([p[axis] for p in points])
        body += struct.pack("<i", len(encoded)) + encoded
    body += b"".join(struct.pack("<H", int(round(p[2] * 65535))) for p in points)
    header = b"SB" + bytes([2, 1]) + struct.pack("<i", len(points)) + bytes([0])
    return base64.b64encode(header + body).decode()


def child_id(parent, index):
    digest = hashlib.sha256(f"notable-page-split:{parent}:{index}".encode()).hexdigest()[:32]
    return f"{digest[0:8]}-{digest[8:12]}-{digest[12:16]}-{digest[16:20]}-{digest[20:32]}"


def stroke(sid, top, bottom):
    return {
        "id": sid, "createdAt": TS, "updatedAt": TS, "deviceId": "ipad",
        "pen": "BALLPEN", "color": -16777216, "size": 3, "maxPressure": 1,
        "top": top, "bottom": bottom, "left": 5, "right": 15,
        "pointsData": encode_points([(5.0, top, 0.5), (15.0, bottom, 0.5)]),
    }


def page(pid, strokes, images=None):
    return {
        "type": "page", "schema": 1, "id": pid, "notebookId": "nb-1",
        "background": "blank", "backgroundType": "native",
        "pageWidth": SHEET["width"], "pageHeight": SHEET["height"],
        "scroll": 0, "strokes": strokes, "deletedStrokes": [],
        "images": images or [], "deletedImages": [],
        "createdAt": TS, "updatedAt": TS, "deviceId": "ipad",
    }


def expected(pid, strokes, images=None):
    """What the split must produce — ids, order, and the geometry after shifting."""
    return {
        "id": pid,
        "strokes": [
            {"id": s["id"], "top": s["top"], "bottom": s["bottom"],
             "pointsData": s["pointsData"]}
            for s in strokes
        ],
        "images": [{"id": i["id"], "y": i["y"]} for i in (images or [])],
        "pageWidth": SHEET["width"], "pageHeight": SHEET["height"],
    }


def vectors():
    out = []

    # Three sheets' worth of writing, one stroke on each.
    out.append({
        "name": "split-one-page-per-sheet",
        "kind": "split",
        "why": "Writing past the sheet made the page taller; each sheet becomes a page, in order.",
        "sheet": SHEET,
        "now": NOW,
        "page": page("page-a", [
            stroke("s1", 100, 200), stroke("s2", 1100, 1200), stroke("s3", 2500, 2600),
        ]),
        "expected": [
            expected("page-a", [stroke("s1", 100, 200)]),
            expected(child_id("page-a", 1), [stroke("s2", 100, 200)]),
            expected(child_id("page-a", 2), [stroke("s3", 500, 600)]),
        ],
    })

    # Nothing below the first sheet: left alone, and still one page.
    out.append({
        "name": "split-page-within-its-sheet-is-untouched",
        "kind": "split",
        "why": "A page that fits its sheet must not be divided, or every open would file a page.",
        "sheet": SHEET,
        "now": NOW,
        "page": page("page-b", [stroke("s1", 10, 900)]),
        "expected": [expected("page-b", [stroke("s1", 10, 900)])],
    })

    # A stroke that begins above the boundary and trails past it.
    out.append({
        "name": "split-stroke-crossing-the-boundary-stays-whole",
        "kind": "split",
        "why": (
            "Ink belongs to the sheet it starts on and is never cut; counting sheets from where "
            "content starts is also what makes a second run a no-op."
        ),
        "sheet": SHEET,
        "now": NOW,
        "page": page("page-c", [stroke("straddler", 950, 1050), stroke("below", 1500, 1600)]),
        "expected": [
            expected("page-c", [stroke("straddler", 950, 1050)]),
            expected(child_id("page-c", 1), [stroke("below", 500, 600)]),
        ],
    })

    # The straddler alone: content reaches past the sheet, but no content *starts* there.
    out.append({
        "name": "split-overhang-alone-makes-no-second-page",
        "kind": "split",
        "why": (
            "Sheets are counted from where content begins, not how far it reaches — measuring the "
            "extent would file an empty page on every open, for ever."
        ),
        "sheet": SHEET,
        "now": NOW,
        "page": page("page-d", [stroke("straddler", 950, 1400)]),
        "expected": [expected("page-d", [stroke("straddler", 950, 1400)])],
    })

    # An image below the fold travels with its sheet.
    image = {"id": "img", "x": 100, "y": 1200, "width": 300, "height": 200,
             "createdAt": TS, "updatedAt": TS}
    moved = dict(image, y=200)
    out.append({
        "name": "split-image-below-the-sheet-travels-with-it",
        "kind": "split",
        "why": "Images are placed by their top edge, by the same rule as ink.",
        "sheet": SHEET,
        "now": NOW,
        "page": page("page-e", [stroke("s1", 10, 20)], [image]),
        "expected": [
            expected("page-e", [stroke("s1", 10, 20)]),
            expected(child_id("page-e", 1), [], [moved]),
        ],
    })

    return out


def main():
    new = vectors()
    for path in (BOPA, NOTABLE):
        if not path.exists():
            raise SystemExit(f"missing {path} — is the sibling checkout there?")
        data = json.loads(path.read_text())
        kept = [v for v in data["vectors"] if v.get("kind") != "split"]
        data["vectors"] = kept + new
        path.write_text(json.dumps(data, indent=2) + "\n")
        print(f"wrote {len(new)} split vectors to {path}")


if __name__ == "__main__":
    main()
