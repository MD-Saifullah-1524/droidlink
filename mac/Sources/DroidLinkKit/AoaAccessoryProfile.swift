import Foundation

/// Defines the USB AOA 2.0 Accessory Handshake profiles supported by DroidLink.
public enum AoaAccessoryProfile: String, CaseIterable, Identifiable, Sendable {
    case autoDetect = "Auto-Detect"
    case droidOS = "droidOS Workstation"
    case droidLink = "DroidLink Standard"

    public var id: String { rawValue }

    /// Manufacturer name sent in AOA Request 52 (Index 0)
    public var manufacturer: String {
        switch self {
        case .droidOS:
            return "droidOS"
        case .droidLink, .autoDetect:
            return "DroidLink"
        }
    }

    /// Model name sent in AOA Request 52 (Index 1)
    public var model: String {
        switch self {
        case .droidOS:
            return "droidOS Desktop"
        case .droidLink, .autoDetect:
            return "DroidLink Display"
        }
    }

    /// Description string sent in AOA Request 52 (Index 2)
    public var descriptionString: String {
        switch self {
        case .droidOS:
            return "droidOS Workstation Bridge"
        case .droidLink, .autoDetect:
            return "Mac Display Bridge"
        }
    }

    /// Version string sent in AOA Request 52 (Index 3)
    public var version: String {
        return "1.0"
    }

    /// URI sent in AOA Request 52 (Index 4)
    public var uri: String {
        switch self {
        case .droidOS:
            return "https://github.com/droidOS"
        case .droidLink, .autoDetect:
            return "https://github.com/droidlink"
        }
    }

    /// Resolves actual handshake parameters given the detected USB device name
    public func resolve(forDeviceName deviceName: String) -> (manufacturer: String, model: String, descriptionString: String, uri: String, isDroidOs: Bool) {
        if self == .droidOS {
            return ("droidOS", "droidOS Desktop", "droidOS Workstation Bridge", "https://github.com/droidOS", true)
        }
        if self == .droidLink {
            return ("DroidLink", "DroidLink Display", "Mac Display Bridge", "https://github.com/droidlink", false)
        }
        // Auto-detect: if device name indicates droidOS, use droidOS; otherwise default to DroidLink
        let lower = deviceName.lowercased()
        if lower.contains("droidos") || lower.contains("droid_os") {
            return ("droidOS", "droidOS Desktop", "droidOS Workstation Bridge", "https://github.com/droidOS", true)
        }
        return ("DroidLink", "DroidLink Display", "Mac Display Bridge", "https://github.com/droidlink", false)
    }

    /// Serial number sent in AOA Request 52 (Index 5)
    public var serialNumber: String {
        return "0000000012345678"
    }

    private static let profileKey = "com.droidlink.aoa.accessoryProfile"

    /// Retrieves user-selected profile from UserDefaults, defaulting to .autoDetect
    public static var current: AoaAccessoryProfile {
        get {
            guard let raw = UserDefaults.standard.string(forKey: profileKey),
                  let profile = AoaAccessoryProfile(rawValue: raw) else {
                return .autoDetect
            }
            return profile
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: profileKey)
        }
    }
}
