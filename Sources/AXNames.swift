import Cocoa
import ApplicationServices

// Resolve real application names for menu bar items.
//
// On macOS 26 the CGWindow owner of every status item reports "Control Center"
// (the compositor hosts them), and Control-Center-namespace items carry useless
// titles like "Item-0" or a UUID. The real owner is discoverable through
// Accessibility: each app exposes its status items under `AXExtrasMenuBar`,
// rooted at the app's own pid. We walk every app's extras, read each AX item's
// on-screen frame, and match it back to a window by left edge — the AX element
// and the CGWindow are the same on-screen thing, so their frames coincide.
//
// Limitation: an app that publishes nothing to Accessibility (e.g. ZeroTier, a
// Qt app whose AX element exposes no attributes at all) is unresolvable — there
// is no bridge from its Control-Center-hosted window back to its process.
//
// Cost control (right-click must feel instant):
//   - each app's IPC bounded by a short messaging timeout;
//   - the per-app walks run in parallel, so wall time is the slowest app, not
//     the sum. Ported from probe/probe_ax.swift; used on-click only.

/// Thread-safe sink for the parallel walk. `@unchecked` because the array is
/// guarded by the lock.
private final class AXEntryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var entries: [(minX: CGFloat, width: CGFloat, name: String)] = []
    func add(_ new: [(minX: CGFloat, width: CGFloat, name: String)]) {
        lock.lock()
        entries.append(contentsOf: new)
        lock.unlock()
    }
}

@MainActor
func resolveAppNames(for items: [MenuBarItem]) -> [CGWindowID: String] {
    // Include every process: some menu bar agents (e.g. ZeroTier) run as
    // background-only (.prohibited) apps yet still own a status item. Old apps
    // (e.g. ControlPlane) have an empty localizedName, so fall back to the bundle
    // name. The parallel walk below absorbs the extra processes.
    let appInfos: [(pid: pid_t, name: String)] = NSWorkspace.shared.runningApplications.compactMap { app in
        guard app.processIdentifier > 0 else { return nil }
        let name = app.localizedName.flatMap { $0.isEmpty ? nil : $0 }
            ?? app.bundleURL?.deletingPathExtension().lastPathComponent
            ?? app.bundleIdentifier
        guard let name, !name.isEmpty else { return nil }
        return (app.processIdentifier, name)
    }

    let collector = AXEntryCollector()
    DispatchQueue.concurrentPerform(iterations: appInfos.count) { i in
        collector.add(axStatusItemFrames(pid: appInfos[i].pid, name: appInfos[i].name))
    }
    let axEntries = collector.entries

    var result: [CGWindowID: String] = [:]
    for item in items {
        let itemMinX = item.frame.minX
        guard let match = axEntries.min(by: { abs($0.minX - itemMinX) < abs($1.minX - itemMinX) }) else { continue }
        // The same element in both trees ⇒ frames coincide. Accept a small slop.
        if abs(match.minX - itemMinX) <= 6 {
            result[item.windowID] = match.name
        }
    }
    return result
}

/// Every status item frame under one app's `AXExtrasMenuBar`, tagged with the
/// app name. Runs off the main thread (called from `concurrentPerform`).
private func axStatusItemFrames(pid: pid_t, name: String) -> [(minX: CGFloat, width: CGFloat, name: String)] {
    let axApp = AXUIElementCreateApplication(pid)
    // Bound each app's IPC so a hung app can't stall the walk.
    AXUIElementSetMessagingTimeout(axApp, 0.15)

    var extrasRef: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &extrasRef) == .success,
        let extras = extrasRef, CFGetTypeID(extras) == AXUIElementGetTypeID()
    else { return [] }
    var childrenRef: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(extras as! AXUIElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
        let children = childrenRef as? [AXUIElement]
    else { return [] }

    var frames: [(minX: CGFloat, width: CGFloat, name: String)] = []
    for child in children {
        guard let frame = axFrame(child) else { continue }
        frames.append((frame.minX, frame.width, name))
    }
    return frames
}

private func axFrame(_ element: AXUIElement) -> CGRect? {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success
    else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard
        AXValueGetValue(posRef as! AXValue, .cgPoint, &point),
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: point, size: size)
}
