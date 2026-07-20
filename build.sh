#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="Tuck"
BUNDLE_ID="com.beau.tuck"
VERSION="${TUCK_VERSION:-0.1.0}"
BUNDLE="build/$APP.app"
MACOS="$BUNDLE/Contents/MacOS"
RES="$BUNDLE/Contents/Resources"

mkdir -p "$MACOS" "$RES"

echo "Compiling…"
swiftc -O \
  -o "$MACOS/$APP" \
  Sources/*.swift \
  -framework Cocoa -framework ServiceManagement -framework ApplicationServices

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
  <key>LSMinimumSystemVersion</key><string>13.0</string>
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
