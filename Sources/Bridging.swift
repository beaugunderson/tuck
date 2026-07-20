//
//  Bridging.swift
//  Ice
//

import Cocoa

/// A namespace for bridged functionality.
enum Bridging { }

// MARK: - CGSConnection

extension Bridging {
    /// Sets a value for the given key in the current connection to the window server.
    ///
    /// - Parameters:
    ///   - value: The value to set for `key`.
    ///   - key: A key associated with the current connection to the window server.
    static func setConnectionProperty(_ value: Any?, forKey key: String) {
        let result = CGSSetConnectionProperty(
            CGSMainConnectionID(),
            CGSMainConnectionID(),
            key as CFString,
            value as CFTypeRef
        )
        if result != .success {
            Logger.bridging.error("CGSSetConnectionProperty failed with error \(result.logString)")
        }
    }

    /// Returns the value for the given key in the current connection to the window server.
    ///
    /// - Parameter key: A key associated with the current connection to the window server.
    /// - Returns: The value associated with `key` in the current connection to the window server.
    static func getConnectionProperty(forKey key: String) -> Any? {
        var value: Unmanaged<CFTypeRef>?
        let result = CGSCopyConnectionProperty(
            CGSMainConnectionID(),
            CGSMainConnectionID(),
            key as CFString,
            &value
        )
        if result != .success {
            Logger.bridging.error("CGSCopyConnectionProperty failed with error \(result.logString)")
        }
        return value?.takeRetainedValue()
    }
}

// MARK: - CGSWindow

extension Bridging {
    /// Returns the frame for the window with the specified identifier.
    ///
    /// - Parameter windowID: An identifier for a window.
    /// - Returns: The frame -- specified in screen coordinates -- of the window associated
    ///   with `windowID`, or `nil` if the operation failed.
    static func getWindowFrame(for windowID: CGWindowID) -> CGRect? {
        var rect = CGRect.zero
        let result = CGSGetScreenRectForWindow(CGSMainConnectionID(), windowID, &rect)
        guard result == .success else {
            Logger.bridging.error("CGSGetScreenRectForWindow failed with error \(result.logString)")
            return nil
        }
        return rect
    }
}

// MARK: Private Window List Helpers
extension Bridging {
    private static func getWindowCount() -> Int {
        var count: Int32 = 0
        let result = CGSGetWindowCount(CGSMainConnectionID(), 0, &count)
        if result != .success {
            Logger.bridging.error("CGSGetWindowCount failed with error \(result.logString)")
        }
        return Int(count)
    }

    private static func getOnScreenWindowCount() -> Int {
        var count: Int32 = 0
        let result = CGSGetOnScreenWindowCount(CGSMainConnectionID(), 0, &count)
        if result != .success {
            Logger.bridging.error("CGSGetOnScreenWindowCount failed with error \(result.logString)")
        }
        return Int(count)
    }

    private static func getWindowList() -> [CGWindowID] {
        let windowCount = getWindowCount()
        var list = [CGWindowID](repeating: 0, count: windowCount)
        var realCount: Int32 = 0
        let result = CGSGetWindowList(
            CGSMainConnectionID(),
            0,
            Int32(windowCount),
            &list,
            &realCount
        )
        guard result == .success else {
            Logger.bridging.error("CGSGetWindowList failed with error \(result.logString)")
            return []
        }
        return [CGWindowID](list[..<Int(realCount)])
    }

    private static func getOnScreenWindowList() -> [CGWindowID] {
        let windowCount = getOnScreenWindowCount()
        var list = [CGWindowID](repeating: 0, count: windowCount)
        var realCount: Int32 = 0
        let result = CGSGetOnScreenWindowList(
            CGSMainConnectionID(),
            0,
            Int32(windowCount),
            &list,
            &realCount
        )
        guard result == .success else {
            Logger.bridging.error("CGSGetOnScreenWindowList failed with error \(result.logString)")
            return []
        }
        return [CGWindowID](list[..<Int(realCount)])
    }

    private static func getMenuBarWindowList() -> [CGWindowID] {
        let windowCount = getWindowCount()
        var list = [CGWindowID](repeating: 0, count: windowCount)
        var realCount: Int32 = 0
        let result = CGSGetProcessMenuBarWindowList(
            CGSMainConnectionID(),
            0,
            Int32(windowCount),
            &list,
            &realCount
        )
        guard result == .success else {
            Logger.bridging.error("CGSGetProcessMenuBarWindowList failed with error \(result.logString)")
            return []
        }
        return [CGWindowID](list[..<Int(realCount)])
    }

    private static func getOnScreenMenuBarWindowList() -> [CGWindowID] {
        let onScreenList = Set(getOnScreenWindowList())
        return getMenuBarWindowList().filter(onScreenList.contains)
    }
}

// MARK: Public Window List API
extension Bridging {
    /// Options that determine the window identifiers to return in a window list.
    struct WindowListOption: OptionSet {
        let rawValue: Int

