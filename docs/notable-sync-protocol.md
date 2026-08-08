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
  "createdAt": "...", "updatedAt": "...",
  "serverTimestamp": "..."
}
```

`updatedAt` is the conflict-resolution clock for the whole notebook (see §8).

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

## 7. Backgrounds

`background` / `backgroundType` fields: `backgroundType` `"native"` refers to built-in template
names in `background` (e.g. `blank`, lined/grid variants); custom image/PDF backgrounds use the
`backgrounds/` directory. Exact native template names TBD — enumerate from
`editor/utils` before implementing background rendering (tracked as an open task).

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

## 9. Interop cautions

- **Clock skew matters** (LWW on `updatedAt` timestamps): keep both devices NTP-synced.
- Notable pages are **infinite vertical scroll**; the iPad canvas must handle unbounded y
  (PencilKit canvases have no intrinsic page size — fine, but export/pagination needs care).
- `color` is a signed Android ARGB int; convert via `UInt32(bitPattern:)`.
- Emit `dt` (delta-time) and tilt channels when available from PencilKit; Notable stores but does
  not yet use `dt`.
- Notable writes `manifest.json` pretty-printed and page files compact; either is parseable —
  don't depend on formatting.
