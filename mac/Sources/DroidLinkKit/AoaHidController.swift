import Foundation
import IOKit
import IOKit.usb

/// Native AOA 2.0 HID Controller.
/// Enables macOS to act as a hardware USB Mouse and Keyboard to Android
/// using Android Open Accessory 2.0 HID control requests (Requests 54-57).
/// Operates with zero Android software latency and requires zero permissions on Android.
@MainActor
public final class AoaHidController: ObservableObject {
    public static let shared = AoaHidController()

    @Published public private(set) var isMouseRegistered: Bool = false
    @Published public private(set) var isKeyboardRegistered: Bool = false

    public static let mouseHidId: UInt16 = 1
    public static let keyboardHidId: UInt16 = 2

    // AOA 2.0 Control Requests
    private let reqRegisterHid: UInt8 = 54
    private let reqUnregisterHid: UInt8 = 55
    private let reqSetReportDesc: UInt8 = 56
    private let reqSendHidEvent: UInt8 = 57

    // Standard 3-Button USB Mouse + Wheel Report Descriptor (54 bytes)
    private static let mouseReportDescriptor: [UInt8] = [
        0x05, 0x01, // USAGE_PAGE (Generic Desktop)
        0x09, 0x02, // USAGE (Mouse)
        0xA1, 0x01, // COLLECTION (Application)
        0x09, 0x01, //   USAGE (Pointer)
        0xA1, 0x00, //   COLLECTION (Physical)
        0x05, 0x09, //     USAGE_PAGE (Button)
        0x19, 0x01, //     USAGE_MINIMUM (Button 1)
        0x29, 0x03, //     USAGE_MAXIMUM (Button 3)
        0x15, 0x00, //     LOGICAL_MINIMUM (0)
        0x25, 0x01, //     LOGICAL_MAXIMUM (1)
        0x95, 0x03, //     REPORT_COUNT (3)
        0x75, 0x01, //     REPORT_SIZE (1)
        0x81, 0x02, //     INPUT (Data,Var,Abs)
        0x95, 0x01, //     REPORT_COUNT (1)
        0x75, 0x05, //     REPORT_SIZE (5)
        0x81, 0x03, //     INPUT (Cnst,Var,Abs)
        0x05, 0x01, //     USAGE_PAGE (Generic Desktop)
        0x09, 0x30, //     USAGE (X)
        0x09, 0x31, //     USAGE (Y)
        0x15, 0x81, //     LOGICAL_MINIMUM (-127)
        0x25, 0x7F, //     LOGICAL_MAXIMUM (127)
        0x75, 0x08, //     REPORT_SIZE (8)
        0x95, 0x02, //     REPORT_COUNT (2)
        0x81, 0x06, //     INPUT (Data,Var,Rel)
        0x09, 0x38, //     USAGE (Wheel)
        0x15, 0x81, //     LOGICAL_MINIMUM (-127)
        0x25, 0x7F, //     LOGICAL_MAXIMUM (127)
        0x75, 0x08, //     REPORT_SIZE (8)
        0x95, 0x01, //     REPORT_COUNT (1)
        0x81, 0x06, //     INPUT (Data,Var,Rel)
        0xC0,       //   END_COLLECTION
        0xC0        // END_COLLECTION
    ]

    // Standard 104-Key USB Keyboard Report Descriptor (63 bytes)
    private static let keyboardReportDescriptor: [UInt8] = [
        0x05, 0x01, // USAGE_PAGE (Generic Desktop)
        0x09, 0x06, // USAGE (Keyboard)
        0xA1, 0x01, // COLLECTION (Application)
        0x05, 0x07, //   USAGE_PAGE (Keyboard)
        0x19, 0xE0, //   USAGE_MINIMUM (Keyboard LeftControl)
        0x29, 0xE7, //   USAGE_MAXIMUM (Keyboard Right GUI)
        0x15, 0x00, //   LOGICAL_MINIMUM (0)
        0x25, 0x01, //   LOGICAL_MAXIMUM (1)
        0x75, 0x01, //   REPORT_SIZE (1)
        0x95, 0x08, //   REPORT_COUNT (8)
        0x81, 0x02, //   INPUT (Data,Var,Abs)
        0x95, 0x01, //   REPORT_COUNT (1)
        0x75, 0x08, //   REPORT_SIZE (8)
        0x81, 0x03, //   INPUT (Cnst,Var,Abs)
        0x95, 0x06, //   REPORT_COUNT (6)
        0x75, 0x08, //   REPORT_SIZE (8)
        0x15, 0x00, //   LOGICAL_MINIMUM (0)
        0x25, 0x65, //   LOGICAL_MAXIMUM (101)
        0x05, 0x07, //   USAGE_PAGE (Keyboard)
        0x19, 0x00, //   USAGE_MINIMUM (Reserved)
        0x29, 0x65, //   USAGE_MAXIMUM (Keyboard Application)
        0x81, 0x00, //   INPUT (Data,Ary,Abs)
        0xC0        // END_COLLECTION
    ]

