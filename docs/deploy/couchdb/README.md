# CouchDB on the NAS

Server side of [the CouchDB sync plan](../../couchdb-sync-plan.md). One container, one
database, one non-admin account that both apps share.

## Setup

```bash
mkdir -p /volume1/docker/couchdb && cd /volume1/docker/couchdb
# copy docker-compose.yml, config/10-sync.ini, .env.example, provision.sh here

cp .env.example .env
# fill in passwords; for the Erlang cookie: openssl rand -hex 32
```

**Create the data directory with the right owner before the first start.** The image runs as
uid/gid `5984`, and on a NAS share it will not be able to create its own directory:

```bash
mkdir -p data && sudo chown -R 5984:5984 data
```

Then:

```bash
docker compose up -d
docker compose logs -f couchdb     # wait for "Apache CouchDB has started"
chmod +x provision.sh && ./provision.sh
```

`provision.sh` creates the `notes` database and the `sync` account, restricts the database to
that account, and then verifies that anonymous access is refused — that last check is the one
that catches `require_valid_user` silently not applying.

Run it against the LAN address first if TLS is not up yet:

```bash
COUCHDB_URL=http://192.168.1.10:5984 ./provision.sh
```

## Exposing it publicly

Put it behind the same Synology reverse proxy that serves `webdav.liyifan.us`:
`couch.liyifan.us` → `localhost:5984`, with a Let's Encrypt certificate. Mobile clients
require an OS-trusted certificate, so a self-signed one will not work.

Two proxy settings matter, and the second one is the one that bites silently.

**The read timeout.** Near-real-time sync works by holding a
`GET /_changes?feed=longpoll` request open until something changes. The client asks
for a 55-second window, chosen to sit under the common 60-second proxy default — so most
proxies need no change. If yours times out sooner, sync still works but each idle period ends
in a reconnect; lower the client's `timeoutMs` to a few seconds under the proxy's limit rather
than raising the proxy, since idle reconnects are cheap and a stuck connection is not.

**The request body limit — `client_max_body_size`.** Pictures and PDF backgrounds travel as a
single document with the bytes inlined as a base64 attachment, so an asset upload is the largest
request the apps ever make. **nginx defaults this to 1 MB**, which — after base64 inflates the
bytes by 4/3 — rejects any asset over roughly 768 KiB. That is every photograph a phone takes.

The failure mode is the reason this is called out rather than left to defaults: notes and ink
keep syncing perfectly, because a page document is 15–80 KB. Only pictures stop arriving, on
both devices, with a `413` that never reaches CouchDB's log because CouchDB never saw the
request.

```nginx
client_max_body_size 128m;    # headroom for a 60 MB PDF at 4/3 base64 inflation
```

On the Synology reverse proxy this lives in Control Panel → Login Portal → Advanced →
Reverse Proxy → edit the entry → Custom Header, or in a snippet under
`/usr/local/etc/nginx/conf.d/` if you manage nginx directly. Whichever way you set it,
re-run `provision.sh`: it probes the ceiling by PUTting asset-shaped documents of 1, 8 and
32 MiB through `COUCHDB_URL` — the same path the apps use, proxy included — and reports the
largest that got through.

Do not publish port 5984 to the internet directly. With `require_valid_user = true` there is
no anonymous surface, but TLS terminates at the proxy and that is where it should stay.

## Maintenance

Weekly compaction (Synology Task Scheduler, or cron):

```bash
curl -sS -X POST -H 'Content-Type: application/json' \
  --user "$COUCHDB_ADMIN_USER:$COUCHDB_ADMIN_PASSWORD" \
  "$COUCHDB_URL/notes/_compact"
```

Backups: Hyper Backup over `/volume1/docker/couchdb/data` is enough. For a
restore-anywhere copy that does not depend on CouchDB's on-disk format:

```bash
curl -sS --user "$COUCHDB_ADMIN_USER:$COUCHDB_ADMIN_PASSWORD" \
  "$COUCHDB_URL/notes/_all_docs?include_docs=true" | gzip > "notes-$(date +%F).json.gz"
```

Health: `GET /_up` for liveness, `GET /notes` for document count and disk size.

## Checking it by hand

The same commands the sync engine issues, useful for confirming the round trip end to end:

```bash
AUTH="--user sync:<sync password>"; URL=https://couch.liyifan.us/notes

curl -sS $AUTH -X PUT "$URL/page:test" -H 'Content-Type: application/json' \
  -d '{"type":"page","schema":1,"notebookId":"nb","strokes":[],"deletedStrokes":[],
       "images":[],"deletedImages":[],"createdAt":"2026-08-10T00:00:00Z",
       "updatedAt":"2026-08-10T00:00:00Z","updatedBy":"laptop"}'

curl -sS $AUTH "$URL/page:test"
curl -sS $AUTH "$URL/_changes?since=0&include_docs=true"
```

To watch the live feed the way the apps do — this should block, then return the moment you
write a document from another shell:

```bash
curl -sS $AUTH "$URL/_changes?feed=longpoll&since=now&timeout=55000"
```

## Notes

- Defaults are fine for document size, and the reason is worth knowing because it is easy to
  get backwards. `max_document_size` (8,000,000) is measured against the JSON body **with
  attachment data removed**, so an asset is never refused by CouchDB no matter how large:
  measured against stock 3.3 and 3.5, a 60 MiB PDF inlined as `_attachments.blob.data` is
  accepted and reads back with a matching SHA-256. What the limit does govern is ordinary
  fields, which means **pages** — 15–80 KB today, two orders of magnitude of headroom.
  The limit that actually stops assets is the proxy's, above.
- `revs_limit` needs no tuning. The engine pushes with the last known `_rev` and merges on
  409, so the revision tree stays linear instead of accumulating conflict branches.
- The admin credentials are for setup and maintenance only. The apps hold the `sync` account,
  which cannot read any other database.
