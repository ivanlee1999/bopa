#!/bin/bash
# Package only committed source. This is not an installable or signed application.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: package-source.sh /output/directory}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
cd "$ROOT"
version=$(git show HEAD:App/project.yml | awk '/MARKETING_VERSION:/ {print $2; exit}')
build=$(git show HEAD:App/project.yml | awk '/CURRENT_PROJECT_VERSION:/ {print $2; exit}')
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$build" =~ ^[0-9]+$ ]]
sha=$(git rev-parse HEAD)
name="bopa-$version-build$build-source"
git archive --format=tar --prefix="$name/" HEAD | gzip -n > "$OUT/$name.tar.gz"
git archive --format=zip --prefix="$name/" HEAD > "$OUT/$name.zip"
cat > "$OUT/BUILD-INFO.txt" <<INFO
Bopa $version ($build)
Source commit: $sha
Source code only. No compiled app, IPA, signing identity or provisioning profile.
See docs/release-$version.md for validation scope and device-testing limitations.
INFO
cd "$OUT"
if command -v sha256sum >/dev/null; then
  sha256sum "$name.tar.gz" "$name.zip" BUILD-INFO.txt > SHA256SUMS
else
  shasum -a 256 "$name.tar.gz" "$name.zip" BUILD-INFO.txt > SHA256SUMS
fi
