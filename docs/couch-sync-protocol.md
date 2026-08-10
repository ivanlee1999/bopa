# CouchDB Sync Protocol (normative)

Contract shared by **bopa** (iPad, Swift) and **notable** (BOOX, Kotlin). Rationale and
rollout live in [couchdb-sync-plan.md](couchdb-sync-plan.md); this file is the part both
implementations must agree on byte-for-byte.

Conformance is checked by [couch-sync-vectors/vectors.json](couch-sync-vectors/vectors.json),
which both test suites execute. The file is identical in both repos (CI asserts it).

---

## 1. Database and identifiers

One database, default name `notes`. Document IDs are `<type>:<id>`:

| Type | ID form | Example |
|---|---|---|
| `folder` | `folder:<uuid>` | `folder:9db4c182-977b-4b22-8a3f-e7d3d8205846` |
| `notebook` | `notebook:<uuid>` | `notebook:b1bf438e-a332-4709-873b-ec034bf33b2c` |
| `page` | `page:<uuid>` | `page:64d92c8c-9f36-4de7-838c-f21df150ec9e` |
| `asset` | `asset:<sha256-hex>` | `asset:9f2c…` (64 lowercase hex chars) |

UUIDs are lowercase and stable for the lifetime of the object. Titles never appear in IDs.

`deviceId` is a short stable string identifying the writing device: `"ipad"` for bopa,
`"boox"` for notable. It participates in tiebreaks, so the two values must differ.

## 2. Common fields

Every document carries:

| Field | Type | Meaning |
|---|---|---|
| `type` | string | `folder` \| `notebook` \| `page` \| `asset` |
| `schema` | int | `1`. A reader seeing a **higher** value must not merge (§6.5). |
| `createdAt` | timestamp | Creation time. Merges to the **minimum**. |
| `updatedAt` | timestamp | Last local mutation. Display + tiebreak only. |
| `updatedBy` | string | `deviceId` of the last writer. |

**Timestamps** are ISO-8601 UTC strings in `java.time.Instant.toString()` style —
fractional seconds present only when non-zero (`2026-08-10T06:12:33.871Z`,
`2026-08-10T06:12:04Z`). Both forms must parse.

> **Timestamps are never compared as strings.** Lexicographic order disagrees with
> chronological order (`"…:33.871Z" < "…:33Z"` because `.` < `Z`). Always parse to epoch
> milliseconds and compare numerically. A timestamp that fails to parse compares as
> `Long.MIN_VALUE` (loses every comparison) — it must never crash a merge.

## 3. Document schemas

### 3.1 folder

```json
{ "_id": "folder:<uuid>", "type": "folder", "schema": 1,
  "title": "study", "parentFolderId": null,
  "createdAt": "…", "updatedAt": "…", "updatedBy": "boox" }
```

Deletion: `PUT` the document with `"_deleted": true` while retaining `type`, `deletedAt`,
`updatedAt`, `updatedBy` in the body, so the peer can apply §6.4.

### 3.2 notebook

```json
{ "_id": "notebook:<uuid>", "type": "notebook", "schema": 1,
  "title": "tese2",
  "pageIds": ["<uuid>", "…"],
  "deletedPageIds": [{ "id": "<uuid>", "deletedAt": "…" }],
  "parentFolderId": null,
  "defaultBackground": "blank", "defaultBackgroundType": "native",
  "createdAt": "…", "updatedAt": "…", "updatedBy": "ipad" }
```

`openPageId`, scroll position and `linkedExternalUri` are device-local and **never** written.

### 3.3 page