    private init() {
        NotificationCenter.default.addObserver(
            forName: .droidlinkUsbConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.registerMouse()
            self?.registerKeyboard()
        }

        NotificationCenter.default.addObserver(
            forName: .droidlinkUsbDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isMouseRegistered = false
            self?.isKeyboardRegistered = false
        }
    }

    /// Registers the Mac as a USB Mouse on Android via AOA 2.0
    @discardableResult
    public func registerMouse() -> Bool {
        guard AoaUsbManager.shared.isConnected else { return false }
        let desc = Self.mouseReportDescriptor

        // 1. ACCESSORY_REGISTER_HID (Request 54)
        let okReg = AoaUsbManager.shared.sendControlRequest(
            requestType: 0x40,
            request: reqRegisterHid,
            value: Self.mouseHidId,
            index: UInt16(desc.count),
            data: nil
        )
        guard okReg else {
            print("⚠️ AoaHidController: Failed to register mouse HID ID \(Self.mouseHidId)")
            return false
        }

        // 2. ACCESSORY_SET_HID_REPORT_DESC (Request 56)
        let okDesc = AoaUsbManager.shared.sendControlRequest(
            requestType: 0x40,
            request: reqSetReportDesc,
            value: Self.mouseHidId,
            index: 0,
            data: Data(desc)
        )
        guard okDesc else {
            print("⚠️ AoaHidController: Failed to set mouse report descriptor")
            return false
        }

        isMouseRegistered = true
        print("⚡ AoaHidController: Native USB Mouse registered with Android kernel!")
        return true
    }

    /// Registers the Mac as a USB Keyboard on Android via AOA 2.0
    @discardableResult
    public func registerKeyboard() -> Bool {
        guard AoaUsbManager.shared.isConnected else { return false }
        let desc = Self.keyboardReportDescriptor

        // 1. ACCESSORY_REGISTER_HID (Request 54)
        let okReg = AoaUsbManager.shared.sendControlRequest(
            requestType: 0x40,
            request: reqRegisterHid,
            value: Self.keyboardHidId,
            index: UInt16(desc.count),
            data: nil
        )
        guard okReg else {
            print("⚠️ AoaHidController: Failed to register keyboard HID ID \(Self.keyboardHidId)")
            return false
        }

        // 2. ACCESSORY_SET_HID_REPORT_DESC (Request 56)
        let okDesc = AoaUsbManager.shared.sendControlRequest(
            requestType: 0x40,
            request: reqSetReportDesc,
            value: Self.keyboardHidId,
            index: 0,
            data: Data(desc)
        )
        guard okDesc else {
            print("⚠️ AoaHidController: Failed to set keyboard report descriptor")
            return false
        }

        isKeyboardRegistered = true
        print("⚡ AoaHidController: Native USB Keyboard registered with Android kernel!")
        return true
    }

    /// Unregisters HID devices on disconnect or session exit
    public func unregisterAll() {
        if isMouseRegistered {
            _ = AoaUsbManager.shared.sendControlRequest(
                requestType: 0x40,
                request: reqUnregisterHid,
                value: Self.mouseHidId,
                index: 0,
                data: nil
            )
            isMouseRegistered = false
        }
        if isKeyboardRegistered {
            _ = AoaUsbManager.shared.sendControlRequest(
                requestType: 0x40,
                request: reqUnregisterHid,
                value: Self.keyboardHidId,
                index: 0,
                data: nil
            )
            isKeyboardRegistered = false
        }
    }

    // MARK: - Input Dispatching

    /// Sends a relative mouse report (4 bytes: buttons, dX, dY, wheel)
    public func sendMouseMove(dx: Int8, dy: Int8, buttons: UInt8, wheel: Int8 = 0) {
        if !isMouseRegistered {
            registerMouse()
        }
        let report: [UInt8] = [
            buttons,
            UInt8(bitPattern: dx),
            UInt8(bitPattern: dy),
            UInt8(bitPattern: wheel)
        ]
        _ = AoaUsbManager.shared.sendControlRequest(
            requestType: 0x40,
            request: reqSendHidEvent,
            value: Self.mouseHidId,
            index: 0,
            data: Data(report)
        )
    }

    /// Sends a standard 8-byte keyboard report
    public func sendKeyboardReport(modifiers: UInt8, keyCodes: [UInt8]) {
        if !isKeyboardRegistered {
            registerKeyboard()
        }
        var report = [UInt8](repeating: 0, count: 8)
        report[0] = modifiers
        report[1] = 0 // Reserved
        for (i, code) in keyCodes.prefix(6).enumerated() {
            report[2 + i] = code
        }
        _ = AoaUsbManager.shared.sendControlRequest(
            requestType: 0x40,
            request: reqSendHidEvent,
            value: Self.keyboardHidId,
            index: 0,
            data: Data(report)
        )
    }

    /// Releases all pressed keys
    public func sendKeyboardReleaseAll() {
        guard isKeyboardRegistered else { return }
        let emptyReport = [UInt8](repeating: 0, count: 8)
        _ = AoaUsbManager.shared.sendControlRequest(
            requestType: 0x40,
            request: reqSendHidEvent,
            value: Self.keyboardHidId,
            index: 0,
            data: Data(emptyReport)
        )
    }
}
