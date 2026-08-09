#!/bin/bash
# List the children of a WebDAV collection (PROPFIND Depth: 1).
# Usage:
#   BOPA_WEBDAV_HOST=https://host BOPA_WEBDAV_USER=you ./scripts/webdav-ls.sh /share/notable/notebooks
set -uo pipefail

HOST="${BOPA_WEBDAV_HOST:-}"
USER_NAME="${BOPA_WEBDAV_USER:-}"
PATH_ARG="${1:-/}"

if [ -z "$HOST" ] || [ -z "$USER_NAME" ]; then
  echo "usage: BOPA_WEBDAV_HOST=https://host BOPA_WEBDAV_USER=you $0 <path>" >&2
  exit 1
fi
HOST="${HOST%/}"

printf "Password for %s (input hidden): " "$USER_NAME"
read -rs PASSWORD
echo
echo "== PROPFIND $HOST$PATH_ARG"

curl -sS -X PROPFIND -H "Depth: 1" -u "${USER_NAME}:${PASSWORD}" "$HOST$PATH_ARG/" \
  | python3 -c '
import sys, re, urllib.parse
xml = sys.stdin.read()
hrefs = re.findall(r"<[a-zA-Z]*:?href>(.*?)</[a-zA-Z]*:?href>", xml)
if not hrefs:
    print("(no entries — check the path, or the server returned an error)")
    print(xml[:400])
else:
    base = urllib.parse.unquote(hrefs[0]).rstrip("/")
    for h in hrefs[1:]:
        name = urllib.parse.unquote(h).rstrip("/").rsplit("/", 1)[-1]
        kind = "dir " if h.endswith("/") else "file"
        print(f"  {kind} {name}")
    print(f"({len(hrefs)-1} entries under {base})")
'
