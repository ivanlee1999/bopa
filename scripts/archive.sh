#!/bin/bash
# Build a signed .ipa for TestFlight / App Store distribution.
#
# Usage: ./scripts/archive.sh <TEAM_ID> [BUILD_NUMBER]
#   TEAM_ID       Apple Developer Team ID (developer.apple.com → Membership)
#   BUILD_NUMBER  optional; defaults to a UTC timestamp so every upload is unique
#
# Requires: paid Apple Developer Program membership, and your Apple ID added in
# Xcode → Settings → Accounts (so -allowProvisioningUpdates can create the
# provisioning profile). The upload itself is NOT done here — see the printed
# next steps; do it from Xcode Organizer or Transporter.
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <TEAM_ID> [BUILD_NUMBER]" >&2
  exit 1
fi

TEAM_ID="$1"
BUILD_NUMBER="${2:-$(date -u +%Y%m%d%H%M)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/Bopa.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

cd "$ROOT/App"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null

rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Archiving (team $TEAM_ID, build $BUILD_NUMBER)"
xcodebuild archive \
  -project Bopa.xcodeproj \
  -scheme Bopa \
  -configuration Release \
  -destination 'generic/platform=iOS' \
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
	<string>app-store-connect</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>uploadSymbols</key>
	<true/>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
EOF

echo "==> Exporting .ipa"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates

IPA="$(find "$EXPORT_DIR" -name '*.ipa' | head -1)"
echo
echo "Built: $IPA"
echo
echo "Next steps (yours — they need your Apple ID):"
echo "  1. App Store Connect → Apps → + → New App, bundle ID dev.ivan.bopa"
echo "  2. Upload with Transporter (drag the .ipa in), or open $ARCHIVE"
echo "     in Xcode Organizer and use Distribute App."
echo "  3. TestFlight tab → add yourself as an internal tester."
