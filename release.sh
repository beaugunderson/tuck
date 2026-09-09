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
LATEST_ZIP="build/${APP}.zip"
TAG="v${VERSION}"

echo "==> Building $APP $VERSION"
TUCK_VERSION="$VERSION" ./build.sh
bash Tests/check-bundle.sh

# Refuse to ship an ad-hoc-signed bundle (notarization would fail anyway, and it
# would lose the stable TCC identity). Capture first rather than piping into
# grep -q, which would SIGPIPE codesign and trip pipefail.
SIGINFO="$(codesign -dvv "$BUNDLE" 2>&1 || true)"
if ! grep -q "Authority=Developer ID Application" <<<"$SIGINFO"; then
  echo "ERROR: $BUNDLE is not Developer ID signed. Aborting." >&2
  exit 1
fi

echo "==> Zipping for notarization"
/usr/bin/ditto -c -k --keepParent "$BUNDLE" "$ZIP"

echo "==> Submitting to Apple notary service (waits for result)"
if [ -n "${APPLE_APP_PASSWORD:-}" ]; then
  # CI / non-interactive: explicit credentials from the environment.
  xcrun notarytool submit "$ZIP" \
    --apple-id "${APPLE_ID:?APPLE_ID required alongside APPLE_APP_PASSWORD}" \
    --team-id "${APPLE_TEAM_ID:?APPLE_TEAM_ID required alongside APPLE_APP_PASSWORD}" \
    --password "$APPLE_APP_PASSWORD" --wait
else
  # Local: credentials stored in the keychain profile (see header).
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
fi

echo "==> Stapling the ticket into the app"
xcrun stapler staple "$BUNDLE"
xcrun stapler validate "$BUNDLE"

echo "==> Re-zipping the stapled app (this is the artifact that ships)"
/usr/bin/ditto -c -k --keepParent "$BUNDLE" "$ZIP"

# Keep a stable asset name for /releases/latest/download/Tuck.zip. Both names
# contain the same signed, notarized, stapled app; Homebrew keeps the versioned one.
cp "$ZIP" "$LATEST_ZIP"

echo "==> Creating GitHub release $TAG"
gh release create "$TAG" "$ZIP" "$LATEST_ZIP" \
  --repo beaugunderson/tuck \
  --title "$APP $VERSION" \
  --notes "Tuck $VERSION — a tiny, performance-obsessed menu bar manager for macOS."

SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "$SHA" > "build/${APP}-${VERSION}.sha256"
echo "==> sha256 (for the Homebrew cask): $SHA"
echo "==> Done. Release: https://github.com/beaugunderson/tuck/releases/tag/$TAG"
