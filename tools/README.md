# Tools

CLI utilities working directly on a Notable on-device database
(`Documents/notabledb/app_database`, copy it off the BOOX e.g. via BooxDrop).

Build (from repo root):

```bash
swiftc -O NotableKit/Sources/NotableKit/{Polyline,StrokePoint,SBStrokeCodec}.swift tools/dbverify/main.swift -o /tmp/dbverify
swiftc -O NotableKit/Sources/NotableKit/{Polyline,StrokePoint,SBStrokeCodec,WireModels}.swift tools/dbimport/main.swift -o /tmp/dbimport
```

- `dbverify <app_database>` — decodes every stroke blob with NotableKit's SB codec and
  prints stats; proves byte-level format compatibility against real device data.
- `dbimport <app_database> <outputRoot>` — converts the database into the sync/local-store
  layout (`notebooks/<id>/manifest.json` + `pages/*.json`), normalizing legacy raw
  pressure. Point outputRoot at the app's `Documents/notable` to import real notebooks
  without any server.
- `dbexport <app_database> <storeRoot> [notebookId ...]` — the reverse: writes the app's
  local store back into a (copy of a) Notable database, carrying iPad edits to the BOOX
  without a server. WAL-checkpointed; replace `app_database` on-device with Notable
  force-stopped and the old `-wal`/`-shm` files deleted.

Build dbexport:

```bash
swiftc -O NotableKit/Sources/NotableKit/{Polyline,StrokePoint,SBStrokeCodec,WireModels}.swift tools/dbexport/main.swift -o /tmp/dbexport
```
