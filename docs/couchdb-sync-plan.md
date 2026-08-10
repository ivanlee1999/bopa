# CouchDB Sync — Full Plan & Implementation Detail

Replaces WebDAV sync in both apps with a CouchDB-backed, offline-first engine with
near-real-time propagation and automatic, lossless ink merging.

- **bopa** (iPad, Swift/PencilKit) — this repo
- **notable** (BOOX, Kotlin, Notable fork) — `/Users/ivan/workspace/eink/notable`
- **Server** — CouchDB 3.x in Docker on the Synology NAS, exposed publicly over HTTPS

Existing WebDAV data is disposable (per Ivan): no migration. Fresh database; devices
seed it by pushing their local content.

---

## 1. Goals / non-goals

**Goals**

1. Offline-first: both apps fully usable with no network; all edits queue and sync on reconnect.
2. Near-real-time: while both apps are foregrounded, an edit appears on the other device in ≤ ~2 s.
3. Automatic merge for ink: two devices editing the same page offline merge losslessly, never a prompt.
4. No silent data loss, ever: where auto-merge is impossible, produce a conflict copy (OneNote model), never last-writer-wins.
5. No client-clock dependence in any sync decision (kills the clock-skew class of bugs).

**Non-goals**

- Migrating existing WebDAV data (wiped instead).
- More than 2–3 devices, multi-user, or E2EE (single user; TLS + auth is the boundary).
- Live multi-cursor collaboration on the same open page (phase-2 nicety, not required).
- PouchDB or any embedded replica DB. Local storage stays what it is today
  (bopa: files under `Documents/notable/`; notable: Room). Only the transport changes.

**Key architectural choices** (rationale researched from obsidian-livesync, Apple
Notes, GoodNotes, OneNote, reMarkable, CouchDB docs — see §10):

| Choice | Decision | Why |
|---|---|---|
| Client library | Hand-rolled thin HTTP client in each app | No maintained native CouchDB client exists for Swift/Kotlin (Couchbase Lite is protocol-incompatible; CDTDatastore/cloudant-sync abandoned). Needed surface is ~5 endpoints. |
| Conflict strategy | **Merge-on-409 upsert loop**, revision tree never branches | Simpler than full replication protocol (`new_edits:false` + conflict leaves); eliminates conflict-leaf accumulation and `revs_limit` pitfalls entirely. Correct for a small fixed device set. |
| Ink merge | **2P-set CRDT**: stroke set union minus tombstone union | The convergent industry answer (Apple Notes stroke records, GoodNotes event log, whiteboard CRDTs). Deterministic, commutative, idempotent, needs no common ancestor. |
| Page granularity | One doc per page, whole stroke array | Pages are 15–80 KB in practice; CouchDB `max_document_size` default is 8 MB. livesync-style chunking exists for multi-MB files and is unnecessary complexity here. |
| Realtime channel | `_changes` longpoll while foregrounded | Sub-second push latency, plain HTTP, no websockets, resumable via `since=` checkpoint. |

---

## 2. Server setup (NAS, public exposure)

### 2.1 Container

`docker-compose.yml` on the NAS:

```yaml
services:
  couchdb:
    image: couchdb:3
    container_name: couchdb
    restart: unless-stopped
    ports:
      - "5984:5984"          # LAN only; public access goes through the reverse proxy
    environment:
      COUCHDB_USER: admin
      COUCHDB_PASSWORD: "<strong admin password, only used for setup/ops>"
    volumes:
      - /volume1/docker/couchdb/data:/opt/couchdb/data
      - /volume1/docker/couchdb/etc:/opt/couchdb/etc/local.d
```

`local.d/10-sync.ini`:

```ini
[couchdb]
single_node = true

[chttpd]
require_valid_user = true
bind_address = 0.0.0.0

[chttpd_auth]
require_valid_user = true
```

Defaults are fine for `max_document_size` (8 MB) and `revs_limit` (irrelevant here —
the upsert-loop design never branches the revision tree).

### 2.2 One-time provisioning (run from the Mac)

