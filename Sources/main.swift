import Cocoa
import ApplicationServices
import ServiceManagement

// Tuck — a tiny, performance-obsessed Bartender replacement.
//
// Near-zero idle work: no always-on event tap, no mouse tracking. Everything
// is click-driven except one 5s poll that exists only while a preset has
// entries. Left-click the chevron for a horizontal strip of hidden glyphs
// (click one to open it); right-click for options.

/// The user's shown/hidden decisions for one menu bar width. Keyed by
/// `MenuBarItemInfo` (namespace:title) — stable for real apps and for SwiftBar
/// plugins (whose window title is the plugin filename). Items with no entry are
/// left wherever they sit.
struct ScreenPreset: Codable {
    var shown: Set<MenuBarItemInfo> = []
    var hidden: Set<MenuBarItemInfo> = []

    var isEmpty: Bool { shown.isEmpty && hidden.isEmpty }

    mutating func set(_ info: MenuBarItemInfo, shown isShown: Bool) {
        if isShown {
            hidden.remove(info)
            shown.insert(info)
        } else {
            shown.remove(info)
            hidden.insert(info)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var toggleItem: NSStatusItem!
    private var separatorItem: NSStatusItem!

    private let collapsedWidth: CGFloat = 10_000
    private let expandedWidth: CGFloat = 20

    private let defaults = UserDefaults.standard
    private let revealKey = "revealInBar"
    private let presetsKey = "screenPresets"
    private let legacyPinnedKey = "pinnedItems"

    /// One preset per menu bar width (see `screenKey`), so the laptop's notched
    /// bar and a wide external monitor each keep their own set of hidden icons.
    /// The checklist edits the preset for the screen the menu bar is on right now.
    private var presets: [String: ScreenPreset] = [:]
    private var activeKey = ""
    private var activePreset: ScreenPreset {
        get { presets[activeKey] ?? ScreenPreset() }
        set { presets[activeKey] = newValue }
    }

    /// A lightweight poll that reconciles the bar with the active preset: it
    /// restores a shown item after it respawns hidden (SwiftBar plugins that go
    /// null-output and return) and re-hides one that came back on the wrong side.
    /// macOS emits no Accessibility event when a status item is *added* (only on
    /// removal), so there's nothing to hang an event-driven restore on — a poll is
    /// the only way to notice the item is back. It runs only while the active
    /// preset has entries; each tick is a sub-ms window enumeration that moves
    /// nothing unless an item is actually on the wrong side.
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 5
    private var isReconciling = false

    /// Docking fires `didChangeScreenParameters` several times while the menu bar
    /// re-lays out; the key is re-read once things settle.
    private var screenChangeWork: DispatchWorkItem?
    private let screenChangeSettle: TimeInterval = 1.5

    private let itemManager = ItemManager()
    private let iceBar = IceBar()
    private var chevron: Chevron?
    private var currentHidden: [MenuBarItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        toggleItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toggleItem.autosaveName = "tuck.toggle"
        if let button = toggleItem.button {
            chevron = Chevron { [weak button] image in button?.image = image }
            button.toolTip = "Tuck — click to see hidden menu bar icons"
            button.setAccessibilityValue("Collapsed")
            button.target = self
            button.action = #selector(chevronClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        iceBar.onVisibilityChange = { [weak self] isOpen in
            guard let self else { return }
            chevron?.setExpanded(isOpen)
            toggleItem.button?.toolTip = isOpen
                ? "Tuck — click to hide the icon strip"
                : "Tuck — click to see hidden menu bar icons"
            toggleItem.button?.setAccessibilityValue(isOpen ? "Expanded" : "Collapsed")
        }

        separatorItem = NSStatusBar.system.statusItem(withLength: expandedWidth)
        separatorItem.autosaveName = "tuck.separator"
        if let button = separatorItem.button {
            button.image = dividerImage()
            button.target = self
            button.action = #selector(chevronClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        applyReveal()
        loadPresets()
        activeKey = screenKey()
        updatePolling()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        if !Bridging.screenRecordingGranted() {
            Bridging.requestScreenRecording()
        }
    }

    private var revealInBar: Bool {
        get { defaults.bool(forKey: revealKey) }
        set { defaults.set(newValue, forKey: revealKey); applyReveal() }
    }

    private func applyReveal() {
        separatorItem.length = revealInBar ? expandedWidth : collapsedWidth
        separatorItem.button?.image = revealInBar ? dividerImage() : nil
    }

    private func dividerImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 8, height: 16))
        image.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: 3.25, y: 2, width: 1.5, height: 12), xRadius: 0.75, yRadius: 0.75).fill()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - Clicks

    @objc private func chevronClicked(_ sender: NSStatusBarButton) {
        let isRight = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if isRight || !AXIsProcessTrusted() {
            showOptionsMenu(from: sender)
        } else {
            toggleBar(from: sender)
        }
    }

    // MARK: - Screen presets

    /// The screen Tuck's own status item is drawn on, i.e. the menu bar we manage.
    private func menuBarScreen() -> NSScreen? {
        separatorItem.button?.window?.screen ?? NSScreen.screens.first
    }

    /// Presets vary by available real estate, so the key is the menu bar's width
    /// in points plus a notch marker: two monitors of the same width share a
    /// preset, and the notched laptop bar (two ~770pt strips) never masquerades
    /// as a 1728pt external display. Falls back to the last key when no screen
    /// is attached (e.g. mid-dock).
    private func screenKey() -> String {
        guard let screen = menuBarScreen() else { return activeKey }
        let width = Int(screen.frame.width.rounded())
        let notch = screen.auxiliaryTopLeftArea != nil ? "n" : ""
        return "\(width)\(notch)"
    }

    private func loadPresets() {
        if let data = defaults.data(forKey: presetsKey),
           let stored = try? JSONDecoder().decode([String: ScreenPreset].self, from: data) {
            presets = stored
            return
        }
        // Single-preset install: its pinned set becomes this screen's shown set.
        if let data = defaults.data(forKey: legacyPinnedKey),
           let pinned = try? JSONDecoder().decode([MenuBarItemInfo].self, from: data) {
            presets[screenKey()] = ScreenPreset(shown: Set(pinned))
            defaults.removeObject(forKey: legacyPinnedKey)
            savePresets()
        }
    }

    private func savePresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: presetsKey)
    }

    @objc private func screenParametersChanged(_ note: Notification) {
        screenChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.activateScreen() }
        }
        screenChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + screenChangeSettle, execute: work)
    }

    /// Switches to the preset for the screen the menu bar is on now. A width
    /// never seen before starts as a copy of the outgoing preset, so nothing
    /// moves until the user edits it; from then on the two diverge.
    private func activateScreen() {
        let key = screenKey()
        if key != activeKey {
            if presets[key] == nil, let outgoing = presets[activeKey] {
                presets[key] = outgoing
                savePresets()
            }
            activeKey = key
            updatePolling()
        }
        Task { await reconcile() }
    }

    /// Runs the reconcile poll only while the active preset has entries — an
    /// empty preset means no timer, so the idle cost stays at zero.
    private func updatePolling() {
        if activePreset.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        } else if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.reconcile() }
            }
        }
    }

    /// Drags every item that sits on the wrong side of the separator for the
    /// active preset across it, one at a time so macOS never overflow-drops.
    /// Only touches items whose `info` maps to exactly one live, non-placeholder
    /// window — Control Center's many identical "Item-N" titles are ambiguous, so
    /// we never risk grabbing the wrong one. The idle tick is a single window
    /// enumeration; items are re-enumerated only after a move, since every move
    /// shifts the separator.
    private func reconcile() async {
        let preset = activePreset
        guard !isReconciling, !preset.isEmpty, AXIsProcessTrusted() else { return }
        isReconciling = true
        defer { isReconciling = false }
        let decisions = preset.shown.map { ($0, true) } + preset.hidden.map { ($0, false) }
        var all = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
        for (info, wantShown) in decisions {
            guard !isPlaceholderName(info.title) else { continue }
            guard let separator = separatorModel(in: all), separator.frame.width > 0 else { return }
            let matches = all.filter { $0.info == info }
            guard matches.count == 1 else { continue }
            let item = matches[0]
            guard item.isMovable, isShownAlways(item, separator: separator) != wantShown else { continue }
            do {
                try await itemManager.slowMove(item: item, to: wantShown ? .rightOfItem(separator) : .leftOfItem(separator))
            } catch {
                NSLog("Tuck: reconcile failed for \(item.displayName): \(error)")
            }
            all = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
        }
    }

    private func hiddenItems() -> [MenuBarItem] {
        MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
            .filter { item in
                guard !item.isOnScreen else { return false }
                guard item.owningApplication != .current else { return false }
                guard !item.info.title.hasPrefix("tuck.") else { return false }
                return true
            }
            .sortedByOrderInMenuBar()
    }

    private func toggleBar(from sender: NSStatusBarButton) {
        if iceBar.isOpen { iceBar.hide(); return }
        guard Bridging.screenRecordingGranted() else {
            showScreenRecordingHelp()
            return
        }
        currentHidden = hiddenItems()
        let glyphs = captureGlyphs(for: currentHidden)
        guard currentHidden.isEmpty || !glyphs.isEmpty else {
            showScreenRecordingHelp()
            return
        }
        let entries = currentHidden.map { item in
            let glyph = glyphs[item.windowID]
            return BarEntry(
                glyph: glyph ?? NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: "Icon unavailable"),
                label: glyph == nil ? "\(item.displayName) — icon unavailable" : item.displayName
            )
        }
        iceBar.onSelect = { [weak self] index in
            guard let self, index >= 0, index < currentHidden.count else { return }
            itemManager.tempShowItem(currentHidden[index], clickWhenFinished: true, mouseButton: .left)
        }
        iceBar.toggle(entries, below: sender)
    }

    // MARK: - Glyph capture (composite, Ice's createImages approach)

    private func captureGlyphs(for items: [MenuBarItem]) -> [CGWindowID: NSImage] {
        guard Bridging.screenRecordingGranted(), let screen = menuBarScreen() else { return [:] }
        let scale = screen.backingScaleFactor

        var frames: [CGWindowID: CGRect] = [:]
        var windowIDs: [CGWindowID] = []
        var union = CGRect.null
        for item in items {
            guard let frame = Bridging.getWindowFrame(for: item.windowID) else { continue }
            frames[item.windowID] = frame
            windowIDs.append(item.windowID)
            union = union.union(frame)
        }
        guard
            let composite = Bridging.captureComposite(windowIDs, bounds: .null),
            CGFloat(composite.width) == (union.width * scale).rounded()
        else {
            return [:]
        }

        var result: [CGWindowID: NSImage] = [:]
        for id in windowIDs {
            guard let frame = frames[id] else { continue }
            let crop = CGRect(
                x: (frame.origin.x - union.origin.x) * scale,
                y: (frame.origin.y - union.origin.y) * scale,
                width: frame.width * scale,
                height: frame.height * scale
            )
            guard let cg = composite.cropping(to: crop) else { continue }
            result[id] = NSImage(cgImage: cg, size: NSSize(width: frame.width, height: frame.height))
        }
        return result
    }

    // MARK: - Options menu (right-click)

    private func showOptionsMenu(from button: NSStatusBarButton) {
        iceBar.hide()
        let menu = NSMenu()
        if !AXIsProcessTrusted() {
            add(menu, "Enable Accessibility for Tuck…", #selector(openAccessibilitySettings))
            menu.addItem(.separator())
        }
        if !Bridging.screenRecordingGranted() {
            add(menu, "Enable Screen Recording for Tuck…", #selector(showScreenRecordingHelp))
            menu.addItem(.separator())
        }
        addIconChecklist(to: menu)
        add(menu, "Show All", #selector(toggleReveal), state: revealInBar ? .on : .off)
        add(menu, "Launch at Login", #selector(toggleLaunchAtLogin), state: SMAppService.mainApp.status == .enabled ? .on : .off)
        menu.addItem(.separator())
        add(menu, "How to Hide an Icon…", #selector(showHelp))
        add(menu, "Icon Capture Help…", #selector(showScreenRecordingHelp))
        add(menu, "Restart Tuck…", #selector(confirmRestart))
        let quit = NSMenuItem(title: "Quit Tuck", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, state: NSControl.StateValue = .off) {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        mi.state = state
        menu.addItem(mi)
    }

    // MARK: - Icon checklist (toggle "shown always" without dragging)
    //
    // Each manageable menu bar icon is a row with a checkmark: checked = shown
    // always (right of Tuck's separator, on screen), unchecked = hidden (left of
    // it, off screen). Toggling ⌘-drags the item across the separator via
    // ItemManager, one at a time — so, unlike "Show All", macOS is never asked to
    // fit every icon on the visible bar at once and never drops the overflow.

    /// All third-party items the user can hide/show, sorted by menu-bar order.
    private func manageableItems(in items: [MenuBarItem]) -> [MenuBarItem] {
        items.filter { item in
            guard !item.info.title.hasPrefix("tuck.") else { return false }
            guard item.owningApplication != .current else { return false }
            guard item.isMovable, item.canBeHidden else { return false }
            return true
        }
    }

    private func separatorModel(in items: [MenuBarItem]) -> MenuBarItem? {
        items.first { $0.info.title == "tuck.separator" }
    }

    /// Whether a name is a useless machine placeholder (Control Center hands many
    /// items the title "Item-N", and some carry a bare UUID) rather than a real
    /// label — the signal to reach for the AX-resolved owner name instead.
    private func isPlaceholderName(_ name: String) -> Bool {
        if name.isEmpty { return true }
        if name.range(of: #"^Item-\d+$"#, options: .regularExpression) != nil { return true }
        if name.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// Whether an item is currently shown-always: it sits to the right of the
    /// divider, on the menu bar row. Position (not `isOnScreen`) is the truth —
    /// an overflow-dropped item parks low (y≈1116) and an animating item can
    /// momentarily read as on-screen while tucked away.
    private func isShownAlways(_ item: MenuBarItem, separator: MenuBarItem) -> Bool {
        item.frame.midX > separator.frame.maxX && item.frame.minY < 100
    }

    private func addIconChecklist(to menu: NSMenu) {
        guard AXIsProcessTrusted() else { return }
        let allItems = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
        let manageable = manageableItems(in: allItems)
        guard !manageable.isEmpty, let separator = separatorModel(in: allItems) else { return }

        let glyphs = captureGlyphs(for: manageable)
        let names = resolveAppNames(for: manageable) // fills in placeholder titles; owner attribution is "Control Center" for all
        menu.addItem(.sectionHeader(title: "Menu Bar Icons · \(presetLabel())"))
        for item in manageable {
            // Prefer displayName (it already names Control Center's own items:
            // Wi-Fi, Battery, Focus…). Fall back to the AX-resolved owner only
            // when displayName is a useless placeholder (Item-N / UUID / empty).
            let title = isPlaceholderName(item.displayName)
                ? (names[item.windowID] ?? "Unknown")
                : item.displayName
            let mi = NSMenuItem(title: title, action: #selector(toggleItemVisibility(_:)), keyEquivalent: "")
            mi.target = self
            mi.state = isShownAlways(item, separator: separator) ? .on : .off
            mi.representedObject = NSNumber(value: item.windowID)
            if let glyph = glyphs[item.windowID] {
                mi.image = menuGlyph(glyph)
            }
            menu.addItem(mi)
        }
        menu.addItem(.separator())
    }

    /// Names the preset being edited, e.g. "MacBook Pro, 1728pt" — so the user
    /// can tell which screen's set of icons a checklist toggle will change.
    private func presetLabel() -> String {
        guard let screen = menuBarScreen() else { return activeKey }
        return "\(screen.localizedName), \(Int(screen.frame.width.rounded()))pt"
    }

    /// A copy of an item's glyph/icon scaled to a menu-appropriate height.
    private func menuGlyph(_ image: NSImage) -> NSImage {
        let height: CGFloat = 16
        let width = image.size.height > 0 ? image.size.width * (height / image.size.height) : height
        let copy = image.copy() as! NSImage
        copy.size = NSSize(width: width, height: height)
        return copy
    }

    @objc private func toggleItemVisibility(_ sender: NSMenuItem) {
        guard let windowID = (sender.representedObject as? NSNumber)?.uint32Value else { return }
        // Re-read fresh so the frames used for the move are current.
        let allItems = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
        guard
            let item = allItems.first(where: { $0.windowID == windowID }),
            let separator = separatorModel(in: allItems)
        else { return }

        // Shown ⇒ hide it (move left of the separator);
        // hidden ⇒ show it (move right of the separator).
        let willShow = !isShownAlways(item, separator: separator)
        let destination: ItemManager.MoveDestination =
            willShow ? .rightOfItem(separator) : .leftOfItem(separator)

        // Record the decision in this screen's preset so it survives the item
        // vanishing and respawning, and so it comes back when this screen does.
        // Only real (non-placeholder) titles; ambiguous ones can't be re-matched
        // safely later anyway.
        if !isPlaceholderName(item.info.title) {
            activePreset.set(item.info, shown: willShow)
            savePresets()
            updatePolling()
        }

        Task {
            do {
                try await itemManager.slowMove(item: item, to: destination)
            } catch {
                NSLog("Tuck: toggle visibility failed for \(item.displayName): \(error)")
            }
        }
    }

    @objc private func toggleReveal() { revealInBar.toggle() }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Tuck: launch-at-login toggle failed: \(error)")
        }
    }

    @objc private func openAccessibilitySettings() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showScreenRecordingHelp() {
        iceBar.hide()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = Bridging.screenRecordingGranted()
            ? "Menu bar icons couldn’t be captured" : "Tuck needs Screen Recording"
        alert.informativeText = """
        Enable Tuck in System Settings → Privacy & Security → Screen Recording \
        (called Screen & System Audio Recording on some macOS versions). \
        Tuck uses this permission to display the real menu bar icons.

        If you already enabled it, quit and reopen Tuck or choose Restart Tuck below. \
        macOS may not make a new grant available until the app restarts.

        If restarting doesn’t help, use Show All in Tuck’s right-click menu to check \
        that the icons are still in the menu bar; macOS can drop overflowing icons.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Restart Tuck")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            restart()
        default:
            break
        }
    }

    @objc private func confirmRestart() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Restart Tuck?"
        alert.informativeText = "Your shown and hidden icon choices will be kept."
        alert.addButton(withTitle: "Restart Tuck")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { restart() }
    }

    private func restart() {
        iceBar.hide()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        // LaunchServices must start a new instance, not activate this one. Keep
        // this process alive on failure so the user still has a working chevron.
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
            Task { @MainActor in
                if app != nil {
                    NSApp.terminate(nil)
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Tuck couldn’t restart"
                    alert.informativeText = error?.localizedDescription ?? "Quit Tuck and reopen it from Applications."
                    alert.runModal()
                }
            }
        }
    }

    @objc private func showHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Hiding and showing menu bar icons"
        alert.informativeText = """
        1. Right-click Tuck's chevron and turn on “Show All” — this reveals Tuck's divider \
        (a thin bar) in the menu bar.

        2. Hold ⌘ (Command) and drag any menu bar icon to the LEFT of the divider to hide it, \
        or to the RIGHT to keep it always visible.

        3. Turn off “Show All” — everything left of the divider tucks away.

        Then click Tuck's chevron anytime for a strip of your hidden icons; click one to open it.
        """
        let diagram = NSImageView(frame: NSRect(x: 0, y: 0, width: 380, height: 96))
        diagram.image = helpDiagram()
        diagram.imageScaling = .scaleNone
        alert.accessoryView = diagram
        alert.addButton(withTitle: "Got it")
        alert.runModal()
    }

    /// A small illustration of the divider with hidden icons left, visible right.
    private func helpDiagram() -> NSImage {
        let size = NSSize(width: 380, height: 96)
        let image = NSImage(size: size)
        image.lockFocus()

        // Menu-bar strip.
        let bar = NSRect(x: 10, y: 54, width: 360, height: 30)
        NSColor(white: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 7, yRadius: 7).fill()

        func dot(_ cx: CGFloat, _ shade: CGFloat) {
            NSColor(white: shade, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - 6, y: 63, width: 12, height: 12)).fill()
        }
        // Hidden (dim) on the left.
        dot(40, 0.5); dot(64, 0.5); dot(88, 0.5)
        // The divider.
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: NSRect(x: 118, y: 61, width: 3, height: 16), xRadius: 1.5, yRadius: 1.5).fill()
        // Always-visible (bright) on the right, ending with a "clock".
        dot(150, 0.95); dot(174, 0.95); dot(198, 0.95)
        let clock = "12:00" as NSString
        clock.draw(at: NSPoint(x: 320, y: 62),
                   withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white])

        // Labels + ⌘-drag hint.
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        ("hidden" as NSString).draw(at: NSPoint(x: 44, y: 30), withAttributes: small)
        ("← divider →" as NSString).draw(at: NSPoint(x: 150, y: 30), withAttributes: small)

        let hint = "⌘-drag icons across the divider" as NSString
        hint.draw(at: NSPoint(x: 40, y: 6),
                  withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor])

        image.unlockFocus()
        return image
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
