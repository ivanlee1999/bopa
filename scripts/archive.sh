#!/bin/bash
# Build a signed app for distribution: an .ipa for TestFlight / the App Store, or a
# notarised Mac .app for handing out directly.
#
# Usage: ./scripts/archive.sh <TEAM_ID> [BUILD_NUMBER] [ios|mac]
#   TEAM_ID       Apple Developer Team ID (developer.apple.com → Membership)
#   BUILD_NUMBER  optional; defaults to a UTC timestamp so every upload is unique
#   PLATFORM      ios (default) archives for the App Store; mac archives the Catalyst
#                 build, exports it Developer ID-signed and, when NOTARY_PROFILE names a
#                 keychain profile made by `xcrun notarytool store-credentials`, submits
#                 it for notarisation and staples the ticket.
#
# Requires: paid Apple Developer Program membership, and your Apple ID added in
# Xcode → Settings → Accounts (so -allowProvisioningUpdates can create the
# provisioning profile). The upload itself is NOT done here — see the printed
# next steps; do it from Xcode Organizer or Transporter.
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <TEAM_ID> [BUILD_NUMBER] [ios|mac]" >&2
  exit 1
fi

TEAM_ID="$1"
BUILD_NUMBER="${2:-$(date -u +%Y%m%d%H%M)}"
PLATFORM="${3:-ios}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/Bopa-$PLATFORM.xcarchive"
EXPORT_DIR="$BUILD_DIR/export-$PLATFORM"

case "$PLATFORM" in
  ios) DESTINATION='generic/platform=iOS'; METHOD=app-store-connect ;;
  mac) DESTINATION='generic/platform=macOS,variant=Mac Catalyst'; METHOD=developer-id ;;
  *)   echo "unknown platform: $PLATFORM (ios|mac)" >&2; exit 1 ;;
esac

cd "$ROOT/App"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null

rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Archiving $PLATFORM (team $TEAM_ID, build $BUILD_NUMBER)"
xcodebuild archive \
  -project Bopa.xcodeproj \
  -scheme Bopa \
  -configuration Release \
  -destination "$DESTINATION" \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -allowProvisioningUpdates

cat > "$BUILD_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>$METHOD</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>uploadSymbols</key>
	<true/>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
EOF

echo "==> Exporting ($METHOD)"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates

if [ "$PLATFORM" = mac ]; then
  APP="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.app' | head -1)"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    # Gatekeeper refuses a Developer ID app it has not seen notarised, and it says so with a
    # dialog that reads as "this app is damaged". Zipped because notarytool takes an archive,
    # not a bundle; the ticket is then stapled to the .app so it opens offline too.
    ZIP="$BUILD_DIR/Bopa-mac.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "==> Notarising"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
  else
    echo "NOTARY_PROFILE not set: skipping notarisation. The app will only open on this Mac" >&2
    echo "or after a right-click › Open; set it to a notarytool keychain profile to ship." >&2
  fi
  echo
  echo "Built: $APP"
  exit 0
fi

IPA="$(find "$EXPORT_DIR" -name '*.ipa' | head -1)"
echo
echo "Built: $IPA"
echo
echo "Next steps (yours — they need your Apple ID):"
echo "  1. App Store Connect → Apps → + → New App, bundle ID dev.ivan.bopa"
echo "  2. Upload with Transporter (drag the .ipa in), or open $ARCHIVE"
echo "     in Xcode Organizer and use Distribute App."
echo "  3. TestFlight tab → add yourself as an internal tester."
