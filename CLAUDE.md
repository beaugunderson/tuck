# Tuck — CLAUDE.md

A tiny, performance-obsessed macOS menu bar manager (Bartender replacement). Plain `swiftc`, no Xcode project. Built on macOS 26, notched 16" MBP.

## What it does
- Left-click the chevron → a floating horizontal strip (IceBar) of the hidden icons' **real glyphs**; click one to open it.
- Right-click the chevron → options: a checklist of manageable menu bar icons (checkmark = shown always; toggle a row to hide/show it by ⌘-dragging it across the separator via `ItemManager`, one at a time, so macOS never overflow-drops), then Show All, Launch at Login, How to Hide an Icon…, Quit.
- Checking a row **pins** it (persisted in UserDefaults by `info` = `namespace:title`). A pinned item that vanishes and respawns in the hidden zone gets dragged back right of the separator automatically by `reassertPinned()`, driven by a poll (`pinPollTimer`, 5s). Fixes SwiftBar plugins that go null-output and return — their window title is the stable plugin filename, so `info` re-matches on return. The move only fires when a pin is actually sitting hidden; otherwise each tick is just a cheap enumeration.
- Hiding: a wide "separator" status item shoves everything to its left off-screen; the user ⌘-drags icons across it. "Show All" makes the divider visible for arranging.

## Design tenet: near-zero idle work
No always-on event tap, no mouse tracking. Everything is click-driven except one recurring timer: the pin-restore poll (`pinPollTimer`, 5s), which exists only while items are pinned and whose tick is a sub-ms window enumeration — so idle still measures **0.0% CPU / ~14 MB** (top real-mem; `ps` RSS reads ~43 MB counting shared framework pages). (Ice idles at 1.5–2.6% / 44 MB because of its always-on mouse-tracking tap — deliberately not ported.) The poll is a poll because macOS gives no other option — see the gotcha below.

## Architecture (Sources/)
- `main.swift` — AppDelegate: status items, the chevron/options handlers, `captureGlyphs` (composite capture + per-item crop), the help dialog + diagram.
- `IceBar.swift` — the floating horizontal strip (borderless NSPanel + NSVisualEffectView + hover cells). Centered on the chevron, clamped to screen. 0.25s debounce so clicking the chevron while open closes it (not close-then-reopen).
- `ItemManager.swift` — ported from Ice's MenuBarItemManager: synthetic-CGEvent click + ⌘-drag move + temp-show/rehide. Event taps here are transient (per-op, 50ms) → no idle cost. `tlog()` writes `/tmp/tuck.log` for debugging.
- `Bridging.swift` / `Private.swift` — private SkyLight (CGS) window APIs + capture, bound via `@_silgen_name`.
- `WindowInfo` / `MenuBarItem` / `MenuBarItemInfo` — Ice's item model (trimmed).
- `EventTap` / `MouseCursor` / `TaskTimeout` / `Support.swift` (Logger/Constants shims) — ported Ice utilities.

## Load-bearing gotchas
- **Capture the array variant**: `CGWindowListCreateImageFromArray` renders far-off-screen items; the single-window `CGWindowListCreateImage` returns nil for them. Both are `unavailable` in the macOS 26 SDK — bind via `@_silgen_name` (Ice's protocol shim no longer compiles). Needs Screen Recording.
- **Track temp-shown items by `windowID`, not `info`**: Control Center gives ~a dozen items the identical title "Item-0" → same `MenuBarItemInfo`, so info-based lookup grabs the wrong item and the rehide strands the shown one on the bar forever.
- Owner attribution is useless (everything reports "Control Center"); map window→app by frame-matching the AX tree if you need real names. `AXNames.swift` does this for the right-click checklist: walk every app's `AXExtrasMenuBar`, match each item to a window by left edge. The window-server *connection* owner is also useless — `CGSGetWindowOwner`→`CGSConnectionGetPID` returns Control Center's pid (36740) for every item, so there is NO window-server route to the real app; AX frame-matching is the only bridge, don't re-try the CGS route. Do it in parallel (`DispatchQueue.concurrentPerform`) over all processes with a per-app `AXUIElementSetMessagingTimeout` (0.15s) — a serial main-thread walk beach-balls for seconds; parallel is ~200ms for two dozen items.
  - Prefer `MenuBarItem.displayName` for the row label and only fall back to the AX-resolved owner when `displayName` is a placeholder (`Item-N`, a UUID, empty). `displayName` already names Control Center's own modules (Wi-Fi, Battery, Focus…) better than AX, which just reports "Control Center" for them.
  - Some agents own a status item yet are background-only (`.prohibited`, e.g. ZeroTier) or have an empty `localizedName` (old Intel apps, e.g. ControlPlane — fall back to the bundle name). Don't filter by activation policy. An app that publishes nothing to AX at all (ZeroTier's element returns zero attributes) is unresolvable — no bridge exists; it shows as "Unknown".
- "Shown always" vs "hidden" is decided by position relative to the separator (`item.frame.midX > separator.frame.maxX`, plus `minY < 100` to exclude overflow-dropped items), never `isOnScreen` — an animating or dropped item lies about being on screen.
- macOS-*dropped* items (parked at y≈1116, no window) can't be captured/clicked by anyone — keep items windowed-on-the-row. macOS drops the overflow when the right strip fills; on this Mac the usable strips are `0–771` (left of notch) and `956–1728` (right), notch `771–956`. Keep hidden icons windowed off-screen-left (still capturable) rather than letting them overflow-drop.
- **No Accessibility event fires when a status item is *added*** — only `AXUIElementDestroyed` on removal. Verified across the owning app element, the Control Center host process, and the `AXExtrasMenuBar` container itself, over ten notification types (created / children-changed / layout-changed / …). So pin-restore *cannot* be event-driven off the reappearance; the 5s poll is the only way to notice an item is back. Don't waste a session trying to replace the poll with an AXObserver on "created" — it silently never fires.

## Build / sign / permissions
- `./build.sh` → compiles `Sources/*.swift`, assembles `build/Tuck.app`, signs with Developer ID (`Developer ID Application: Beau Gunderson (D7UFB67V5Z)`). Developer ID keeps TCC grants across rebuilds; ad-hoc loses them every rebuild.
- Needs **Accessibility** (enumerate/move) + **Screen Recording** (capture glyphs). Stale grants after an identity change: `tccutil reset {Accessibility|ScreenCapture} com.beau.tuck`.

## License
Ports GPLv3 code from Ice (jordanbaird/Ice) → Tuck is GPLv3. `reference/Ice/` is the studied checkout; `port-staging/` holds the source files adapted in.
