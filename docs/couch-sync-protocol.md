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

### 1.1 Reserved identifiers

The `sync-meta:` prefix is reserved for protocol bookkeeping and carries no user content. A client
**must not** enumerate, merge, conflict-copy, or present these documents as library items, and
**must not** treat one arriving on the change feed as an unknown schema. `sync-meta:database`
(§1.2) and `sync-meta:asset-gc:<deviceId>` (§3.5) are defined; a client encountering any other
`sync-meta:` id records its revision, ignores it, and checkpoints past it.

That last rule is what lets this namespace grow. A bookkeeping document added by a later release
reaches a peer that has never heard of it and is *already* handled correctly — recorded, skipped,
checkpointed past — so no staged rollout is needed for the peer's sake, only for the writer's.

**A `sync-meta:` id ending in a `deviceId` is single-writer.** Only the device named may write it;
every other device reads it and never merges it. None of §5's merge functions apply, and no
tiebreak is needed, because two writers never meet on one such document. This is the reason
§3.5's ledger is keyed by device rather than shared: bookkeeping several devices must agree about
is far easier to reason about as several documents each with one author than as one document with
a merge rule.

### 1.2 `sync-meta:database` — database identity

Local sync state — the change-feed checkpoint and the per-document revision cache — is scoped by
endpoint and database name. That pair does not distinguish the original database from a new one
created later under the same name. A checkpoint from the old database either fails against the new
one or, worse, succeeds while describing unrelated history; stale revision entries then suppress
genuine changes as if they were this device's own echoes.

The identity document makes the difference observable:

```json
{
  "_id": "sync-meta:database",
  "type": "sync-database-metadata",
  "protocolVersion": 1,
  "minimumClientProtocol": 1,
  "generation": "3f1a…",
  "locked": false,
  "lockReason": null,
  "updatedAt": "2026-08-13T00:00:00Z"
}
```

| Field | Type | Meaning |
|---|---|---|
| `protocolVersion` | int | The protocol the writer speaks. |
| `minimumClientProtocol` | int | The lowest protocol this database may be synced by. A client whose own version is lower must refuse. |
| `generation` | string | A UUID minted **with the database**. Its only job is to be different when the database is not the same one. |
| `locked` | bool | When true, no client may pull or push ordinary documents. Set for the duration of a rebuild. |
| `lockReason` | string \| null | Shown to the user while locked. |

**Client behaviour.** Before using a stored non-zero checkpoint, read the document and compare
`generation` with the one persisted locally.

| Observation | Required behaviour |
|---|---|
| Generations match | Proceed. |
| Absent, and the database is empty | Create it with `_rev` protection (`PUT` with no revision). A racing device loses with a `409`, re-reads, and adopts the winner's generation — but only if it has no prior identity of its own. |
| Absent, and the database is **not** empty | Adopt and record the observed state without resetting anything. A pre-existing database predates this document; missing metadata is never permission to rebuild. |
| Generation differs from the stored one | Stop automatic sync. Do **not** reset the checkpoint and do **not** upload the local library. |
| `minimumClientProtocol` exceeds this client's version | Refuse before applying or uploading anything. |
| `locked` is true | Refuse pull and push, and say why. |

**Recovery from a generation mismatch is always explicit**, because the two databases may each hold
work the other does not:

- **Use the server copy** — clear local CouchDB sync state and replay from zero. Back up first.
- **Rebuild the server from this device** — confirm, lock the remote, mint a new generation, upload,
  unlock.
- **Merge** — back up both sides, reset the local checkpoint and revision cache, replay from zero,
  then push the deterministic merge results.

**Rollout.** This document is introduced in stages, and a client must not require what a peer of the
previous release cannot provide:

1. Understand and ignore the document during normal processing.
2. Create it for new databases, and record the generation of existing ones.
3. Only once both apps have shipped stages 1–2 may a mismatch or a protocol floor block sync.

Stages 1 and 2 are implemented; stage 3 is gated behind a client-side switch that is off by default.

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
  "deletedAt": null,
  "createdAt": "…", "updatedAt": "…", "updatedBy": "boox" }
```

`deletedAt` is the Trash — see §3.2. A trashed folder hides its whole subtree without any
descendant being written: the descendants stay filed where they are and go on syncing, and the
library simply stops listing anything whose ancestor is trashed. Restoring is therefore one field
changing back, on every device at once.

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
  "defaultPageWidth": 1400, "defaultPageHeight": 1980,
  "bookmarks": [{ "pageId": "<uuid>", "updatedAt": "…", "removed": false }],
  "outline": [{ "id": "<uuid>", "pageId": "<uuid>", "title": "Chapter 1",
                "depth": 0, "updatedAt": "…", "removed": false }],
  "deletedAt": null,
  "createdAt": "…", "updatedAt": "…", "updatedBy": "ipad" }
```

`defaultPageWidth`/`defaultPageHeight` are the sheet new pages here are created with, in page
units; a page's own `pageWidth`/`pageHeight` (§3.3) is what lays that page out. Null means
undeclared — written before page sizes existed. The unit, the preset table and the layout rules
are normative in [notable-sync-protocol.md](notable-sync-protocol.md) §3.1; the merge rule is
§6.7 below.

`deletedAt` is **the Trash**: an ISO-8601 stamp means "thrown away, then"; null or absent means
"in the library". It is deliberately part of the document rather than local bookkeeping, because
deleting has to mean the same thing on every device — throwing a notebook away on the BOOX takes
it out of the iPad's library too, and restoring it on either brings it back on both. A trashed
notebook is **not** deleted: its pages, strokes and assets are untouched and go on merging
normally, so a peer that is still editing it loses nothing. Only emptying the Trash deletes,
and that is the `_deleted` tombstone of §6.4 — not this field.

Writers **MUST** stamp `updatedAt`/`updatedBy` when they set or clear `deletedAt`. It merges as
an ordinary scalar (§5.5), so an unstamped trashing ties with the peer's live copy and can lose.
A reader that does not know the field treats the notebook as live, which is the safe direction:
the item stays visible on an old build rather than vanishing with no way to get it back.

`openPageId`, scroll position and `linkedExternalUri` are device-local and **never** written.

#### 3.2.1 `bookmarks` — starred pages

A flat set of pages the reader starred, keyed by `pageId`. Both entries and removals live in the
same array: `removed: true` is a page that was starred and then un-starred, kept so the un-starring
reaches a peer that still holds the star.

