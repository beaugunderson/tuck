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

    /// macOS 27: the hidden apps' icons are back on the bar until the chevron
    /// is clicked again or `peekTimer` fires.
    private var isPeeking = false
    private var peekTimer: Timer?
    private let peekInterval: TimeInterval = 10
    private var agentCheckTimer: Timer?
    private let autoUpdateKey = "checkForUpdatesAutomatically"
    private let askedAboutUpdatesKey = "askedAboutUpdates"
    private var updateTimer: Timer?
    private var isCheckingForUpdates = false
    /// A downloaded, verified release waiting for a restart.
    private var stagedUpdate: (version: String, bundle: URL)?
    private var isRestarting = false

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

        // macOS 27 hides by app through `AllowList`, so there is no divider there.
        if !AgentBar.isActive {
            separatorItem = NSStatusBar.system.statusItem(withLength: expandedWidth)
            separatorItem.autosaveName = "tuck.separator"
            if let button = separatorItem.button {
                button.image = dividerImage()
                button.target = self
                button.action = #selector(chevronClicked(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
        }

        loadPresets()
        activeKey = screenKey()
        applyReveal()
        updatePolling()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        if !AgentBar.isActive, !Bridging.screenRecordingGranted() {
            Bridging.requestScreenRecording()
        }
        if defaults.bool(forKey: autoUpdateKey) {
            scheduleUpdateCheck(after: 15)
        } else if !defaults.bool(forKey: askedAboutUpdatesKey) {
            // After launch settles, so it does not land under the Accessibility prompt.
            Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.askAboutUpdates() }
            }
        }
    }

    /// Hidden apps have no icon to click while Tuck is gone, so quitting
    /// switches them all back on.
    func applicationWillTerminate(_ notification: Notification) {
        // A restart hands the switches to the instance that is already running.
        guard AgentBar.isActive, !isRestarting else { return }
        try? AllowList.apply(Dictionary(uniqueKeysWithValues: managedBundles().map { ($0, true) }))
    }

    private var revealInBar: Bool {
        get { defaults.bool(forKey: revealKey) }
        set { defaults.set(newValue, forKey: revealKey); applyReveal() }
    }

    private func applyReveal() {
        if AgentBar.isActive { applyHidden(); return }
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
        (separatorItem ?? toggleItem).button?.window?.screen ?? NSScreen.screens.first
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
        if AgentBar.isActive { applyHidden(); return }
        Task { await reconcile() }
    }

    /// Runs the reconcile poll only while the active preset has entries — an
    /// empty preset means no timer, so the idle cost stays at zero. macOS 27
    /// needs no poll: the system keeps an app's switch across relaunches.
    private func updatePolling() {
        if activePreset.isEmpty || AgentBar.isActive {
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

    // MARK: - Hiding by app (macOS 27)
    //
    // A preset's `hidden` set holds one entry per hidden app, keyed by bundle
    // identifier with an empty title. Hidden means the app's "Allow in the
    // Menu Bar" switch is off; `applyHidden` makes the switches match.

    private func bundleInfo(_ bundleID: String) -> MenuBarItemInfo {
        MenuBarItemInfo(namespace: MenuBarItemInfo.Namespace(bundleID), title: "")
    }

    private func hiddenBundles(in preset: ScreenPreset) -> Set<String> {
        Set(preset.hidden.filter { $0.title.isEmpty }.map(\.namespace.rawValue))
    }

    /// Every app any screen's preset hides: the switches Tuck is responsible
    /// for. An app the user switched off in System Settings is never in here.
    private func managedBundles() -> Set<String> {
        presets.values.reduce(into: Set<String>()) { $0.formUnion(hiddenBundles(in: $1)) }
    }

    /// The names `MenuBarAgent` may file an app's saved positions under: its
    /// bundle identifier, or the app's own name.
    private func itemOwners(of bundles: Set<String>) -> Set<String> {
        var owners = bundles
        for bundle in bundles {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
            let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            if let name = running?.localizedName { owners.insert(name) }
            if let name = url?.deletingPathExtension().lastPathComponent { owners.insert(name) }
        }
        return owners
    }

    /// Switches off the active preset's hidden apps and switches on the rest
    /// of the managed ones; everything is on while peeking or showing all.
    /// Returns false when the switches could not be read or written.
    @discardableResult
    private func applyHidden() -> Bool {
        let hidden = hiddenBundles(in: activePreset)
        let hide = (isPeeking || revealInBar) ? [] : hidden
        let changes = Dictionary(uniqueKeysWithValues: managedBundles().map { ($0, !hide.contains($0)) })
        do {
            // Before any switch flips, so icons that come back land together
            // on the left instead of in among the always-shown ones.
            try ItemOrder.group(hiddenOwners: itemOwners(of: hidden))
            if try AllowList.apply(changes) { scheduleAgentCheck() }
            return true
        } catch {
            NSLog("Tuck: could not update the menu bar allow list: \(error)")
            return false
        }
    }

    /// `MenuBarAgent` stops hearing about allow-list writes once the user's
    /// `cfprefsd` has been killed: the write lands and the bar does not move.
    /// A restarted agent reloads the list, so a write the bar ignored gets one.
    private func scheduleAgentCheck() {
        agentCheckTimer?.invalidate()
        guard AXIsProcessTrusted() else { return }
        agentCheckTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.restartAgentIfStale() }
        }
    }

    private func restartAgentIfStale() {
        let hidden = hiddenBundles(in: activePreset)
        let onBar = Set(AgentBar.items(on: nil).compactMap {
            NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier
        })
        let stale: Bool
        if isPeeking || revealInBar {
            let running = hidden.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
            stale = !running.isEmpty && onBar.isDisjoint(with: running)
        } else {
            stale = !onBar.isDisjoint(with: hidden)
        }
        guard stale, let agent = AgentBar.agent else { return }
        NSLog("Tuck: the menu bar ignored an allow-list write; restarting MenuBarAgent")
        kill(agent.processIdentifier, SIGTERM)
    }

    private func setPeeking(_ peeking: Bool) {
        isPeeking = peeking
        peekTimer?.invalidate()
        peekTimer = nil
        // A click that changes nothing on the bar says why.
        guard applyHidden() else {
            isPeeking = false
            showFullDiskAccessHelp()
            return
        }
        chevron?.setExpanded(peeking)
        toggleItem.button?.toolTip = peeking
            ? "Tuck — click to hide menu bar icons"
            : "Tuck — click to see hidden menu bar icons"
        toggleItem.button?.setAccessibilityValue(peeking ? "Expanded" : "Collapsed")
        if peeking { schedulePeekEnd(after: peekInterval) }
    }

    /// A one-shot timer that hides the icons again, unless the pointer is
    /// still up in the menu bar or a button is down (a menu is being used).
    private func schedulePeekEnd(after interval: TimeInterval) {
        peekTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPeeking else { return }
                let pointer = NSEvent.mouseLocation
                let inMenuBar = NSScreen.screens.contains { $0.frame.contains(pointer) && pointer.y > $0.frame.maxY - 30 }
                if inMenuBar || NSEvent.pressedMouseButtons != 0 {
                    self.schedulePeekEnd(after: 3)
                } else {
                    self.setPeeking(false)
                }
            }
        }
    }

    /// One row per app: those with an icon on the bar now, then the hidden ones.
    private func addAppChecklist(to menu: NSMenu) {
        guard let states = try? AllowList.states() else {
            add(menu, "Enable Full Disk Access for Tuck…", #selector(showFullDiskAccessHelp))
            menu.addItem(.separator())
            return
        }
        let agentPID = AgentBar.agent?.processIdentifier
        var bundles: [String] = []
        for item in AgentBar.items(on: menuBarScreen()) where item.pid != getpid() && item.pid != agentPID {
            guard let bundle = NSRunningApplication(processIdentifier: item.pid)?.bundleIdentifier, !bundles.contains(bundle) else { continue }
            bundles.append(bundle)
        }
        let hidden = hiddenBundles(in: activePreset)
        bundles += hidden.subtracting(bundles).sorted()
        guard !bundles.isEmpty else { return }

        menu.addItem(.sectionHeader(title: "Menu Bar Icons · \(presetLabel())"))
        for bundle in bundles {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
            let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            let name = running?.localizedName.flatMap { $0.isEmpty ? nil : $0 }
                ?? url?.deletingPathExtension().lastPathComponent
                ?? bundle
            let mi = NSMenuItem(title: name, action: #selector(toggleAppVisibility(_:)), keyEquivalent: "")
            mi.target = self
            // An app switched off in System Settings, outside Tuck, also reads as hidden.
            mi.state = hidden.contains(bundle) || states[bundle] == false ? .off : .on
            mi.representedObject = bundle
            if let url { mi.image = menuGlyph(NSWorkspace.shared.icon(forFile: url.path)) }
            menu.addItem(mi)
        }
        menu.addItem(.separator())
    }

    @objc private func toggleAppVisibility(_ sender: NSMenuItem) {
        guard let bundle = sender.representedObject as? String else { return }
        var preset = activePreset
        if sender.state == .on {
            preset.hidden.insert(bundleInfo(bundle))
        } else {
            preset.hidden.remove(bundleInfo(bundle))
            // Switch it on here: once out of every preset it is no longer managed.
            try? AllowList.apply([bundle: true])
        }
        activePreset = preset
        savePresets()
        applyHidden()
    }

    @objc private func showFullDiskAccessHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Tuck needs Full Disk Access"
        alert.informativeText = """
        On macOS 27, Tuck hides an app's menu bar icons by switching it off in System Settings → \
        Menu Bar → Allow in the Menu Bar. macOS keeps those switches in Control Center's settings \
        file, which an app can only read and change with Full Disk Access.

        Tuck reads and writes that one file. Enable Tuck in System Settings → Privacy & Security → \
        Full Disk Access, then restart Tuck.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Restart Tuck")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            restart()
        default:
            break
        }
    }

    private func toggleBar(from sender: NSStatusBarButton) {
        if AgentBar.isActive { setPeeking(!isPeeking); return }
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
        if !AgentBar.isActive, !Bridging.screenRecordingGranted() {
            add(menu, "Enable Screen Recording for Tuck…", #selector(showScreenRecordingHelp))
            menu.addItem(.separator())
        }
        addIconChecklist(to: menu)
        add(menu, "Show All", #selector(toggleReveal), state: revealInBar ? .on : .off)
        add(menu, "Launch at Login", #selector(toggleLaunchAtLogin), state: SMAppService.mainApp.status == .enabled ? .on : .off)
        menu.addItem(.separator())
        if let stagedUpdate {
            add(menu, "Restart to Update to Tuck \(stagedUpdate.version)", #selector(installUpdate))
        } else {
            add(menu, "Check for Updates…", #selector(checkForUpdatesNow))
        }
        add(menu, "Check for Updates Automatically", #selector(toggleAutoUpdate), state: defaults.bool(forKey: autoUpdateKey) ? .on : .off)
        menu.addItem(.separator())
        add(menu, "How to Hide an Icon…", #selector(showHelp))
        if !AgentBar.isActive { add(menu, "Icon Capture Help…", #selector(showScreenRecordingHelp)) }
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
        if AgentBar.isActive { addAppChecklist(to: menu); return }
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
                    self.isRestarting = true
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

    // MARK: - Updates (opt-in)
    //
    // A check asks `Updater` for the latest release and, when it is newer than
    // this build, downloads and verifies it. The result waits in the options
    // menu as "Restart to Update"; nothing is installed until that is chosen.

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Asked once per install; the answer is the menu's switch.
    private func askAboutUpdates() {
        defaults.set(true, forKey: askedAboutUpdatesKey)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Check for Tuck updates automatically?"
        alert.informativeText = """
        Tuck can look for a new version once a day and download it. It never installs on its own: \
        the update waits in the right-click menu until you restart Tuck.

        You can change this any time from that menu.
        """
        alert.addButton(withTitle: "Check Automatically")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { toggleAutoUpdate() }
    }

    @objc private func toggleAutoUpdate() {
        let enabled = !defaults.bool(forKey: autoUpdateKey)
        defaults.set(enabled, forKey: autoUpdateKey)
        updateTimer?.invalidate()
        updateTimer = nil
        if enabled { scheduleUpdateCheck(after: 1) }
    }

    /// A one-shot timer; each automatic check schedules the next, a day later.
    private func scheduleUpdateCheck(after interval: TimeInterval) {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.defaults.bool(forKey: self.autoUpdateKey) else { return }
                await self.checkForUpdates(manual: false)
                self.scheduleUpdateCheck(after: 24 * 60 * 60)
            }
        }
    }

    @objc private func checkForUpdatesNow() {
        Task { await checkForUpdates(manual: true) }
    }

    private func checkForUpdates(manual: Bool) async {
        guard stagedUpdate == nil, !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        do {
            let latest = try await Updater.latest()
            guard Updater.isNewer(latest.version, than: currentVersion) else {
                if manual { updateAlert("Tuck is up to date", "Version \(currentVersion) is the latest release.") }
                return
            }
            let bundle = try await Updater.stage(version: latest.version, from: latest.url, replacing: Bundle.main.bundleURL)
            stagedUpdate = (latest.version, bundle)
            toggleItem.button?.toolTip = "Tuck — version \(latest.version) is ready; right-click to restart into it"
            if manual { offerStagedUpdate() }
        } catch {
            NSLog("Tuck: update check failed: \(error)")
            if manual { updateAlert("Tuck couldn’t check for updates", "\(error.localizedDescription)\n\nYou can download the latest version from tuck.bar.") }
        }
    }

    private func updateAlert(_ message: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    private func offerStagedUpdate() {
        guard let stagedUpdate else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Tuck \(stagedUpdate.version) is ready"
        alert.informativeText = "You have \(currentVersion). Restart Tuck to finish updating, or do it later from the right-click menu."
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { installUpdate() }
    }

    @objc private func installUpdate() {
        guard let stagedUpdate else { return }
        do {
            try Updater.install(stagedUpdate.bundle, over: Bundle.main.bundleURL)
            self.stagedUpdate = nil
            restart()
        } catch {
            NSLog("Tuck: update install failed: \(error)")
            updateAlert("Tuck couldn’t install the update", "\(error.localizedDescription)\n\nYou can download version \(stagedUpdate.version) from tuck.bar.")
        }
    }

    @objc private func showHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Hiding and showing menu bar icons"
        if AgentBar.isActive {
            alert.informativeText = """
            1. Right-click Tuck's chevron and untick an app — its menu bar icons disappear. \
            Tick it again to bring them back.

            2. Click Tuck's chevron anytime to bring every hidden icon back for a moment; \
            click it again, or move away from the menu bar, and they hide.

            Hiding works per app: if an app has several menu bar icons, they hide together.
            """
            alert.addButton(withTitle: "Got it")
            alert.runModal()
            return
        }
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
