import Foundation

@main
struct UpdaterTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }

        check(Updater.components("0.2.0") == [0, 2, 0], "Splits a version into numbers")
        check(Updater.components("1") == [1], "Accepts a single part")
        for bad in ["", "1..2", "1.x", "+1.0", "-1.0", "1.0 ", "v1.0", "1.0-beta"] {
            check(Updater.components(bad) == nil, "Rejects \"\(bad)\"")
        }

        check(Updater.isNewer("0.2.1", than: "0.2.0"), "A higher patch is newer")
        check(Updater.isNewer("0.10.0", than: "0.9.9"), "Parts compare as numbers, not text")
        check(Updater.isNewer("1.0", than: "0.9.9"), "A shorter version can be newer")
        check(Updater.isNewer("0.2.0.1", than: "0.2.0"), "An extra part breaks a tie")
        check(!Updater.isNewer("0.2.0", than: "0.2.0"), "The same version is not newer")
        check(!Updater.isNewer("0.2", than: "0.2.0"), "Missing parts count as zero")
        check(!Updater.isNewer("0.1.9", than: "0.2.0"), "An older release is never offered")
        check(!Updater.isNewer("garbage", than: "0.2.0"), "An unreadable version is never offered")

        func version(_ string: String) -> String? { Updater.version(inReleaseURL: URL(string: string)!) }
        check(version("https://github.com/beaugunderson/tuck/releases/download/v0.2.0/Tuck.zip") == "0.2.0", "Reads the version from a release asset URL")
        for other in [
            "https://github.com/beaugunderson/tuck/releases/latest/download/Tuck.zip",
            "http://github.com/beaugunderson/tuck/releases/download/v0.2.0/Tuck.zip",
            "https://github.com.evil.example/beaugunderson/tuck/releases/download/v0.2.0/Tuck.zip",
            "https://github.com/someone/tuck/releases/download/v0.2.0/Tuck.zip",
            "https://github.com/beaugunderson/tuck/releases/download/v0.2.0/Other.zip",
            "https://github.com/beaugunderson/tuck/releases/download/0.2.0/Tuck.zip",
            "https://github.com/beaugunderson/tuck/releases/download/vNext/Tuck.zip",
            "https://release-assets.githubusercontent.com/github-production-release-asset/1/abc",
            "https://tuck.bar/download",
        ] {
            check(version(other) == nil, "Ignores \(other)")
        }

        print("Updater tests passed (\(checks) checks)")
    }
}
