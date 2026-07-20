import Cocoa

// Ported from Ice's MenuBarItemManager (GPLv3), trimmed to just the click/move/
// temp-show machinery. Removed: ObservableObject/Combine, AppState, item caching,
// section model, and the always-on mouse-tracking event monitor (that monitor is
// Ice's idle-CPU cost; Tuck acts only on explicit clicks). The event taps used
// here are transient — created per operation with a 50 ms timeout — so they add
// no idle cost. The synthetic-event logic itself is preserved verbatim.

// Debug file logger (log show redacts NSLog as <private>).
func tlog(_ s: String) {
    let line = "\(s)\n"
    let path = "/tmp/tuck.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); fh.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

@MainActor
final class ItemManager {
    private var tempShownItemContexts: [TempShownItemContext] = []
    private var tempShownItemsTimer: Timer?
    private var itemMoveCount = 0
    /// How long a temporarily shown item stays out before it's rehidden.
    private let tempShowInterval: TimeInterval = 5

    var isMovingItem: Bool { itemMoveCount > 0 }

    private struct TempShownItemContext {
        let windowID: CGWindowID // unique — `info` collides (many CC items share "Item-0")
        let returnDestination: MoveDestination
        let shownInterfaceWindow: WindowInfo?

        var isShowingInterface: Bool {
            guard let currentWindow = shownInterfaceWindow.flatMap({ WindowInfo(windowID: $0.windowID) }) else {
                return false
            }
            return if
                currentWindow.layer != CGWindowLevelForKey(.popUpMenuWindow),
                let owningApplication = currentWindow.owningApplication
            {
                owningApplication.isActive && currentWindow.isOnScreen
            } else {
                currentWindow.isOnScreen
            }
        }
    }
}

// MARK: - Errors

extension ItemManager {
    struct EventError: Error, CustomStringConvertible, LocalizedError {
        enum ErrorCode: Int {
            case couldNotComplete, eventCreationFailure, invalidEventSource
            case invalidCursorLocation, invalidItem, notMovable
            case eventOperationTimeout, frameCheckTimeout, otherTimeout, notEnoughRoom
        }
        let code: ErrorCode
        let item: MenuBarItem
        // `code` is a plain enum (not CustomStringConvertible), so interpolating it
        // reflects the case name without recursing.
        var description: String { "EventError(code: \(code), item: \(item.logString))" }
        var errorDescription: String? { "Menu bar item event failed (\(code)) for \(item.displayName)" }
    }
}

// MARK: - Move destinations

extension ItemManager {
    enum MoveDestination {
        case leftOfItem(MenuBarItem)
        case rightOfItem(MenuBarItem)
        var logString: String {
            switch self {
            case .leftOfItem(let item): "left of \(item.logString)"
            case .rightOfItem(let item): "right of \(item.logString)"
            }
        }
    }

    private func getCurrentFrame(for item: MenuBarItem) -> CGRect? {
        Bridging.getWindowFrame(for: item.windowID)
    }

    private func getEndPoint(for destination: MoveDestination) throws -> CGPoint {
        switch destination {
        case .leftOfItem(let targetItem):
            guard let frame = getCurrentFrame(for: targetItem) else { throw EventError(code: .invalidItem, item: targetItem) }
            return CGPoint(x: frame.minX, y: frame.midY)
        case .rightOfItem(let targetItem):
            guard let frame = getCurrentFrame(for: targetItem) else { throw EventError(code: .invalidItem, item: targetItem) }
            return CGPoint(x: frame.maxX, y: frame.midY)
        }
    }

    private func getFallbackPoint(for item: MenuBarItem) throws -> CGPoint {
        guard let frame = getCurrentFrame(for: item) else { throw EventError(code: .invalidItem, item: item) }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func getTargetItem(for destination: MoveDestination) -> MenuBarItem {
        switch destination {
        case .leftOfItem(let t), .rightOfItem(let t): t
        }
    }

    private func itemHasCorrectPosition(item: MenuBarItem, for destination: MoveDestination) throws -> Bool {
        guard let currentFrame = getCurrentFrame(for: item) else { throw EventError(code: .invalidItem, item: item) }
        switch destination {
        case .leftOfItem(let targetItem):
            guard let t = getCurrentFrame(for: targetItem) else { throw EventError(code: .invalidItem, item: targetItem) }
            return currentFrame.maxX == t.minX
        case .rightOfItem(let targetItem):
            guard let t = getCurrentFrame(for: targetItem) else { throw EventError(code: .invalidItem, item: targetItem) }
            return currentFrame.minX == t.maxX
        }
    }
}

// MARK: - Event posting (verbatim from Ice)

extension ItemManager {
    private nonisolated func eventsMatch(_ events: [CGEvent], by integerFields: [CGEventField]) -> Bool {
        var fieldValues = Set<[Int64]>()
        for event in events {
            let values = integerFields.map(event.getIntegerValueField)
            fieldValues.insert(values)
            if fieldValues.count != 1 { return false }
        }
        return true
    }

    private nonisolated func postEvent(_ event: CGEvent, to location: EventTap.Location) {
        switch location {
        case .hidEventTap: event.post(tap: .cghidEventTap)
        case .sessionEventTap: event.post(tap: .cgSessionEventTap)
        case .annotatedSessionEventTap: event.post(tap: .cgAnnotatedSessionEventTap)
        case .pid(let pid): event.postToPid(pid)
        }
    }

    private func postEventAndWaitToReceive(_ event: CGEvent, to location: EventTap.Location, item: MenuBarItem) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let eventTap = EventTap(
                options: .listenOnly, location: location, place: .tailAppendEventTap, types: [event.type]
            ) { [weak self] proxy, type, rEvent in
                guard let self else { proxy.disable(); return nil }
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout { proxy.enable(); return nil }
                guard eventsMatch([rEvent, event], by: CGEventField.menuBarItemEventFields) else { return nil }
                guard proxy.isEnabled else { return nil }
                proxy.disable()
                continuation.resume()
                return nil
            }
            eventTap.enable(timeout: .milliseconds(50)) {
                eventTap.disable()
                continuation.resume(throwing: EventError(code: .eventOperationTimeout, item: item))
            }
            postEvent(event, to: location)
        }
    }

    private func scrombleEvent(_ event: CGEvent, from firstLocation: EventTap.Location, to secondLocation: EventTap.Location, item: MenuBarItem) async throws {
        guard let nullEvent = CGEvent(source: nil) else { throw EventError(code: .eventCreationFailure, item: item) }
        let nullUserData = Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(nullEvent)))
        nullEvent.setIntegerValueField(.eventSourceUserData, value: nullUserData)

        return try await withCheckedThrowingContinuation { continuation in
            let eventTap1 = EventTap(
                label: "EventTap 1", options: .defaultTap, location: firstLocation, place: .tailAppendEventTap, types: [nullEvent.type]
            ) { [weak self] proxy, type, rEvent in
                guard let self else { proxy.disable(); return nil }
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout { proxy.enable(); return nil }
                guard rEvent.getIntegerValueField(.eventSourceUserData) == nullUserData else { return nil }
                proxy.disable()
                postEvent(event, to: secondLocation)
                return nil
            }
            let eventTap2 = EventTap(
                label: "EventTap 2", options: .listenOnly, location: secondLocation, place: .tailAppendEventTap, types: [event.type]
            ) { [weak self] proxy, type, rEvent in
                guard let self else { proxy.disable(); return nil }
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout { proxy.enable(); return nil }
                guard eventsMatch([rEvent, event], by: CGEventField.menuBarItemEventFields) else { return nil }
                guard proxy.isEnabled else { return nil }
                proxy.disable()
                postEvent(event, to: firstLocation)
                continuation.resume()
                return nil
            }
            eventTap1.enable()
            eventTap2.enable(timeout: .milliseconds(50)) {
                eventTap1.disable()
                eventTap2.disable()
                continuation.resume(throwing: EventError(code: .eventOperationTimeout, item: item))
            }
            postEvent(nullEvent, to: firstLocation)
        }
    }

    private func scrombleEvent(_ event: CGEvent, from firstLocation: EventTap.Location, to secondLocation: EventTap.Location, waitingForFrameChangeOf item: MenuBarItem) async throws {
        guard let currentFrame = getCurrentFrame(for: item) else {
            try await scrombleEvent(event, from: firstLocation, to: secondLocation, item: item)
            try await Task.sleep(for: .milliseconds(50))
            return
        }
        try await scrombleEvent(event, from: firstLocation, to: secondLocation, item: item)
        try await waitForFrameChange(of: item, initialFrame: currentFrame, timeout: .milliseconds(50))
    }

    private func waitForFrameChange(of item: MenuBarItem, initialFrame: CGRect, timeout: Duration) async throws {
        struct FrameCheckCancellationError: Error { }
        let frameCheckTask = Task(timeout: timeout) {
            while true {
                try Task.checkCancellation()
                guard let currentFrame = await self.getCurrentFrame(for: item) else { throw FrameCheckCancellationError() }
                if currentFrame != initialFrame { return }
            }
        }
        do {
            try await frameCheckTask.value
        } catch is FrameCheckCancellationError {
            try await Task.sleep(for: .milliseconds(50))
        } catch is TaskTimeoutError {
            throw EventError(code: .frameCheckTimeout, item: item)
        }
    }

    private func permitAllEvents(for stateID: CGEventSourceStateID, during states: [CGEventSuppressionState], suppressionInterval: TimeInterval, item: MenuBarItem) throws {
        guard let source = CGEventSource(stateID: stateID) else { throw EventError(code: .invalidEventSource, item: item) }
        for state in states {
            source.setLocalEventsFilterDuringSuppressionState(.permitAllEvents, state: state)
        }
        source.localEventsSuppressionInterval = suppressionInterval
    }

    private func wakeUpItem(_ item: MenuBarItem) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else { throw EventError(code: .invalidEventSource, item: item) }
        guard let currentFrame = getCurrentFrame(for: item) else { throw EventError(code: .invalidItem, item: item) }
        guard
            let mouseDownEvent = CGEvent.menuBarItemEvent(type: .move(.leftMouseDown), location: CGPoint(x: currentFrame.midX, y: currentFrame.midY), item: item, pid: item.ownerPID, source: source),
            let mouseUpEvent = CGEvent.menuBarItemEvent(type: .move(.leftMouseUp), location: CGPoint(x: currentFrame.midX, y: currentFrame.midY), item: item, pid: item.ownerPID, source: source)
        else { throw EventError(code: .eventCreationFailure, item: item) }
        try await scrombleEvent(mouseDownEvent, from: .pid(item.ownerPID), to: .sessionEventTap, item: item)
        try await scrombleEvent(mouseUpEvent, from: .pid(item.ownerPID), to: .sessionEventTap, item: item)
    }
}

