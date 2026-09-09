# Tuck

A tiny, performance-obsessed menu bar manager for macOS — a lightweight Bartender replacement. ~0% idle CPU, ~14 MB, no always-on event tap.

## What it does today

- Click Tuck's chevron for a panel listing **every hidden menu bar icon** — including ones the notch pushed off the bar — read from the Accessibility tree.
- Each icon shows its **real rendered menu-bar glyph** (Wi-Fi, battery, Dropbox, SwiftBar's live text, Dato's date…), captured in one composite pass.
- The strip samples the menu bar’s background color when opened, keeping white glyphs readable even with light-mode apps and a dark or colorful wallpaper. Original glyph colors are preserved.
- Click a hidden icon and it opens: Tuck briefly slides it on-screen, clicks it so its own menu opens, then slides it back (synthetic-CGEvent technique ported from Ice).
- Right-click the chevron for options: a checklist to show/hide each icon (no dragging needed), plus Show All, Launch at Login, and help.
- ⌘-drag any icon to the left of Tuck's divider to hide it, right to keep it visible (native macOS gesture).
- Checklist choices are remembered and restored — a menu bar icon that vanishes and reappears (e.g. a SwiftBar plugin that goes quiet) is nudged back to where you put it.
- **Per-screen presets.** Choices are kept per menu bar width, so the notched laptop bar and a wide external monitor each have their own set of hidden icons. Docking or undocking switches presets automatically; a screen width you have never used starts as a copy of the previous one. The checklist header names the screen you are editing.

## Why it's fast

Design tenet: **near-zero idle work.** No always-on event tap, no mouse tracking; nothing runs until you click. The only recurring work is a lightweight poll that exists solely while the active preset has entries, moving items back if they respawn on the wrong side. Screen changes arrive as a notification, not a poll. Measured idle: **~0% CPU / ~14 MB**, vs Ice's 1.5–2.6% / 44 MB (Ice keeps a global mouse-tracking event tap alive).

## Techniques

Menu bar item enumeration and capture use private SkyLight window APIs bound via `@_silgen_name`, plus the (SDK-obsoleted but still-shipping) `CGWindowListCreateImage` bound the same way. The reliable click/move machinery is ported from Ice (jordanbaird/Ice, GPLv3). Tuck is GPLv3.

## Permissions

- **Accessibility** — enumerate icons.
- **Screen Recording** — capture real glyphs.

After granting Screen Recording, **quit and reopen Tuck** if icons do not appear. macOS may require a restart before capture works. Tuck now offers Settings and Restart actions when permission is missing or all hidden-icon captures fail, rather than showing a strip of identical Control Center icons. These actions are also available under **Icon Capture Help…** in the right-click menu. A single uncapturable icon gets a question-mark placeholder; if macOS dropped an overflowing icon, try **Show All**.

Sign with a stable Developer ID so grants persist across rebuilds (`build.sh` does this).

## Install

```sh
brew install --cask beaugunderson/tap/tuck
```

Then grant **Accessibility** and **Screen Recording** when prompted (see Permissions).

## Build from source

```sh
./build.sh          # compiles Sources/*.swift, assembles + Developer-ID signs build/Tuck.app
open build/Tuck.app
```

Requires macOS 14+ (developed on macOS 26). No Xcode project — plain `swiftc`. `release.sh <version>` builds, notarizes, and publishes a release.

## Tests

Run `bash Tests/run.sh` for background-color and sampling-geometry checks, then `./build.sh` to compile and sign the app. See `Tests/Manual.md` for permission and appearance checks that require a running app and macOS privacy settings.

## Layout

- `Sources/` — the app: `main.swift` (status items + click handlers), `IceBar.swift` (the hidden-icon strip), `ItemManager.swift` (click/move machinery), `Bridging.swift`/`Private.swift` (SkyLight + capture), `AXNames.swift` (real app names).
- `port-staging/` — the verbatim Ice files the port adapted from.
