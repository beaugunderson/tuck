# Tuck

A tiny, performance-obsessed menu bar manager for macOS — a lightweight Bartender replacement. ~0% idle CPU, ~14 MB, no always-on event tap. **Free, forever.**

**[tuck.bar](https://tuck.bar)** · [Download the latest release](https://github.com/beaugunderson/tuck/releases/latest/download/Tuck.zip)

## What it does today

- Click Tuck's chevron for a panel listing **every hidden menu bar icon** — including ones the notch pushed off the bar — read from the Accessibility tree. The chevron rotates down while the strip is open and back left when it closes; Reduce Motion is respected.
- Each icon shows its **real rendered menu-bar glyph** (Wi-Fi, battery, Dropbox, SwiftBar's live text, Dato's date…), captured in one composite pass.
- The strip samples the menu bar’s background color when opened, keeping white glyphs readable even with light-mode apps and a dark or colorful wallpaper. Original glyph colors are preserved.
- Click a hidden icon and it opens: Tuck briefly slides it on-screen, clicks it so its own menu opens, then slides it back (synthetic-CGEvent technique ported from Ice).
- Right-click the chevron for options: a checklist to show/hide each icon (no dragging needed), plus Show All, Launch at Login, and help.
- Updates are opt-in: "Check for Updates Automatically" looks once a day, downloads a newer release, and offers "Restart to Update" in the same menu. A download is used only if it is Tuck, signed by the same Developer ID, and notarized.
- ⌘-drag any icon to the left of Tuck's divider to hide it, right to keep it visible (native macOS gesture).
- Checklist choices are remembered and restored — a menu bar icon that vanishes and reappears (e.g. a SwiftBar plugin that goes quiet) is nudged back to where you put it.
- **Per-screen presets.** Choices are kept per menu bar width, so the notched laptop bar and a wide external monitor each have their own set of hidden icons. Docking or undocking switches presets automatically; a screen width you have never used starts as a copy of the previous one. The checklist header names the screen you are editing.

## On macOS 27

macOS 27 draws every status item in one `MenuBarAgent` window, so there are no per-icon windows to capture or push off-screen. Tuck works differently there:

- Hiding is per app. Tuck switches an app off in macOS's own "Allow in the Menu Bar" list, and its icons leave the bar; an app with several icons hides them together.
- Click Tuck's chevron and every hidden app's real icons come back, grouped to the left of the ones that are always shown. Click again, or wait about ten seconds with the pointer out of the menu bar, and they hide.
- Right-click the chevron for a checklist of apps, Show All, and per-screen presets. Quitting Tuck brings every hidden icon back.
- Tuck needs **Full Disk Access** there, because macOS keeps that list in Control Center's settings file. It reads and writes that one file. Screen Recording is not used; there is no strip and no capture.

## Why it's fast

Design tenet: **near-zero idle work.** No always-on event tap, no mouse tracking; nothing runs until you click. The only recurring work is a lightweight poll that exists solely while the active preset has entries, moving items back if they respawn on the wrong side. Screen changes arrive as a notification, not a poll. Measured idle: **~0% CPU / ~14 MB**, vs Ice's 1.5–2.6% / 44 MB (Ice keeps a global mouse-tracking event tap alive).

## Techniques

Menu bar item enumeration and capture use private SkyLight window APIs bound via `@_silgen_name`, plus the (SDK-obsoleted but still-shipping) `CGWindowListCreateImage` bound the same way. The reliable click/move machinery is ported from Ice (jordanbaird/Ice, GPLv3). Tuck is GPLv3.

## Thanks, Ice

Tuck’s core menu bar clicking and moving code is adapted from **[Ice](https://github.com/jordanbaird/Ice)**, by **[Jordan Baird](https://github.com/jordanbaird)** and its contributors. Ice’s capture approach and Ice Bar also helped make Tuck’s hidden-icon strip possible. Both projects are GPLv3; upstream source headers and license notices are retained.

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

Requires **macOS 15+**, on **Apple silicon or Intel**. `build.sh` cross-compiles arm64 and x86_64 with an explicit macOS 15.0 deployment target, combines them into one universal executable with `lipo`, and signs the final bundle. Developed on macOS 26. No Xcode project — plain `swiftc`. `release.sh <version>` validates both slices, notarizes, and publishes a release.

## Tests

Run `bash Tests/run.sh` for background-color, sampling-geometry, and chevron animation checks compiled for both architectures. It executes each supported architecture (including x86_64 under Rosetta when available) and reports any runtime skips. After `./build.sh`, run `bash Tests/check-bundle.sh` to verify both slices, deployment targets, bundle metadata, and signatures. The release pipeline runs both checks. See `Tests/Manual.md` for permission and appearance checks that require a running app and macOS privacy settings.

## Website

The microsite at **https://tuck.bar** lives in `site/` and is hosted on Netlify (`tuck-bar`, project ID `8a0e0c9f-1fac-4490-acbe-b4b26922d834`). Plain HTML/CSS/JS, local system fonts, no build step, trackers, or runtime dependencies. Netlify publishes `site/`; `netlify.toml` contains the build settings.

`/download` is a non-cacheable 302 to GitHub’s `/releases/latest/download/Tuck.zip`. Every release uploads that stable name alongside the versioned ZIP used by Homebrew. Both contain the same notarized, stapled app; no GitHub API call or website redeploy is needed when a new app version ships.

Local preview and browser checks:

```sh
python3 -m http.server 8126 --bind 127.0.0.1 --directory site
# In another shell (playwright-cli installed):
mkdir -p tmp
playwright-cli -s=tuck-site open http://127.0.0.1:8126/
playwright-cli -s=tuck-site run-code --filename=Tests/site-browser.js
```

Push to `main` to deploy automatically through Netlify’s GitHub integration. Manual deployment: `netlify deploy --prod --no-build --dir site --site 8a0e0c9f-1fac-4490-acbe-b4b26922d834`.

DNS stays at Spaceship: `@ A 75.2.60.5`, `www CNAME tuck-bar.netlify.app` (TTL 300). Keep Spaceship’s nameservers and DNSSEC; there is no need to migrate DNS to Netlify.

## Layout

- `Sources/` — the app: `main.swift` (status items + click handlers), `IceBar.swift` (the hidden-icon strip), `ItemManager.swift` (click/move machinery), `Bridging.swift`/`Private.swift` (SkyLight + capture), `AXNames.swift` (real app names), `AgentBar.swift` and `AllowList.swift` (the macOS 27 path: which apps have icons, and the per-app switches that hide them).
- `port-staging/` — the verbatim Ice files the port adapted from.
