import Foundation

public extension Notification.Name {
    static let droidlinkDeviceConnected = Notification.Name("droidlinkDeviceConnected")
    static let droidlinkDeviceDisconnected = Notification.Name("droidlinkDeviceDisconnected")
    static let droidlinkClipboardReceived = Notification.Name("droidlinkClipboardReceived")
    static let droidlinkNotificationReceived = Notification.Name("droidlinkNotificationReceived")
    static let droidlinkFileReceived = Notification.Name("droidlinkFileReceived")
    static let droidlinkIncognitoChanged = Notification.Name("droidlinkIncognitoChanged")
    static let droidlinkOpenSettings = Notification.Name("droidlinkOpenSettings")
    static let droidlinkDeviceStatusReceived = Notification.Name("droidlinkDeviceStatusReceived")
    static let droidlinkLocalTelemetryChanged = Notification.Name("droidlinkLocalTelemetryChanged")
    static let droidlinkFileChanged = Notification.Name("droidlinkFileChanged")
    static let droidlinkDistributedOpenMainWindow = Notification.Name("com.droidlink.mac.openMainWindow")
}