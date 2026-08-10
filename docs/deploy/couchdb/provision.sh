#!/usr/bin/env bash
# Creates the notes database and the non-admin sync account, then locks the database to it.
# Idempotent: re-running reports "already exists" rather than failing.
#
#   cp .env.example .env && $EDITOR .env
#   ./provision.sh                      # against COUCHDB_URL from .env
#   COUCHDB_URL=http://192.168.1.10:5984 ./provision.sh   # or override for first-run on the LAN
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { echo "No .env — copy .env.example to .env and fill it in." >&2; exit 1; }
set -a; . ./.env; set +a

: "${COUCHDB_URL:?}" "${COUCHDB_ADMIN_USER:?}" "${COUCHDB_ADMIN_PASSWORD:?}"
: "${COUCHDB_SYNC_USER:?}" "${COUCHDB_SYNC_PASSWORD:?}" "${COUCHDB_DATABASE:?}"

admin=(--user "${COUCHDB_ADMIN_USER}:${COUCHDB_ADMIN_PASSWORD}")

# Body first, status code last, so both can be reported.
call() {
  local method=$1 path=$2 data=${3-}
  local args=(-sS -o /tmp/couch-provision-body -w '%{http_code}' -X "$method" "${admin[@]}")
  [ -n "$data" ] && args+=(-H 'Content-Type: application/json' -d "$data")
  local code
  code=$(curl "${args[@]}" "${COUCHDB_URL}${path}")
  printf '%s %-34s -> %s %s\n' "$method" "$path" "$code" "$(head -c 120 /tmp/couch-provision-body)"
  case "$code" in 2*|412) return 0 ;; *) return 1 ;; esac
}

echo "== reachable? =="
curl -fsS "${COUCHDB_URL}/_up" "${admin[@]}" >/dev/null && echo "up"

echo "== system databases (single_node should have made these) =="
call PUT /_users        || true
call PUT /_replicator   || true

echo "== application database =="
call PUT "/${COUCHDB_DATABASE}"

echo "== sync account =="
call PUT "/_users/org.couchdb.user:${COUCHDB_SYNC_USER}" \
  "{\"name\":\"${COUCHDB_SYNC_USER}\",\"password\":\"${COUCHDB_SYNC_PASSWORD}\",\"roles\":[],\"type\":\"user\"}" \
  || echo "  (already exists — delete it first if you need to rotate the password)"

echo "== restrict the database to that account =="
call PUT "/${COUCHDB_DATABASE}/_security" \
  "{\"admins\":{\"names\":[],\"roles\":[]},\"members\":{\"names\":[\"${COUCHDB_SYNC_USER}\"],\"roles\":[]}}"

echo
echo "== verifying as the sync user =="
sync=(--user "${COUCHDB_SYNC_USER}:${COUCHDB_SYNC_PASSWORD}")
curl -fsS "${admin[@]}" "${COUCHDB_URL}/${COUCHDB_DATABASE}" >/dev/null && echo "admin can read the db"
curl -fsS "${sync[@]}"  "${COUCHDB_URL}/${COUCHDB_DATABASE}" >/dev/null && echo "sync user can read the db"

# Anonymous access must fail: this is the check that catches require_valid_user not applying.
if curl -fsS "${COUCHDB_URL}/${COUCHDB_DATABASE}" >/dev/null 2>&1; then
  echo "WARNING: the database is readable WITHOUT credentials — check config/10-sync.ini" >&2
  exit 1
fi
echo "anonymous access correctly refused"

rm -f /tmp/couch-provision-body
echo
echo "Done. Point both apps at ${COUCHDB_URL}, database '${COUCHDB_DATABASE}',"
echo "user '${COUCHDB_SYNC_USER}'."
