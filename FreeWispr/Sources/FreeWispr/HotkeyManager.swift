import Cocoa
import CoreGraphics
import ApplicationServices

class HotkeyManager: ObservableObject {
    @Published var isListening = false

    var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    var isHotkeyHeld = false

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

    if hotkeyActive && !manager.isHotkeyHeld {
        manager.isHotkeyHeld = true
        DispatchQueue.main.async { manager.onHotkeyDown?() }
    } else if !hotkeyActive && manager.isHotkeyHeld {
        manager.isHotkeyHeld = false
        DispatchQueue.main.async { manager.onHotkeyUp?() }
    }

    return Unmanaged.passUnretained(event)
}