```bash
CDB=https://couch.liyifan.us   # or http://<nas-lan-ip>:5984 during setup
AUTH='admin:<adminpw>'

# system dbs (single-node requirement)
curl -su "$AUTH" -X PUT $CDB/_users
curl -su "$AUTH" -X PUT $CDB/_replicator

# the one app database
curl -su "$AUTH" -X PUT $CDB/notes

# dedicated non-admin sync user — the ONLY credential the apps hold
curl -su "$AUTH" -X PUT $CDB/_users/org.couchdb.user:sync \
  -H 'Content-Type: application/json' \
  -d '{"name":"sync","password":"<strong sync password>","roles":[],"type":"user"}'

# lock the db down to that user
curl -su "$AUTH" -X PUT $CDB/notes/_security \
  -H 'Content-Type: application/json' \
  -d '{"admins":{"names":[],"roles":[]},"members":{"names":["sync"],"roles":[]}}'
```

### 2.3 Public exposure hardening

- **Reverse proxy** (Synology's built-in one, same as webdav.liyifan.us): new host
  `couch.liyifan.us` → `localhost:5984`, Let's Encrypt cert. Mobile clients require an
  OS-trusted cert — no self-signed.
- Proxy timeouts must exceed the longpoll window: read timeout ≥ 90 s (client uses
  `timeout=55000`). If nginx-based, `proxy_buffering off` (longpoll stalls otherwise)
  and `client_max_body_size 16M`.
- `require_valid_user = true` means zero anonymous surface — every request needs the
  `sync` (or admin) credential. Do not expose port 5984 directly; only 443 via proxy.
- Optional but recommended on Synology: enable auto-block (fail2ban-style) on the
  reverse proxy, and Geo/IP allowlist if you never sync from abroad.
- Keep the `couchdb:3` image updated (Watchtower or manual monthly pull).

### 2.4 Ops

- **Compaction**: weekly NAS task: `curl -su admin:… -X POST $CDB/notes/_compact -H 'Content-Type: application/json'`.
- **Backup**: Hyper Backup of `/volume1/docker/couchdb/data`, plus (belt-and-braces)
  a nightly JSON dump: `curl -su … "$CDB/notes/_all_docs?include_docs=true" | gzip > notes-$(date +%F).json.gz`.
- **Monitoring**: `GET /_up` for liveness; `GET /notes` reports doc count + disk size.

---

## 3. Document model

One database `notes`. All docs carry `type`, `schema: 1`, `updatedAt` (ISO-8601 UTC,
display/tiebreak only — never a sync decision), and `updatedBy` (device id string:
`"ipad"` / `"boox"`).

IDs are type-prefixed: `notebook:<uuid>`, `page:<uuid>`, `folder:<uuid>`,
`asset:<sha256>`. UUIDs are lowercase. Titles never appear in IDs.

### 3.1 `folder:<uuid>`

```json
{
  "_id": "folder:9db4c182-977b-4b22-8a3f-e7d3d8205846",
  "type": "folder", "schema": 1,
  "title": "study",
  "parentFolderId": null,
  "createdAt": "2026-06-06T22:30:07.555Z",
  "updatedAt": "2026-06-06T22:30:07.555Z",
  "updatedBy": "boox"
}
```

Per-folder docs replace `folders.json`. Deletion = PUT with `"_deleted": true` plus
`deletedAt`/`updatedBy` retained in the body (deleted docs still flow through
`_changes` with `include_docs`, so the other device sees a real tombstone). **This
fixes the folder-resurrection bug both apps currently share.**

### 3.2 `notebook:<uuid>`

```json
{
  "_id": "notebook:b1bf438e-a332-4709-873b-ec034bf33b2c",
  "type": "notebook", "schema": 1,
  "title": "tese2",
  "pageIds": ["64d92c8c-9f36-4de7-838c-f21df150ec9e"],
  "deletedPageIds": [{ "id": "…", "deletedAt": "…" }],
  "parentFolderId": null,
  "defaultBackground": "blank",
  "defaultBackgroundType": "native",
  "createdAt": "2026-08-10T06:12:04.299Z",
  "updatedAt": "2026-08-10T06:12:33.871Z",
  "updatedBy": "ipad"
}
```

- `deletedPageIds` is the tombstone set that lets pageIds merge without resurrecting
  deleted pages.
- `openPageId`, scroll positions, `linkedExternalUri` are **device-local and never sync**.
- Notebook deletion = `_deleted: true` + `deletedAt` in body; delete-vs-edit is
  resolved by comparing the surviving edit's `updatedAt` to `deletedAt` (edit newer →
  resurrect, matching notable's current rule, now race-free because it happens inside
  the 409 loop).