```json
{ "_id": "page:<uuid>", "type": "page", "schema": 1,
  "notebookId": "<uuid>",
  "background": "blank", "backgroundType": "native",
  "strokes": [ { "id": "<uuid>", "createdAt": "…", "updatedAt": "…", "deviceId": "boox",
                 "pen": "FOUNTAIN", "color": -16777216, "size": 4.48, "maxPressure": 1,
                 "top": 312, "bottom": 393, "left": 214, "right": 262,
                 "pointsData": "U0IC…" } ],
  "deletedStrokes": [ { "id": "<uuid>", "deletedAt": "…" } ],
  "images": [ { "id": "<uuid>", "assetId": "asset:<sha256>", "x": 0, "y": 0,
                "width": 0, "height": 0, "createdAt": "…", "updatedAt": "…" } ],
  "deletedImages": [ { "id": "<uuid>", "deletedAt": "…" } ],
  "createdAt": "…", "updatedAt": "…", "updatedBy": "boox" }
```

Stroke geometry fields (`pen`, `color`, `size`, `maxPressure`, bounds, `pointsData`) keep
the existing WebDAV wire semantics unchanged — see
[notable-sync-protocol.md](notable-sync-protocol.md) §4. `color` is a **signed** 32-bit
Android ARGB int. `pointsData` is base64 of the SB binary encoding.

### 3.4 asset

```json
{ "_id": "asset:<sha256>", "type": "asset", "schema": 1,
  "contentType": "image/png", "createdAt": "…", "updatedAt": "…", "updatedBy": "ipad",
  "_attachments": { "blob": { "content_type": "image/png", "data": "<base64>" } } }
```

Content-addressed, therefore immutable. A `409` on asset upload means "already present"
and is a success, not a conflict.

## 4. Ordering primitives

```
millis(ts)         = parsed epoch millis, or Long.MIN_VALUE if unparseable
scalarKey(doc)     = the doc's scalar fields only, rendered as key-sorted minimal JSON:
                     type, schema, createdAt, updatedAt, updatedBy, and per type —
                     page:     notebookId, background, backgroundType
                     notebook: title, parentFolderId, defaultBackground, defaultBackgroundType
                     folder:   title, parentFolderId
                     Absent/null values render as `null`.
```

`scalarKey` deliberately excludes every mergeable collection (`strokes`, `images`,
`pageIds`, and their tombstone arrays). Those are unioned, never picked — and excluding
them keeps the key free of floating-point fields, whose textual rendering is the one thing
Swift and Kotlin would not agree on for free.

**`pick(a, b)`** — total, commutative choice of a "winner" for scalar fields:

1. greater `millis(updatedAt)` wins;
2. else greater `updatedBy` by UTF-8 code-unit order wins;
3. else greater `scalarKey(doc)` by UTF-8 code-unit order wins;
4. else the scalar envelopes are identical — either may be returned.

Step 3 exists so `pick` stays commutative when two devices write the same millisecond
under the same device id; without it `merge(a,b) ≠ merge(b,a)` in that case. Because the
two devices use distinct `deviceId` values, step 3 is unreachable in normal operation —
it is a determinism backstop, not a routine path.

**`earlier(x, y)` / `later(x, y)`** — the timestamp string with the smaller / larger
`millis`. When the instants are equal but the spellings differ (`…:05Z` vs `…:05.000Z`),
`earlier` keeps the lexicographically smaller string and `later` the larger, so the choice
does not depend on argument order.

**`unionById(xs, ys, pick:)`** — set union keyed by `id`. Whenever two elements share an
`id`, `pick` decides — **including two elements within the same input array**. Skipping the
intra-array case makes the outcome depend on element order, which is not something a reader
can assume about a document another writer produced.

**`unionTombstones(xs, ys)`** — `unionById` keeping the **earliest** `deletedAt` (a deletion
cannot un-happen; the earliest observation is the true one), result sorted by `id`.

**Element tiebreaks must be total.** A `pick` that can itself tie leaves the result
argument-order dependent. For a stroke: greater `millis(updatedAt)` wins, else the greater
of

```
deviceId|createdAt|updatedAt|pen|color|maxPressure|
bits(size)|bits(top)|bits(bottom)|bits(left)|bits(right)|pointsData
```