// MARK: - Move

extension ItemManager {
    private func moveItemWithoutRestoringMouseLocation(_ item: MenuBarItem, to destination: MoveDestination) async throws {
        itemMoveCount += 1
        defer { itemMoveCount -= 1 }

        guard item.isMovable else { throw EventError(code: .notMovable, item: item) }
        guard let source = CGEventSource(stateID: .hidSystemState) else { throw EventError(code: .invalidEventSource, item: item) }

        let startPoint = CGPoint(x: 20_000, y: 20_000)
        let endPoint = try getEndPoint(for: destination)
        let fallbackPoint = try getFallbackPoint(for: item)
        let targetItem = getTargetItem(for: destination)

        guard
            let mouseDownEvent = CGEvent.menuBarItemEvent(type: .move(.leftMouseDown), location: startPoint, item: item, pid: item.ownerPID, source: source),
            let mouseUpEvent = CGEvent.menuBarItemEvent(type: .move(.leftMouseUp), location: endPoint, item: targetItem, pid: item.ownerPID, source: source),
            let fallbackEvent = CGEvent.menuBarItemEvent(type: .move(.leftMouseUp), location: fallbackPoint, item: item, pid: item.ownerPID, source: source)
        else { throw EventError(code: .eventCreationFailure, item: item) }

        try permitAllEvents(
            for: .combinedSessionState,
            during: [.eventSuppressionStateRemoteMouseDrag, .eventSuppressionStateSuppressionInterval],
            suppressionInterval: 0, item: item
        )

        do {
            try await scrombleEvent(mouseDownEvent, from: .pid(item.ownerPID), to: .sessionEventTap, waitingForFrameChangeOf: item)
            try await scrombleEvent(mouseUpEvent, from: .pid(item.ownerPID), to: .sessionEventTap, waitingForFrameChangeOf: item)
        } catch {
            try? await postEventAndWaitToReceive(fallbackEvent, to: .sessionEventTap, item: item)
            throw error
        }
    }

