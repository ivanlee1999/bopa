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
# Older .env files predate recognized text; default rather than fail on them.
COUCHDB_TEXT_DATABASE=${COUCHDB_TEXT_DATABASE:-notes_text}

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

echo "== recognized-text database =="
call PUT "/${COUCHDB_TEXT_DATABASE}"

echo "== sync account =="
call PUT "/_users/org.couchdb.user:${COUCHDB_SYNC_USER}" \
  "{\"name\":\"${COUCHDB_SYNC_USER}\",\"password\":\"${COUCHDB_SYNC_PASSWORD}\",\"roles\":[],\"type\":\"user\"}" \
  || echo "  (already exists — delete it first if you need to rotate the password)"

echo "== restrict the databases to that account =="
security="{\"admins\":{\"names\":[],\"roles\":[]},\"members\":{\"names\":[\"${COUCHDB_SYNC_USER}\"],\"roles\":[]}}"
call PUT "/${COUCHDB_DATABASE}/_security"      "$security"
call PUT "/${COUCHDB_TEXT_DATABASE}/_security" "$security"

echo
echo "== verifying as the sync user =="
sync=(--user "${COUCHDB_SYNC_USER}:${COUCHDB_SYNC_PASSWORD}")
curl -fsS "${admin[@]}" "${COUCHDB_URL}/${COUCHDB_DATABASE}" >/dev/null && echo "admin can read the db"
curl -fsS "${sync[@]}"  "${COUCHDB_URL}/${COUCHDB_DATABASE}" >/dev/null && echo "sync user can read the db"
curl -fsS "${sync[@]}"  "${COUCHDB_URL}/${COUCHDB_TEXT_DATABASE}" >/dev/null && echo "sync user can read the text db"

# Anonymous access must fail: this is the check that catches require_valid_user not applying.
for db in "${COUCHDB_DATABASE}" "${COUCHDB_TEXT_DATABASE}"; do
  if curl -fsS "${COUCHDB_URL}/${db}" >/dev/null 2>&1; then
    echo "WARNING: '${db}' is readable WITHOUT credentials — check config/10-sync.ini" >&2
    exit 1
  fi
done
echo "anonymous access correctly refused"

# ---------------------------------------------------------------------------
# Upload ceiling. Pictures and PDF backgrounds travel as one document with the
# bytes inlined as a base64 attachment, so the largest request the apps ever
# make is an asset upload. CouchDB does not limit that — max_document_size is
# measured with attachment data removed — but anything in front of it does, and
# nginx's client_max_body_size defaults to 1 MB. That rejects any asset over
# roughly 768 KiB once base64 has inflated it: every photograph a phone takes.
#
# The failure is invisible from the CouchDB side, which is why this probes
# through COUCHDB_URL — the same path the apps use, proxy included.
# ---------------------------------------------------------------------------
echo
echo "== upload ceiling (asset-shaped PUTs through ${COUCHDB_URL}) =="
probe_doc=/tmp/couch-provision-asset.json
probe_id="asset:provision-probe"
ceiling=0

for mib in ${COUCHDB_ASSET_PROBE_MIB:-1 8 32}; do
  # Same wire shape as a real asset: bytes inlined at _attachments.blob.data.
  # base64 wraps by default on both GNU and BSD, and a newline inside a JSON
  # string is invalid, so the wrapping is stripped rather than switched off
  # with a flag the two implementations spell differently.
  b64=$(dd if=/dev/zero bs=1048576 count="$mib" 2>/dev/null | base64 | tr -d '\n')
  printf '{"type":"asset","schema":1,"contentType":"application/octet-stream",'      > "$probe_doc"
  printf '"_attachments":{"blob":{"content_type":"application/octet-stream",'       >> "$probe_doc"
  printf '"data":"%s"}}}' "$b64"                                                    >> "$probe_doc"
  unset b64

  rev=$(curl -sS "${admin[@]}" "${COUCHDB_URL}/${COUCHDB_DATABASE}/${probe_id}" \
        | sed -n 's/.*"_rev":"\([^"]*\)".*/\1/p')
  code=$(curl -sS -o /tmp/couch-provision-body -w '%{http_code}' -X PUT "${admin[@]}" \
         -H 'Content-Type: application/json' --data-binary @"$probe_doc" \
         "${COUCHDB_URL}/${COUCHDB_DATABASE}/${probe_id}${rev:+?rev=$rev}")

  if [ "$code" = 201 ] || [ "$code" = 202 ] || [ "$code" = 200 ]; then
    printf '  %3s MiB asset -> %s ok\n' "$mib" "$code"
    ceiling=$mib
    continue
  fi

  printf '  %3s MiB asset -> %s\n' "$mib" "$code"
  if [ "$code" = 413 ]; then
    if grep -q document_too_large /tmp/couch-provision-body 2>/dev/null; then
      echo "  CouchDB itself refused it. That is unexpected for an asset — raise" >&2
      echo "  [couchdb] max_document_size in config/10-sync.ini." >&2
    else
      echo "  Something in front of CouchDB refused it before CouchDB saw it —" >&2
      echo "  the response is not CouchDB's JSON error. Raise the body limit on" >&2
      echo "  the reverse proxy (nginx: client_max_body_size 128m; Synology:" >&2
      echo "  Control Panel > Login Portal > Advanced > Reverse Proxy > Custom" >&2
      echo "  Header, or the nginx snippet in README.md)." >&2
    fi
    echo "  Until then, assets of ${mib} MiB and above will never sync." >&2
  else
    echo "  Unexpected status; body: $(head -c 200 /tmp/couch-provision-body)" >&2
  fi
  break
done

# Remove the probe document whatever happened, so it never reaches a client.
rev=$(curl -sS "${admin[@]}" "${COUCHDB_URL}/${COUCHDB_DATABASE}/${probe_id}" \
      | sed -n 's/.*"_rev":"\([^"]*\)".*/\1/p')
if [ -n "$rev" ]; then
  curl -sS -o /dev/null -X DELETE "${admin[@]}" \
    "${COUCHDB_URL}/${COUCHDB_DATABASE}/${probe_id}?rev=${rev}"
fi
rm -f "$probe_doc"

if [ "$ceiling" -gt 0 ]; then
  echo "  largest asset accepted: ${ceiling} MiB"
else
  # Same standing as the anonymous-access check above: the deployment is up and
  # will look healthy, while a whole class of content silently never arrives.
  echo "  WARNING: even the smallest probe was refused — no picture will ever sync." >&2
  rm -f /tmp/couch-provision-body
  exit 1
fi

rm -f /tmp/couch-provision-body
echo
echo "Done. Point both apps at ${COUCHDB_URL}, database '${COUCHDB_DATABASE}',"
echo "user '${COUCHDB_SYNC_USER}'. Recognized handwriting goes to '${COUCHDB_TEXT_DATABASE}'"
echo "with the same account; the Obsidian plugin reads both."
