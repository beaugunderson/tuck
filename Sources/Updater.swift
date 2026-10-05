import Foundation
import Security

// Opt-in updates.
//
// The latest release is whatever `tuck.bar/download` redirects to: the chain
// passes through `github.com/beaugunderson/tuck/releases/download/v<version>/Tuck.zip`,
// which names the version, so no API is involved. A downloaded bundle is
// trusted only when it satisfies `requirement`: Tuck's identifier, signed by
// this team's Developer ID, and notarized. The stapled ticket makes that check
// work offline. Nothing here installs on its own; the app offers the staged
// bundle in its menu.

enum Updater {
    enum Failure: Error {
        case noRelease
        case downloadFailed
        case badArchive
        case badSignature(OSStatus)
        case versionMismatch
    }

    static let source = URL(string: "https://tuck.bar/download")!

    static let requirement = """
        identifier "com.beau.tuck" and anchor apple generic \
        and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
        and certificate leaf[subject.OU] = D7UFB67V5Z and notarized
        """

    // MARK: Pure

    /// `[0, 2, 0]` for "0.2.0"; `nil` unless every dot-separated part is digits.
    static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : nil
    }

    /// Whether `candidate` is a later version than `current`; missing parts count as zero.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = components(candidate), let old = components(current) else { return false }
        for index in 0..<max(new.count, old.count) {
            let (a, b) = (index < new.count ? new[index] : 0, index < old.count ? old[index] : 0)
            if a != b { return a > b }
        }
        return false
    }

    /// The version a release asset URL names, or `nil` for any other URL.
    static func version(inReleaseURL url: URL) -> String? {
        let parts = url.pathComponents
        guard
            url.scheme == "https", url.host == "github.com", parts.count == 7,
            Array(parts[1...4]) == ["beaugunderson", "tuck", "releases", "download"],
            parts[6] == "Tuck.zip", parts[5].hasPrefix("v")
        else { return nil }
        let version = String(parts[5].dropFirst())
        return components(version) == nil ? nil : version
    }

    // MARK: Network

    /// Follows redirects until one names a release, and stops there.
    private final class ReleaseFinder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        var release: URL?

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            if let url = request.url, Updater.version(inReleaseURL: url) != nil {
                release = url
                completionHandler(nil)
            } else {
                completionHandler(request)
            }
        }
    }

    /// The latest release's version and asset URL.
    static func latest(from source: URL = source) async throws -> (version: String, url: URL) {
        var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "HEAD"
        let finder = ReleaseFinder()
        _ = try await URLSession.shared.data(for: request, delegate: finder)
        guard let url = finder.release, let version = version(inReleaseURL: url) else { throw Failure.noRelease }
        return (version, url)
    }

    /// Downloads a release and unpacks it next to `bundle`, returning the
    /// verified new bundle. Staging on the same volume keeps the later swap atomic.
    static func stage(version: String, from url: URL, replacing bundle: URL) async throws -> URL {
        let (zip, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: zip) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.downloadFailed }
        return try unpack(zip, version: version, replacing: bundle)
    }

    /// Unpacks a release archive next to `bundle` and verifies what came out.
    static func unpack(_ zip: URL, version: String, replacing bundle: URL) throws -> URL {
        let directory = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundle, create: true
        )
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, directory.path]
        ditto.standardOutput = Pipe()
        ditto.standardError = Pipe()
        try ditto.run()
        ditto.waitUntilExit()
        let staged = directory.appendingPathComponent("Tuck.app")
        do {
            guard ditto.terminationStatus == 0 else { throw Failure.badArchive }
            try verify(staged, version: version)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return staged
    }

    // MARK: Trust

    /// Throws unless `bundle` is this team's notarized Tuck at exactly `version`.
    static func verify(_ bundle: URL, version: String) throws {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(bundle as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw Failure.badSignature(status) }
        var parsed: SecRequirement?
        status = SecRequirementCreateWithString(requirement as CFString, [], &parsed)
        guard status == errSecSuccess, let parsed else { throw Failure.badSignature(status) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        status = SecStaticCodeCheckValidity(code, flags, parsed)
        guard status == errSecSuccess else { throw Failure.badSignature(status) }

        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleShortVersionString"] as? String == version else { throw Failure.versionMismatch }
    }

    /// Swaps the staged bundle into place.
    static func install(_ staged: URL, over bundle: URL) throws {
        _ = try FileManager.default.replaceItemAt(bundle, withItemAt: staged)
    }
}
