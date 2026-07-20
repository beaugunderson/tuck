import Cocoa

// A floating horizontal strip of the hidden menu bar glyphs — like a detached
// slice of the menu bar, shown under Tuck's chevron. Native AppKit (no SwiftUI),
// built and torn down per open so it costs nothing when closed.

struct BarEntry {
    let glyph: NSImage?
    let label: String
}

@MainActor
final class IceBar {
    private var panel: NSPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastHiddenAt = Date.distantPast

    /// Called with the tapped entry's index.
    var onSelect: ((Int) -> Void)?

    var isOpen: Bool { panel != nil }

    func toggle(_ entries: [BarEntry], below button: NSStatusBarButton) {
        if isOpen {
            hide()
            return
        }
        // If the outside-click monitor just closed the bar on this same click's
        // mouse-down, don't let the chevron's mouse-up immediately reopen it.
        if Date().timeIntervalSince(lastHiddenAt) < 0.25 { return }
        show(entries, below: button)
    }

    func hide() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        lastHiddenAt = Date()
    }

    private func show(_ entries: [BarEntry], below button: NSStatusBarButton) {
        guard let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }

        let content = BarContentView(entries: entries) { [weak self] index in
            self?.hide()
            self?.onSelect?(index)
        }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = content

        // Position: hang just under the menu bar, horizontally CENTERED on the
        // chevron, clamped to the screen (so it hugs the right edge when the
        // chevron is near the corner).
        let bf = buttonWindow.frame
        let gap: CGFloat = 4
        var x = bf.midX - size.width / 2
        x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        let y = bf.minY - gap - size.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
        self.panel = panel

        // Dismiss on any click outside, or Escape.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            if event.type == .keyDown {
                if event.keyCode == 53 { self?.hide(); return nil } // Escape
                return event
            }
            // A click inside the panel is handled by the buttons; anything else dismisses.
            if event.window != self?.panel { self?.hide() }
            return event
        }
    }
}

// MARK: - Content

private final class BarContentView: NSView {
    private let onSelect: (Int) -> Void

    init(entries: [BarEntry], onSelect: @escaping (Int) -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero)

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)

        if entries.isEmpty {
            let empty = NSTextField(labelWithString: "No hidden icons")
            empty.textColor = .secondaryLabelColor
            empty.font = .systemFont(ofSize: 13)
            stack.addArrangedSubview(empty)
        } else {
            for (index, entry) in entries.enumerated() {
                let cell = GlyphCell(entry: entry, index: index) { [weak self] i in
                    self?.onSelect(i)
                }
                stack.addArrangedSubview(cell)
            }
        }

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Glyph cell (hover-highlighted, clickable)

private final class GlyphCell: NSView {
    private let index: Int
    private let onClick: (Int) -> Void
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(entry: BarEntry, index: Int, onClick: @escaping (Int) -> Void) {
        self.index = index
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView()
        imageView.image = entry.glyph
        imageView.imageScaling = .scaleNone // render at native menu-bar size
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.toolTip = entry.label
        addSubview(imageView)

        // Render each glyph at its real captured (menu-bar) point size.
        let glyphSize = entry.glyph?.size ?? NSSize(width: 22, height: 22)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: glyphSize.width + 8),
            heightAnchor.constraint(equalToConstant: glyphSize.height + 6),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: glyphSize.width),
            imageView.heightAnchor.constraint(equalToConstant: glyphSize.height),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor
        layer?.cornerRadius = 6
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        layer?.backgroundColor = nil
    }

    override func mouseUp(with event: NSEvent) {
        onClick(index)
    }
}
