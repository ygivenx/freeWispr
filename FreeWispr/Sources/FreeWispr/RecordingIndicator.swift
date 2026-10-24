import AppKit

/// A floating red dot that appears while recording.
/// Uses NSPanel at status-window level so it floats above all apps and appears on all Spaces.
@MainActor
final class RecordingIndicator {
    private var panel: NSPanel?
    private var screenObserver: NSObjectProtocol?
    private var captionBox: NSVisualEffectView?
    private var captionLabel: NSTextField?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.positionPanel(panel)
            }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        // Actor-isolated objects may still be released by a nonisolated owner.
        let panel = panel
        DispatchQueue.main.async { panel?.orderOut(nil) }
    }

    private static let dotSize: CGFloat = 12
    private static let panelPadding: CGFloat = 4
    private static let panelSize = dotSize + panelPadding * 2
    private static let captionMaxWidth: CGFloat = 420
    private static let captionGap: CGFloat = 6
    private static let captionInset = NSSize(width: 10, height: 6)

    func show() {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelSize, height: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true

        let dot = NSView(frame: NSRect(x: Self.panelPadding, y: Self.panelPadding,
                                        width: Self.dotSize, height: Self.dotSize))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = Self.dotSize / 2

        panel.contentView?.addSubview(dot)

        positionPanel(panel)

        panel.orderFrontRegardless()
        self.panel = panel

        // Pulse animation unless Reduce Motion is enabled
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            startPulsing(dot: dot)
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        captionBox = nil
        captionLabel = nil
    }

    /// Shows live recognized text beside the dot (empty hides it). Head-truncated so the newest words stay visible.
    func updatePreview(_ text: String) {
        guard let panel else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            captionBox?.isHidden = true
            resize(panel, to: NSSize(width: Self.panelSize, height: Self.panelSize))
            return
        }

        if captionBox == nil {
            // HUD material is dark translucent; the panel stays non-activating and mouse-transparent.
            let box = NSVisualEffectView()
            box.material = .hudWindow
            box.appearance = NSAppearance(named: .vibrantDark)
            box.blendingMode = .behindWindow
            box.state = .active
            box.wantsLayer = true
            box.layer?.cornerRadius = 10
            box.layer?.masksToBounds = true
            let label = NSTextField(wrappingLabelWithString: "")
            label.font = .systemFont(ofSize: 13)
            label.textColor = .white
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byTruncatingHead
            label.cell?.truncatesLastVisibleLine = true
            box.addSubview(label)
            panel.contentView?.addSubview(box)
            captionBox = box
            captionLabel = label
        }
        guard let box = captionBox, let label = captionLabel else { return }
        label.stringValue = trimmed
        box.isHidden = false

        let inset = Self.captionInset
        let maxText = Self.captionMaxWidth - inset.width * 2
        label.preferredMaxLayoutWidth = maxText
        let fit = label.sizeThatFits(NSSize(width: maxText, height: .greatestFiniteMagnitude))
        let textSize = NSSize(width: min(ceil(fit.width), maxText), height: ceil(fit.height))
        let boxSize = NSSize(width: textSize.width + inset.width * 2, height: textSize.height + inset.height * 2)
        let total = NSSize(width: Self.panelSize + Self.captionGap + boxSize.width,
                           height: max(Self.panelSize, boxSize.height))
        resize(panel, to: total)
        box.frame = NSRect(x: Self.panelSize + Self.captionGap, y: (total.height - boxSize.height) / 2,
                           width: boxSize.width, height: boxSize.height)
        label.frame = NSRect(x: inset.width, y: inset.height, width: textSize.width, height: textSize.height)
    }

    /// Resizes while keeping the dot where it was (left edge and vertical center stay fixed).
    private func resize(_ panel: NSPanel, to size: NSSize) {
        let old = panel.frame
        panel.setFrame(NSRect(x: old.minX, y: old.midY - size.height / 2, width: size.width, height: size.height),
                       display: true)
        if let dot = panel.contentView?.subviews.first(where: { $0 !== captionBox }) {
            dot.frame.origin = NSPoint(x: Self.panelPadding, y: (size.height - Self.dotSize) / 2)
        }
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.minX + frame.width / 3 - Self.panelSize / 2,
            y: frame.midY - panel.frame.height / 2
        ))
    }

    private func startPulsing(dot: NSView) {
        guard let layer = dot.layer else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.4
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "pulse")
    }
}
