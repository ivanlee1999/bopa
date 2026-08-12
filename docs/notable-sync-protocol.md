# Notable WebDAV Sync Protocol (as implemented by Ethran/notable)

This document specifies the on-server format and sync semantics used by
[Ethran/notable](https://github.com/Ethran/notable)'s experimental WebDAV sync, reverse-documented
from source so that the bopa iPad app can interoperate with a stock Notable install on a BOOX
device — no fork required.

**Pinned reference:** Ethran/notable commit `eb3a4c166ccfbb7f9d1f317860b0b1eeb57d2f64`
(v0.2.6-2, 2026-08-02). Local study clone: `~/workspace/notable`.
Key source files:

| Concern | File |
|---|---|
| Server paths | `sync/SyncPaths.kt` |
| Notebook/page/stroke JSON | `sync/serializers/NotebookSerializer.kt` |
| folders.json | `sync/serializers/FolderSerializer.kt` |
| Stroke binary codec ("SB") | `data/db/StrokePointConverter.kt` |
| Polyline coordinate codec | `data/db/EncodePolyline.kt` |
| Stroke/point model, pens | `data/db/Stroke.kt`, `editor/utils/pen.kt` |
| Reconciliation logic | `sync/NotebookSyncPlanner.kt`, `sync/NotebookSyncService.kt` |

The sync feature is marked *experimental* upstream (added v0.2.5, Jul 2026). All JSON payloads
carry `version: 1` and Notable parses with `ignoreUnknownKeys = true`. Track upstream releases for
protocol changes before updating either side.

## 1. Server layout

All paths relative to the configured WebDAV base URL.

```
/notable/
  folders.json                          # full folder tree, one file
  deletions/<notebookId>                # zero-byte tombstone per deleted notebook
  notebooks/<notebookId>/
    manifest.json                       # notebook metadata
    pages/<pageId>.json                 # one file per page: page + strokes + images
    images/<imageName>                  # raster assets referenced by pages
    backgrounds/<bgName>                # custom background assets
```

- IDs are UUID strings (`java.util.UUID.randomUUID().toString()`).
- A tombstone's *presence* means the notebook is deleted; the server's `Last-Modified` on the
  tombstone is the deletion timestamp used in conflict resolution.

## 2. folders.json

```json
{
  "version": 1,
  "folders": [
    {
      "id": "<uuid>",
      "title": "Work",
      "parentFolderId": null,          // optional; null/absent = root
      "createdAt": "2026-08-02T10:00:00Z",
      "updatedAt": "2026-08-02T10:00:00Z"
    }
  ],
  "serverTimestamp": "2026-08-02T10:00:01Z"   // Instant.now() at serialization
}
```

All timestamps in this protocol are strict ISO-8601 UTC (`java.time.Instant.toString()`,
e.g. `2026-08-02T10:00:00.123Z`). Notable skips (does not fail on) entries with unparsable dates.

## 3. manifest.json

```json
{
  "version": 1,
  "notebookId": "<uuid>",
  "title": "My notebook",
  "pageIds": ["<uuid>", "<uuid>"],     // ordered page list
  "openPageId": "<uuid or null>",
  "parentFolderId": "<uuid or null>",
  "defaultBackground": "blank",         // see §7 backgrounds
  "defaultBackgroundType": "native",
  "linkedExternalUri": null,
  "defaultPageWidth": 1400,             // page units; null = undeclared, see §3.1
  "defaultPageHeight": 1980,
  "createdAt": "...", "updatedAt": "...",
  "serverTimestamp": "..."
}
```

`updatedAt` is the conflict-resolution clock for the whole notebook (see §8).

### 3.1 Page size (page units)

`defaultPageWidth`/`defaultPageHeight` are the sheet **new pages in this notebook** are created
with; the authoritative geometry for laying out a given page is that page's own `pageWidth`/
`pageHeight` (§4). Same division of labour as `defaultBackground` and `background`.

Both are in **page units**: the coordinate space stroke and image geometry is already expressed
in. One unit is exactly **0.15 mm** (≈169.3 dpi), which makes a unit ≈ 0.42520 PostScript points,
so A4 in page units is the standard 595.3 × 841.9 pt PDF page box.

Sizes are stored **portrait** (`width <= height`). There is no orientation field: turning a device
sideways changes how much of the sheet is on screen, not how big the sheet is.

| Preset | mm | page units |
|---|---|---|
| `a3` | 297 × 420 | 1980 × 2800 |
| `a4` | 210 × 297 | 1400 × 1980 |
| `a5` | 148 × 210 | 987 × 1400 |
| `letter` | 215.9 × 279.4 | 1439 × 1863 |
| `legal` | 215.9 × 355.6 | 1439 × 2371 |

This table is normative: it exists in both repos (`NotableKit/PageSize.swift`, Kotlin
`PageSizes.kt`) and both test suites pin the values, because a dimension differing by one unit
between the two would put the apps back to laying out different pages.

**Absent, null or non-positive means undeclared** — a notebook or page written before page sizes
existed. Nothing retrofits a size onto one: each app falls back to what it always used (bopa 1404
× 1872, Notable the device's own screen width), so old notebooks keep rendering as they did.

Rules both implementations follow:

- The size is chosen when a notebook is created and never edited afterwards. Ink is positioned
  against the sheet from the first stroke, so changing it later would move every stroke on the
  page relative to the paper.
- A declaration is never lost to a peer that has none: on merge, `winner.pageWidth ?? loser
  .pageWidth`. Otherwise one sync from a build that has not learned the field would silently
  reflow every page it touched.
- Height is the *sheet* height, not a limit on writing. Both apps keep scrolling past the bottom
  of the sheet; the height is what pagination and export divide by.
- **The scrollable area must cover the ink even when the ink is outside the sheet.** Ink lands
  past the right edge whenever it was written on a device wider than the sheet (including every
  undeclared page). An area that stops at the sheet's edge does not merely park that ink
  off-page, it makes it unreachable.

## 4. Page file (`pages/<pageId>.json`)

Written compactly (no pretty-print) by a streaming serializer; field order is scalar page fields
first, then `strokes`, then `images`. Parsers must not rely on whitespace.

```json
{
  "version": 1,
  "id": "<pageId>",
  "notebookId": "<uuid or null>",
  "background": "blank",
  "backgroundType": "native",
  "parentFolderId": null,
  "scroll": 0,                          // int, vertical scroll position
  "pageWidth": 1400,                    // page units; null = undeclared, see §3.1
  "pageHeight": 1980,
  "createdAt": "...", "updatedAt": "...",
  "strokes": [ <StrokeDto>... ],
  "images":  [ <ImageDto>... ]
}
```

### StrokeDto

```json
{
  "id": "<uuid>",
  "size": 3.0,                 // brush size, float
  "pen": "BALLPEN",            // Pen enum name, see §6
  "color": -16777216,          // Android ARGB packed into SIGNED 32-bit int (0xFF000000 = black)
  "maxPressure": 1,            // 1 = pressures normalized to [0,1] ("SB2"); legacy rows carry the
                               // raw digitizer max (e.g. 4096) and pressures scaled to it
  "top": 10.0, "bottom": 40.0, "left": 5.0, "right": 200.0,   // bounding box, page coords
  "pointsData": "<base64 of SB binary, see §5>",
  "createdAt": "...", "updatedAt": "..."
}
```

On import Notable normalizes pressure to [0,1] whenever `maxPressure != 1`. **Writers should emit
normalized pressure with `maxPressure: 1`.** Corrupted strokes/images are skipped individually,
not fatally.

### ImageDto

```json
{
  "id": "<uuid>",
  "x": 0, "y": 0, "width": 100, "height": 100,     // ints, page coords
  "uri": "images/abc123.jpg",                       // relative path under the notebook dir
  "createdAt": "...", "updatedAt": "..."
}
```

## 5. SB stroke-points binary format (v2)

`pointsData` decodes (base64) to this **little-endian** structure:

```
Header (10 bytes):
  byte 0    'S' (0x53)
  byte 1    'B' (0x42)
  byte 2    version = 2        (readers accept <= 2; v1 differs only in pressure encoding)
  byte 3    mask               bit0 pressure, bit1 tiltX, bit2 tiltY, bit3 dt
  bytes 4-7 count (int32)      number of points
  byte 8    compression        0 = none, 1 = LZ4 block
[if compression == 1]
  bytes 9-12 rawBodySize (int32)  uncompressed body size
Body (raw, or LZ4-block-compressed as a whole):
  int32  xLen;  byte[xLen]  X coordinates, Google-polyline-encoded, precision 2, UTF-8
  int32  yLen;  byte[yLen]  Y coordinates, same encoding
  [mask bit0] uint16[count]  pressure, fixed-point: round(p * 65535), p in [0,1]   (v2)
                             (v1: raw digitizer value truncated to int16)
  [mask bit1] int8[count]    tiltX, degrees, -90..90
  [mask bit2] int8[count]    tiltY, degrees, -90..90
  [mask bit3] uint16[count]  dt, ms since first point of stroke; 0xFFFF reserved as
                             null sentinel (values clamped to 0..65534 on write)
```

Invariants and gotchas:

- **Channel uniformity:** per stroke, an optional channel is present for *all* points or none
  (mask computed from the first point; writer validates).
- **Polyline codec:** Google's polyline algorithm (delta + zigzag + base-63 varint chars) applied
  to each axis independently with precision 2 (values multiplied by 100 and rounded). Coordinates
  are page-local floats, `y` includes scroll offset. Effective coordinate resolution is 0.01.
- **LZ4:** the *block* format (`net.jpountz` high-compression block), i.e. a raw LZ4 block —
  compatible with Apple `Compression`'s `COMPRESSION_LZ4_RAW` (NOT `COMPRESSION_LZ4`, which
  expects Apple's framed variant). Compression is applied only when the raw body is ≥ 512 bytes
  and saves ≥ 25%; otherwise flag 0 with raw body.
- Decoder must reject trailing bytes (uncompressed case), bad magic, version > 2.

## 6. Pen enum

`BALLPEN`, `REDBALLPEN`†, `GREENBALLPEN`†, `BLUEBALLPEN`†, `PENCIL` (charcoal v1), `BRUSH`,
`MARKER`, `FOUNTAIN`, `DASHED`, `CHARCOAL` (charcoal v2), `CALLIGRAPHY` (+45° square nib).

† legacy — never written by current Notable, but must parse (map to BALLPEN + color).

Proposed PencilKit mapping (to be tuned by eye):

| Notable pen | PencilKit ink |
|---|---|
| BALLPEN / DASHED | `.pen` |
| FOUNTAIN / BRUSH / CALLIGRAPHY | `.fountainPen` (iOS 17+) / `.pen` fallback |
| PENCIL / CHARCOAL | `.pencil` |
| MARKER | `.marker` |

Unknown-pen safety: Notable's `Pen.fromString` falls back to BALLPEN; our reader should do the
same. Writers must only emit the enum names above.

## 7. Backgrounds (page templates)

A page's template is the `background` + `backgroundType` pair. The type keys come from
`data/model/BackgroundType.kt`:

| `backgroundType` | meaning | `background` holds | local folder |
|---|---|---|---|
| `native` | grid the app draws itself | template name | — |
| `image` | image scaled to page width, drawn once at the top | asset path | `images/` |
| `imagerepeating` | same image tiled down the scroll | asset path | `images/` |
| `coverImage` | notebook cover art (a title box is drawn over it) | asset path | `covers/` |
| `pdf<N>` | one fixed PDF page; **N is 0-based** | asset path | `pdfs/` |
| `autoPdf` | PDF page follows the page's index within its notebook | asset path | `pdfs/` |

`BackgroundType.fromKey` falls back to `native` for anything it doesn't recognize, including a
`pdf` key with a non-numeric suffix.

**Native template names** (`ui/dialogs/BackgroundSelector.kt`): `blank`, `dotted`, `lined`,
`squared`, `hexed` — nothing else. Notable *throws* when asked to draw a native name it doesn't
know (`drawBg`), so only these five are safe to write. Their geometry
(`editor/drawing/backgrounds.kt`): lines, squares and dots on an 80-unit grid anchored to the page
origin (so they align across devices at any scroll offset), 1px Android `GRAY` (#888888), dots 6
units across. Hexagons are the exception — the radius is derived from the live canvas size
(`max(w, h) / (26 * 1.5)`), so the pattern is viewport-dependent and cannot be matched exactly.

**Assets** are stored per device under `notabledb/backgrounds/{images,covers,pdfs}/` and are drawn
scaled so their width matches the page width, anchored at the top of the (infinitely scrolling)
page. On the server they are flat, per notebook: `notebooks/<id>/backgrounds/<basename>` —
so basenames must be unique across the whole local store, not just within one folder.

### Custom backgrounds do not round-trip in v0.2.6

The three halves of the feature disagree about what `background` contains for a non-native
background:

- **Writers** store an *absolute* device path — `BackgroundSelector.kt:161` (picker) and
  `importPdf.kt:57` (PDF import) both save `copiedFile.toString()`, e.g.
  `/storage/emulated/0/Documents/notabledb/backgrounds/pdfs/weekly.pdf`.
- **The uploader** skips any background whose path `isAbsolute`, treating it as a linked external
  file outside managed storage (`NotebookSyncService.kt:368`). So a template imported on the BOOX
  is never uploaded, and the page JSON that *is* uploaded carries a device-local path.
- **The downloader** does the opposite: it reads `background` as a path *relative* to the
  backgrounds folder, fetches `backgrounds/<basename>`, and writes it to
  `backgrounds/<relative path>` (`NotebookSyncService.kt:509-527`). Unlike images — which it
  rewrites to an absolute path on the way in (`image.copy(uri = localFile.absolutePath)`) — it
  leaves the page's `background` field untouched, and `loadBackgroundBitmap` resolves it with a
  bare `File(path)`, which cannot find a relative path.

Net effect: templates imported on either side don't currently show up on the other.

**What bopa does:** always write the *relative* form (`pdfs/weekly.pdf`) and upload the asset to
`backgrounds/<basename>` ourselves. That is the shape Notable's download path understands, so the
file lands in the right place on the BOOX; the page renders blank there until upstream resolves
relative background paths against the backgrounds folder (a one-line fix in
`loadBackgroundBitmap`, plus relativizing on upload). Reading is tolerant of every form —
relative, bare basename, and the absolute paths Notable writes.

Implementation: `NotableKit/Sources/NotableKit/Backgrounds` (wire format) and `…/Templates`
(import, apply, render).

## 8. Sync semantics (what a compatible client must do)

Per-client persistent state, per notebook: `localUpdatedAtAtSync` (epoch ms) and the manifest
**ETag** stored at last committed sync.

Reconciliation per notebook (`NotebookSyncPlanner`, tolerance = 1000 ms):

1. Conditional `GET manifest.json` with `If-None-Match: <storedEtag>`.
2. `304 Not Modified` → remote unchanged: upload iff `localUpdatedAt − localUpdatedAtAtSync >
   1000ms` (guard the manifest `PUT` with `If-Match: <storedEtag>`), else skip.
3. Remote changed → compare `manifest.updatedAt` vs local `updatedAt`:
   - local newer by > 1000 ms → **upload** (`If-Match` with the *fresh* remote ETag);
   - remote newer by > 1000 ms → **download**;
   - within tolerance → skip (treat as equal).
   Both-changed conflicts resolve **last-writer-wins at notebook granularity** (no merge).
4. Local notebook absent on server → plain upload. Remote notebook absent locally → download.
5. Deletions: check `deletions/<id>` tombstones; tombstone presence beats existence, with the
   tombstone's server `Last-Modified` as deletion time. Write a zero-byte tombstone when deleting.
6. A failed `If-Match` PUT (412) means a concurrent writer won — re-plan, don't overwrite.

Upload of a notebook = PUT manifest + all page files (+ referenced images/backgrounds); Notable
v0.2.6 streams page uploads and cleans up orphaned page files. `MKCOL` parent directories as
needed.

### 8.1 Per-page reconciliation (bopa)

Step 3's "both changed" case is where bopa is stricter than the baseline above: rather than
last-writer-wins over the whole notebook, it keeps per-page state (`syncedLocalUpdatedAt`, ETag and
a SHA-256 of the bytes that transfer moved) and looks at the pages. Edits to *different* pages
merge with no prompt; only a page changed on both sides, or a manifest whose structure disagrees,
is a conflict — and then **nothing** is transferred until the user chooses.

A page counts as changed on the server only when its content differs, not merely when its ETag
does. An ETag says a file was written; Notable rewrites page files when a notebook is opened, and
servers and proxies vary the spelling of the same validator (`W/"v3"` vs `"v3"`). So a page whose
ETag moved is fetched and compared against the stored digest: identical bytes mean the remote did
not move, and the fresh ETag is simply adopted. Without that check, a rewrite carrying no change
turned the user's next edit of that page — typically an erase, since erasing targets ink both
devices have long since synced — into a conflict they had to settle by hand.

Implementation: `SyncEngine.reconcileDiverged`, `PageSyncState`.

## 9. Interop cautions

- **Clock skew matters** (LWW on `updatedAt` timestamps): keep both devices NTP-synced.
- Notable pages are **infinite vertical scroll**; the iPad canvas must handle unbounded y
  (PencilKit canvases have no intrinsic page size — fine, but export/pagination needs care).
- `color` is a signed Android ARGB int; convert via `UInt32(bitPattern:)`.
- Emit `dt` (delta-time) and tilt channels when available from PencilKit; Notable stores but does
  not yet use `dt`.
- Notable writes `manifest.json` pretty-printed and page files compact; either is parseable —
  don't depend on formatting.