    func move(item: MenuBarItem, to destination: MoveDestination) async throws {
        if try itemHasCorrectPosition(item: item, for: destination) { return }

        try await waitForNoModifiersPressed()

        guard let cursorLocation = MouseCursor.locationCoreGraphics else { throw EventError(code: .invalidCursorLocation, item: item) }
        guard let initialFrame = getCurrentFrame(for: item) else { throw EventError(code: .invalidItem, item: item) }

        MouseCursor.hide()
        defer {
            MouseCursor.warp(to: cursorLocation)
            MouseCursor.show()
        }

        // Item movement can occasionally fail. Retry up to 5 attempts.
        for n in 1...5 {
            do {
                try await moveItemWithoutRestoringMouseLocation(item, to: destination)
                guard let newFrame = getCurrentFrame(for: item) else { throw EventError(code: .invalidItem, item: item) }
                if newFrame != initialFrame { break }
                throw EventError(code: .couldNotComplete, item: item)
            } catch where n < 5 {
                try? await wakeUpItem(item)
                continue
            }
        }
    }

    func slowMove(item: MenuBarItem, to destination: MoveDestination, timeout: Duration = .seconds(1)) async throws {
        itemMoveCount += 1
        defer { itemMoveCount -= 1 }
        try await move(item: item, to: destination)
        let waitTask = Task(timeout: timeout) {
            while true {
                try Task.checkCancellation()
                if try await self.itemHasCorrectPosition(item: item, for: destination) { return }
            }
        }
        do {
            try await waitTask.value
        } catch is TaskTimeoutError {
            throw EventError(code: .otherTimeout, item: item)
        }
    }
}

