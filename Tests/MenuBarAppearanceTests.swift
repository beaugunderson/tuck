import Cocoa

@main
struct MenuBarAppearanceTests {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        func image(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) -> CGImage {
            let context = CGContext(data: nil, width: 20, height: 2, bitsPerComponent: 8,
                                    bytesPerRow: 80, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha))
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 2))
            return context.makeImage()!
        }
        func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.015 }

        let blue = MenuBarAppearance.averageColor(of: image(red: 0.05, green: 0.4, blue: 0.65))!
        check(close(blue.redComponent, 0.05) && close(blue.greenComponent, 0.4)
              && close(blue.blueComponent, 0.65), "Preserve the wallpaper's blue tint")
        check(MenuBarAppearance.prefersDarkAppearance(blue), "Blue bar needs light UI text")
        let white = MenuBarAppearance.averageColor(of: image(red: 1, green: 1, blue: 1))!
        check(!MenuBarAppearance.prefersDarkAppearance(white), "Light bar needs dark UI text")
        let black = MenuBarAppearance.averageColor(of: image(red: 0, green: 0, blue: 0))!
        check(MenuBarAppearance.prefersDarkAppearance(black), "Opaque black is a valid dark bar")
        check(MenuBarAppearance.averageColor(of: image(red: 0, green: 0, blue: 0, alpha: 0)) == nil,
              "Missing capture must not masquerade as black")
        check(MenuBarAppearance.averageColor(of: image(red: 1, green: 1, blue: 1, alpha: 0.25)) == nil,
              "Reject mostly transparent samples")
        let translucent = MenuBarAppearance.averageColor(of: image(red: 0.8, green: 0.4, blue: 0.2, alpha: 0.75))!
        check(close(translucent.redComponent, 0.8) && close(translucent.greenComponent, 0.4)
              && close(translucent.blueComponent, 0.2) && translucent.alphaComponent == 1,
              "Unpremultiply RGB and return an opaque background")

        let frame = CGRect(x: 0, y: 0, width: 1728, height: 37)
        check(MenuBarAppearance.sampleBounds(in: frame, nearX: 1200)
              == CGRect(x: 1150, y: 0, width: 100, height: 1), "Sample near the chevron")
        check(MenuBarAppearance.sampleBounds(in: frame, nearX: 0).minX == 0, "Clamp left edge")
        check(MenuBarAppearance.sampleBounds(in: frame, nearX: 1728).maxX == 1728, "Clamp right edge")
        let external = CGRect(x: -3008, y: -1000, width: 3008, height: 24)
        check(MenuBarAppearance.sampleBounds(in: external, nearX: -20)
              == CGRect(x: -100, y: -1000, width: 100, height: 1), "Preserve external display coordinates")
        let narrow = CGRect(x: 20, y: 30, width: 40, height: 1)
        check(MenuBarAppearance.sampleBounds(in: narrow, nearX: 0) == narrow, "Clamp undersized frames")
        check(MenuBarAppearance(background: blue).appearance?.name == .darkAqua, "Dark controls on blue sample")
        check(MenuBarAppearance(background: white).appearance?.name == .aqua, "Light controls on white sample")
        print("Passed \(checks) appearance checks")
    }
}
