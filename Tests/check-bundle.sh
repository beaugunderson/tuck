#!/bin/bash
# Validate what ships, not just the host architecture's test binary.
set -euo pipefail
cd "$(dirname "$0")/.."
bundle="${1:-build/Tuck.app}"
binary="$bundle/Contents/MacOS/Tuck"
lipo "$binary" -verify_arch arm64 x86_64
minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$bundle/Contents/Info.plist")
[[ "$minimum" == "15.0" ]]
for architecture in arm64 x86_64; do
    actual=$(vtool -arch "$architecture" -show-build "$binary" | awk '$1 == "minos" {print $2}')
    [[ "$actual" == "$minimum" ]] || { echo "$architecture minimum OS $actual does not match bundle $minimum" >&2; exit 1; }
done
codesign --verify --deep --strict --all-architectures "$bundle"
echo "Verified universal arm64/x86_64 bundle, macOS $minimum minimum, and both signatures."
