#!/bin/bash
# List the children of a WebDAV collection (PROPFIND Depth: 1).
# Usage: ./scripts/webdav-ls.sh [path]        e.g. ./scripts/webdav-ls.sh /onyx/notable/notebooks
set -uo pipefail

HOST="${BOPA_WEBDAV_HOST:-https://webdav.liyifan.us}"
USER_NAME="${BOPA_WEBDAV_USER:-ivan}"
PATH_ARG="${1:-/onyx}"

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
