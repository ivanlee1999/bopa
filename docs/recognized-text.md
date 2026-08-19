# Recognized handwriting — the `notes_text` database

Both apps recognize handwriting on-device and publish the result to a CouchDB database that is
**not** the synced library. This document is the contract between the three implementations:
notable (BOOX), bopa (iPad), and the Obsidian plugin.

## Why a second database

Recognized text is derived data. It is regenerable from ink, it has one writer per page at a
time, and nothing in the library refers to it. Putting it in `notes` would have made it a
first-class sync citizen: a new document type in [the sync protocol](couch-sync-protocol.md),
merge rules, entries in the shared conformance vectors, and — because both sync engines
conflict-copy documents whose type they do not recognize into a visible "Unreadable sync copy"
notebook — a two-stage rollout where neither app may write the type until both can read it.

A separate database avoids all of that. The sync engines never open `notes_text`; an app that
knows nothing about recognized text is unaffected by its existence. The cost is that recognized
text does not participate in the library's merge semantics, which is why the freshness rule
below is carried in the document itself rather than derived from sync state.

## Document shape

One document per page, id `pagetext:<pageId>`, so two devices recognizing the same page collide
on one document instead of accumulating duplicates.

```json
{
  "_id": "pagetext:6f1c0a1e-2b7d-4c3a-9f10-1d2e3f4a5b6c",
  "pageId": "6f1c0a1e-2b7d-4c3a-9f10-1d2e3f4a5b6c",
  "notebookId": "b1bf438e-a332-4709-873b-ec034bf33b2c",
  "pageTitle": "Groceries",
  "text": "milk, eggs\nbread",
  "engine": "myscript",
  "language": "en-US",
  "recognizedClock": "2026-08-18T04:11:02.113Z",
  "updatedAt": "2026-08-18T04:11:07.902Z",
  "updatedBy": "boox"
}
```

| Field | Rule |
|---|---|
| `pageId` | The page this text describes. Redundant with `_id`; carried so bodies are self-describing. |
| `notebookId` | Denormalized so the plugin can file the text without reading the page document. May be null; the library in `notes` is authoritative. |
| `pageTitle` | Denormalized for the same reason. May be null — most pages are untitled. |
| `text` | Required. Plain text, lines joined with `\n`. Empty string means "recognized, found nothing". |
| `engine` | `"myscript"` (BOOX firmware) or `"vision"` (Apple). Informational: never used for freshness or conflict decisions. |
| `language` | BCP-47, or null when the engine did not report one. Informational. |
| `recognizedClock` | **The page's `updatedAt` at the moment the recognized strokes were read**, copied verbatim — never a wall-clock stamp. This is what makes freshness comparable across devices with skewed clocks. |
| `updatedAt` | When this recognition ran. Used only to break ties between two recognitions of the same ink. |
| `updatedBy` | `"boox"` or `"ipad"`, matching the sync protocol's device ids. |

## Freshness

Text is **stale** when the page has been edited since it was recognized:

```
stale(text, page) := millis(page.updatedAt) > millis(text.recognizedClock)
```

A page's `updatedAt` also moves for scalar edits like a title change, so a page occasionally
gets re-recognized without its ink having changed. That is accepted: the alternative — the
newest stroke's timestamp — does not move when strokes are *erased*, and an erasure must
trigger re-recognition.

Stale text stays readable everywhere. It is better to search and export slightly outdated text
than none, so readers display it and note that it lags the ink.

## Writing rules

These four rules are what keep two engines from writing over each other forever. All of them
are required of any writer.

1. **Recognize only when the local text is absent or stale.** Text that is fresh but came from
   the *other* engine is left alone — disagreement between MyScript and Vision is not staleness,
   and treating it as staleness is exactly the loop that never converges.
2. **Debounce.** Recognize no sooner than ~5 seconds after the last edit to that page, and on
   page close or app background.
3. **Never write a no-op.** If the recognized text, engine, and language equal what the document
   already holds, do not PUT.
4. **Guard the write against a fresher one.** Before PUTting: GET the current document; if its
   `recognizedClock` is newer than the one being written, abandon the write. On a 409, re-GET
   and re-apply the guard rather than retrying blindly.

Together these bound a race between the two devices to a single round: whichever recognition
describes newer ink wins, and neither device rewrites it afterwards.

## Deletion

A device that deletes a page deletes `pagetext:<pageId>` on a best-effort basis — a failure
here is harmless, so it is never retried. Authoritative cleanup belongs to the Obsidian plugin,
which already reads the library: text whose page appears in no live notebook's `pageIds` is
pruned. Orphaned documents are inert until then; nothing reads text for a page it does not have.

## Access

`notes_text` is provisioned by [`deploy/couchdb/provision.sh`](deploy/couchdb/provision.sh)
and restricted to the same `sync` account as `notes`. CouchDB members may write, so the
plugin's credentials are not read-only in any enforced sense; on a private homeserver that is
acceptable. A `validate_doc_update` design document rejecting writes from the plugin's account
would harden it if the database is ever exposed more widely.
