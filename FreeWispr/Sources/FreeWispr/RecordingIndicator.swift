import AppKit

/// A floating red dot that appears while recording.
/// Uses NSPanel at status-window level so it floats above all apps and appears on all Spaces.
@MainActor
final class RecordingIndicator {
    private var panel: NSPanel?
    private var screenObserver: NSObjectProtocol?

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
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.minX + frame.width / 3 - Self.panelSize / 2,
            y: frame.minY + frame.height / 2 - Self.panelSize / 2
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