        /// Specifies windows that are currently on-screen.
        static let onScreen = WindowListOption(rawValue: 1 << 0)

        /// Specifies windows that represent items in the menu bar.
        static let menuBarItems = WindowListOption(rawValue: 1 << 1)

        /// Specifies windows on the currently active space.
        static let activeSpace = WindowListOption(rawValue: 1 << 2)
    }

    /// The total number of windows.
    static var windowCount: Int {
        getWindowCount()
    }

    /// The number of windows currently on-screen.
    static var onScreenWindowCount: Int {
        getOnScreenWindowCount()
    }

    /// Returns a list of window identifiers using the given options.
    ///
    /// - Parameter option: Options that filter the returned list.
    static func getWindowList(option: WindowListOption = []) -> [CGWindowID] {
        let list = if option.contains(.menuBarItems) {
            if option.contains(.onScreen) {
                getOnScreenMenuBarWindowList()
            } else {
                getMenuBarWindowList()
            }
        } else if option.contains(.onScreen) {
            getOnScreenWindowList()
        } else {
            getWindowList()
        }
        return if option.contains(.activeSpace) {
            list.filter(isWindowOnActiveSpace)
        } else {
            list
        }
    }
}

// MARK: - CGSSpace

extension Bridging {
    /// Options that determine the space identifiers to return in a space list.
    enum SpaceListOption {
        case allSpaces, visibleSpaces
    }

    /// The identifier of the active space.
    static var activeSpaceID: CGSSpaceID {
        CGSGetActiveSpace(CGSMainConnectionID())
    }

    /// Returns an array of identifiers for the spaces containing the window with
    /// the given identifier.
    ///
    /// - Parameter windowID: An identifier for a window.
    static func getSpaceList(for windowID: CGWindowID, option: SpaceListOption) -> [CGSSpaceID] {
        let mask: CGSSpaceMask = switch option {
        case .allSpaces: .allSpaces
        case .visibleSpaces: .allVisibleSpaces
        }
        guard let spaces = CGSCopySpacesForWindows(CGSMainConnectionID(), mask, [windowID] as CFArray) else {
            Logger.bridging.error("CGSCopySpacesForWindows failed")
            return []
        }
        guard let spaceIDs = spaces.takeRetainedValue() as? [CGSSpaceID] else {
            Logger.bridging.error("CGSCopySpacesForWindows returned array of unexpected type")
            return []
        }
        return spaceIDs
    }

    /// Returns a Boolean value that indicates whether the window with the
    /// given identifier is on the active space.
    ///
    /// - Parameter windowID: An identifier for a window.
    static func isWindowOnActiveSpace(_ windowID: CGWindowID) -> Bool {
        getSpaceList(for: windowID, option: .allSpaces).contains(activeSpaceID)
    }

    /// Returns a Boolean value that indicates whether the space with the given
    /// identifier is a fullscreen space.
    ///
    /// - Parameter spaceID: An identifier for a space.
    static func isSpaceFullscreen(_ spaceID: CGSSpaceID) -> Bool {
        let type = CGSSpaceGetType(CGSMainConnectionID(), spaceID)
        return type == .fullscreen
    }
}

// MARK: - Capture

// CGWindowListCreateImage is `unavailable` in the macOS 15+ SDK, but
// ScreenCaptureKit still can't capture off-screen menu bar items. Bind the C
// symbol directly; it still ships in CoreGraphics (obsoleted != removed).
// The ARRAY/composite variant. Crucially, this renders windows that are pushed
// far off-screen (e.g. our hidden items at negative x) — the single-window
// variant clips those to nil. This is why Ice uses it. Bound directly since
// it's `unavailable` in the SDK but still ships in CoreGraphics.
@_silgen_name("CGWindowListCreateImageFromArray")
private func _CGWindowListCreateImageFromArray(_ bounds: CGRect, _ windowArray: CFArray, _ imageOption: UInt32) -> Unmanaged<CGImage>?

extension Bridging {
    /// Captures a composite image of the given windows (works for off-screen
    /// menu bar items). Pass `.null` bounds to get the union of the windows at
    /// backing (2×) resolution — matching Ice's approach.
    static func captureComposite(_ windowIDs: [CGWindowID], bounds: CGRect = .null) -> CGImage? {
        guard !windowIDs.isEmpty else { return nil }
        let pointer = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: windowIDs.count)
        defer { pointer.deallocate() }
        for (i, wid) in windowIDs.enumerated() { pointer[i] = UnsafeRawPointer(bitPattern: UInt(wid)) }
        guard let array = CFArrayCreate(kCFAllocatorDefault, pointer, windowIDs.count, nil) else { return nil }
        let imageOption = CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue
        return _CGWindowListCreateImageFromArray(bounds, array, imageOption)?.takeRetainedValue()
    }

    static func screenRecordingGranted() -> Bool { CGPreflightScreenCaptureAccess() }
    static func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }
}

// MARK: - Logger
private extension Logger {
    static let bridging = Logger(category: "Bridging")
}
