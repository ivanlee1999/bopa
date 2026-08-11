#!/usr/bin/env bash
# The merge vectors are a contract between two codebases, so the two copies have to be the same
# file. They drifted once already — bopa grew two `page-rename` vectors that notable never got, and
# because notable's decoder simply dropped the field they described, its suite went on passing while
# a rename made on the iPad was being erased by the BOOX. A vector only tests what both sides parse.
#
#   ./scripts/couch-vectors-parity.sh
#   NOTABLE_DIR=~/src/notable ./scripts/couch-vectors-parity.sh
set -uo pipefail

BOPA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NOTABLE_DIR="${NOTABLE_DIR:-$BOPA_DIR/../notable}"
MINE="$BOPA_DIR/docs/couch-sync-vectors"
THEIRS="$NOTABLE_DIR/app/src/test/resources/couch-sync-vectors"

fail() { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }

[ -d "$THEIRS" ] || { fail "no notable vectors at $THEIRS — set NOTABLE_DIR to your checkout"; exit 1; }

# Only `vectors.json` is duplicated. The scenario file is read straight from this repo by both
# runners (`couch-scenarios.sh` hands notable the path as a Gradle property), so it has one copy and
# cannot drift.
status=0
for name in vectors.json; do
  if [ ! -f "$MINE/$name" ]; then
    fail "missing $MINE/$name"; status=1; continue
  fi
  if [ ! -f "$THEIRS/$name" ]; then
    fail "notable has no $name — copy $MINE/$name to $THEIRS/"; status=1; continue
  fi
  if ! diff -q "$MINE/$name" "$THEIRS/$name" >/dev/null; then
    fail "$name differs between the two repos:"
    diff -u "$MINE/$name" "$THEIRS/$name" | head -40 >&2
    status=1
  fi
done

[ $status -eq 0 ] && echo "couch sync vectors match"
exit $status
