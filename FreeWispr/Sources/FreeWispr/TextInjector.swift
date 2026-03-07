import AppKit
import ApplicationServices

class TextInjector {

    func injectText(_ text: String) {
        // Use clipboard paste — works universally (terminals, editors, web apps)
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 9

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        // Restore previous clipboard after paste completes
        if let previous = previousContents {
            let changeCount = pasteboard.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // Only restore if nothing else has touched the clipboard
                if pasteboard.changeCount == changeCount {
                    pasteboard.clearContents()
                    pasteboard.setString(previous, forType: .string)
                }
            }
        }
    }
}