// MARK: - Click

extension ItemManager {
    func click(item: MenuBarItem, with mouseButton: CGMouseButton) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else { throw EventError(code: .invalidEventSource, item: item) }
        guard let cursorLocation = MouseCursor.locationCoreGraphics else { throw EventError(code: .invalidCursorLocation, item: item) }
        guard let currentFrame = getCurrentFrame(for: item) else { throw EventError(code: .invalidItem, item: item) }

        let buttonStates = mouseButton.buttonStates
        let clickPoint = CGPoint(x: currentFrame.midX, y: currentFrame.midY)

        guard
            let mouseDownEvent = CGEvent.menuBarItemEvent(type: .click(buttonStates.down), location: clickPoint, item: item, pid: item.ownerPID, source: source),
            let mouseUpEvent = CGEvent.menuBarItemEvent(type: .click(buttonStates.up), location: clickPoint, item: item, pid: item.ownerPID, source: source),
            let fallbackEvent = CGEvent.menuBarItemEvent(type: .click(buttonStates.up), location: clickPoint, item: item, pid: item.ownerPID, source: source)
        else { throw EventError(code: .eventCreationFailure, item: item) }

        try permitAllEvents(
            for: .combinedSessionState,
            during: [.eventSuppressionStateRemoteMouseDrag, .eventSuppressionStateSuppressionInterval],
            suppressionInterval: 0, item: item
        )

        MouseCursor.hide()
        defer {
            MouseCursor.warp(to: cursorLocation)
            MouseCursor.show()
        }

        do {
            try await postEventAndWaitToReceive(mouseDownEvent, to: .sessionEventTap, item: item)
            try await postEventAndWaitToReceive(mouseUpEvent, to: .sessionEventTap, item: item)
        } catch {
            try? await postEventAndWaitToReceive(fallbackEvent, to: .sessionEventTap, item: item)
            throw error
        }
    }
}

// MARK: - Temporarily show (Tuck-adapted: no section model)

