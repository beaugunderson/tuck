import Cocoa

@main
struct ChevronTests {
    @MainActor
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        var images: [NSImage] = []
        let chevron = Chevron { images.append($0) }
        check(chevron.angle == 0 && !chevron.isAnimating, "Starts left with no idle timer")
        check(images.count == 1 && images[0].isTemplate, "Initial glyph is a system-tinted template")
        let size = images[0].size
        let closed = images[0].tiffRepresentation
        chevron.setExpanded(true, animated: false)
        check(chevron.angle == 90 && !chevron.isAnimating, "Immediate open points down")
        check(images.last?.size == size, "Opening does not change status item size")
        check(images.last?.tiffRepresentation != closed, "Open image actually changes orientation")
        chevron.setExpanded(false, animated: false)
        check(chevron.angle == 0 && !chevron.isAnimating, "Immediate close restores left")
        check(images.last?.size == size, "Closing does not change status item size")

        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            chevron.setExpanded(true)
            check(chevron.isAnimating, "Opening starts a transient animation")
            RunLoop.main.run(until: Date().addingTimeInterval(0.07))
            check(chevron.angle > 0 && chevron.angle < 90, "Animation draws intermediate angles")
            let intermediate = chevron.angle
            chevron.setExpanded(false)
            check(chevron.angle == intermediate, "Interrupted animation reverses without jumping")
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            check(chevron.angle == 0 && !chevron.isAnimating, "Reverse finishes left and invalidates timer")
            chevron.setExpanded(true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            check(chevron.angle == 90 && !chevron.isAnimating, "Open finishes down and invalidates timer")
            let count = images.count
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            check(images.count == count, "No drawing after animation finishes")
            chevron.setExpanded(true)
            check(!chevron.isAnimating && images.count == count, "Repeated open notification does no work")
        } else {
            chevron.setExpanded(true)
            check(chevron.angle == 90 && !chevron.isAnimating, "Reduce Motion skips animation")
        }
        chevron.setExpanded(false, animated: false)
        check(images.allSatisfy { $0.isTemplate && $0.size == size }, "Every frame preserves tint and dimensions")
        let bar = IceBar()
        var visibility: [Bool] = []
        bar.onVisibilityChange = { visibility.append($0) }
        bar.hide()
        bar.hide()
        check(visibility.isEmpty, "Hiding an already-closed strip emits no false transition")
        print("Passed \(checks) chevron checks")
    }
}
