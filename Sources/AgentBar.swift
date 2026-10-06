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

    // MARK: Hearing preference changes
    //
    // The agent learns of an allow-list write from the user's `cfprefsd`. When
    // that daemon is killed and replaced, the agent keeps running and hears
    // nothing more, so an agent older than the daemon is deaf.

    static func isDeaf(agentStart: Date, daemonStart: Date?) -> Bool {
        guard let daemonStart else { return false }
        return agentStart < daemonStart
    }

    static var isDeaf: Bool {
        guard let agent, let agentStart = Processes.start(of: agent.processIdentifier) else { return false }
        let daemonStart = Processes.pids(named: "cfprefsd").compactMap(Processes.start(of:)).max()
        return isDeaf(agentStart: agentStart, daemonStart: daemonStart)
    }

    // An agent can also stop hearing with neither process restarted, which no
    // start time shows; the bar itself is the evidence then.

    /// The apps whose icons contradict their switches: a switched-off app with
    /// an icon on the bar, or a switched-on, running app that has had an icon
    /// (`known`) and has none.
    static func mismatched(switches: [String: Bool], onBar: Set<String>, running: Set<String>, known: Set<String>) -> Set<String> {
        Set(switches.compactMap { bundle, allowed in
            let wrong = allowed
                ? running.contains(bundle) && known.contains(bundle) && !onBar.contains(bundle)
                : onBar.contains(bundle)
            return wrong ? bundle : nil
        })
    }

    /// How much longer the agent needs to apply the last write before the bar
    /// can be judged; zero once `settle` has passed. A look can come due late
    /// (timers wait while a menu is open) and land just after a newer write.
    static func settleRemaining(lastWrite: Date?, now: Date, settle: TimeInterval) -> TimeInterval {
        guard let lastWrite else { return 0 }
        return max(0, settle - now.timeIntervalSince(lastWrite))
    }

    /// Whether a display is the 1920x1080 one the Window Server puts up while
    /// no monitor is connected (vendor "unkn", model "virt"). Nobody sees its bar.
    static func isStandIn(vendor: UInt32, model: UInt32) -> Bool {
        vendor == 0x756e_6b6e && model == 0x7669_7274
    }

    /// Whether the agent's bar windows can be read for items. Under the screen
    /// saver or the lock screen its window is 0 by 0 and lists no status
    /// items, which says nothing about which apps have icons.
    static func isReadable(windowFrames: [CGRect]) -> Bool {
        windowFrames.contains { $0.width > 0 && $0.height > 0 }
    }

    static var isReadable: Bool {
        guard let agent else { return false }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let windows = values(app, [kAXWindowsAttribute])[0] as? [AXUIElement] ?? []
        return isReadable(windowFrames: windows.compactMap { rect(values($0, ["AXFrame"])[0]) })
    }

    /// The apps with a status item on any display's bar.
    static func bundlesOnBar() -> Set<String> {
        Set(items(on: nil).compactMap { NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier })
    }

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

extension Logger {
    /// In the system log, where a restart of the agent can be found afterwards:
    /// `log show --predicate 'subsystem == "com.beau.tuck"'`.
    static let agentBar = Logger(category: "AgentBar")
}

/// The kernel's process table, for this user's processes.
enum Processes {
    private static let stride = MemoryLayout<kinfo_proc>.stride

    static func start(of pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size == stride else { return nil }
        let time = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
    }

    /// Pids of this user's processes whose executable has the given name.
    static func pids(named name: String) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        // Room for processes that start between the two calls.
        var list = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = list.count * stride
        guard sysctl(&mib, 4, &list, &size, nil, 0) == 0 else { return [] }
        return list.prefix(size / stride).compactMap { process in
            var command = process.kp_proc.p_comm
            let matches = withUnsafeBytes(of: &command) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) == name
            }
            return matches ? process.kp_proc.p_pid : nil
        }
    }
}
