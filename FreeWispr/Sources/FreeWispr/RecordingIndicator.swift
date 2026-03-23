import AppKit

/// A small floating red dot that appears at the top-center of the screen while recording.
/// Uses NSPanel at status-window level so it floats above all apps and appears on all Spaces.
final class RecordingIndicator {
    private var panel: NSPanel?
    private var pulseTimer: Timer?

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

        // Position at 1/3 from left, vertically centered on screen
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let x = visibleFrame.minX + visibleFrame.width / 3 - Self.panelSize / 2
            let y = visibleFrame.minY + visibleFrame.height / 2 - Self.panelSize / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel

        // Pulse animation unless Reduce Motion is enabled
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            startPulsing(dot: dot)
        }
    }

    func hide() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        panel?.orderOut(nil)
        panel = nil
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
