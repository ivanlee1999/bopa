#!/bin/bash
# Tiered test runner — keeps the edit-verify loop fast.
#
# Usage: ./scripts/test.sh [tier]
#   kit    NotableKit package tests (~1s, no simulator)
#   app    App unit tests (BopaTests) on an iPad simulator (seconds once built)
#   quick  kit + app — the default; run this while iterating and before commits
#   ui     BopaUITests only (~2.5 min — touch synthesis is slow by nature)
#   full   everything; same coverage CI runs on every push/PR
#
# RECORD=1 re-records the snapshot reference images instead of comparing
# (after an intentional visual change). Eyeball the diff before committing.
#
# Known flake: very occasionally a simulator run dies with "Early unexpected
# exit ... before establishing connection". That is the test runner crashing
# before attaching — infrastructure, not the code under test. Rerun once
# before believing it.
set -euo pipefail

TIER="${1:-quick}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# SnapshotTesting reads SNAPSHOT_TESTING_RECORD from the test process; xcodebuild
# only forwards env vars carrying the TEST_RUNNER_ prefix into that process.
if [ -n "${RECORD:-}" ]; then
  export SNAPSHOT_TESTING_RECORD=all
  export TEST_RUNNER_SNAPSHOT_TESTING_RECORD=all
fi

run_kit() {
  echo "==> NotableKit (swift test)"
  swift test --package-path "$ROOT/NotableKit"
}

run_xcode() { # extra xcodebuild args, e.g. -only-testing:BopaTests
  cd "$ROOT/App"
  command -v xcodegen >/dev/null && xcodegen generate >/dev/null

  local udid
  udid=$(xcrun simctl list devices available -j | jq -r '
    [.devices | to_entries[]
     | select(.key | contains("SimRuntime.iOS"))
     | .value[] | select(.name | startswith("iPad"))] | .[0].udid // empty')
  if [ -z "$udid" ]; then
    echo "No iPad simulator available:" >&2
    xcrun simctl list devices available >&2
    exit 1
  fi
  xcrun simctl bootstatus "$udid" -b

  echo "==> xcodebuild test $*"
  xcodebuild test \
    -project Bopa.xcodeproj \
    -scheme Bopa \
    -destination "id=$udid" \
    -destination-timeout 120 \
    "$@" \
    CODE_SIGNING_ALLOWED=NO
}

case "$TIER" in
  kit)   run_kit ;;
  app)   run_xcode -only-testing:BopaTests ;;
  ui)    run_xcode -only-testing:BopaUITests ;;
  quick) run_kit; run_xcode -only-testing:BopaTests ;;
  full)  run_kit; run_xcode ;;
  *)     echo "usage: $0 [kit|app|quick|ui|full]" >&2; exit 1 ;;
esac
