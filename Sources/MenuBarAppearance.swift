import Cocoa

/// Sample only on open. The menu bar can be dark (or tinted by wallpaper) even
/// when the app uses Aqua, and captured glyphs cannot adapt to a new background.
struct MenuBarAppearance {
    let background: NSColor

    var appearance: NSAppearance? {
        NSAppearance(named: Self.prefersDarkAppearance(background) ? .darkAqua : .aqua)
    }

    static func prefersDarkAppearance(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent < 0.5
    }

    /// A narrow strip of the background window, not the screen contents: no
    /// glyphs, chevron highlight, notch, or app window can contaminate the sample.
    static func sampleBounds(in frame: CGRect, nearX x: CGFloat) -> CGRect {
        let width = min(100, frame.width)
        return CGRect(x: min(max(x - width / 2, frame.minX), frame.maxX - width),
                      y: frame.minY, width: width, height: min(1, frame.height))
    }

    @MainActor
    static func capture(below button: NSStatusBarButton) -> MenuBarAppearance? {
        guard Bridging.screenRecordingGranted(),
              let buttonWindow = button.window,
              let screen = buttonWindow.screen,
              let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let displayBounds = CGDisplayBounds(display.uint32Value)
        guard let window = WindowInfo.getOnScreenWindows().first(where: {
            $0.isWindowServerWindow && $0.layer == kCGMainMenuWindowLevel
                && $0.title == "Menubar" && displayBounds.contains($0.frame)
        }) else { return nil }
        let bounds = sampleBounds(in: window.frame, nearX: buttonWindow.frame.midX)
        guard let image = Bridging.captureComposite([window.windowID], bounds: bounds),
              let color = averageColor(of: image) else { return nil }
        return MenuBarAppearance(background: color)
    }

    /// Downsample in sRGB. Reject transparent captures rather than accidentally
    /// interpreting missing pixels as a black menu bar; unpremultiply valid RGB.
    static func averageColor(of image: CGImage) -> NSColor? {
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                                          bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                              | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn, pixel[3] >= 128 else { return nil }
        let alpha = CGFloat(pixel[3])
        return NSColor(srgbRed: CGFloat(pixel[0]) / alpha,
                       green: CGFloat(pixel[1]) / alpha,
                       blue: CGFloat(pixel[2]) / alpha, alpha: 1)
    }
}
