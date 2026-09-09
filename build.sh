#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="Tuck"
BUNDLE_ID="com.beau.tuck"
VERSION="${TUCK_VERSION:-0.1.0}"
BUNDLE="build/$APP.app"
MACOS="$BUNDLE/Contents/MacOS"
RES="$BUNDLE/Contents/Resources"
MIN_MACOS="15.0"
SLICES="build/slices"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$MACOS" "$RES" "$SLICES"

# Cross-compile both architectures regardless of the host. An explicit target
# also prevents a newer build machine from silently raising the minimum OS.
for ARCH in arm64 x86_64; do
  echo "Compiling $ARCH (macOS $MIN_MACOS+)…"
  swiftc -O -sdk "$SDK" -target "${ARCH}-apple-macos${MIN_MACOS}" \
    -o "$SLICES/$APP-$ARCH" \
    Sources/*.swift \
    -framework Cocoa -framework ServiceManagement -framework ApplicationServices
done
lipo -create "$SLICES/$APP-arm64" "$SLICES/$APP-x86_64" -output "$MACOS/$APP"
lipo "$MACOS/$APP" -verify_arch arm64 x86_64

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>$APP</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Built by Beau + Claude</string>
</dict>
</plist>
PLIST

# Stable Developer ID signature: TCC (Accessibility) grants persist across
# rebuilds because the designated requirement keys on the Team ID, not the
# binary hash. Falls back to ad-hoc if the cert isn't present.
DEVID="Developer ID Application: Beau Gunderson (D7UFB67V5Z)"
if security find-identity -v -p codesigning | grep -q "$DEVID"; then
  echo "Signing with Developer ID…"
  codesign --force --options runtime --sign "$DEVID" "$BUNDLE"
else
  echo "Developer ID not found; ad-hoc signing…"
  codesign --force --sign - "$BUNDLE"
fi

echo "Built $BUNDLE"