joined with `|`, where `bits(f)` is the IEEE-754 32-bit pattern of `f` as an **unsigned**
decimal integer (`String(f.bitPattern)` in Swift, where `bitPattern` is already `UInt32`;
`Integer.toUnsignedString(Float.floatToIntBits(f))` in Kotlin, where `floatToIntBits` is
signed). Rendering unsigned on both sides matters only for floats with the sign bit set —
which no vector covers, so the vectors cannot catch getting this wrong. Bit patterns are
used at all because the two languages' default float *printing* does not agree, while their
bit patterns are identical by definition. For an image, the same shape over
`assetId|createdAt|updatedAt|x|y|width|height` (no floats involved).

String comparisons above are by code unit. Swift compares UTF-8 and Kotlin UTF-16; these
agree for all ASCII, which covers every id, device id and timestamp in the protocol. They
could differ only for supplementary-plane characters in a `title` that reached the
last-resort `scalarKey` tiebreak — a path §4 already establishes is unreachable while the
devices use distinct ids.

## 5. Merge functions

All are **commutative** (`merge(a,b) == merge(b,a)`) and **idempotent**
(`merge(merge(a,b), a) == merge(a,b)`). None requires a common ancestor. Implementations
MUST satisfy both properties for every vector.

### 5.1 mergePage(a, b)

```
tombS   = unionTombstones(a.deletedStrokes, b.deletedStrokes)
tombI   = unionTombstones(a.deletedImages,  b.deletedImages)
strokes = unionById(a.strokes, b.strokes, pick: by (millis(updatedAt), id, canonical) desc)
            .filter { $0.id ∉ tombS }
            .sorted  by (millis(createdAt) asc, id asc)
images  = same shape, tombI, sorted by (millis(createdAt) asc, id asc)
w       = pick(a, b)
result  = { notebookId, background, backgroundType from w
            strokes, images, deletedStrokes: tombS, deletedImages: tombI
            createdAt: whichever source string has the smaller millis (ties keep either)
            updatedAt: whichever source string has the larger  millis (ties keep either)
            updatedBy: w.updatedBy
            schema: max(a.schema, b.schema)  // both ≤ reader's version, see §6.5
            type: "page" }
```

Erasure beats drawing: a stroke present on one side and tombstoned on the other is
absent from the result on both devices. Because stroke ids are never reused (a redraw
mints a new id), "remove wins" cannot suppress later work.

### 5.2 mergeNotebook(a, b)

```
w       = pick(a, b) ; o = the other
tomb    = unionTombstones(a.deletedPageIds, b.deletedPageIds)
pageIds = w.pageIds ++ [ id ∈ o.pageIds : id ∉ w.pageIds ]   // o's relative order kept
            .filter { $0 ∉ tomb }
result  = { title, parentFolderId, defaultBackground, defaultBackgroundType from w
            pageIds, deletedPageIds: tomb
            createdAt/updatedAt/updatedBy/schema as in 5.1, type: "notebook" }
```

Ordered add-wins union: the winner's page order is authoritative; pages only the loser
knows about are appended in the loser's relative order.

> Ordering is deterministic for any fixed pair of inputs and therefore identical on both
> devices. It is not strictly associative across three or more concurrent orderings — the
> resulting **set** always is. With two devices this never surfaces.

### 5.3 mergeFolder(a, b)

`pick(a, b)`, with `createdAt` merged to the minimum. Folders are names; nothing inside
them can conflict.

### 5.4 mergeAsset(a, b)

Assets are immutable; return either (they are equal by construction).

## 6. Conflict rules beyond field merging

### 6.1 Local-vs-remote on push (`409`)

The pusher re-reads the current remote document (including `_deleted` tombstones), merges
per §5, and re-PUTs with the fresh `_rev`. Bounded retries (5, jittered); on exhaustion the
document stays dirty and is retried on the next flush.

