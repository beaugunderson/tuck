import Foundation

// macOS 27's per-app "Allow in the Menu Bar" switches (System Settings → Menu
// Bar), which is how Tuck hides icons there.
//
// Control Center keeps them as `trackedApplications` in its app-group
// preferences: a binary plist holding an array of alternating key and value,
// where a key is `{bundle: {_0: <bundle id>}}` and a value carries `isAllowed`.
// `MenuBarAgent` applies a change as soon as the domain is re-imported through
// `defaults`, so an app's icons leave or rejoin the bar within about a second.
// The switch is per app: every status item an app owns follows it.

enum AllowList {
    enum Failure: Error {
        /// The domain could not be read or written; Tuck lacks Full Disk Access.
        case noAccess
        case unexpectedFormat
    }

    /// The preferences domain, addressed by path: the group suite itself is
    /// only open to members of the app group.
    static let domain = NSHomeDirectory()
        + "/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter"

    private static let listKey = "trackedApplications"

    // MARK: Pure transforms

    private static func decode(_ domain: Data) throws -> (outer: [String: Any], rows: [Any]) {
        guard
            let outer = try? PropertyListSerialization.propertyList(from: domain, format: nil) as? [String: Any],
            let listData = outer[listKey] as? Data,
            let rows = try? PropertyListSerialization.propertyList(from: listData, format: nil) as? [Any],
            rows.count % 2 == 0
        else { throw Failure.unexpectedFormat }
        return (outer, rows)
    }

    private static func bundleID(ofKey key: Any) -> String? {
        ((key as? [String: Any])?["bundle"] as? [String: Any])?["_0"] as? String
    }

    /// Each tracked app's switch, by bundle identifier.
    static func states(inDomain domain: Data) throws -> [String: Bool] {
        let rows = try decode(domain).rows
        var result: [String: Bool] = [:]
        for index in stride(from: 0, to: rows.count, by: 2) {
            guard let bundle = bundleID(ofKey: rows[index]) else { continue }
            result[bundle] = (rows[index + 1] as? [String: Any])?["isAllowed"] as? Bool ?? true
        }
        return result
    }

    /// The domain with the given apps' switches set. Every other row and key is
    /// passed through; an app with no row yet gets one.
    static func updating(domain: Data, with changes: [String: Bool]) throws -> Data {
        var (outer, rows) = try decode(domain)
        var remaining = changes
        for index in stride(from: 0, to: rows.count, by: 2) {
            guard
                let bundle = bundleID(ofKey: rows[index]),
                let allowed = remaining.removeValue(forKey: bundle),
                var value = rows[index + 1] as? [String: Any]
            else { continue }
            value["isAllowed"] = allowed
            rows[index + 1] = value
        }
        for (bundle, allowed) in remaining.sorted(by: { $0.key < $1.key }) {
            let key: [String: Any] = ["bundle": ["_0": bundle]]
            rows.append(key)
            rows.append(["isAllowed": allowed, "location": key, "menuItemLocations": [key]] as [String: Any])
        }
        outer[listKey] = try PropertyListSerialization.data(fromPropertyList: rows, format: .binary, options: 0)
        return try PropertyListSerialization.data(fromPropertyList: outer, format: .binary, options: 0)
    }

    // MARK: Live domain

    fileprivate static func defaults(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.noAccess }
        return data
    }

    /// Through `defaults`, so the read sees what the preferences daemon holds
    /// and not a file it has yet to flush.
    private static func export() throws -> Data {
        let data = try defaults(["export", domain, "-"])
        // An unreadable domain exports as an empty dictionary.
        guard (try? decode(data)) != nil else { throw Failure.noAccess }
        return data
    }

    static func states() throws -> [String: Bool] {
        try states(inDomain: export())
    }

    /// Sets the given apps' switches, skipping the write when nothing differs.
    static func apply(_ changes: [String: Bool]) throws {
        let current = try export()
        let existing = try states(inDomain: current)
        // An app with no row is allowed, so only a hide needs a new row.
        let needed = changes.filter { existing[$0.key] ?? true != $0.value }
        guard !needed.isEmpty else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tuck-allowlist-\(UUID().uuidString).plist")
        try updating(domain: current, with: needed).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try defaults(["import", domain, file.path])
    }
}

// Where a hidden app's icons land when they come back.
//
// `MenuBarAgent` saves each item's position as its distance from the right
// edge of the bar, under `TrailingItemPreferredPositions`: keys are
// `status:<owner>::<autosave name>` for app items (the owner is a bundle
// identifier, or the app's name for some apps) and `module:<name>` for system
// ones. The agent reads an item's saved position when the item rejoins the
// bar, so a position written while an app is switched off takes effect the
// next time it is switched on.

enum ItemOrder {
    static let domain = NSHomeDirectory()
        + "/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar"

    private static let positionsKey = "TrailingItemPreferredPositions"
    /// Gap between consecutive grouped items; only the order matters.
    private static let step: Double = 30

    private static func owner(ofKey key: String) -> String? {
        guard key.hasPrefix("status:"), let end = key.range(of: "::") else { return nil }
        return String(key[key.index(key.startIndex, offsetBy: 7)..<end.lowerBound])
    }

    /// The domain with the hidden apps' items moved, in their current order,
    /// to the left of every other item, or `nil` when they already are.
    static func grouping(domain: Data, hiddenOwners: Set<String>) throws -> Data? {
        guard
            var outer = try? PropertyListSerialization.propertyList(from: domain, format: nil) as? [String: Any],
            var positions = outer[positionsKey] as? [String: Double]
        else { throw AllowList.Failure.unexpectedFormat }
        let hiddenKeys = positions.keys.filter { owner(ofKey: $0).map(hiddenOwners.contains) ?? false }
        guard !hiddenKeys.isEmpty else { return nil }
        let leftmostOther = positions.filter { !hiddenKeys.contains($0.key) }.values.max() ?? 0
        if hiddenKeys.allSatisfy({ positions[$0]! > leftmostOther }) { return nil }
        let ordered = hiddenKeys.sorted { (positions[$0]!, $0) < (positions[$1]!, $1) }
        for (index, key) in ordered.enumerated() {
            positions[key] = leftmostOther + step * Double(index + 1)
        }
        outer[positionsKey] = positions
        return try PropertyListSerialization.data(fromPropertyList: outer, format: .binary, options: 0)
    }

    /// Groups the hidden apps' items at the left end of the saved order.
    static func group(hiddenOwners: Set<String>) throws {
        let current = try AllowList.defaults(["export", domain, "-"])
        guard let grouped = try grouping(domain: current, hiddenOwners: hiddenOwners) else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tuck-order-\(UUID().uuidString).plist")
        try grouped.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try AllowList.defaults(["import", domain, file.path])
    }
}