### 3.3 `page:<uuid>`

```json
{
  "_id": "page:64d92c8c-9f36-4de7-838c-f21df150ec9e",
  "type": "page", "schema": 1,
  "notebookId": "b1bf438e-a332-4709-873b-ec034bf33b2c",
  "background": "blank",
  "backgroundType": "native",
  "createdAt": "…", "updatedAt": "…", "updatedBy": "boox",
  "strokes": [
    {
      "id": "f705be87-d2c8-4a88-95d7-0291a1e4dd21",
      "createdAt": "2026-08-10T02:43:18.751Z",
      "deviceId": "boox",
      "pen": "FOUNTAIN", "color": -16777216, "size": 4.48,
      "maxPressure": 1,
      "top": 312, "bottom": 393, "left": 214, "right": 262,
      "pointsData": "U0IC…"      // existing SB binary format, unchanged
    }
  ],
  "deletedStrokes": [{ "id": "…", "deletedAt": "…" }],
  "images": [{ "id": "…", "assetId": "asset:<sha256>", "x": 0, "y": 0, "w": 0, "h": 0 }],
  "deletedImages": [{ "id": "…", "deletedAt": "…" }]
}
```

- The stroke DTO is **exactly today's wire format** (`docs/notable-sync-protocol.md`
  §4) — both apps already serialize it; only the envelope changes.
- Erasing a stroke: remove it from `strokes`, append `{id, deletedAt}` to
  `deletedStrokes`. Partial-stroke erase = tombstone the original + add fragments as
  new strokes (new UUIDs). A stroke id is never reused → remove-wins is safe.
- Typical size 15–80 KB; hard ceiling 8 MB is two orders of magnitude away. If a page
  ever approaches 1 MB of strokes, the app splits nothing — it just works; assets are
  attachments and don't count toward document size.

### 3.4 `asset:<sha256>` (images / PDF backgrounds)

```json
{ "_id": "asset:9f2c…", "type": "asset", "schema": 1, "contentType": "image/png",
  "_attachments": { "blob": { "content_type": "image/png", "data": "<base64>" } } }
```

Content-addressed by SHA-256 of the bytes → immutable, deduplicated, **conflicts
impossible** (concurrent PUTs of the same asset write identical content; a 409 is
resolved by treating it as already-present). Fetched lazily on first render, cached
locally forever.

---

## 4. Merge specification (must be bit-identical in Swift and Kotlin)

All merges are pure functions `merge(a, b) -> m` that are **commutative,
associative, and idempotent**. No common ancestor is needed. `newer(a,b)` means:
compare `updatedAt`; tie → higher `updatedBy` (ASCII); tie → either (identical).

### 4.1 `mergePage(a, b)`

```
tombS = unionById(a.deletedStrokes, b.deletedStrokes)   // keep earliest deletedAt per id
tombI = unionById(a.deletedImages,  b.deletedImages)
m.strokes = unionById(a.strokes, b.strokes)             // keep the copy from newer(a,b) if both have id
            .filter(s => s.id not in tombS)
            .sortBy(s => (s.createdAt, s.id))           // deterministic z-order
m.images  = analogous with tombI
m.deletedStrokes = tombS ; m.deletedImages = tombI
m.background, m.backgroundType, m.notebookId = from newer(a, b)
m.createdAt = min(a.createdAt, b.createdAt)
m.updatedAt = max(a.updatedAt, b.updatedAt) ; m.updatedBy = newer(a,b).updatedBy
```

Result: both devices' offline drawings appear; an erase always sticks; identical
inputs merge to themselves (idempotence makes replays free).

### 4.2 `mergeNotebook(a, b)`

