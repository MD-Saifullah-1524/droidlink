import Foundation

/// Protocol constants, message types, and binary serialization helpers for droidOS AOA Accessory Mode.
public enum DroidOsProtocol {
    public static let magicByte0: UInt8 = 0x44 // 'D'
    public static let magicByte1: UInt8 = 0x4F // 'O'
    public static let headerSize: Int = 8

    public enum MessageType: UInt8, Sendable {
        case videoFrame = 0x01
        case audioStream = 0x02
        case mouseEvent = 0x03
        case keyboardEvent = 0x04
        case displayConfig = 0x05
        case reverseTether = 0x06
        case clipboard = 0x07
        case unknown = 0xFF
    }

    public struct Header: Sendable {
        public let type: MessageType
        public let flags: UInt8
        public let payloadLength: UInt32

        public var isKeyframe: Bool {
            return (flags & 0x01) != 0
        }

        public init(type: MessageType, flags: UInt8 = 0, payloadLength: UInt32) {
            self.type = type
            self.flags = flags
            self.payloadLength = payloadLength
        }
    }

    // MARK: - Mouse Event (Type 0x03) - 12 Bytes

    public enum MouseAction: UInt8, Sendable {
        case move = 0
        case down = 1
        case up = 2
        case scroll = 3
    }

    public enum MouseButton: UInt8, Sendable {
        case none = 0
        case primary = 1    // Left
        case secondary = 2  // Right
        case tertiary = 3   // Middle
    }

    public struct MousePayload: Sendable {
        public let action: MouseAction
        public let button: MouseButton
        public let scrollDeltaY: Int16
        public let normalizedX: UInt16
        public let normalizedY: UInt16

        public init(action: MouseAction, button: MouseButton, scrollDeltaY: Int16 = 0, normalizedX: UInt16, normalizedY: UInt16) {
            self.action = action
            self.button = button
            self.scrollDeltaY = scrollDeltaY
            self.normalizedX = normalizedX
            self.normalizedY = normalizedY
        }

        public func serialize() -> Data {
            var data = Data(count: 12)
            data[0] = action.rawValue
            data[1] = button.rawValue

            var scrollBE = scrollDeltaY.bigEndian
            withUnsafeBytes(of: &scrollBE) { data.replaceSubrange(2..<4, with: $0) }

            var xBE = normalizedX.bigEndian
            withUnsafeBytes(of: &xBE) { data.replaceSubrange(4..<6, with: $0) }

            var yBE = normalizedY.bigEndian
            withUnsafeBytes(of: &yBE) { data.replaceSubrange(6..<8, with: $0) }

            // Bytes 8..11 are reserved padding (zeros)
            return data
        }
    }

    // MARK: - Keyboard Event (Type 0x04) - 8 Bytes

    public enum KeyAction: UInt8, Sendable {
        case down = 0
        case up = 1
    }

    public struct KeyModifiers: OptionSet, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let shift = KeyModifiers(rawValue: 0x01)
        public static let ctrl  = KeyModifiers(rawValue: 0x02)
        public static let alt   = KeyModifiers(rawValue: 0x04)
        public static let meta  = KeyModifiers(rawValue: 0x08) // Command / Windows key
    }

    public struct KeyboardPayload: Sendable {
        public let action: KeyAction
        public let modifiers: KeyModifiers
        public let androidKeyCode: UInt16
        public let unicodeCodepoint: UInt32

        public init(action: KeyAction, modifiers: KeyModifiers, androidKeyCode: UInt16, unicodeCodepoint: UInt32) {
            self.action = action
            self.modifiers = modifiers
            self.androidKeyCode = androidKeyCode
            self.unicodeCodepoint = unicodeCodepoint
        }

        public func serialize() -> Data {
            var data = Data(count: 8)
            data[0] = action.rawValue
            data[1] = modifiers.rawValue

            var codeBE = androidKeyCode.bigEndian
            withUnsafeBytes(of: &codeBE) { data.replaceSubrange(2..<4, with: $0) }

            var charBE = unicodeCodepoint.bigEndian
            withUnsafeBytes(of: &charBE) { data.replaceSubrange(4..<8, with: $0) }

            return data
        }
    }

    // MARK: - Dynamic Display Configuration (Type 0x05) - 12 Bytes

    public struct DisplayConfigPayload: Sendable {
        public let width: UInt16
        public let height: UInt16
        public let dpi: UInt16
        public let fps: UInt16
        public let bitrateBps: UInt32

        public init(width: UInt16, height: UInt16, dpi: UInt16 = 240, fps: UInt16 = 60, bitrateBps: UInt32 = 12_000_000) {
            self.width = width
            self.height = height
            self.dpi = dpi
            self.fps = fps
            self.bitrateBps = bitrateBps
        }

        public func serialize() -> Data {
            var data = Data(count: 12)

            var wBE = width.bigEndian
            withUnsafeBytes(of: &wBE) { data.replaceSubrange(0..<2, with: $0) }

            var hBE = height.bigEndian
            withUnsafeBytes(of: &hBE) { data.replaceSubrange(2..<4, with: $0) }

            var dpiBE = dpi.bigEndian
            withUnsafeBytes(of: &dpiBE) { data.replaceSubrange(4..<6, with: $0) }

            var fpsBE = fps.bigEndian
            withUnsafeBytes(of: &fpsBE) { data.replaceSubrange(6..<8, with: $0) }

            var brBE = bitrateBps.bigEndian
            withUnsafeBytes(of: &brBE) { data.replaceSubrange(8..<12, with: $0) }

            return data
        }
    }

    // MARK: - Frame Packaging Helper

    public static func packFrame(type: MessageType, flags: UInt8 = 0, payload: Data) -> Data {
        var packet = Data(count: headerSize + payload.count)
        packet[0] = magicByte0
        packet[1] = magicByte1
        packet[2] = type.rawValue
        packet[3] = flags

        var lengthBE = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &lengthBE) { packet.replaceSubrange(4..<8, with: $0) }

        if !payload.isEmpty {
            packet.replaceSubrange(8..<(8 + payload.count), with: payload)
        }
        return packet
    }
}