This is the one removal in the protocol **not** expressed as a `deletedX` tombstone list, and the
exception is deliberate. Tombstone unions make removal permanent (§4), which is sound everywhere
else because the removed thing never returns under the same id — a redrawn stroke is a new stroke.
A page keeps its id, so starring it again is routine, and remove-wins would make the second star
impossible to express. Last-writer-wins per `pageId` can say either thing; see §5.2.1.

Absent or `null` reads as an empty list: a notebook written by a build that predates the field has
no bookmarks, which is the correct reading.

#### 3.2.2 `outline` — the table of contents

An **ordered** list of named entries pointing at pages. Order is carried by the array itself, the
way `pageIds` carries page order, and merges the same way (§5.2.2). `removed: true` is a deleted
entry, kept as its own tombstone for the same reason as a bookmark's.

| Field | Type | Meaning |
|---|---|---|
| `id` | string | The entry's own id, **not** the page's. A page may appear in the outline more than once, so the page cannot be the key. |
| `pageId` | string | The page this entry jumps to. |
| `title` | string | What the reader named it. |
| `depth` | int | `0`, `1` or `2` — heading, subheading, sub-subheading. |
| `updatedAt` | string | Stamped on every edit to this entry; drives the per-entry merge. |
| `removed` | bool | A deleted entry. |

An entry anchors to a **page**, never to a position on one. Ink has no headings to re-find, so an
offset anchor would drift the moment the page was edited on the other device — and both apps this
protocol answers to (Goodnotes' outline, the BOOX reader's TOC) anchor by page as well.

`depth` is **clamped, not rejected**, to the range above. A document from a build that one day
allows four levels must degrade to a flatter outline rather than fail to merge; the two
implementations clamp identically, or they would render different outlines from one document.

### 3.3 page

```json
{ "_id": "page:<uuid>", "type": "page", "schema": 1,
  "notebookId": "<uuid>",
  "title": "Shopping list",
  "background": "blank", "backgroundType": "native",
  "pageWidth": 1400, "pageHeight": 1980,
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

The id is the lowercase hex SHA-256 of the exact bytes — no framing, no normalization — so two
devices holding the same picture agree on its name without ever comparing notes.

**How the bytes travel.** The document is written in a single `PUT` with the blob inlined as
`_attachments.blob.data`; a separate attachment write would need the document's revision first,
turning one immutable upload into two requests that can half-fail. Reading is the other way round:
the change feed renders an attachment as a `{"stub": true}` placeholder, so a reader that needs
the bytes fetches them from `GET /{db}/asset:<sha>/blob`.

**What bounds an asset's size — and what does not.** `max_document_size` (default `8000000`) is
measured against the document body **with attachment data removed**. Inline
`_attachments.blob.data` is exempt from it. Measured against stock CouchDB 3.3.3 and 3.5.2, no
config overrides, using exactly the document above: a 4 MiB asset, a 12 MiB asset and a **60 MiB
PDF** are all accepted, and the last reads back through `GET /{db}/asset:<sha>/blob` with a
matching SHA-256. A 4 MiB attachment beside a 7.9 MB ordinary field is accepted; the *same*
attachment beside an 8.1 MB ordinary field is refused. The limit follows the ordinary fields
alone.

Two consequences are normative:

- **CouchDB never refuses an asset document for its size.** Everything outside `_attachments` in
  the schema above is a couple of hundred bytes. The only document this protocol defines that can
  reach `max_document_size` is a **page**, whose `strokes[].pointsData` are ordinary fields.
- **What actually bounds an asset is the smallest request-body cap on the path**, which is
  normally a reverse proxy and not CouchDB at all. nginx's `client_max_body_size` defaults to
  **1 MB** — which, after base64 inflates the bytes by 4/3, rejects any asset above roughly
  768 KiB. That is every photograph a phone takes, not merely large PDFs, and it is why a
  deployment behind a proxy can appear to sync notes perfectly while no picture ever arrives.

A client therefore **MUST NOT** read a `413` as a statement about this protocol or about the
asset's content until it has checked which hop produced it — see §7, which makes the two cases
distinguishable and requires different handling for each. In particular, an implementation that
suppresses a refused document until its content changes must not apply that to a proxy's refusal:
the fix for that one happens on the server, and no local edit will ever arrive to lift the
suppression.

**Assets are fetched on demand, not followed.** An `asset:` row on the feed is recorded and
skipped. A device downloads a blob when one of its own pages places it and it does not hold the
bytes — which keeps it from pulling every picture in the library, and makes a failed download a
retry rather than lost work. Because the id is a promise about the content, a reader checks the
hash of what arrives before storing it.

An `images[]` entry whose `assetId` is null is an image whose content the writer does not know —
its file is missing there. A reader must leave its own copy of that image alone rather than
treating the null as "this image has no bytes".

Where a device *keeps* the bytes is its own business and never travels. Both apps file a
downloaded blob under its hash (bopa in the notebook's `images/`, notable in its shared images
folder), which lets either recover the asset id from the filename in the window between a page
arriving and its pictures being fetched — so a page pushed in that window still names the images
it places instead of dropping references to bytes that are on their way.

### 3.5 Collecting assets nobody references

Everything else in this protocol has a way to stop existing. An asset did not: content-addressed
and immutable, it was written once and never deleted, on the server or on either device. Erasing
the picture removes the `images[]` entry and leaves the bytes; deleting the notebook that held it
leaves them too. The largest objects in the system — PDF backgrounds, routinely tens of megabytes
— were the ones that accumulated fastest, on a server and on a BOOX whose storage is not
generous. This section is how they are reclaimed.

**Why deleting an asset is not like deleting a page.** A page tombstone is irreversible: the
content is gone and no device can reconstruct it. An asset's name *is* a description of its
content, so a device still holding the bytes can put them back under the identical id, and the
peer that was missing the picture then finds it. Deleting an asset is therefore recoverable, and
the worst outcome of sweeping one too eagerly is a picture that is briefly absent on one device
before the next sync restores it. That is what makes a sweep sound without reference counting,
which CouchDB cannot give us — there is no transaction spanning a page and the asset it names.

**The rule that makes recovery real, and it is normative.** An implementation caches the
revisions of documents it has uploaded, and uses "I have a revision for this asset" as "this asset
is on the server, never send it again". Once assets can be swept, that reading is wrong and
silently so. A client **MUST** treat an asset it cannot fetch as one it has not uploaded: a `404`
from `GET /{db}/asset:<sha>/blob`, or from the asset document itself, **MUST** discard any cached
revision for that id and re-queue the asset for push if this device holds the bytes. Without this,
a swept asset that is still referenced is never repaired by the one device that could repair it.

#### 3.5.1 The referenced set

An asset is **referenced** if any **live** document names it:

- a page's `images[].assetId`, or its `background`;
- a notebook's `defaultBackground`.

**Live** means not a `_deleted` tombstone. A **trashed** document — one carrying `deletedAt`
(§3.2) — is live and its references count, because trashing is not deleting and its pages are
still merging normally. A page whose notebook is absent counts too: §6.4 leaves orphan pages
inert rather than deleted, and an asset must not be swept because the only document naming it was
one this device declines to file.

A `null` `assetId` names nothing and is not a reference (§3.4).

#### 3.5.2 `sync-meta:asset-gc:<deviceId>` — one ledger per device

```json
{ "_id": "sync-meta:asset-gc:boox", "type": "sync-asset-gc", "schema": 1,
  "enumeratedAt": "2026-08-18T04:11:02Z",
  "enumeratedThroughSeq": "1849-g1AAAA…",
  "unreferenced": [ { "assetId": "asset:9f2c…", "sinceAt": "2026-07-02T18:40:11Z" } ],
  "updatedAt": "…", "updatedBy": "boox" }
