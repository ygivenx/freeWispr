import Cocoa
import CoreGraphics
import ApplicationServices

@MainActor
final class HotkeyManager: ObservableObject {
    @Published var isListening = false

    // Accessed from the CGEvent tap C callback (non-isolated context).
    // Thread safety is ensured by dispatching all reads/writes to DispatchQueue.main.
    nonisolated(unsafe) var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    nonisolated(unsafe) var isHotkeyHeld = false

    var onHotkeyDown: (() -> Void)?
    var onHotkeyUp: (() -> Void)?

    static func checkAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func start() -> Bool {
        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isListening = true
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        isListening = false
    }

    deinit {
        // The C callback holds an unretained pointer to this object. Disable and
        // invalidate the tap before the object is released so any in-flight or
        // subsequent CGEvent callbacks do not dereference a dangling pointer.
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            if let tap = manager.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    guard let userInfo = userInfo, type == .flagsChanged else {
        return Unmanaged.passUnretained(event)
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    let flags = event.flags

    // Globe key (fn) or Ctrl+Option held together
    let globePressed = flags.contains(.maskSecondaryFn)
    let ctrlOptionPressed = flags.contains(.maskControl) && flags.contains(.maskAlternate)
    let hotkeyActive = globePressed || ctrlOptionPressed

    // Dispatch all state mutations to main thread to avoid data races
    // with SwiftUI view updates that read from this ObservableObject.
    DispatchQueue.main.async {
        if hotkeyActive && !manager.isHotkeyHeld {
            manager.isHotkeyHeld = true
            manager.onHotkeyDown?()
        } else if !hotkeyActive && manager.isHotkeyHeld {
            manager.isHotkeyHeld = false
            manager.onHotkeyUp?()
        }
    }

    return Unmanaged.passUnretained(event)
}
