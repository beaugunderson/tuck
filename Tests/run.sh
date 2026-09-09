#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sources=()
for source in Sources/*.swift; do
    [[ "$source" == Sources/main.swift ]] || sources+=("$source")
done
swiftc -o "$work/appearance-tests" "${sources[@]}" Tests/MenuBarAppearanceTests.swift \
    -framework Cocoa -framework ServiceManagement -framework ApplicationServices
"$work/appearance-tests"