```
n = newer(a, b); o = other
tomb = unionById(a.deletedPageIds, b.deletedPageIds)
m = scalar fields (title, parentFolderId, defaults) from n
m.pageIds = n.pageIds ++ (o.pageIds - n.pageIds preserving o's relative order)
            filtered by tomb
m.deletedPageIds = tomb
timestamps as in mergePage
```

Ordered add-wins union: the newer device's ordering is the base; pages known only to
the older doc are appended in their relative order; tombstoned pages drop out.

### 4.3 `mergeFolder(a, b)` — plain `newer(a, b)` (LWW; folders are just names).

### 4.4 Deletion vs edit (notebooks, folders)

When the 409 loop or the changes feed pairs a live doc with a `_deleted` tombstone:
`live.updatedAt > tomb.deletedAt` → resurrect (PUT live over the tombstone's `_rev`);
otherwise apply the deletion locally. Pages don't need this: page life is governed by
the owning notebook's `pageIds`/`deletedPageIds`.

### 4.5 Un-mergeable fallback — conflict copy, never data loss

If a doc fails to decode, or `schema` is newer than the app understands, or any merge
precondition is violated: do **not** guess. Materialize the remote version as a new
local object titled `"<title> (conflict <date> <device>)"` with fresh UUIDs, keep the
local version as-is, and let both sync. (OneNote conflict-page / Nebo
duplicate-on-conflict tier.)

### 4.6 Shared test vectors

`docs/couch-sync-vectors/*.json` in this repo, mirrored into notable's
`app/src/test/resources/couch-sync-vectors/` (CI job asserts the two directories are
identical). Each vector:

```json
{ "name": "erase-vs-draw", "kind": "page", "a": {…}, "b": {…}, "expected": {…} }
```

Both test suites iterate every vector and assert `merge(a,b) == merge(b,a) ==
expected` and `merge(expected, a) == expected`. Minimum vector set: disjoint draws;
draw-vs-erase same stroke; both erase; re-erase after merge; image add/remove; title
LWW tie; pageIds reorder + add; pageIds delete-vs-add; tombstone precedence;
idempotent self-merge; scalar tiebreak by deviceId.

---

## 5. Sync engine (same design, two implementations)

### 5.1 Local bookkeeping

```
CouchSyncState {
  lastSeq: String            // _changes checkpoint ("0" initially)
  revs:   { docId: rev }     // last _rev this device wrote or applied
  dirty:  Set<docId>         // outbox
}
```

- bopa: `.bopa-couch-state.json` next to the store (replaces `.bopa-sync-state.json`).
- notable: two Room tables `couch_doc_state(docId PK, rev, dirty)` and
  `couch_checkpoint(id=0, lastSeq)` (replace `notebook_sync_state`/`page_sync_state`).

Every local mutation (stroke commit, erase, rename, page add/delete, folder change)
marks the owning doc(s) dirty. Losing this state is harmless: all docs re-push
(409 → merge → typically identical) and the feed replays from 0 — slow, not wrong,
because merge is idempotent.

### 5.2 Push — debounced flush + merge-on-409 upsert loop

Trigger: ~3 s after last pen-up / mutation (coalesced), plus on page close, app
background, and reconnect. Pseudocode:

```
flush():
  for docId in dirty (assets first, then pages, then notebooks, then folders):
    body = encodeLocal(docId); body._rev = revs[docId]  // absent for new docs
    resp = PUT /notes/{docId}
    if 201: revs[docId] = resp.rev; dirty.remove(docId)
    elif 409:
      remote = GET /notes/{docId}?deleted=true          // may be a tombstone
      merged = merge(local, remote)                      // or delete-vs-edit rule
      writeLocal(merged)                                 // local store adopts merge
      body = merged; body._rev = remote._rev; retry (≤5, jittered)
    elif 401/403: stop, surface "check credentials"
    else (5xx, timeout, offline): keep dirty, exponential backoff, stop this flush
```

Ordering (assets → pages → notebooks) preserves today's invariant: a reader never
sees a notebook referencing a page that hasn't landed.

### 5.3 Pull — longpoll `_changes` while foregrounded

```
pullLoop():
  while app is active:
    resp = GET /notes/_changes?feed=longpoll&since={lastSeq}
           &include_docs=true&timeout=55000&heartbeat=15000
    for change in resp.results:
      if revs[change.id] == change.rev: continue         // our own echo
      incoming = change.doc                              // may be _deleted
      merged = merge(localOrEmpty(change.id), incoming)  // idempotent
      writeLocal(merged)
      if merged != incoming: dirty.add(change.id)        // local had extra → push back
      else: revs[change.id] = change.rev
    lastSeq = resp.last_seq; persistState()
  on network error: backoff 1s→2s→…→60s, resume from lastSeq
```

Cold start / reconnect: run one `feed=normal` catch-up first, flush the outbox, then
enter longpoll. Latency while both apps are open: one RTT after the debounce —
**sub-second on LAN, ~1–2 s over the internet.**

### 5.4 Applying pulls to the UI

- Library/list views: refresh on any applied change (both apps already have
  notification paths for this).
- Open editor: phase 1 — apply to any page **not currently on canvas**; the on-canvas
  page applies on page-switch or editor close (replaces bopa's current
  whole-notebook `uploadOnly` deferral, which becomes unnecessary). Phase 2
  (optional) — live-inject merged strokes into the open canvas.

### 5.5 Deleted things

- Notebook delete in UI → PUT `_deleted` tombstone doc (body keeps `deletedAt`),
  remove locally. Keep notable's mass-deletion guard: refuse to tombstone ≥10
  notebooks in one flush without explicit confirmation.
- Old stroke tombstones: prunable locally once `deletedAt` is > 30 days old (both
  devices sync far more often than that); pruning is safe because remove-wins only
  matters while the other side might still hold the stroke.

---

## 6. bopa implementation (this repo)

### 6.1 New code — `NotableKit/Sources/NotableKit/Couch/`

| File | Contents |
|---|---|
| `CouchDBClient.swift` | Thin client over the existing `HTTPTransport` (Basic auth reuse): `getDoc`, `putDoc`, `deleteDoc`, `changes(since:feed:)`, `putAttachment/getAttachment`, typed errors (`.conflict`, `.unauthorized`, `.offline`, `.server`). ~200 lines. |
| `CouchModels.swift` | `Codable` doc DTOs from §3. Reuses the existing stroke/image DTOs in `WireModels.swift` verbatim; adds envelopes + tombstone arrays. Explicit-null encoding stays (notable's parser now uses `ignoreUnknownKeys`, but keep the convention). |
| `Merge.swift` | Pure functions from §4. No I/O. This is the file the shared vectors test. |
| `CouchSyncState.swift` | State struct + JSON persistence (`.bopa-couch-state.json`), lenient decoding. |
| `CouchSyncEngine.swift` | `flush()`, `pullOnce()`, `pullLoop()` from §5; local read/write via `NotebookStore` paths; conflict-copy fallback; mass-delete guard. |

### 6.2 Changed code

- `App/Sources/SyncSettings.swift` — new backend enum (`webdav` | `couchdb`), fields:
  server URL, database name (default `notes`), username, password, deviceId
  (default `"ipad"`). Keep WebDAV settings for one release as escape hatch.
- `App/Sources/SyncCoordinator.swift` — when backend == couchdb: replace the 120 s
  poll with a `pullLoop` `Task` started on `.active` and cancelled on `.background`;
  `noteEdited` debounce drops 20 s → 3 s and calls `flush()`; `syncNow` = catch-up +
  flush. The conflict list shrinks to conflict-copies only (informational, not
  blocking).
- `App/Sources/NotebookStore.swift` — mutations also mark docs dirty (small hook where
  `didChangeLocallyNotification` already fires); eraser path records
  `deletedStrokes` tombstones (the persistence from the "Save what the eraser rubbed
  out" commit becomes the tombstone source).
- `App/Sources/LibraryView.swift` / `ConflictResolutionView.swift` — remove the
  blocking conflict flow for ink; keep a simple list showing conflict-copies.
- `EditorView` — on page switch/close, re-read the page from the store (picks up
  merged strokes).

### 6.3 Removed (after cutover)

`SyncPlanner.swift` decision logic, WebDAV reconcile paths in `SyncEngine.swift`,
`ConflictResolutionView` rebaseline machinery (the known-broken path), `.bopa-sync-state.json`,
`RemoteIndex` (badges now derive from `dirty` set: "N pending" vs "synced").

### 6.4 Tests (per `scripts/test.sh` tiers)

- `kit`: `MergeTests` (drive the shared vectors + property checks: commutativity,
  idempotence on 200 randomized pages), `CouchSyncEngineTests` against a new
  `MockCouchServer` (in-memory doc store with `_rev` bumping, 409 on stale rev,
  scripted `_changes`) — port the shape of `MockWebDAVServer`. Scenarios: fresh push,
  echo suppression, 409 merge, delete-vs-edit both directions, checkpoint replay,
  offline outbox growth + drain, conflict-copy on bad schema.
- `app`: `SyncCoordinatorTests` — debounce, lifecycle of the pull task, badge counts.
- `ui`: none needed (no interaction plumbing changes in phase 1).

---

## 7. notable implementation (`/Users/ivan/workspace/eink/notable`)

### 7.1 New code — `app/src/main/java/com/ethran/notable/sync/couch/`

| File | Contents |
|---|---|
| `CouchDbClient.kt` | OkHttp wrapper: same five operations + longpoll call with 90 s read timeout; Basic auth; typed `CouchResult` sealed class. |
| `CouchModels.kt` | kotlinx-serialization DTOs (§3), reusing the stroke/image DTOs from `serializers/NotebookSerializer.kt`. |
| `Merge.kt` | §4 pure functions — mirror of bopa's `Merge.swift`. |
| `CouchSyncEngine.kt` | flush / pullOnce / pullLoop; reads-writes Room via existing repositories; conflict-copy fallback; keeps `looksLikeStaleStateWipe` guard. |
| `CouchSyncState` | Room entities `couch_doc_state`, `couch_checkpoint` + DAO (migration adds tables, drops the old sync-state tables at cutover). |

### 7.2 Changed code

- **Sync-on-save (the big BOOX fix):** `PageDataManager.bumpEditTimestamps()`
  (`data/PageDataManager.kt:1052`) additionally marks the page + notebook docs dirty
  and pokes a debouncer (3–5 s after last stroke) that calls `flush()` on an
  application-scope coroutine. Uploads no longer wait for note-close or the 15-min
  periodic job.
- **Foreground pull loop:** lifecycle-aware coroutine (ProcessLifecycleOwner
  `ON_START`/`ON_STOP`) running `pullLoop()`. E-ink battery cost is one idle HTTP
  longpoll — negligible while the app is open, and it stops when backgrounded.
- **Background catch-up:** keep the WorkManager periodic job (15 min, network-
  constrained) but its body becomes `pullOnce() + flush()`. Keep `ExistingWorkPolicy`
  but switch Sync Now to `REPLACE` so taps are never silently dropped (tonight's
  tese2 lesson).
- `SyncSettings.kt` — backend switch + CouchDB fields (URL, db, user, password,
  deviceId `"boox"`). Remove upload-only/download-only modes (root cause of tonight's
  silent skip; force-replace flows survive as explicit one-shot actions implemented
  as "mark everything dirty" / "reset revs + pull from 0").
- Delete: `SyncPreflightService` clock-skew check, `NotebookSyncPlanner` timestamp
  window, LWW overwrite path in `NotebookReconciliationService` (the silent-data-loss
  path), tombstone `deletions/` handling.
- Editor: on page switch/close re-read from Room; check-on-open banner becomes
  unnecessary (the pull loop keeps state fresh).

### 7.3 Tests

JVM unit tests: `MergeTest` driving the same shared vectors (CI asserts vector
parity with bopa), `CouchSyncEngineTest` against a `FakeCouchServer` (OkHttp
`MockWebServer`-based, same scenarios as bopa's list). Instrumented: one smoke test
that a stroke commit marks docs dirty and the debouncer fires.

---

## 8. Error / edge-case matrix

| Situation | Behavior |
|---|---|
| Offline (any duration) | App fully usable; `dirty` grows; badge "offline · N pending"; drain on reconnect (connectivity callbacks: `NWPathMonitor` / `ConnectivityManager`). |
| Both drew on same page offline | Union merge at first contact — all strokes survive. |
| Draw vs erase of same stroke | Tombstone wins deterministically on both devices. |
| Both renamed notebook | LWW by `updatedAt`, deviceId tiebreak. Low stakes, automatic. |
| Delete vs edit (notebook/folder) | Edit newer than `deletedAt` → resurrect; else delete. Inside 409 loop → race-free. |
| 409 storm (simultaneous pushes) | Upsert loop converges — merge is commutative; ≤5 retries then keep dirty + backoff. |
| Longpoll drop / proxy timeout | Backoff, resume from `lastSeq`. Heartbeat 15 s keeps proxies from buffering to death. |
| Checkpoint/state lost (reinstall) | Replay from seq 0 + full re-push; idempotent merges make this safe, only slow. **This replaces bopa's current "wall of conflicts on state loss."** |
| Crash mid-flush | Docs are independent; re-push of a landed doc 409s into an identical merge. |
| Doc fails schema/decode | Conflict copy (§4.5). Never blocks the rest of the sync. |
| Asset upload interrupted | Content-addressed: retry PUT is idempotent; pages referencing a missing asset render a placeholder and re-fetch on demand (fixes notable's "404 never retried"). |
| Server credential rotation | 401 surfaces immediately as a settings prompt; nothing is lost (outbox persists). |
| Tombstone/db growth | Stroke-tombstone pruning after 30 d; weekly `_compact`; deleted-doc tombstones are permanent but tiny (single-user scale: irrelevant). |
| Mass deletion (wiped device state) | `looksLikeStaleStateWipe`-style guard on flush: ≥10 notebook tombstones in one batch requires explicit user confirmation. |

---

## 9. Rollout plan

Each phase lands as a PR (bopa: branch off `main` here; notable: its own branch).
`quick` tier before every commit per the testing standard.

> **Status (2026-08-10).** Phase 0 is **done in both repos**, and bopa's engine (phase 3's
> kit half) is done ahead of order because it defined the contract notable implements.
> bopa branch `claude/notebook-sync-ipad-boox-02adc8`; notable branch `claude/couchdb-sync`.
>
> | Piece | bopa | notable |
> |---|---|---|
> | Protocol spec + vectors | ✅ `docs/couch-sync-protocol.md`, `docs/couch-sync-vectors/` | ✅ vectors copied byte-identical |
> | Merge (vector-driven) | ✅ `CouchMerge.swift` | ✅ `sync/couch/Merge.kt` |
> | Document models | ✅ `CouchModels.swift` | ✅ `sync/couch/CouchModels.kt` |
> | Tombstone derivation | ✅ `CouchTombstones.swift` | ⬜ |
> | CouchDB client | ✅ `CouchDBClient.swift` | ⬜ |
> | Sync engine | ✅ `CouchSyncEngine.swift` (+ `MockCouchServer`) | ⬜ |
> | Storage mapping | ✅ `CouchMapping.swift` | ⬜ (needs a `deleted_stroke` Room table) |
> | Local-store adapter + app wiring | ⬜ | ⬜ |
> | Server on the NAS | ⬜ | — |
>
> Two findings changed the design mid-flight, both recorded in the spec:
> **(a)** neither app records erasures today, so tombstones must be *derived* by diffing the
> stroke-id set at save time (§6.6 of the protocol) — notable additionally needs a new table,
> since it hard-deletes stroke rows; **(b)** the merge tiebreaks had to become total orders
> and float comparison had to move to IEEE-754 bit patterns, or Swift and Kotlin disagree.

**Phase 0 — Spec + vectors (both repos, ~1 day)** — **done**
Write `docs/couch-sync-protocol.md` (§3–§5 of this plan, normative), author the
vector set, add the vector-parity CI check. *Accept: both repos' vector tests exist
and fail (no impl yet) / are skipped.*

**Phase 1 — Server (~1 hour)**
§2 on the NAS; verify from the Mac with curl (PUT/GET/changes longpoll through the
public URL, TLS cert valid). *Accept: longpoll returns a change pushed from a second
curl within 1 s.*

**Phase 2 — Merge + engine in notable (~2–3 days)**
§7 complete behind the backend setting, WebDAV path untouched. *Accept: unit suite
green; on-device smoke: stroke → visible in `curl` within ~5 s; airplane-mode edits
drain on reconnect.*

**Phase 3 — Merge + engine in bopa (~2–3 days)**
§6 complete behind the backend setting. *Accept: kit+app suites green; simulator
smoke against the real NAS.*

**Phase 4 — Two-device cutover (~half a day)**
Erase old WebDAV tree (`curl -X DELETE …/onyx/notable/` — recycle bin keeps a copy),
wipe or keep local data per device (fresh start: pick one device to seed, or let both
push and delete any duplicate same-name notebooks once, since duplicates from the
WebDAV era have distinct UUIDs and will both appear). Switch both apps to couchdb.
Test matrix: both online drawing on different pages; same page simultaneously; BOOX
airplane-mode edit + iPad edit same page → reconnect → union visible both sides;
delete on one + edit on other; kill app mid-stroke-flush.
*Accept: all matrix cells pass; latency both-foregrounded ≤ 2 s.*

**Phase 5 — Cleanup (later release)**
Remove WebDAV engines, planners, conflict-resolution rebaseline UI, old state
files/tables from both repos. Keep a manual "export notebook to file" for backups.

---

## 10. Research sources

Design inputs (fetched 2026-08-10):

- obsidian-livesync: [data structure](https://github.com/vrtmrz/obsidian-livesync/blob/main/docs/datastructure.md) · [conflict resolution spec](https://github.com/vrtmrz/obsidian-livesync/blob/main/docs/specs_conflict_resolution.md) · [GC spec](https://github.com/vrtmrz/obsidian-livesync/blob/main/docs/specs_garbage_collection.md) · [tech info](https://github.com/vrtmrz/obsidian-livesync/blob/main/docs/tech_info.md) — borrowed: local-first mirror, eager conflict resolution, "deterministic winner is not authoritative", ops checklist. Skipped: chunking/CDC (built for multi-MB files), E2EE chunk addressing, full PouchDB replication.
- CouchDB: [replication protocol](https://docs.couchdb.org/en/stable/replication/protocol.html) · [conflict model](https://docs.couchdb.org/en/stable/replication/conflicts.html) · [PouchDB conflicts guide](https://pouchdb.com/guides/conflicts.html) (upsert-loop pattern) · [smaller-docs guidance](https://dev.to/neighbourhoodie/couchdb-data-modelling-prefer-smaller-documents-4585) · [3.0 defaults](https://docs.couchdb.org/en/stable/whatsnew/3.0.html)
- Native clients: [Couchbase Lite is not CouchDB-compatible](https://www.couchbase.com/forums/t/can-couchbase-lite-2-0-sync-with-couchdb-without-sync-gateway/16834/5) · [CDTDatastore (deprecated)](https://github.com/cloudant/CDTDatastore) · [Cloudant SDK EOL](https://blog.cloudant.com/2021/06/30/Cloudant-SDK-Transition.html)
- Ink merge precedents: [Apple Notes format/CRDT reverse-engineering](https://github.com/dunhamsteve/notesutils/blob/master/notes.md) · [Goodnotes event-sourced CRDT sync engine](https://job-boards.greenhouse.io/goodnotes/jobs/5736918004) · [P2P whiteboard stroke-set design](https://medium.com/bpxl-craft/building-a-peer-to-peer-whiteboarding-app-for-ipad-2a4c7728863e) · [OneNote conflict pages](https://microsoft.public.onenote.narkive.com/n5ia84c5/onenote-synchronization-and-conflict-pages) · [reMarkable CAS-index cautionary tale](https://akeil.de/posts/remarkable-cloud-api/) · [Nebo duplicate-on-conflict](https://help.myscript.com/notes/export-sync-and-back-up/cloud-sync/)