```

| Field | Meaning |
|---|---|
| `enumeratedAt` | When this device last completed a **full** enumeration. Its freshness is what earns the device a vote. |
| `enumeratedThroughSeq` | The server's `update_seq` at the start of that enumeration, so a reader can see what the device had actually caught up to. |
| `unreferenced` | Every asset this device found referenced by nothing, with the instant it *first* found so. |

Single-writer by §1.1: only `boox` writes `sync-meta:asset-gc:boox`. Nothing merges it, and a
device that has never heard of asset collection records it and skips it like any other unknown
`sync-meta:` id.

**Enumerating.** A device may enumerate only when it is **caught up** — its checkpoint is at the
server's current `update_seq` — and its **outbox is empty**. A device with unpushed work holds
references the server cannot see, and its vote would be a lie. It then walks every document,
builds the referenced set of §3.5.1, and rewrites its ledger:

- an asset in the referenced set is **removed** from `unreferenced`, which revives it completely;
- an asset not in it **keeps** its existing `sinceAt` if it has one, and is stamped with now if it
  does not;
- an asset that no longer exists on the server at all is **dropped** from the ledger. Without this
  the ledger is the one thing in the system that still grows without bound, which would be a poor
  result for the section that exists to stop that.

Carrying `sinceAt` forward is the whole clock. Re-stamping it on every sweep would keep every
asset permanently young and nothing would ever be collected — the same mistake §6.6 ("Producing
tombstones") warns against when it forbids re-stamping a `deletedAt`, for the mirror-image reason.

#### 3.5.3 When an asset may be deleted

**Which devices get a vote.** The enumeration already reads every live document, and every one
carries `updatedBy` (§2). The devices that count are exactly the `updatedBy` values it observed —
no registry, no heartbeat, nothing to keep in step. A device is **active** if any live document it
wrote carries an `updatedAt` within the **freshness window, 30 days**; otherwise it is **dormant**
and neither votes nor blocks.

Dormancy is the same bargain §6.6 ("Producing tombstones") already strikes with the device that
stopped syncing: past the horizon it loses its guarantees, and returning is allowed to cost
something. Here that cost is small and self-healing — a device that returns after a year may find
an asset it still references has been swept, and re-uploads it from its own copy under the
identical id (§3.5).

A device deletes `asset:X` only when **all** of these hold:

1. Every **active** device has a `sync-meta:asset-gc:<deviceId>` document, **and there is at least
   one** — the deleting device's own always counts, so the set is never empty. A device that has
   written to this database but publishes no ledger **blocks the sweep entirely**: it is running a
   build that does not know about collection, and it cannot agree to something it has never been
   asked. This is what makes §3.5.5's rollout self-enforcing rather than a switch to remember.
2. Every **active** device's ledger lists `X` in `unreferenced` and carries an `enumeratedAt`
   within the freshness window. A dormant device's stale ledger is ignored, not consulted. An
   active device that is behind on enumerating **blocks the sweep** until it catches up: it may be
   holding a page it has not pushed, and the cost of waiting is disk, while the cost of not
   waiting is a picture vanishing from a device that was merely switched off for a fortnight.
3. The greatest `sinceAt` across those ledgers is at least the **grace period, 30 days**, in the
   past. Taking the greatest rather than the earliest means the clock starts when the *last*
   device agreed, not the first.
4. The deleting device's own enumeration, just completed, still agrees.
5. `asset:X`'s own `createdAt` is older than the grace period. This is what covers the in-flight
   case: assets are pushed before the page that places them (§3.4), so an asset uploaded seconds
   ago is legitimately unreferenced and must never be swept for it.

The grace period matches the 30-day tombstone horizon of §6.6 ("Producing tombstones"), and for
the same reason: it is the point past which a device that stopped syncing is already re-offering
content everyone else has moved on from.

Deletion is the ordinary `_deleted` tombstone of §6.4, written over the asset's current `_rev`.
An asset carries no `deletedAt` and needs none: nothing merges an asset (§5.4), so no rule ever
compares its deletion against an edit.

#### 3.5.4 Sweeping local bytes

A device also reclaims its own blobs, and here it may be stricter than the server because it is
deciding alone. Delete a local blob only when:

- nothing on this device references it, by §3.5.1 applied to local documents;
- it has been so for the grace period; **and**
- the **server still holds the asset document**, so the bytes are re-downloadable.

The last condition is the one that matters. Without it a device that imported a PDF, drew on it,
and deleted those pages before ever syncing would delete the only copy in existence. With it, the
local sweep is strictly safer than the server sweep and needs no agreement from anyone.

#### 3.5.5 Rollout

Same shape as §1.2, and for the same reason — a client must not require what a peer of the
previous release cannot provide:

1. Write your own ledger; delete nothing.
2. Once **both** apps are writing ledgers, deletion may begin — and by rule 1 of §3.5.3 it cannot
   begin sooner, since a peer that publishes no ledger is not a peer that agrees. The gate is
   therefore self-enforcing rather than a switch someone has to remember to throw.

## 4. Ordering primitives

```
millis(ts)         = parsed epoch millis, or Long.MIN_VALUE if unparseable
scalarKey(doc)     = the doc's scalar fields only, rendered as key-sorted minimal JSON:
                     type, schema, createdAt, updatedAt, updatedBy, and per type —
                     page:     notebookId, title, background, backgroundType,
                               pageWidth, pageHeight
                     notebook: title, parentFolderId, defaultBackground, defaultBackgroundType,
                               defaultPageWidth, defaultPageHeight, deletedAt
                     folder:   title, parentFolderId, deletedAt
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

