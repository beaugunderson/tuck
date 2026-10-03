# Manual regression checks

These require a running, signed Tuck app. Do not reset a user's TCC grants just to run tests; use a test account for fresh permission states.

## Capture permissions

- With Accessibility granted but Screen Recording denied, left-click the chevron. Expect guidance with Open Settings, Restart Tuck, and Cancel, not repeated Control Center icons. Cancel must leave Tuck usable.
- Open Settings and grant Screen Recording without accepting macOS's quit/reopen action. Click the chevron. If this process still cannot capture, expect recovery guidance. Restart Tuck should leave exactly one instance running, restore the chevron, preserve presets, and capture actual glyphs.
- With capture working, use right-click → Restart Tuck…; cancel once, then confirm. Confirm there is exactly one instance and preferences persist.
- Revoke Screen Recording while Tuck is running. On a subsequent open, expect guidance if the system reports denial or returns no glyph captures.
- With permission granted and no hidden icons, expect “No hidden icons”, not a capture-error alert.
- Check a partial capture failure (e.g. an overflow-dropped item): other glyphs remain usable; only the missing glyph shows a question mark with an unavailable tooltip.
- Right-click with Screen Recording denied: the checklist still has labels and works with Accessibility, but must not show misleading Control Center app icons.

## macOS 27 (hiding by app)

- Without Full Disk Access, right-click shows "Enable Full Disk Access for Tuck…" with Open Settings, Restart Tuck, and Cancel, and nothing is hidden. After granting it and restarting, the checklist lists one row per app.
- Untick an app: its icons leave the bar within about a second and no system `«` button appears. Tick it: they return where they were.
- Untick an app with several icons (SwiftBar): all of them hide together.
- Hide an app whose icon sits between two always-shown icons, then left-click the chevron: it comes back left of every always-shown icon, and the hidden apps keep their order among themselves.
- Left-click the chevron: every hidden app's icons return and are clickable. Click again: they hide. Leave it open with the pointer away from the menu bar: it closes after about ten seconds, and not while the pointer is in the menu bar or a menu is open.
- Hide an app, quit it, relaunch it: it stays hidden with no action from Tuck.
- Show All on: everything is visible; off: the preset's apps hide again.
- Quit Tuck with apps hidden: every one of them is back on the bar, and System Settings → Menu Bar shows them allowed.
- Switch an app off in System Settings yourself: Tuck's checklist shows it unticked and never switches it back on unless it is ticked there.
- Dock or undock to a screen of another width: that screen's preset applies, and an app hidden only on the other screen returns.
- With Screen Recording denied, nothing prompts for it.

## Appearance

- Light system mode + blue/dark menu bar + white glyphs: open the strip. Its background should match the local menu bar tint and the glyphs should remain readable.
- Dark system mode + dark menu bar, and light mode + light menu bar: check contrast, empty-state text, hover highlight, and original multicolor glyphs.
- Change wallpaper/Space or light/dark mode, then reopen: the color should be sampled anew, without restarting Tuck.
- Move to a secondary display (including one positioned above or left of the primary, and mixed Retina/non-Retina displays). Expect the color of that display's menu bar and correct positioning.
- If the menu bar background window cannot be captured, check the material fallback uses the status button's appearance.
- Open the strip: the chevron should smoothly rotate from left to down without shifting neighboring icons. Close via chevron, outside click, Escape, selecting an icon, or opening the right-click options menu: it should return left every time.
- Dismiss quickly during the opening animation: it should reverse smoothly and finish left. The 0.25s close/debounce should not briefly point down on a suppressed reopen.
- With macOS Reduce Motion enabled, the chevron should change direction immediately, without animation. Check template tint in both light and dark menu bars.
- Verify icon selection and outside-click/Escape dismissal are unchanged.
- Leave the strip closed: no additional timers, screen capture, or idle CPU activity should occur.
