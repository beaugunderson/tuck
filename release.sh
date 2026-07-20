#!/bin/bash
# Build, notarize, staple, and publish a Tuck release.
#
# Prereq (one-time): store notarization credentials in a keychain profile named
# "tuck-notary":
#   xcrun notarytool store-credentials tuck-notary \
#     --apple-id <your-apple-id> --team-id D7UFB67V5Z --password <app-specific-password>
# (or the App Store Connect API-key form: --key <p8> --key-id <id> --issuer <uuid>)
#
# Usage: ./release.sh <version>        e.g. ./release.sh 0.1.0
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version> (e.g. 0.1.0)}"
PROFILE="tuck-notary"
APP="Tuck"
BUNDLE="build/$APP.app"
ZIP="build/${APP}-${VERSION}.zip"
TAG="v${VERSION}"

echo "==> Building $APP $VERSION"
TUCK_VERSION="$VERSION" ./build.sh

# Refuse to ship an ad-hoc-signed bundle (notarization would fail anyway, and it
# would lose the stable TCC identity).
if ! codesign -dvv "$BUNDLE" 2>&1 | grep -q "Authority=Developer ID Application"; then
  echo "ERROR: $BUNDLE is not Developer ID signed. Aborting." >&2
  exit 1
fi

echo "==> Zipping for notarization"
/usr/bin/ditto -c -k --keepParent "$BUNDLE" "$ZIP"

echo "==> Submitting to Apple notary service (waits for result)"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling the ticket into the app"
xcrun stapler staple "$BUNDLE"
xcrun stapler validate "$BUNDLE"

echo "==> Re-zipping the stapled app (this is the artifact that ships)"
/usr/bin/ditto -c -k --keepParent "$BUNDLE" "$ZIP"

echo "==> Creating GitHub release $TAG"
gh release create "$TAG" "$ZIP" \
  --repo beaugunderson/tuck \
  --title "$APP $VERSION" \
  --notes "Tuck $VERSION — a tiny, performance-obsessed menu bar manager for macOS."

echo "==> sha256 (for the Homebrew cask):"
shasum -a 256 "$ZIP" | awk '{print $1}'
echo "==> Done. Release: https://github.com/beaugunderson/tuck/releases/tag/$TAG"
