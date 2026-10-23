import Foundation
import CoreGraphics
import ApplicationServices

/// Injects touch, stylus, mouse, and keyboard events from Android directly into the macOS virtual display.
/// Features a strict touch-state watchdog to prevent stuck dragging and supports hardware keyboard forwarding.
final class VirtualDisplayInputInjector: @unchecked Sendable {
    private var isMouseDown = false
    private var lastCursorPoint: CGPoint = .zero
    private var touchWatchdogWorkItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.droidlink.inputInjector", qos: .userInteractive)

    init() {}

    /// Injects an input event from Android onto the target virtual display
    func injectInput(_ input: Droidlink_Protocol_ExternalDisplayInput, displayID: CGDirectDisplayID) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.processInput(input, displayID: displayID)
        }
    }

    /// Releases any stuck mouse down state (e.g. if finger left screen abruptly)
    func releaseStuckInput() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.cancelWatchdog()
            if self.isMouseDown {
                self.isMouseDown = false
                if let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: self.lastCursorPoint, mouseButton: .left) {
                    event.post(tap: .cghidEventTap)
                    print("🖱️ VirtualDisplayInputInjector: Watchdog released stuck mouse down")
                }
            }
        }
    }

    private func processInput(_ input: Droidlink_Protocol_ExternalDisplayInput, displayID: CGDirectDisplayID) {
        // Verify macOS Accessibility permission
        guard AXIsProcessTrusted() else {
            return
        }

        let bounds = CGDisplayBounds(displayID)
        let targetX = bounds.origin.x + CGFloat(input.normalizedX) * bounds.size.width
        let targetY = bounds.origin.y + CGFloat(input.normalizedY) * bounds.size.height
        let cursorPoint = CGPoint(x: targetX, y: targetY)
        self.lastCursorPoint = cursorPoint

        let isRightClick = (input.buttonState & 2) != 0

        switch input.action {
        case .down:
            cancelWatchdog()
            isMouseDown = true
            CGWarpMouseCursorPosition(cursorPoint)

            let mouseType: CGEventType = isRightClick ? .rightMouseDown : .leftMouseDown
            let mouseButton: CGMouseButton = isRightClick ? .right : .left
            if let event = CGEvent(mouseEventSource: nil, mouseType: mouseType, mouseCursorPosition: cursorPoint, mouseButton: mouseButton) {
                if input.toolType == .stylus && input.pressure > 0 {
                    event.setDoubleValueField(.mouseEventPressure, value: Double(input.pressure))
                }
                event.post(tap: .cghidEventTap)
            }
            scheduleWatchdog()

        case .move:
            cancelWatchdog()
            CGWarpMouseCursorPosition(cursorPoint)

            let mouseType: CGEventType
            let mouseButton: CGMouseButton
            if isMouseDown {
                mouseType = isRightClick ? .rightMouseDragged : .leftMouseDragged
                mouseButton = isRightClick ? .right : .left
                scheduleWatchdog()
            } else {
                mouseType = .mouseMoved
                mouseButton = .left
            }

            if let event = CGEvent(mouseEventSource: nil, mouseType: mouseType, mouseCursorPosition: cursorPoint, mouseButton: mouseButton) {
                if input.toolType == .stylus && input.pressure > 0 {
                    event.setDoubleValueField(.mouseEventPressure, value: Double(input.pressure))
                }
                event.post(tap: .cghidEventTap)
            }

        case .up, .cancel:
            cancelWatchdog()
            if isMouseDown {
                isMouseDown = false
                let mouseType: CGEventType = isRightClick ? .rightMouseUp : .leftMouseUp
                let mouseButton: CGMouseButton = isRightClick ? .right : .left
                if let event = CGEvent(mouseEventSource: nil, mouseType: mouseType, mouseCursorPosition: cursorPoint, mouseButton: mouseButton) {
                    event.post(tap: .cghidEventTap)
                }
            }

        case .scroll:
            let dy = Int32(input.scrollDy * 10)
            let dx = Int32(input.scrollDx * 10)
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) {
                event.location = cursorPoint
                event.post(tap: .cghidEventTap)
            }

        case .keyDown:
            injectKeyEvent(input: input, keyDown: true)

        case .keyUp:
            injectKeyEvent(input: input, keyDown: false)

        case .actionUnknown, .UNRECOGNIZED:
            break
        }
    }

    private func scheduleWatchdog() {
        cancelWatchdog()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.isMouseDown else { return }
            self.isMouseDown = false
            if let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: self.lastCursorPoint, mouseButton: .left) {
                event.post(tap: .cghidEventTap)
                print("⚠️ VirtualDisplayInputInjector: Touch watchdog timeout (400ms); released mouse down")
            }
        }
        self.touchWatchdogWorkItem = item
        queue.asyncAfter(deadline: .now() + .milliseconds(400), execute: item)
    }

    private func cancelWatchdog() {
        touchWatchdogWorkItem?.cancel()
        touchWatchdogWorkItem = nil
    }

    // MARK: - Keyboard Injection

    private func injectKeyEvent(input: Droidlink_Protocol_ExternalDisplayInput, keyDown: Bool) {
        let macKeyCode = mapAndroidKeyCodeToMac(input.keyCode)
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: macKeyCode, keyDown: keyDown) else {
            return
        }

        // Apply modifiers bitmask if present (Shift=1, Control=2, Alt/Option=4, Meta/Command=8)
        var flags: CGEventFlags = []
        if (input.modifiers & 1) != 0 { flags.insert(.maskShift) }
        if (input.modifiers & 2) != 0 { flags.insert(.maskControl) }
        if (input.modifiers & 4) != 0 { flags.insert(.maskAlternate) }
        if (input.modifiers & 8) != 0 { flags.insert(.maskCommand) }
        if !flags.isEmpty {
            event.flags = flags
        }

        // If characters string is provided and non-empty, attach Unicode string
        if !input.characters.isEmpty {
            let utf16 = Array(input.characters.utf16)
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        }

        event.post(tap: .cghidEventTap)
    }

    /// Maps Android KeyEvent keycodes to macOS Virtual Key Codes
    private func mapAndroidKeyCodeToMac(_ androidCode: Int32) -> CGKeyCode {
        switch androidCode {
        case 66: return 0x24 // KEYCODE_ENTER -> Return
        case 67: return 0x33 // KEYCODE_DEL -> Delete/Backspace
        case 112: return 0x75 // KEYCODE_FORWARD_DEL -> Forward Delete
        case 61: return 0x30 // KEYCODE_TAB -> Tab
        case 62: return 0x31 // KEYCODE_SPACE -> Space
        case 111: return 0x35 // KEYCODE_ESCAPE -> Escape
        case 19: return 0x7E // KEYCODE_DPAD_UP -> Up Arrow
        case 20: return 0x7D // KEYCODE_DPAD_DOWN -> Down Arrow
        case 21: return 0x7B // KEYCODE_DPAD_LEFT -> Left Arrow
        case 22: return 0x7C // KEYCODE_DPAD_RIGHT -> Right Arrow
        case 122: return 0x73 // KEYCODE_MOVE_HOME -> Home
        case 123: return 0x77 // KEYCODE_MOVE_END -> End
        case 92: return 0x74 // KEYCODE_PAGE_UP -> Page Up
        case 93: return 0x79 // KEYCODE_PAGE_DOWN -> Page Down

        // Letters A-Z
        case 29: return 0x00 // A
        case 30: return 0x0B // B
        case 31: return 0x08 // C
        case 32: return 0x02 // D
        case 33: return 0x0E // E
        case 34: return 0x03 // F
        case 35: return 0x05 // G
        case 36: return 0x04 // H
        case 37: return 0x22 // I
        case 38: return 0x26 // J
        case 39: return 0x28 // K
        case 40: return 0x25 // L
        case 41: return 0x2E // M
        case 42: return 0x2D // N
        case 43: return 0x1F // O
        case 44: return 0x23 // P
        case 45: return 0x0C // Q
        case 46: return 0x0F // R
        case 47: return 0x01 // S
        case 48: return 0x11 // T
        case 49: return 0x20 // U
        case 50: return 0x09 // V
        case 51: return 0x0D // W
        case 52: return 0x07 // X
        case 53: return 0x10 // Y
        case 54: return 0x06 // Z

        // Numbers 0-9
        case 7: return 0x1D  // 0
        case 8: return 0x12  // 1
        case 9: return 0x13  // 2
        case 10: return 0x14 // 3
        case 11: return 0x15 // 4
        case 12: return 0x17 // 5
        case 13: return 0x16 // 6
        case 14: return 0x1A // 7
        case 15: return 0x1C // 8
        case 16: return 0x19 // 9

        default:
            return 0x31 // Default to Space if unknown
        }
    }
}