extension ItemManager {
    /// Returns where to move an item back to after temporarily showing it.
    private func getReturnDestination(for item: MenuBarItem, in items: [MenuBarItem]) -> MoveDestination? {
        if let index = items.firstIndex(where: { $0.windowID == item.windowID }) {
            if items.indices.contains(index + 1) { return .leftOfItem(items[index + 1]) }
            if items.indices.contains(index - 1) { return .rightOfItem(items[index - 1]) }
        }
        return nil
    }

    private func runTempShownItemTimer(for interval: TimeInterval) {
        tlog("scheduling rehide in \(interval)s (\(tempShownItemContexts.count) temp-shown)")
        tempShownItemsTimer?.invalidate()
        tempShownItemsTimer = .scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { await self.rehideTempShownItems() }
        }
    }

    /// Temporarily moves a hidden item on-screen (so its own menu can open where
    /// the user can see it), optionally clicks it, then schedules a move back.
    func tempShowItem(_ item: MenuBarItem, clickWhenFinished: Bool, mouseButton: CGMouseButton) {
        if let latest = MenuBarItem(windowID: item.windowID), latest.isOnScreen {
            if clickWhenFinished {
                Task { try? await click(item: latest, with: mouseButton) }
            }
            return
        }

        guard let screen = NSScreen.main else { return }
        let allItems = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true).sortedByOrderInMenuBar()
        guard let destination = getReturnDestination(for: item, in: allItems) else { return }

        // Place the item just left of the leftmost on-screen item that still
        // leaves room right of the notch.
        let minX = (screen.auxiliaryTopRightArea?.minX ?? 0) + 20
        let onScreen = allItems.filter(\.isOnScreen)
        guard let targetItem = onScreen.first(where: { $0.frame.minX - item.frame.width > minX }) else {
            tlog("not enough room to temporarily show \(item.displayName)")
            return
        }
        tlog("tempShow \(item.logString): destination=leftOf \(targetItem.logString), returnTo=\(destination.logString)")

        let initialWindows = WindowInfo.getOnScreenWindows()

        Task {
            do {
                if clickWhenFinished {
                    try await slowMove(item: item, to: .leftOfItem(targetItem))
                    try await click(item: item, with: mouseButton)
                } else {
                    try await move(item: item, to: .leftOfItem(targetItem))
                }
            } catch {
                Logger.itemManager.error("temp-show failed: \(error)")
            }

            try? await Task.sleep(for: .milliseconds(100))
            let currentWindows = WindowInfo.getOnScreenWindows()
            let shownInterfaceWindow = currentWindows.first { cur in
                cur.ownerPID == item.ownerPID && !initialWindows.contains { $0.windowID == cur.windowID }
            }
            tempShownItemContexts.append(TempShownItemContext(
                windowID: item.windowID, returnDestination: destination, shownInterfaceWindow: shownInterfaceWindow))
            runTempShownItemTimer(for: tempShowInterval)
        }
    }

    func rehideTempShownItems() async {
        itemMoveCount += 1
        defer { itemMoveCount -= 1 }

        tlog("rehide fired (\(tempShownItemContexts.count) contexts)")
        guard !tempShownItemContexts.isEmpty else { return }
        guard NSEvent.pressedMouseButtons == 0 else {
            tlog("rehide deferred — mouse button down"); runTempShownItemTimer(for: 3); return
        }
        guard !tempShownItemContexts.contains(where: { $0.isShowingInterface }) else {
            tlog("rehide deferred — interface still showing"); runTempShownItemTimer(for: 3); return
        }

        var failed: [TempShownItemContext] = []
        let items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)

        MouseCursor.hide()
        defer { MouseCursor.show() }

        while let context = tempShownItemContexts.popLast() {
            guard let item = items.first(where: { $0.windowID == context.windowID }) else {
                tlog("rehide: item win=\(context.windowID) no longer found"); continue
            }
            do {
                tlog("rehide: moving \(item.logString) to \(context.returnDestination.logString); before frame=\(getCurrentFrame(for: item).map { "\($0)" } ?? "nil")")
                try await move(item: item, to: context.returnDestination)
                tlog("rehide: moved \(item.logString); after frame=\(getCurrentFrame(for: item).map { "\($0)" } ?? "nil")")
            } catch {
                tlog("rehide FAILED for \(item.logString): \(error)")
                failed.append(context)
            }
        }

        if failed.isEmpty {
            tempShownItemsTimer?.invalidate()
            tempShownItemsTimer = nil
        } else {
            tempShownItemContexts = failed
            runTempShownItemTimer(for: 3)
        }
    }
}

