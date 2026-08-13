#!/bin/bash
# Empty the CouchDB database the end-to-end tests share, so the suite stays fast.
#
#   ./scripts/couch-reset.sh                       # the local test container
#   ./scripts/couch-reset.sh http://host:5984 notes
#
# Why this exists: every device in `CouchAppLayerEndToEndTests` and `CouchEndToEndTests` starts
# from an empty checkpoint and replays the whole feed, so the suite's cost grows with everything
# every previous run left behind. Deleting documents does not help — a tombstone is another
# sequence — so the database has to be recreated. Left alone it goes from seconds to minutes and
# then starts timing out, which reads as flakiness rather than as a fault with an address.
#
# Admin credentials are required: the `sync` account is a database member, not a server admin, and
# a member cannot drop a database. They are read from the environment, or from the local CouchDB
# container when one is running. They are never printed.
#
#   COUCHDB_ADMIN_USER=admin COUCHDB_ADMIN_PASSWORD=… ./scripts/couch-reset.sh
#
# SAFETY: this refuses to touch a database that looks like a real library. Test documents are
# namespaced per run (`e2e-ipad-3f1a…`, `held 4 9c2b…`); a notebook someone actually made is not.
# The check is deliberately conservative — it would rather stop on a database full of test data
# than delete one notebook that mattered. `--force` overrides it, and prints what it is overriding.
set -uo pipefail

URL="${1:-${COUCH_URL:-http://127.0.0.1:5984}}"
DATABASE="${2:-${COUCHDB_DATABASE:-notes}}"
SYNC_USER="${COUCHDB_SYNC_USER:-sync}"
FORCE="${FORCE:-}"
[ "${1:-}" = "--force" ] && { FORCE=1; URL="${COUCH_URL:-http://127.0.0.1:5984}"; }
[ "${2:-}" = "--force" ] && FORCE=1
[ "${3:-}" = "--force" ] && FORCE=1

die() { printf '\033[1;31m%s\033[0m\n' "$*" >&2; exit 1; }
say() { printf '\033[1m%s\033[0m\n' "$*"; }

# --- credentials -------------------------------------------------------------------------------

ADMIN_USER="${COUCHDB_ADMIN_USER:-}"
ADMIN_PASSWORD="${COUCHDB_ADMIN_PASSWORD:-}"

if [ -z "$ADMIN_PASSWORD" ] && command -v docker >/dev/null 2>&1; then
  # The local test container carries its own admin credentials. Reading them here means the common
  # case needs no arguments at all — and no password typed anywhere it might be recorded.
  for container in eink-couch couchdb; do
    env_dump=$(docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null) || continue
    [ -n "$env_dump" ] || continue
    ADMIN_USER="${ADMIN_USER:-$(printf '%s' "$env_dump" | sed -n 's/^COUCHDB_USER=//p')}"
    ADMIN_PASSWORD=$(printf '%s' "$env_dump" | sed -n 's/^COUCHDB_PASSWORD=//p')
    [ -n "$ADMIN_PASSWORD" ] && { say "Using admin credentials from the '$container' container."; break; }
  done
fi

[ -n "$ADMIN_PASSWORD" ] || die "No admin credentials. Set COUCHDB_ADMIN_USER and COUCHDB_ADMIN_PASSWORD."
ADMIN_USER="${ADMIN_USER:-admin}"
AUTH=(--user "$ADMIN_USER:$ADMIN_PASSWORD")

# --- look before deleting ----------------------------------------------------------------------

curl -fsS "${AUTH[@]}" "$URL/_all_dbs" >/dev/null 2>&1 \
  || die "Cannot authenticate as '$ADMIN_USER' at $URL, or the server is unreachable."

if ! curl -fsS "${AUTH[@]}" "$URL/$DATABASE" >/dev/null 2>&1; then
  say "$URL/$DATABASE does not exist; creating it."
else
  docs=$(curl -fsS "${AUTH[@]}" "$URL/$DATABASE/_all_docs?include_docs=true&limit=2000") \
    || die "Could not read $URL/$DATABASE."

  verdict=$(printf '%s' "$docs" | python3 -c '
import sys, json, re

rows = json.load(sys.stdin).get("rows", [])
# A test device id carries the run namespace the suites append: "e2e-ipad-3f1a2b4c". The bare
# "ipad"/"boox" pair belongs to the hand-wired integration tests, whose ids are suffixed instead
# ("page:0ec9351d-longpoll", "page:interop-1786566052-8011").
namespaced = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*-[0-9a-f]{6,}$")
integration = re.compile(r"-(shared|longpoll|converge|erase|roundtrip|exists|feed|stale)$|^interop-")

real = []
for row in rows:
    doc = row.get("doc") or {}
    doc_id = row.get("id", "")
    if doc_id.startswith("sync-meta:"):
        continue
    by = str(doc.get("updatedBy", ""))
    ident = doc_id.split(":", 1)[-1]
    if namespaced.match(by) or integration.search(ident):
        continue
    real.append((doc_id, doc.get("title")))

print(json.dumps({"total": len(rows), "real": real[:5], "real_count": len(real)}))
') || die "Could not inspect the documents in $DATABASE."

  total=$(printf '%s' "$verdict" | python3 -c 'import sys,json;print(json.load(sys.stdin)["total"])')
  real_count=$(printf '%s' "$verdict" | python3 -c 'import sys,json;print(json.load(sys.stdin)["real_count"])')
  say "$DATABASE holds $total documents; $real_count do not look like test fixtures."

  if [ "$real_count" -gt 0 ]; then
    printf '%s' "$verdict" | python3 -c '
import sys, json
for doc_id, title in json.load(sys.stdin)["real"]:
    print(f"    {doc_id}  {title!r}")
'
    if [ -z "$FORCE" ]; then
      die "Refusing to delete $URL/$DATABASE — it does not look like a test database.
Check the address: the tests use 127.0.0.1:5984, which is not the server your devices sync to.
Re-run with --force if you are certain."
    fi
    say "--force given; deleting anyway."
  fi
fi

# --- recreate ----------------------------------------------------------------------------------

security=$(curl -fsS "${AUTH[@]}" "$URL/$DATABASE/_security" 2>/dev/null)
case "$security" in
  *'"members"'*) ;;
  # A database with no security object is readable by any authenticated user. Restore the shape
  # `docs/deploy/couchdb/provision.sh` sets rather than leaving it open.
  *) security="{\"admins\":{\"names\":[],\"roles\":[]},\"members\":{\"names\":[\"$SYNC_USER\"],\"roles\":[]}}" ;;
esac

curl -fsS "${AUTH[@]}" -X DELETE "$URL/$DATABASE" >/dev/null 2>&1
curl -fsS "${AUTH[@]}" -X PUT "$URL/$DATABASE" >/dev/null || die "Could not create $DATABASE."
curl -fsS "${AUTH[@]}" -X PUT "$URL/$DATABASE/_security" \
  -H 'Content-Type: application/json' -d "$security" >/dev/null \
  || die "Created $DATABASE but could not restore its security object — it is currently open to any authenticated user."

say "Reset $URL/$DATABASE. Members: $(printf '%s' "$security" | python3 -c 'import sys,json;print(",".join(json.load(sys.stdin)["members"]["names"]) or "(none)")')"
