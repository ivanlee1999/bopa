#!/usr/bin/env bash
# Cross-app sync proof: notable (Kotlin) and bopa (Swift) exchanging one page through a real
# CouchDB, each using its own independent implementation of the document format and the merge.
#
#   1. notable pushes  page:interop-<id>  with one stroke, "boox-stroke"
#   2. bopa pulls it, adds "ipad-stroke", pushes back
#   3. notable pulls again and must see both
#
# Nothing here is mocked: a failure means the two implementations genuinely disagree.
#
# Usage:  ./scripts/couch-interop.sh [couchdb-url]
# Needs:  a CouchDB with the `notes` database (docs/deploy/couchdb), and the notable checkout.
set -euo pipefail

COUCH_URL="${1:-${COUCH_URL:-http://127.0.0.1:5984}}"
COUCH_USER="${COUCH_USER:-sync}"
COUCH_PASSWORD="${COUCH_PASSWORD:-testsyncpw}"
COUCH_DATABASE="${COUCH_DATABASE:-notes}"
NOTABLE_DIR="${NOTABLE_DIR:-/Users/ivan/workspace/eink/notable}"
BOPA_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# A fresh id per run keeps repeated runs from colliding in a shared database.
INTEROP_ID="${COUCH_INTEROP_ID:-$(date +%s)-$$}"
DOC="page:interop-${INTEROP_ID}"

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
gradle_test() {
  (cd "$NOTABLE_DIR" && \
    NOTABLE_COUCH_URL="$COUCH_URL" NOTABLE_COUCH_USER="$COUCH_USER" \
    NOTABLE_COUCH_PASSWORD="$COUCH_PASSWORD" NOTABLE_COUCH_DATABASE="$COUCH_DATABASE" \
    COUCH_INTEROP_ID="$INTEROP_ID" \
    ./gradlew --quiet :app:testDebugUnitTest --tests "$1")
}

say "preflight: $COUCH_URL/$COUCH_DATABASE"
curl -fsS --user "$COUCH_USER:$COUCH_PASSWORD" "$COUCH_URL/$COUCH_DATABASE" >/dev/null
echo "reachable, document for this run: $DOC"

say "step 1 — notable pushes the page"
gradle_test 'com.ethran.notable.sync.couch.CouchInteropTest.interop_step1_boox_pushes_a_page'

say "what landed on the server"
curl -fsS --user "$COUCH_USER:$COUCH_PASSWORD" "$COUCH_URL/$COUCH_DATABASE/$DOC" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  strokes:", [s["id"] for s in d["strokes"]], "updatedBy:", d["updatedBy"])'

say "step 2 — bopa merges its own stroke in and pushes back"
(cd "$BOPA_DIR/NotableKit" && \
  BOPA_COUCH_URL="$COUCH_URL" BOPA_COUCH_USER="$COUCH_USER" \
  BOPA_COUCH_PASSWORD="$COUCH_PASSWORD" BOPA_COUCH_DATABASE="$COUCH_DATABASE" \
  COUCH_INTEROP_ID="$INTEROP_ID" \
  swift test --filter CouchInteropTests 2>&1 | grep -E "Test Case|error:|XCTAssert" || true)

say "what the server holds now"
curl -fsS --user "$COUCH_USER:$COUCH_PASSWORD" "$COUCH_URL/$COUCH_DATABASE/$DOC" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  strokes:", sorted(s["id"] for s in d["strokes"]), "updatedBy:", d["updatedBy"])'

say "step 3 — notable pulls and must see both strokes"
gradle_test 'com.ethran.notable.sync.couch.CouchInteropTest.interop_step3_boox_sees_the_union'

printf '\n\033[1;32mInterop passed:\033[0m both apps read, merged and wrote the same page.\n'
