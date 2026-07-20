import Cocoa
import OSLog

// Minimal shims so the ported Ice files compile unchanged.

enum Constants {
    static let bundleIdentifier = "com.beau.tuck"
}

/// Ice-compatible Logger surface backed by os.Logger.
struct Logger {
    private let base: os.Logger
    init(category: String) {
        self.base = os.Logger(subsystem: Constants.bundleIdentifier, category: category)
    }
    func info(_ message: String) { base.info("\(message, privacy: .public)") }
    func debug(_ message: String) { base.debug("\(message, privacy: .public)") }
    func error(_ message: String) { base.error("\(message, privacy: .public)") }
    func warning(_ message: String) { base.warning("\(message, privacy: .public)") }
}

extension CGError {
    var logString: String { "\(self) (rawValue: \(rawValue))" }
}
