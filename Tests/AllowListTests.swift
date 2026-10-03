import Foundation

@main
struct AllowListTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }

        // The shape Control Center stores: an outer dictionary whose
        // `trackedApplications` is a binary plist of alternating key, value.
        func key(_ bundle: String) -> [String: Any] { ["bundle": ["_0": bundle]] }
        func row(_ bundle: String, _ allowed: Bool) -> [Any] {
            [key(bundle), ["isAllowed": allowed, "location": key(bundle), "menuItemLocations": [key(bundle)]] as [String: Any]]
        }
        let pathKey: [String: Any] = ["path": ["_0": "/usr/local/bin/tool"]]
        let inner: [Any] = row("com.example.a", true) + row("com.example.b", false) + [pathKey, ["isAllowed": true] as [String: Any]]
        let innerData = try PropertyListSerialization.data(fromPropertyList: inner, format: .binary, options: 0)
        let outer: [String: Any] = ["showSpotlight": false, "trackedApplications": innerData]
        let domain = try PropertyListSerialization.data(fromPropertyList: outer, format: .binary, options: 0)

        let states = try AllowList.states(inDomain: domain)
        check(states == ["com.example.a": true, "com.example.b": false], "Reads each bundle's switch and skips non-bundle rows")

        let hidden = try AllowList.updating(domain: domain, with: ["com.example.a": false])
        check(try AllowList.states(inDomain: hidden) == ["com.example.a": false, "com.example.b": false], "Switches one app off and leaves the rest")

        let outerAfter = try PropertyListSerialization.propertyList(from: hidden, format: nil) as! [String: Any]
        check(outerAfter["showSpotlight"] as? Bool == false, "Other keys in the domain survive")
        let innerAfter = try PropertyListSerialization.propertyList(from: outerAfter["trackedApplications"] as! Data, format: nil) as! [Any]
        check(innerAfter.count == inner.count, "No rows are added or lost for a known app")
        let valueA = innerAfter[1] as! [String: Any]
        check(valueA["location"] != nil && (valueA["menuItemLocations"] as? [Any])?.count == 1, "A row's other fields are kept")
        check((innerAfter[4] as? [String: Any])?["path"] != nil, "Non-bundle rows are passed through in place")

        let shown = try AllowList.updating(domain: hidden, with: ["com.example.a": true, "com.example.b": true])
        check(try AllowList.states(inDomain: shown) == ["com.example.a": true, "com.example.b": true], "Switches apps back on")

        let added = try AllowList.updating(domain: domain, with: ["com.example.new": false])
        check(try AllowList.states(inDomain: added)["com.example.new"] == false, "An untracked app gets a row")
        let innerAdded = try PropertyListSerialization.propertyList(
            from: (try PropertyListSerialization.propertyList(from: added, format: nil) as! [String: Any])["trackedApplications"] as! Data, format: nil
        ) as! [Any]
        check(innerAdded.count == inner.count + 2, "The new row is one key and one value")
        let newValue = innerAdded.last as! [String: Any]
        check(newValue["location"] != nil && newValue["menuItemLocations"] != nil, "The new row has the fields Control Center writes")

        check((try? AllowList.states(inDomain: Data("nope".utf8))) == nil, "Garbage is an error, not an empty list")
        let noList = try PropertyListSerialization.data(fromPropertyList: ["showSpotlight": true], format: .binary, options: 0)
        check((try? AllowList.updating(domain: noList, with: ["x": false])) == nil, "A domain without the list is an error")

        // Saved positions are distances from the right edge, so a larger value
        // sits further left. Values below are from a real macOS 27 menu bar.
        func positionsDomain(_ positions: [String: Double]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["TrailingItemPreferredPositions": positions], format: .binary, options: 0)
        }
        func positions(_ data: Data) throws -> [String: Double] {
            (try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any])["TrailingItemPreferredPositions"] as! [String: Double]
        }
        let bar: [String: Double] = [
            "module:Clock": 0,
            "module:WiFi": 88.5,
            "status:com.sindresorhus.Dato::Dato": 110.5,
            "status:com.ameba.SwiftBar::/Users/b/005-free-space.1m.sh": 138.5,
            "status:com.ameba.SwiftBar::/Users/b/002-starlink.5s.sh": 248.5,
            "status:leits.MeetingBar::Item-0": 353.5,
            "status:com.getdropbox.dropbox::Item-0": 429.5,
            "status:SpikeItem::Item-0": 613.5,
        ]
        let interleaved = try positionsDomain(bar)

        let grouped = try ItemOrder.grouping(domain: interleaved, hiddenOwners: ["com.ameba.SwiftBar", "leits.MeetingBar"])
        check(grouped != nil, "Interleaved hidden items need a write")
        let after = try positions(grouped!)
        let shownMax = after.filter { !$0.key.contains("SwiftBar") && !$0.key.contains("MeetingBar") }.values.max()!
        let hiddenValues = after.filter { $0.key.contains("SwiftBar") || $0.key.contains("MeetingBar") }
        check(hiddenValues.values.min()! > shownMax, "Every hidden item lands left of every other item")
        check(after["status:com.getdropbox.dropbox::Item-0"] == 429.5 && after["module:Clock"] == 0, "Other items keep their positions")
        let order = hiddenValues.sorted { $0.value < $1.value }.map(\.key)
        check(order == [
            "status:com.ameba.SwiftBar::/Users/b/005-free-space.1m.sh",
            "status:com.ameba.SwiftBar::/Users/b/002-starlink.5s.sh",
            "status:leits.MeetingBar::Item-0",
        ], "Hidden items keep their order among themselves")
        check(Set(hiddenValues.values).count == 3, "Hidden items get distinct positions")

        check(try ItemOrder.grouping(domain: grouped!, hiddenOwners: ["com.ameba.SwiftBar", "leits.MeetingBar"]) == nil, "An already grouped bar needs no write")
        check(try ItemOrder.grouping(domain: interleaved, hiddenOwners: ["com.example.absent"]) == nil, "No saved items for the hidden apps means no write")
        check(try ItemOrder.grouping(domain: interleaved, hiddenOwners: []) == nil, "Nothing hidden means no write")
        let byName = try ItemOrder.grouping(domain: interleaved, hiddenOwners: ["SpikeItem", "com.sindresorhus.Dato"])
        let named = try positions(byName!)
        check(named["status:com.sindresorhus.Dato::Dato"]! > 429.5 && named["status:SpikeItem::Item-0"]! > named["status:com.sindresorhus.Dato::Dato"]!,
              "An owner may be an app name as well as a bundle identifier")
        check((try? ItemOrder.grouping(domain: Data("nope".utf8), hiddenOwners: ["x"])) == nil, "Garbage positions are an error")

        print("AllowList: \(checks) checks passed")
    }
}
