import Cocoa
import ApplicationServices

// The macOS 27 menu bar.
//
// `MenuBarAgent` draws every app's status item inside one window, so there are
// no per-item windows to enumerate, capture, or push off-screen. Accessibility
// replaces enumeration: the agent's window has one child per item, with its
// frame on the bar row, and the element's pid is the owning app's. Hiding is
// `AllowList`'s job.

/// One status item as `MenuBarAgent` lays it out.
struct AgentItem {
    /// The item's slot on the bar row, in global top-left coordinates.
    let frame: CGRect
    /// The owning app; the agent's own pid for system modules and the overflow button.
    let pid: pid_t
    let title: String
}

enum AgentBar {
    static let bundleID = "com.apple.MenuBarAgent"

    static var agent: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// Whether this Mac lays its menu bar out through `MenuBarAgent`.
    static let isActive = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 && agent != nil

    private static func values(_ element: AXUIElement, _ attributes: [String]) -> [Any?] {
        var out: CFArray?
        guard
            AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &out) == .success,
            let array = out as? [Any], array.count == attributes.count
        else { return attributes.map { _ in nil } }
        // A missing attribute comes back as an AXValue wrapping an error code.
        return array.map { value in
            if CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
            return value
        }
    }

    private static func rect(_ value: Any?) -> CGRect? {
        guard let value, CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
    }

    /// The status items on the menu bar of `screen`, left to right.
    static func items(on screen: NSScreen?) -> [AgentItem] {
        guard let agent else { return [] }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let windows = values(app, [kAXWindowsAttribute])[0] as? [AXUIElement] else { return [] }

        let screenBounds = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
            .map(CGDisplayBounds)
        var result: [AgentItem] = []
        for window in windows {
            let windowValues = values(window, ["AXFrame", kAXChildrenAttribute])
            if let screenBounds, let frame = rect(windowValues[0]), !screenBounds.intersects(frame) { continue }
            for container in windowValues[1] as? [AXUIElement] ?? [] {
                if let item = item(in: container) { result.append(item) }
            }
        }
        return result.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Third-party items sit one level under a role-less container, system
    /// modules one level further under a hosting group, and the overflow
    /// button is its own container.
    private static func item(in container: AXUIElement) -> AgentItem? {
        let attributes = [kAXRoleAttribute, "AXFrame", kAXChildrenAttribute, kAXTitleAttribute]
        var element = container
        var found = values(element, attributes)
        guard let frame = rect(found[1]) else { return nil }
        for _ in 0..<3 {
            let role = found[0] as? String
            if let role, role != kAXGroupRole { break }
            guard let child = (found[2] as? [AXUIElement])?.first else { return nil }
            element = child
            found = values(element, attributes)
        }
        guard let role = found[0] as? String, role != kAXGroupRole else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return AgentItem(frame: frame, pid: pid, title: found[3] as? String ?? "")
    }
}
