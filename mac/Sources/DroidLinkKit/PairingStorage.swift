import Foundation

public struct PairedDeviceInfo: Codable, Equatable, Sendable {
    public let deviceId: String
    public let deviceName: String
    public var deviceModel: String?
    public let sessionKey: Data
    public let bluetoothIdentifier: String?
    public let port: UInt16
    
    public init(deviceId: String, deviceName: String, deviceModel: String? = nil, sessionKey: Data, bluetoothIdentifier: String? = nil, port: UInt16 = 9999) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.sessionKey = sessionKey
        self.bluetoothIdentifier = bluetoothIdentifier
        self.port = port
    }
}

public final class PairingStorage {
    private static let keyPairedDevice = "droidlink_paired_device"
    private static let keyMyDeviceId = "droidlink_my_device_id"
    private static let keyClipboardSync = "droidlink_clipboard_sync"
    private static let keyIncognitoMode = "droidlink_incognito_mode"
    private static let keyAutoIgnoreSensitive = "droidlink_auto_ignore_sensitive"
    private static let keyNotificationMirroring = "droidlink_notification_mirroring"
    private static let keyPlayNotificationSound = "droidlink_play_notification_sound"
    private static let keyShowNotificationAppIcons = "droidlink_show_notification_app_icons"
    private static let keyRemoteStatus = "droidlink_remote_status"
    private static let keyFinderStorage = "droidlink_finder_storage"
    private static let keyCallIntegration = "droidlink_call_integration"
    private static let keyFloatingCallWidget = "droidlink_floating_call_widget"
    private static let keyAppleContactsSync = "droidlink_apple_contacts_sync"
    private static let keyRouteAudioThroughMac = "droidlink_route_audio_through_mac"
    private static let keyManuallyDisconnected = "droidlink_manually_disconnected"
    
    public static var isManuallyDisconnected: Bool {
        get {
            UserDefaults.standard.bool(forKey: keyManuallyDisconnected)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: keyManuallyDisconnected)
            UserDefaults.standard.synchronize()
        }
    }
    
    public static var isCallIntegrationEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: keyCallIntegration) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: keyCallIntegration)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: keyCallIntegration)
            UserDefaults.standard.synchronize()
        }
    }

    public static var isFloatingCallWidgetEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: keyFloatingCallWidget) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: keyFloatingCallWidget)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: keyFloatingCallWidget)
            UserDefaults.standard.synchronize()
        }
    }

    public static var isAppleContactsSyncEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: keyAppleContactsSync) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: keyAppleContactsSync)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: keyAppleContactsSync)
            UserDefaults.standard.synchronize()
        }
    }

    public static var routeAudioThroughMacByDefault: Bool {
        get {
            if UserDefaults.standard.object(forKey: keyRouteAudioThroughMac) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: keyRouteAudioThroughMac)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: keyRouteAudioThroughMac)
            UserDefaults.standard.synchronize()
        }
    }
    
    public static var isFinderStorageEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: keyFinderStorage) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: keyFinderStorage)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: keyFinderStorage)
            UserDefaults.standard.synchronize()
        }
    }
    
    public static var isClipboardSyncEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: keyClipboardSync) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: keyClipboardSync)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: keyClipboardSync)
            UserDefaults.standard.synchronize()
        }
    }
    
    public static var isNotificationMirroringEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: keyNotificationMirroring) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: keyNotificationMirroring)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: keyNotificationMirroring)
            UserDefaults.standard.synchronize()
        }
    }
    
    public static var playNotificationSound: Bool {
        get {
            if UserDefaults.standard.object(forKey: keyPlayNotificationSound) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: keyPlayNotificationSound)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: keyPlayNotificationSound)
            UserDefaults.standard.synchronize()
        }
    }
    
    public static var showNotificationAppIcons: Bool {
        get {
            if UserDefaults.standard.object(forKey: keyShowNotificationAppIcons) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: keyShowNotificationAppIcons)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: keyShowNotificationAppIcons)
            UserDefaults.standard.synchronize()
        }
    }
    
    public static var isIncognitoMode: Bool {
        get { UserDefaults.standard.bool(forKey: keyIncognitoMode) }
        set {
            UserDefaults.standard.set(newValue, forKey: keyIncognitoMode)
            UserDefaults.standard.synchronize()
        }
    }
    
    public static var autoIgnoreSensitive: Bool {
        get {
            if UserDefaults.standard.object(forKey: keyAutoIgnoreSensitive) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: keyAutoIgnoreSensitive)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: keyAutoIgnoreSensitive)
            UserDefaults.standard.synchronize()
        }
    }
    
    public static func getOrCreateMyDeviceId() -> String {
        if let id = UserDefaults.standard.string(forKey: keyMyDeviceId), !id.isEmpty {
            return id
        }
        if let paired = loadPairedDevice() {
            UserDefaults.standard.set(paired.deviceId, forKey: keyMyDeviceId)
            UserDefaults.standard.synchronize()
            return paired.deviceId
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: keyMyDeviceId)
        UserDefaults.standard.synchronize()
        return newId
    }
    
    public static var isPaired: Bool {
        return loadPairedDevice() != nil
    }
    
    public static func save(device: PairedDeviceInfo) {
        if let data = try? JSONEncoder().encode(device) {
            UserDefaults.standard.set(data, forKey: keyPairedDevice)
            UserDefaults.standard.set(false, forKey: keyManuallyDisconnected)
            UserDefaults.standard.synchronize()
            print("💾 Saved paired device info for \(device.deviceName)")
            fflush(stdout)
        }
    }
    
    public static func loadPairedDevice() -> PairedDeviceInfo? {
        guard let data = UserDefaults.standard.data(forKey: keyPairedDevice) else { return nil }
        return try? JSONDecoder().decode(PairedDeviceInfo.self, from: data)
    }
    
    public static func clear() {
        UserDefaults.standard.removeObject(forKey: keyPairedDevice)
        UserDefaults.standard.removeObject(forKey: keyManuallyDisconnected)
        UserDefaults.standard.synchronize()
        print("🗑️ Cleared paired device info")
        fflush(stdout)
    }
}