### 6.2 Remote-vs-local on pull

Every incoming change is merged into the local copy with the same functions. If the merge
result differs from the incoming document, the local side had content the server lacks, so
the document is marked dirty and pushed back.

### 6.3 Echo suppression

A change whose `rev` equals the locally recorded `rev` for that document is this device's
own write coming back and is skipped.

### 6.4 Delete vs edit (notebook, folder)

When one side holds a live document and the other a tombstone:

- `millis(live.updatedAt) > millis(tomb.deletedAt)` → **resurrect**: the live document wins
  and is written over the tombstone's `_rev`.
- otherwise → **apply the deletion** locally.

Pages have no independent lifecycle: they live and die with their notebook's `pageIds` /
`deletedPageIds`.

### 6.5 Un-mergeable input — conflict copy

If a document fails to decode, or its `schema` is greater than the reader supports, or a
required field is missing, the reader MUST NOT guess. It keeps its local object untouched
and materializes the remote version as a **new local object with fresh UUIDs**, titled
`"<title> (conflict <yyyy-MM-dd> <deviceId>)"`. Nothing is ever discarded or overwritten.

### 6.6 Producing tombstones

Neither app records erasures today — bopa's exporter writes out whatever ink survived, and
notable hard-deletes the stroke row. Absence is sufficient when a single device owns the
file, but a merge cannot distinguish "this stroke was erased here" from "this stroke has not
reached here yet", and without that distinction the peer's copy simply comes back.

Each save therefore records what stopped existing:

```
departed  = strokeIDs(previous save) − strokeIDs(now) − ids already tombstoned
tombstones = existing ++ { (id, deletedAt: now) : id ∈ departed }, sorted by id
```

An id that is already tombstoned **keeps its original `deletedAt`**. Re-stamping it on every
save would let an arbitrarily later timestamp win a delete-vs-edit comparison it should lose.

Tombstones older than 30 days may be pruned locally; a tombstone whose `deletedAt` cannot be
parsed is never pruned, since it cannot be shown to be old enough.

### 6.7 Mass-deletion guard

A flush that would push ≥10 notebook tombstones **and** those tombstones are a strict
majority of the device's known notebooks must be refused pending explicit user
confirmation. This protects against a wiped local database masquerading as intent.

## 7. Transport

| Step | Request |
|---|---|
| Read | `GET /{db}/{docid}` (add `?deleted=true` semantics via `open_revs` only if needed; a plain 404 means absent, a 200 with `_deleted` means tombstoned) |
| Write | `PUT /{db}/{docid}` with `_rev` when updating; `201` success, `409` conflict → §6.1 |
| Catch-up | `GET /{db}/_changes?feed=normal&since={seq}&include_docs=true&limit=…` |
| Live | `GET /{db}/_changes?feed=longpoll&since={seq}&include_docs=true&timeout=55000&heartbeat=15000` |
| Attachment | `PUT /{db}/{docid}/blob?rev=…`, `GET /{db}/{docid}/blob` |

Auth is HTTP Basic over TLS. `since` checkpoints are persisted locally per device; losing
one is safe (replay from `0` is idempotent), only slower.

Failure classes clients must distinguish: `401/403` (credentials — surface, stop),
`409` (merge, retry), `412/404` (absent — treat as create), `5xx`/timeout/offline
(backoff, keep dirty).

## 8. Test vectors

`couch-sync-vectors/vectors.json`:

```json
{ "version": 1,
  "vectors": [ { "name": "…", "kind": "page|notebook|folder",
                 "a": { … }, "b": { … }, "expected": { … } } ] }
```

For every vector both suites assert:

1. `merge(a, b) == expected`
2. `merge(b, a) == expected` (commutativity)
3. `merge(expected, a) == expected` and `merge(expected, b) == expected` (idempotence)

Documents in vectors omit `_id`/`_rev`; merges operate on document bodies.
