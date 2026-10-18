#!/bin/bash
# Record the exact tested app's identity. Simulator/Catalyst CI disables signing; this evidence
# must never be mistaken for an Apple Distribution or Developer ID archive.
set -euo pipefail
APP="${1:?usage: verify-build.sh /path/to/Bopa.app}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$APP/Info.plist"
[ -f "$PLIST" ] || PLIST="$APP/Contents/Info.plist"
version=$(awk '/MARKETING_VERSION:/ {print $2; exit}' "$ROOT/App/project.yml")
build=$(awk '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' "$ROOT/App/project.yml")
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")" = dev.ivan.bopa ]
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")" = "$version" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")" = "$build" ]
echo "Verified dev.ivan.bopa $version ($build), source $(git -C "$ROOT" rev-parse HEAD)"
echo 'CI build: CODE_SIGNING_ALLOWED=NO; no distribution signing identity.'
codesign -dvv "$APP" 2>&1 || true
