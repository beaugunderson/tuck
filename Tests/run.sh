#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sources=()
for source in Sources/*.swift; do
    [[ "$source" == Sources/main.swift ]] || sources+=("$source")
done
sdk=$(xcrun --sdk macosx --show-sdk-path)
for architecture in arm64 x86_64; do
    for suite in MenuBarAppearance Chevron; do
        binary="$work/$suite-tests-$architecture"
        swiftc -sdk "$sdk" -target "$architecture-apple-macos15.0" \
            -o "$binary" "${sources[@]}" "Tests/${suite}Tests.swift" \
            -framework Cocoa -framework ServiceManagement -framework ApplicationServices
        if [[ "$architecture" == "$(uname -m)" ]] || /usr/bin/arch "-$architecture" /usr/bin/true 2>/dev/null; then
            echo "Running $architecture $suite tests…"
            /usr/bin/arch "-$architecture" "$binary"
        else
            echo "Compiled $architecture $suite tests; execution unavailable on this host (no emulator)."
        fi
    done
done