**UTF-8 code-unit order means bytes — including the equality test.** Neither language's
default string comparison implements it: Swift's `<`/`==` read Unicode canonical
equivalence, which files supplementary-plane characters away from their byte order *and*
equates spellings (composed and decomposed `é`) that differ on the wire, so step 2's gate
can be skipped on one side and taken on the other; Kotlin's `compareTo` orders by UTF-16
code unit, which files every supplementary-plane character below parts of the BMP that
UTF-8 files above. Any string tiebreak in the merge — steps 2 and 3 here, the spelling
tiebreak in `earlier`/`later`, and the stroke/image field keys — compares raw UTF-8 bytes.
Pinned by the `tiebreak-*` vectors.

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

> **Float rendering differs between the two apps and that is fine.** Swift's encoder writes a
> whole-valued float as `0`/`1`; Kotlin writes `0.0`/`1.0`. The same document therefore does
> not round-trip byte-identically between the apps. Nothing depends on it: merges compare
> *decoded* values, and the one place a float's textual form could matter — the stroke
> tiebreak — uses the IEEE-754 bit pattern of the decoded value rather than its JSON text.
> Do not "fix" this by pinning a float format; do not introduce any rule that compares raw
> document text.

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

#### 5.2.1 bookmarks — last-writer-wins per page

```
union by pageId, preferring:
    later updatedAt                      // the ordinary case
    then removed=false                   // same instant: the star survives
    then the larger updatedAt string     // same instant and flag: total, so both orders agree
then .filter { $0.pageId ∉ tomb }
then .sortBy(pageId)
```

The `removed=false` step is not a preference so much as a requirement: the two devices must agree,
and agreeing on *something* is what makes the function commutative. Sorting by `pageId` makes the
encoded document byte-stable, so two devices that merged the same pair produce the same body.

Filtering by `tomb` is safe **here** because a bookmark is keyed by the very field being tested:
the same `pageId` is filtered on every future merge, so the drop cannot come undone.

#### 5.2.2 outline — ordered add-wins, content last-writer-wins per entry

```
content = for each id, prefer: later updatedAt
                             then removed=false
                             then the larger updatedAt string
order   = w.outline.ids ++ [ id ∈ o.outline.ids : id ∉ w.outline.ids ]
result  = order.map { content[$0] }        // NOT filtered by tomb — see below
```

Same ordered add-wins rule as `pageIds`, and for the same reason: the outline is a list the reader
reorders wholesale, the rule is already proven here, and it needs no position field on the entry to
stay deterministic.

**The outline is not filtered by `tomb`, though a dangling entry is as useless to tap as a dangling
bookmark.** An entry is keyed by its own `id` while the test would be on `pageId`, and the two can
disagree. If the surviving version of entry `e` points at a deleted page, filtering erases `e` from
the result entirely — and the next merge against a peer that still holds `e` reads it as an entry
this side has never seen and adds it straight back. That is not idempotent, and
`notebook-outline-entry-survives-its-pages-deletion` pins the agreed behaviour.

Instead:

- **Deleting a page marks its outline entries `removed` at the point of deletion**, with a fresh
  `updatedAt`. That is an ordinary edit, which the merge above already carries correctly.
- **Readers skip any entry whose page is not in `pageIds`**, so an entry that outlives its page
  through some path nobody anticipated is invisible rather than broken.

### 5.3 mergeFolder(a, b)

`pick(a, b)`, with `createdAt` merged to the minimum. Folders are names; nothing inside
them can conflict.

### 5.4 mergeAsset(a, b)

Assets are immutable; return either (they are equal by construction).

An asset **tombstone** is applied, never resurrected. §6.4's delete-versus-edit rule has nothing
to weigh here — an asset carries no `deletedAt` and is never edited, so there is no later work to
outlive the deletion. A sweep (§3.5) is undone by re-uploading the bytes under the same id when
some page turns out to still need them, not by a merge arguing with the tombstone.

### 5.1 Page geometry is picked, but a declaration is never dropped

`pageWidth`/`pageHeight` (and `defaultPageWidth`/`defaultPageHeight`) follow `pick` like any
other scalar **except** that the winner's value is only used when it has one:

```
pageWidth(merge(a, b)) = pick(a, b).pageWidth ?? other(a, b).pageWidth
```

A page's sheet describes how the ink already on that page is laid out. A writer that has not
learned the field would otherwise un-declare the size by merely writing last, silently reflowing
every page it touched. The dimensions are also in `scalarKey` (§4): the merge picks them, so
omitting them there would make both argument orders "win" and cost commutativity.

### 5.5 Scalar metadata is last-writer-wins over the whole envelope

Collections merge; independent scalar fields do not. `pick(a, b)` chooses **one complete scalar
envelope** per document — every field listed in `scalarKey` (§4) travels together, decided by
`(millis(updatedAt), updatedBy, scalarKey)`. The loser's scalar values are all discarded, including
the ones the winner never touched. This is the normative behaviour, deliberately, and not an
accident of the tiebreak.

**The known consequence.** The BOOX renames a notebook while offline. The iPad, still carrying the
old title, later draws in it; saving a page also bumps that notebook's `updatedAt`. The iPad's
envelope is therefore newer, it wins, and the rename is lost — even though the ink merged
perfectly, which is what makes it hard to notice. The same shape applies to a page's title against
its background, and a folder's title against a move to a new parent.

**`deletedAt` travels in that envelope too**, and inherits the same consequence: a notebook trashed
on the BOOX comes back out of the Trash if the iPad writes the notebook afterwards — including an
ink-only save, which bumps `updatedAt` (see below). That is deliberate and is the same answer §6.4
gives a permanent deletion: work done after a deletion outlives it. Vector
`notebook-later-edit-outlives-trash` pins it, so an implementation that "fixes" it by treating
`deletedAt` as sticky fails the shared suite rather than diverging quietly. What must **not** be
done is merging `deletedAt` like a tombstone (earliest-wins union, §4): that makes a restore
inexpressible, because the peer still holding the trashed copy re-buries the item on the next
merge, forever.