// MARK: - Async waiters (poll-based; no always-on monitors)

extension ItemManager {
    private func waitWithTask(timeout: Duration?, operation: @escaping @Sendable () async throws -> Void) async throws {
        let task = timeout.map { Task(timeout: $0, operation: operation) } ?? Task(operation: operation)
        try await task.value
    }

    func waitForItemsToStopMoving(timeout: Duration? = nil) async throws {
        try await waitWithTask(timeout: timeout) { [weak self] in
            guard let self else { return }
            while await isMovingItem {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    func waitForNoModifiersPressed(timeout: Duration? = .seconds(2)) async throws {
        // Only the real chord modifiers — not Fn/capsLock/numericPad, which can
        // read as "pressed" and cause a spurious timeout.
        let chord: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        try await waitWithTask(timeout: timeout) {
            while !NSEvent.modifierFlags.intersection(chord).isEmpty {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}

// MARK: - CGEvent construction (verbatim from Ice)

private enum MenuBarItemEventButtonState {
    case leftMouseDown, leftMouseUp, rightMouseDown, rightMouseUp, otherMouseDown, otherMouseUp
}

private enum MenuBarItemEventType {
    case move(MenuBarItemEventButtonState)
    case click(MenuBarItemEventButtonState)
    var buttonState: MenuBarItemEventButtonState {
        switch self {
        case .move(let s), .click(let s): s
        }
    }
    var cgEventType: CGEventType {
        switch buttonState {
        case .leftMouseDown: .leftMouseDown
        case .leftMouseUp: .leftMouseUp
        case .rightMouseDown: .rightMouseDown
        case .rightMouseUp: .rightMouseUp
        case .otherMouseDown: .otherMouseDown
        case .otherMouseUp: .otherMouseUp
        }
    }
    var cgEventFlags: CGEventFlags {
        switch self {
        case .move(.leftMouseDown): .maskCommand
        case .move, .click: []
        }
    }
    var mouseButton: CGMouseButton {
        switch buttonState {
        case .leftMouseDown, .leftMouseUp: .left
        case .rightMouseDown, .rightMouseUp: .right
        case .otherMouseDown, .otherMouseUp: .center
        }
    }
}

private extension CGMouseButton {
    var buttonStates: (down: MenuBarItemEventButtonState, up: MenuBarItemEventButtonState) {
        switch self {
        case .left: (.leftMouseDown, .leftMouseUp)
        case .right: (.rightMouseDown, .rightMouseUp)
        default: (.otherMouseDown, .otherMouseUp)
        }
    }
}

private extension CGEventField {
    static let windowID = CGEventField(rawValue: 0x33)!
    static let menuBarItemEventFields: [CGEventField] = [
        .eventSourceUserData,
        .mouseEventWindowUnderMousePointer,
        .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
        .windowID,
    ]
}

private extension CGEventFilterMask {
    static let permitAllEvents: CGEventFilterMask = [
        .permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents,
    ]
}

private extension CGEvent {
    class func menuBarItemEvent(type: MenuBarItemEventType, location: CGPoint, item: MenuBarItem, pid: pid_t, source: CGEventSource) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type.cgEventType, mouseCursorPosition: location, mouseButton: type.mouseButton) else {
            return nil
        }
        event.flags = type.cgEventFlags
        let targetPID = Int64(pid)
        let userData = Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(event)))
        let windowID = Int64(item.windowID)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: targetPID)
        event.setIntegerValueField(.eventSourceUserData, value: userData)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowID)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowID)
        event.setIntegerValueField(.windowID, value: windowID)
        if case .click = type {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        return event
    }
}

private extension Logger {
    static let itemManager = Logger(category: "ItemManager")
}
