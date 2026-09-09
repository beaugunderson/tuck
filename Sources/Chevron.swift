import Cocoa
import QuartzCore

/// The status item's template glyph, rotated on a fixed-size canvas so opening
/// the strip never shifts neighboring menu bar items. Only animates for 160ms
/// per visibility change; there is no timer or drawing work while idle.
@MainActor
final class Chevron {
    private let onImageChange: (NSImage) -> Void
    private let glyph: NSImage?
    private var timer: Timer?
    private var targetAngle: CGFloat = 0
    private(set) var angle: CGFloat = 0
    var isAnimating: Bool { timer != nil }

    init(onImageChange: @escaping (NSImage) -> Void) {
        self.onImageChange = onImageChange
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        glyph = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Hidden menu bar icons")?
            .withSymbolConfiguration(configuration)
        render()
    }

    func setExpanded(_ expanded: Bool, animated: Bool = true) {
        let destination: CGFloat = expanded ? 90 : 0 // AppKit's y axis points up.
        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if destination == targetAngle && shouldAnimate { return }
        timer?.invalidate()
        timer = nil
        targetAngle = destination

        guard shouldAnimate, angle != destination else {
            angle = destination
            render()
            return
        }

        // Reverse smoothly from the current angle if dismissed mid-animation.
        let startAngle = angle
        let start = CACurrentMediaTime()
        let duration = 0.16
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let progress = min(max((CACurrentMediaTime() - start) / duration, 0), 1)
                let eased = progress * progress * (3 - 2 * progress)
                self.angle = startAngle + (destination - startAngle) * eased
                self.render()
                if progress >= 1 {
                    timer.invalidate()
                    self.timer = nil
                }
            }
        }
        self.timer = timer
        // Keep finishing the short rotation even if a right-click menu starts
        // tracking. The timer invalidates itself at the exact final orientation.
        RunLoop.main.add(timer, forMode: .common)
    }

    private func render() {
        guard let glyph else { return }
        // Keep the original horizontal padding. The diagonal also leaves room
        // for intermediate angles without clipping the tip during rotation.
        let diagonal = ceil(hypot(glyph.size.width, glyph.size.height))
        let size = NSSize(width: max(glyph.size.width + 10, diagonal), height: diagonal)
        let image = NSImage(size: size)
        image.lockFocus()
        let transform = NSAffineTransform()
        transform.translateX(by: size.width / 2, yBy: size.height / 2)
        transform.rotate(byDegrees: angle)
        transform.concat()
        glyph.draw(at: NSPoint(x: -glyph.size.width / 2, y: -glyph.size.height / 2),
                   from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        image.isTemplate = true
        onImageChange(image)
    }
}