**An ink-only save does not move the notebook's envelope — and §6.4 no longer needs it to.** The
envelope once did double duty: it decided renames and moves (this section) *and* served as §6.4's
liveness ("this notebook was alive more recently than your deletion"). The ink-save bump kept the
liveness half true at the cost of the first half — drawing on one device silently undid a rename
arriving from the other whenever the ink was later. Both apps have since dropped the bump, and
liveness comes from where the work actually lands instead:

- **The applier of a notebook deletion consults its content clock** — the newest `updatedAt`
  among the pages it holds for that notebook (`CouchLocalStore.contentClock`). The §6.4
  comparison reads `max(envelope updatedAt, content clock)`.
- **A survival the envelope does not show stamps the envelope** to the instant that justified it
  — the resurrection edit. The refused deletion then loses on every peer by the ordinary
  envelope comparison, including peers that never consult a content clock (every build before
  this rule), and the stamp happens only on a deletion refusal, so it cannot re-open the
  rename-clobber this section exists to prevent.

Scenario 12 of §8.1, `delete-vs-later-edit-resurrects`, pins the rename shape; scenario 23,
`ink-only-edit-resurrects`, pins the ink shape — the peer's later edit is a single stroke and
nothing else, so the notebook survives only by way of the content clock. A runner's `draw` op
**MUST** write only the page (bumping the notebook would model a save path neither app has), and
its scenario store **MUST** answer `contentClock` from the page documents it holds, exactly as
the real stores answer it from Room and from the notebook directory.

Two future protocol changes could give independent scalar edits their own answer. Both are future
work; neither is part of this version:

- **(a) Split the two roles.** Add a separate liveness timestamp used only by §6.4, leaving
  `updatedAt` to mean "when these scalars were written". Additive, but still a schema and protocol
  change requiring both apps and the shared vectors to move together.
- **(b) Per-field version information or operation records.** The only thing that genuinely
  preserves independent concurrent scalar edits. Changing the total-order tiebreak does not:
  whatever the tiebreak, one whole envelope still wins.

## 6. Conflict rules beyond field merging

### 6.1 Local-vs-remote on push (`409`)

The pusher re-reads the current remote document (including `_deleted` tombstones — which takes
the two-request read described in §7), merges per §5, and re-PUTs with the fresh `_rev` — unless
the merge result already equals the remote document, in which case the server is up to date and
the push is finished (§7). Bounded retries (5, jittered); on exhaustion the document stays dirty
and is retried on the next flush.

### 6.1a Applying a merge is not overwriting

A merge is computed from a snapshot of the local document, and computing it takes at least one
network round trip — during which the editor goes on saving. When the result is written back, the
implementation **MUST NOT** remove local content merely because the merged document lacks it. Only
content the merge *saw* — present in the snapshot it consumed — and did not keep may be removed.
Anything that arrived since is work the merge knows nothing about.

Getting this wrong is silent and total: the stroke is deleted locally, no tombstone is produced
(so it is not an erasure either), and it was never pushed, so no copy of it exists anywhere. It is
the two-device case the design exists for — drawing on one device while the other edits the same
page — so a store that replaces its stroke set wholesale destroys ink exactly when the system is
doing its job. A test double must honour this rule too; one that overwrites wholesale cannot
reproduce the failure and will hide it.

### 6.2 Remote-vs-local on pull

Every incoming change is merged into the local copy with the same functions. If the merge
result differs from the incoming document, the local side had content the server lacks, so
the document is marked dirty and pushed back.

### 6.3 Echo suppression

A change whose `rev` equals the locally recorded `rev` for that document is this device's
own write coming back and is skipped.

### 6.4 Delete vs edit (notebook, folder)

This section is about **permanent** deletion — the `_deleted` tombstone written when the Trash is
emptied. Throwing something away is not that: it sets `deletedAt` (§3.2) on a document that stays
live, merges under §5.5 like any other scalar, and needs none of the rules below. The two are
sequential, not alternatives — an object is trashed, and later purged.

When one side holds a live document and the other a tombstone:

- `millis(liveness) > millis(tomb.deletedAt)` → **resurrect**: the live document wins
  and is written over the tombstone's `_rev`.
- otherwise → **apply the deletion** locally.

**Liveness** is the live document's `updatedAt` — or, for a notebook, the newest `updatedAt`
among the pages the applier holds for it, whichever is later. Ink deliberately does not move a
notebook's envelope (§5.5), so the envelope alone can no longer answer "was there work after the
deletion"; the pages can. When the survival was justified by a page clock the envelope does not
show, the merged result carries the envelope **stamped to that instant** — the resurrection edit
— so the refusal travels: every peer, on any build, then resolves the same conflict by the
ordinary envelope comparison. The stamp happens only on a deletion refusal, never on a plain
merge, so it cannot hand ink the power over renames that §5.5 removed.

Pages have no independent lifecycle: they live and die with their notebook's `pageIds` /
`deletedPageIds`.

**An unknown `deletedAt` loses.** A tombstone whose body was stripped — a plain HTTP `DELETE`, or
a writer that kept no body — carries no instant. A reader must treat that as *unknown*, which by §4
compares as `Long.MIN_VALUE` and therefore **resurrects**: the live document wins. Stamping the
current time instead makes the deletion newer than any edit the user has ever made, so the rule
above can never fire and a bodyless tombstone silently destroys work done after it. For the same
reason, merging two tombstones keeps a known `deletedAt` in preference to an unknown one rather
than taking the "earlier" of the two.

**A parent invented for an orphan page must not outrank a tombstone.** Pages carry no tombstone of
their own (they live and die with their notebook), so a replay from a lost checkpoint meets
`page:<id>` documents whose notebook has since been deleted. An implementation whose storage
requires the parent to exist before the page can be written — notable's Room schema has that
foreign key — creates a placeholder notebook, and that placeholder is a *live* notebook document at
the deleted notebook's id. Applied naively it wins against the incoming tombstone and the notebook
returns from the dead, untitled and empty. Such an implementation MUST apply the rule above when
creating the placeholder, so a deletion newer than the resurrected parent still stands.

This is a requirement only where a parent is fabricated. bopa's `FileCouchStore` writes the page
file into the notebook's directory and creates no manifest, and both its library listing and its
document enumeration ignore a directory that has no manifest — so an orphan page is inert there,
nothing is resurrected, and the rule has nothing to apply to.

