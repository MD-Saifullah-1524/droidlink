import Foundation
import UserNotifications
import AppKit

// MARK: - NotificationManager

/// Manages native macOS notification delivery for mirrored Android notifications using UNUserNotificationCenter
public final class NotificationManager: NSObject, @unchecked Sendable {
    public static let shared = NotificationManager()
    
    private let lock = NSLock()
    private var lastDeliveredKeys: [String: Date] = [:]
    
    /// Indicates whether the current process is running inside a valid .app bundle supported by UNUserNotificationCenter
    public var isSupported: Bool {
        return Bundle.main.bundleURL.pathExtension == "app"
    }
    
    private override init() {
        super.init()
        if isSupported {
            UNUserNotificationCenter.current().delegate = self
        }
    }
    
    /// Requests notification permissions on macOS if not determined yet
    public func requestAuthorization(completion: (@Sendable (Bool) -> Void)? = nil) {
        guard isSupported else {
            completion?(false)
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let self = self else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                print("🔔 Notification permissions already authorized on macOS")
                fflush(stdout)
                completion?(true)
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if granted {
                        print("🔔 Notification permissions granted on macOS")
                    } else if let error = error {
                        print("❌ Notification authorization failed: \(error)")
                    }
                    fflush(stdout)
                    completion?(granted)
                }
            case .denied:
                print("⚠️ Notification permissions are currently denied in macOS System Settings")
                fflush(stdout)
                completion?(false)
            @unknown default:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    completion?(granted)
                }
            }
        }
    }
    
    /// Opens macOS System Settings directly to the Notifications pane
    public func openSystemNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
    
    /// Checks notification authorization status
    public func checkAuthorization(completion: @escaping @Sendable (UNAuthorizationStatus) -> Void) {
        guard isSupported else {
            completion(.notDetermined)
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            completion(settings.authorizationStatus)
        }
    }
    
    /// Displays an incoming mirrored Android notification natively on macOS
    public func postNotification(
        title: String,
        body: String,
        appName: String,
        id: String,
        iconData: Data? = nil
    ) {
        guard PairingStorage.isNotificationMirroringEnabled else {
            print("ℹ️ Notification ignored (mirroring disabled in settings)")
            fflush(stdout)
            return
        }
        
        // Auto-request authorization if not determined yet
        if isSupported {
            checkAuthorization { [weak self] status in
                if status == .notDetermined {
                    self?.requestAuthorization()
                }
            }
        }
        
        // Deduplicate rapid repeat deliveries (within 3 seconds)
        let dedupKey = "\(appName)_\(title)_\(body)"
        let now = Date()
        lock.lock()
        if let lastTime = lastDeliveredKeys[dedupKey], now.timeIntervalSince(lastTime) < 3.0 {
            lock.unlock()
            print("ℹ️ Suppressed duplicate notification on Mac: [\(appName)] \(title)")
            fflush(stdout)
            return
        }
        lastDeliveredKeys[dedupKey] = now
        if lastDeliveredKeys.count > 100 {
            lastDeliveredKeys = lastDeliveredKeys.filter { now.timeIntervalSince($0.value) < 10.0 }
        }
        lock.unlock()
        
        let displayTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? appName : title
        let displaySubtitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : appName
        let displayBody = body
        
        deliverViaUserNotificationCenter(
            title: displayTitle,
            subtitle: displaySubtitle,
            body: displayBody,
            appName: appName,
            id: id,
            iconData: iconData
        )
    }
    
    /// Deliver via modern UserNotifications API with app icon image attachment support
    private func deliverViaUserNotificationCenter(
        title: String,
        subtitle: String,
        body: String,
        appName: String,
        id: String,
        iconData: Data?
    ) {
        guard isSupported else {
            print("ℹ️ Notification received: [\(appName)] \(title) (UNUserNotificationCenter alerts require running within DroidLink.app bundle)")
            fflush(stdout)
            return
        }
        
        let content = UNMutableNotificationContent()
        content.title = title
        if !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        content.body = body
        
        if PairingStorage.playNotificationSound {
            content.sound = .default
        }
        
        // Attach app icon if present and enabled
        if PairingStorage.showNotificationAppIcons, let iconData = iconData, !iconData.isEmpty {
            let tempDir = FileManager.default.temporaryDirectory
            let iconFilename = "droidlink_\(UUID().uuidString).png"
            let fileUrl = tempDir.appendingPathComponent(iconFilename)
            
            do {
                try iconData.write(to: fileUrl)
                let attachment = try UNNotificationAttachment(
                    identifier: "app_icon",
                    url: fileUrl,
                    options: [
                        UNNotificationAttachmentOptionsThumbnailHiddenKey: false
                    ]
                )
                content.attachments = [attachment]
            } catch {
                print("⚠️ Could not attach notification icon: \(error)")
                fflush(stdout)
            }
        }
        
        let request = UNNotificationRequest(
            identifier: id.isEmpty ? UUID().uuidString : id,
            content: content,
            trigger: nil // Deliver immediately
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Failed to display notification via UNUserNotificationCenter: \(error)")
                fflush(stdout)
            } else {
                print("🔔 Native notification delivered: [\(appName)] \(title)")
                fflush(stdout)
            }
        }
    }
    
    /// Triggers a test notification locally to verify native display and icon rendering
    public func postTestNotification() {
        let img = NSImage(size: NSSize(width: 64, height: 64))
        img.lockFocus()
        NSColor.systemBlue.setFill()
        let path = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 64, height: 64), xRadius: 14, yRadius: 14)
        path.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 32),
            .foregroundColor: NSColor.white
        ]
        let str = "🔔" as NSString
        let strSize = str.size(withAttributes: attributes)
        str.draw(at: NSPoint(x: (64 - strSize.width) / 2, y: (64 - strSize.height) / 2), withAttributes: attributes)
        img.unlockFocus()
        
        let testIconData = img.tiffRepresentation.flatMap { rep in
            NSBitmapImageRep(data: rep)?.representation(using: .png, properties: [:])
        }
        
        postNotification(
            title: "Test Notification",
            body: "DroidLink notification mirroring is working natively with app icon!",
            appName: "DroidLink",
            id: UUID().uuidString,
            iconData: testIconData
        )
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Display banner and play sound even when app is active/foreground
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .sound, .list, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }
    
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
        completionHandler()
    }
}
