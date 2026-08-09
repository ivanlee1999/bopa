#!/bin/bash
# Diagnose (and work around) a WebDAV server that rejects HEAD on directories —
# the failure mode behind Notable reporting 404/403 on Synology shares.
#
# Usage:
#   BOPA_WEBDAV_URL=https://host/share BOPA_WEBDAV_USER=you ./scripts/webdav-check.sh
#   ./scripts/webdav-check.sh https://host/share you
set -u

BASE="${1:-${BOPA_WEBDAV_URL:-}}"
USER_NAME="${2:-${BOPA_WEBDAV_USER:-}}"

if [ -z "$BASE" ] || [ -z "$USER_NAME" ]; then
  echo "usage: $0 <base-url> <username>   (or set BOPA_WEBDAV_URL / BOPA_WEBDAV_USER)" >&2
  exit 1
fi
BASE="${BASE%/}"

printf "Password for %s (input hidden): " "$USER_NAME"
read -rs PASSWORD
echo

auth=(-u "${USER_NAME}:${PASSWORD}")

code() { curl -sS -o /dev/null -w "%{http_code}" -m 15 "$@"; }

echo "== 1. HEAD on base (what Notable's test does)"
head1=$(code -I "${auth[@]}" "$BASE/")
echo "   HEAD $BASE/ -> $head1"

echo "== 2. PROPFIND on base (real WebDAV check)"
prop=$(code -X PROPFIND -H "Depth: 0" "${auth[@]}" "$BASE/")
echo "   PROPFIND $BASE/ -> $prop"

if [ "$prop" != "207" ]; then
  echo "RESULT: PROPFIND failed ($prop) — URL or credentials problem, stop here."
  exit 1
fi

if [ "$head1" = "200" ]; then
  echo "RESULT: HEAD already works — Notable should connect. If it still 404s, the URL in Notable differs from $BASE"
  exit 0
fi

echo "== 3. Applying fix: uploading empty index.html so Apache can answer HEAD"
put=$(code -T /dev/null "${auth[@]}" "$BASE/index.html")
echo "   PUT index.html -> $put"

echo "== 4. Re-testing HEAD"
head2=$(code -I "${auth[@]}" "$BASE/")
echo "   HEAD $BASE/ -> $head2"

if [ "$head2" = "200" ]; then
  echo "RESULT: FIXED — retry the connection test in Notable now (URL: $BASE)"
else
  echo "RESULT: HEAD still $head2 after index.html — DirectoryIndex likely disabled; report this back."
fi