A folder deletion takes **only the folder**. Notebooks and subfolders that named it keep the
`parentFolderId` they have — the merge does not re-home them, because rewriting a document
nobody edited would push a change back at a peer that may still hold the folder alive. What
that leaves is a `parentFolderId` naming a folder this device does not have, which is a display
question rather than a merge one: **a library MUST show such an object at the root**, never
hide it. Hiding it would strand a notebook whose files are still on disk.

The requirement is that **every folder and notebook is drawn exactly once**. Only the objects
with nowhere else to appear are taken to the root — the ones naming a parent the library does
not hold. Their descendants still name a parent that exists, so they keep nesting normally
rather than being listed at the root as well. A `parentFolderId` chain that loops in a
half-merged `folders.json` has no such entry point, so the library picks one member (lowest id,
so the choice is stable across launches) and draws the rest beneath it.

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

**Pruning.** A writer prunes stroke and image tombstones whose `deletedAt` is more than **30
days** old, whenever it is rewriting the document anyway — never as an edit of its own (no
`updatedAt` bump, no push of an otherwise-unchanged document). A tombstone whose `deletedAt`
cannot be parsed is never pruned, since it cannot be shown to be old enough.

Pruning needs no coordination. A peer still holding the longer list unions the pruned
tombstones straight back on merge; that is harmless — the next local write prunes them again,
and they are gone everywhere once every writer is past the horizon. What the horizon actually
bounds is the device that *stopped syncing*: one that last pulled before an erasure and
returns after 30 days re-offers the erased ink as if new. That is the accepted cost of not
growing every page document forever.

Only stroke and image tombstones are ever pruned. `deletedPageIds`, bookmarks, and removed
outline entries are kept indefinitely: they carry structural identity the merge needs (a
pruned outline tombstone resurrects its entry — see §5.2.2), and they grow with deliberate
user actions, not with every sweep of the eraser.

### 6.7 Mass-deletion guard

A flush that would push ≥10 notebook tombstones **and** those tombstones are a strict
majority of the device's known notebooks must be refused pending explicit user
confirmation. This protects against a wiped local database masquerading as intent.

The refusal covers **only the tombstones**. The rest of the flush proceeds: a guard that questions
a suspicious deletion has no business stopping a drawing from reaching the other device, and
holding the whole outbox is not a prompt but a permanent stall. What is reported to the user is the
set of deletions held back — the **document ids**, not merely how many — because the two ways out
below act on exactly that set.

The held tombstones stay in the outbox and are re-offered on every flush until one of two
explicit, one-shot, set-scoped resolutions is applied:

| Resolution | Effect |
|---|---|
| **approve** *(ids)* | The next flush sends exactly those ids past the guard. Every id not named stays held, including ones that reach the outbox afterwards. |
| **discard** *(ids)* | The tombstones are dropped entirely — out of the outbox and out of the store's record of local deletions — and never published. The implementation **MUST** additionally rewind `lastSeq` to `"0"` and forget the discarded ids' recorded revisions, so the next pull replays the documents back onto this device (see below). |

Both are **consumed by the flush that acts on them** and neither is persisted. An approval is an
answer to a question about one batch, not a setting: an implementation MUST NOT let it disarm the
guard for a later batch, and MUST NOT carry it across a restart. A flush that fails before
delivering the approved deletions therefore asks again, which is the safe direction to err in for
an irreversible act.

