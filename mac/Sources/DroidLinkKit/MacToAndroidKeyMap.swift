import Foundation
import AppKit

/// Translates macOS virtual keycodes (NSEvent.keyCode) and modifier flags
/// into Android KeyEvent.KEYCODE_* constants and Unicode character codepoints.
public enum MacToAndroidKeyMap {

    /// Maps macOS virtual keycodes to Android key codes
    public static func androidKeyCode(from macKeyCode: UInt16) -> UInt16 {
        switch macKeyCode {
        // Letters (QWERTY layout on macOS)
        case 0:  return 29  // A -> KEYCODE_A
        case 11: return 30  // B -> KEYCODE_B
        case 8:  return 31  // C -> KEYCODE_C
        case 2:  return 32  // D -> KEYCODE_D
        case 14: return 33  // E -> KEYCODE_E
        case 3:  return 34  // F -> KEYCODE_F
        case 5:  return 35  // G -> KEYCODE_G
        case 4:  return 36  // H -> KEYCODE_H
        case 34: return 37  // I -> KEYCODE_I
        case 38: return 38  // J -> KEYCODE_J
        case 40: return 39  // K -> KEYCODE_K
        case 37: return 40  // L -> KEYCODE_L
        case 46: return 41  // M -> KEYCODE_M
        case 45: return 42  // N -> KEYCODE_N
        case 31: return 43  // O -> KEYCODE_O
        case 35: return 44  // P -> KEYCODE_P
        case 12: return 45  // Q -> KEYCODE_Q
        case 15: return 46  // R -> KEYCODE_R
        case 1:  return 47  // S -> KEYCODE_S
        case 17: return 48  // T -> KEYCODE_T
        case 32: return 49  // U -> KEYCODE_U
        case 9:  return 50  // V -> KEYCODE_V
        case 13: return 51  // W -> KEYCODE_W
        case 7:  return 52  // X -> KEYCODE_X
        case 16: return 53  // Y -> KEYCODE_Y
        case 6:  return 54  // Z -> KEYCODE_Z

        // Number row
        case 29: return 7   // 0 -> KEYCODE_0
        case 18: return 8   // 1 -> KEYCODE_1
        case 19: return 9   // 2 -> KEYCODE_2
        case 20: return 10  // 3 -> KEYCODE_3
        case 21: return 11  // 4 -> KEYCODE_4
        case 23: return 12  // 5 -> KEYCODE_5
        case 22: return 13  // 6 -> KEYCODE_6
        case 26: return 14  // 7 -> KEYCODE_7
        case 28: return 15  // 8 -> KEYCODE_8
        case 25: return 16  // 9 -> KEYCODE_9

        // Punctuation & symbols
        case 50: return 68  // ` / ~ -> KEYCODE_GRAVE
        case 27: return 69  // - / _ -> KEYCODE_MINUS
        case 24: return 70  // = / + -> KEYCODE_EQUALS
        case 33: return 71  // [ / { -> KEYCODE_LEFT_BRACKET
        case 30: return 72  // ] / } -> KEYCODE_RIGHT_BRACKET
        case 42: return 73  // \ / | -> KEYCODE_BACKSLASH
        case 41: return 74  // ; / : -> KEYCODE_SEMICOLON
        case 39: return 75  // ' / " -> KEYCODE_APOSTROPHE
        case 43: return 55  // , / < -> KEYCODE_COMMA
        case 47: return 56  // . / > -> KEYCODE_PERIOD
        case 44: return 76  // / / ? -> KEYCODE_SLASH
        case 49: return 62  // Space -> KEYCODE_SPACE

        // Navigation & Editing
        case 36: return 66  // Return / Enter -> KEYCODE_ENTER
        case 76: return 160 // Numpad Enter -> KEYCODE_NUMPAD_ENTER
        case 48: return 61  // Tab -> KEYCODE_TAB
        case 51: return 67  // Delete (Backspace) -> KEYCODE_DEL
        case 117: return 112 // Forward Delete -> KEYCODE_FORWARD_DEL
        case 53: return 111 // Escape -> KEYCODE_ESCAPE
        case 115: return 122 // Home -> KEYCODE_MOVE_HOME
        case 119: return 123 // End -> KEYCODE_MOVE_END
        case 116: return 92 // Page Up -> KEYCODE_PAGE_UP
        case 121: return 93 // Page Down -> KEYCODE_PAGE_DOWN

        // Arrow keys
        case 126: return 19 // Up Arrow -> KEYCODE_DPAD_UP
        case 125: return 20 // Down Arrow -> KEYCODE_DPAD_DOWN
        case 123: return 21 // Left Arrow -> KEYCODE_DPAD_LEFT
        case 124: return 22 // Right Arrow -> KEYCODE_DPAD_RIGHT

        // Modifiers
        case 56: return 59  // Left Shift -> KEYCODE_SHIFT_LEFT
        case 60: return 60  // Right Shift -> KEYCODE_SHIFT_RIGHT
        case 59: return 113 // Left Control -> KEYCODE_CTRL_LEFT
        case 62: return 114 // Right Control -> KEYCODE_CTRL_RIGHT
        case 58: return 57  // Left Option (Alt) -> KEYCODE_ALT_LEFT
        case 61: return 58  // Right Option (Alt) -> KEYCODE_ALT_RIGHT
        case 55: return 117 // Left Command (Meta) -> KEYCODE_META_LEFT
        case 54: return 118 // Right Command (Meta) -> KEYCODE_META_RIGHT
        case 57: return 115 // Caps Lock -> KEYCODE_CAPS_LOCK

        // Function keys F1-F12
        case 122: return 131 // F1 -> KEYCODE_F1
        case 120: return 132 // F2 -> KEYCODE_F2
        case 99:  return 133 // F3 -> KEYCODE_F3
        case 118: return 134 // F4 -> KEYCODE_F4
        case 96:  return 135 // F5 -> KEYCODE_F5
        case 97:  return 136 // F6 -> KEYCODE_F6
        case 98:  return 137 // F7 -> KEYCODE_F7
        case 100: return 138 // F8 -> KEYCODE_F8
        case 101: return 139 // F9 -> KEYCODE_F9
        case 109: return 140 // F10 -> KEYCODE_F10
        case 103: return 141 // F11 -> KEYCODE_F11
        case 111: return 142 // F12 -> KEYCODE_F12

        default:
            return 0 // KEYCODE_UNKNOWN
        }
    }

    /// Converts NSEvent modifier flags into DroidOsProtocol.KeyModifiers bitmask
    public static func modifiers(from flags: NSEvent.ModifierFlags) -> DroidOsProtocol.KeyModifiers {
        var mods = DroidOsProtocol.KeyModifiers()
        if flags.contains(.shift) {
            mods.insert(.shift)
        }
        if flags.contains(.control) {
            mods.insert(.ctrl)
        }
        if flags.contains(.option) {
            mods.insert(.alt)
        }
        if flags.contains(.command) {
            mods.insert(.meta)
        }
        return mods
    }

    /// Extracts unicode codepoint from NSEvent characters
    public static func unicodeCodepoint(from event: NSEvent) -> UInt32 {
        guard let chars = event.charactersIgnoringModifiers, let firstScalar = chars.unicodeScalars.first else {
            return 0
        }
        return firstScalar.value
    }
}