**Discarding resurrects from the peer, and the user must be told so before choosing.** The
documents are still on the server, so the next pull brings them back to this device. That is the
whole point: a device whose local database was wiped recovers its library by declining to publish
the wipe. It also means "discard" is not "cancel" — an implementation that presents it as merely
dismissing the prompt is presenting the wrong outcome. The two choices are surfaced with distinct
labels naming their consequence (bopa: "Delete them on the server too" / "Keep them on the
server"), and the status message that announces the hold names both actions and where to find them.

**Dropping the tombstones does not by itself bring anything back**, which is why the rewind above
is normative rather than an optimisation. `_changes` announces only documents that have *changed*,
and declining to publish a deletion changes nothing on the server — so a notebook nobody happens to
be editing would never appear on the feed again, and the user would be left with it gone locally,
present remotely, and no path between. Rewinding `lastSeq` replays the feed; forgetting the ids'
recorded revisions is equally required, or the replayed rows match what this device last recorded
and are discarded as its own echoes (§6.3). Both apps do this.

The cost is one full replay, which is exactly what a lost checkpoint costs — already treated here as
safe, because every merge is idempotent. Discarding a mass deletion is a rare, deliberate, already
alarming action, so paying for it with one slow sync is the right trade. An implementation MAY
rewind only far enough to re-announce the discarded ids if it can do so soundly, but MUST NOT leave
them unreachable.

A discard is applied only to ids that are in fact tombstones locally. The list travels through a
report and a user interface before it comes back, and "forget the local deletion of X" applied to a
live document would silently drop a real edit out of the outbox.

### 6.6 Dividing a page that outgrew its sheet

A page is an endless vertical canvas in the file format, and both apps used to treat it as one when
writing: the declared sheet was only where export divided it. So a reader who wrote to the bottom
and carried on made the *page* taller, and everything below the first sheet became invisible to
anything that works in pages — one thumbnail in the overview, one bookmark for the whole scroll, no
way to reorder it. Both apps now divide such a page into one page per sheet.

The division is a local repair, not a wire change: it produces ordinary pages, and a peer that has
never run it sees nothing it cannot already read. But two devices can run it independently on the
same page before either has seen the other, so the result MUST be a function of the page alone:

1. **The sheet** is the page's declared `pageWidth`/`pageHeight`; failing that the notebook's
   default; failing that `1404x1872`. It MUST NOT be the device's screen, which the two apps
   disagree about for undeclared pages (§3.4) and which would divide the same page differently on
   each. Every page produced declares its sheet, so the ambiguity is resolved once.
2. **Sheet index** of a stroke or image is `floor(top / sheetHeight)`, where `top` is `top` for a
   stroke and `y` for an image, clamped at 0. Content is never cut: a stroke crossing a boundary
   belongs whole to the sheet it starts in.
3. **The number of sheets** is one more than the highest sheet index of any content — counted from
   where content *starts*, never from how far it reaches. Counting the extent instead is not
   idempotent: an overhanging stroke would keep the page taller than a sheet, so every run would
   find one sheet more than it fills and file an empty page, for ever.
4. **Sheet 0 keeps the page's id.** Bookmarks (§3.2.1) and outline entries (§3.2.2) name a page id,
   and renaming sheet 0 would strand every one of them.
5. **Sheet `k > 0` takes the id** `uuid(sha256("notable-page-split:" + parentId + ":" + k)[0..16])`
   — the first 16 bytes of the digest, lowercase hex, in UUID shape. Not a UUIDv5; the only
   required property is that both implementations compute the same one. Derived rather than random
   so that two devices dividing the same page produce the *same* pages: with random ids the merge
   would take the union and the notebook would hold every page twice.
6. Content moves with its sheet: `y`, `top`, `bottom` and every encoded point shift by
   `-k * sheetHeight`. `createdAt` is the parent's — these are not new notes — and `scroll` is 0.
7. **Sheet 0 records what left it.** Its `deletedStrokes`/`deletedImages` gain a tombstone
   `(id, deletedAt: now)` for every stroke and image that moved to a child, appended after the
   tombstones the page already carried. Without them a peer still holding the tall copy unions
   the moved ink straight back into the parent on merge; the page re-grows on every pull, each
   side pushes its own version back, and the notebook never converges. Tombstones are scoped to
   the document they ride in ("Producing tombstones", above), so the same ink living on a child
   under the same id is untouched — and a peer that has not learned this rule converges anyway,
   because its merge already honours the lists.
8. **Sheets `k > 0` start with empty tombstone lists.** A tombstone handed to a child could name
   ink that already lives there — moved by an earlier division of the same page, before a peer's
   push re-grew the parent — and would erase it on the next merge. Erasures made while the page
   was tall stay recorded on sheet 0, whose id is the page's own; the one race this concedes (an
   erase-while-tall against a peer's *independent* division, both before either has synced) is
   confined to the migration a divided notebook only goes through once.
9. **A division never overwrites an existing child.** A page can re-grow after it was divided — a
   peer's tall copy merged back in is the usual way — and rebuilding its children from the parent
   alone would discard every stroke drawn on them since. The produced child is folded into the
   existing one through the ordinary page merge (§5) instead.

Vectors: `split-*` in `docs/couch-sync-vectors/vectors.json`, which both suites run —
`split-children-start-clean` pins rules 7 and 8, and the merge vector
`page-split-parent-beats-its-tall-past` pins the convergence they exist for.

## 7. Transport

| Step | Request |
|---|---|
| Read | `GET /{db}/{docid}`, then `GET /{db}/{docid}?open_revs=all` with `Accept: application/json` on a 404 — see below |
| Write | `PUT /{db}/{docid}` with `_rev` when updating; `201` success (`200` for a tombstone), `409` conflict → §6.1 |
| Catch-up | `GET /{db}/_changes?feed=normal&since={seq}&include_docs=true&limit=…` |
| Live | `GET /{db}/_changes?feed=longpoll&since={seq}&include_docs=true&timeout=55000&heartbeat=15000` |
| Attachment | `GET /{db}/{docid}/blob` — reads only; assets are written inline by the document `PUT` (§3.4) |

**Reading a deleted document takes two requests.** A plain `GET` of a tombstoned document is
`404 {"error":"not_found","reason":"deleted"}` — CouchDB does not return the body there, and the
404 is indistinguishable from a document that never existed. Only `?open_revs=all` (with
`Accept: application/json`, or the answer is `multipart/mixed`) returns the deleted leaf and its
body; it 404s when the id is genuinely unknown. This distinction is not cosmetic: a pusher that
reads a tombstone as "absent" retries as a create, and **a `PUT` with no `_rev` over a tombstone
succeeds** — silently resurrecting whatever the peer deleted.

**A tombstone may not be written twice.** `PUT` with `_deleted: true` over an already-deleted
document is a `409` *even when the `_rev` is current*. So when a merge resolves to the remote's
tombstone — or to anything else the server already holds — the pusher must stop, not write the
result back: §6.1's retry loop would otherwise spin to exhaustion and leave the id in the outbox
forever. Restated as a rule: **if the merge result equals the remote document, the push is
already done.**

Equality is not quite enough on its own. Two devices that deleted the same document independently
merge to a tombstone whose `updatedAt` and `updatedBy` differ from the stored one — equal
deletions, unequal documents — and writing that back takes the 409 above. So the full rule is:
**if the merge result equals the remote document, *or* both are tombstones, the push is done.**
There is nothing left to say in either case; the deletion is already recorded.

Auth is HTTP Basic over TLS. `since` checkpoints are persisted locally per device; losing
one is safe (replay from `0` is idempotent), only slower.

Failure classes clients must distinguish: `401/403` (credentials — surface, stop),
`409` (merge, retry), `412/404` (absent — treat as create), `413` (two different answers —
see §7.2), `5xx`/timeout/offline (backoff, keep dirty).

### 7.1 Clock skew (advisory)

Every ordering decision in this protocol is made from **client wall-clock timestamps**: §4's
`pick` resolves every scalar field by `millis(updatedAt)`, and §6.4 resolves delete-versus-edit by
comparing a deletion's instant against an edit's. Nothing anywhere validates those instants. A
device whose clock is ahead therefore does not merely mis-report a time — it *wins* comparisons it
should lose, on both devices, silently: an edit made this morning beats one made this afternoon,
and a deletion made an hour ago destroys work done since.

The fix for that is hybrid logical clocks, which is a protocol change both apps and the shared
vectors must make together. It is **not** part of this version. Detection is the floor, and it is
normative — and what is done with the measurement, in §7.1a, is normative on top of it:

- Every response from an origin server with a clock carries a `Date` header (RFC 9110 §6.6.1).
  Clients read it from **every response the transport returns**, whatever the status — a `404` or
  a `409` is still the server saying what time it thinks it is. A request that failed at the
  transport (offline, DNS, timeout) has no response and says nothing.
- The header is parsed as **IMF-fixdate** (`Sun, 06 Nov 1994 08:49:37 GMT`), with a fixed
  POSIX locale and GMT, so a device set to another language still reads it. The two obsolete
  HTTP date formats are not parsed.
- `skew = localNowAtResponseReceipt − serverDate`, **signed**, in seconds. Positive means the
  client is ahead of the server.
- **Threshold: 120 seconds.** `|skew| >= 120` is significant and is recorded as the client's
  current skew; anything smaller clears it. The threshold is loose on purpose: the header has
  one-second granularity, it is stamped before the response travels, and round-trip latency is
  real — a tighter bound would fire on healthy setups, and a warning that appears when nothing is
  wrong is one nobody reads when something is.
- A missing or unparseable `Date` header is **not** an error and **not** a warning. It is no
  information: the previous observation stands, and nothing is inferred.
- Significant skew is a **non-fatal warning**. It is surfaced in the sync status and the log, and
  the sync continues normally. It MUST NOT fail a request, hold back a push, or block a sync.
- The warning names the **direction** (ahead of / behind the server) and a rough **magnitude**,
  because "your clock is wrong" is not actionable and "about 40 minutes ahead" points straight at
  the device's date and time settings.

### 7.1a Stamping from the corrected clock

The measurement is **applied where a timestamp is made**. Every instant a client writes into a
synced document is its wall clock minus the last measured skew — notable's `SyncClock`, bopa's
`SyncClock`. This does not change the wire format, the merge, or any vector: it changes only what a
client writes into the fields the merge already reads.

Three rules make it safe, and an implementation that keeps only some of them is worse than one that
keeps none:

- **Stamp time, never apply time.** An instant that arrived from a peer is used exactly as sent —
  never clamped, rewritten or second-guessed on the way in. The merge stays a pure function of the
  two documents, so both devices still compute the same result from the same pair. Correcting on
  apply would make the result depend on *which device merged*, which the §8 fixed-point assertions
  exist to forbid.
- **The §6.4 liveness clock is one of them.** Liveness is `max(envelope updatedAt, contentClock)`,
  and `contentClock` is the newest *page* clock — so a skewed device that stamped ink into the
  future would inflate its own liveness and beat a deletion the peer made after the ink. The page
  clocks read the corrected clock for exactly that reason.
- **Every sync-relevant stamp or none of them.** Deletion instants, trash and restore stamps,
  envelope touches, page and stroke clocks, conflict copies, and the tombstone-pruning horizon all
  read the corrected clock. Correcting deletions while leaving edit clocks alone is *worse than not
  correcting at all*: on a device an hour fast the deletions move back an hour while the edits stay
  an hour ahead, and §6.4 resurrects far more eagerly than the uncorrected bug destroys.
- **The measurement is persisted.** The edit that most needs correcting is the one made offline
  after a sync — it happens before any response could re-measure. A device that has never reached
  the server is exactly as wrong as it was before, which is the honest floor.

Two things this deliberately is not. It is **not** a hybrid logical clock: two devices agree only to
the precision of their measurements against a shared server, and nothing here establishes causality
or survives a server whose own clock is wrong. And it is **not** a reason to stop warning — a
corrected clock still writes instants no peer can verify, and the instants already written stay
wrong for ever. Past **300 seconds** the warning is therefore **persistent and prominent** in the
sync settings, not a clause appended to a status line: at that scale no latency explains it, the
damage reads as anything but a clock (a notebook that will not stay out of the Trash, a rename that
will not stick), and the only repair is on the device itself.
### 7.2 `413` is two different answers

A `413` can come from CouchDB, meaning *this document's ordinary fields exceed
`max_document_size`*, or from an intermediary — almost always a reverse proxy — meaning *this
request's body exceeds a cap I was configured with, and I never showed it to CouchDB*. They call
for opposite handling, and a client that conflates them tells the user to fix the wrong thing.

They are cleanly distinguishable, and a client **MUST** distinguish them:

| | CouchDB refused the document | A hop refused the request |
|---|---|---|
| `Content-Type` | `application/json` | anything else (`text/html` from nginx) |
| Body | `{"error":"document_too_large","reason":""}` | an HTML error page, or nothing |
| What is too big | the document's **ordinary fields** | the whole **request body**, attachments included |
| Which documents | only pages, in practice (§3.4) | any document, most often an asset |
| Retrying helps? | not until the content changes | **yes — after the server is reconfigured** |

**The test is the body, not the status.** A `413` whose body parses as JSON with
`error == "document_too_large"` is CouchDB's. Everything else — including a body that fails to
parse, which is what a proxy in an unexpected configuration produces — **MUST** be treated as the
intermediary case, because that is the assumption whose failure mode is recoverable.

Required handling:

- **CouchDB's.** Terminal for that content. An implementation MAY suppress the document until its
  `updatedAt` changes, and MAY hold back documents that name it so a reader never sees a manifest
  pointing at something the server refused. The message names the **page** and says its ink needs
  splitting.
- **An intermediary's.** Configuration, not content, and it **MUST NOT** be suppressed until the
  content changes. Nothing about the document will ever change — the user fixes the server, and no
  local edit follows to lift a suppression keyed on `updatedAt`, so the item would stay stuck
  forever after the problem was solved. Such a refusal **MUST** be re-armed on reconnect, on any
  change to the sync configuration, and on an explicit user-initiated sync. The message says a
  proxy is capping uploads, gives the size that was refused, and names `client_max_body_size` —
  because "too large" without that is not actionable, and §3.4 records that the default cap
  rejects most photographs.

Both messages carry the measured request size. It is the one number that tells the user whether
they are looking at a 900 KB photograph or a 60 MB book.

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

### 8.1 Scenario suite

The vectors check the merge as a function. They cannot check the *engines*: what two devices do to
each other through a real server over a sequence of edits, pushes and pulls. That is
`couch-sync-vectors/interop-scenarios.json`, run by `scripts/couch-scenarios.sh` — bopa executes
the `ipad` steps, notable the `boox` steps, each against one real CouchDB, with each device's
content and sync state persisted between steps so an edit made now and pushed three steps later is
genuinely an offline edit.

There are **23 scenarios**. Both defects §7 describes were found this way and are invisible to a
mock: the mocks had modelled a `GET` of a tombstone as `200`, which no CouchDB does. When a mock
disagrees with the server, fix the mock — the point of it is to be the server.

Two of the 23 are about the same rule and neither replaces the other. Scenario 12,
`delete-vs-later-edit-resurrects`, is delete-vs-edit where the later edit is a **rename**; scenario
23, `ink-only-edit-resurrects`, is the same shape where the later edit is **a stroke and nothing
else**. The second is the one that fails if the notebook `updatedAt` bump on an ink save is ever
removed — see §5.5, which also states the `draw` fidelity requirement both runners must meet.
