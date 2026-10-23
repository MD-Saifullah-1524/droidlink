import XCTest
import Foundation
@testable import DroidLink

final class DroidLinkXCTests: XCTestCase {
    
    func testCryptoRoundtrip() throws {
        let key = CryptoChannel.generateSessionKey()
        let channel = try CryptoChannel(keyData: key)
        
        let plaintext = "Hello from DroidLink over local Wi-Fi!".data(using: .utf8)!
        let ciphertext = try channel.encrypt(plaintext)
        
        XCTAssertNotEqual(ciphertext, plaintext)
        XCTAssertGreaterThanOrEqual(ciphertext.count, 28)
        
        let decrypted = try channel.decrypt(ciphertext)
        XCTAssertEqual(decrypted, plaintext)
        XCTAssertEqual(String(data: decrypted, encoding: .utf8), "Hello from DroidLink over local Wi-Fi!")
    }
    
    func testMessageFramer() throws {
        let framer = MessageFramer()
        let payload1 = "Message number 1".data(using: .utf8)!
        let payload2 = "Message number 2 with longer text content".data(using: .utf8)!
        
        let frame1 = try framer.frame(payload1)
        let frame2 = try framer.frame(payload2)
        
        var buffer = Data()
        buffer.append(frame1)
        buffer.append(frame2)
        
        let messages = try framer.deframe(from: &buffer)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0], payload1)
        XCTAssertEqual(messages[1], payload2)
        XCTAssertTrue(buffer.isEmpty)
    }
    
    func testQRCodeGenerator() throws {
        let generator = QRCodeGenerator()
        let key = CryptoChannel.generateSessionKey()
        
        let result = generator.generateQRCode(
            deviceId: "test-device-id",
            deviceName: "Test MacBook Pro",
            host: "192.168.1.100",
            port: 9999,
            sessionKey: key
        )
        
        XCTAssertNotNil(result)
        let token = result!.token
        XCTAssertEqual(token.version, "2.0.0")
        XCTAssertEqual(token.host, "192.168.1.100")
        XCTAssertEqual(token.port, 9999)
        XCTAssertEqual(token.sessionKey, key.base64EncodedString())
    }
    
    func testNotificationStorageAndSerialization() throws {
        // Test notification preferences in PairingStorage
        PairingStorage.isNotificationMirroringEnabled = true
        XCTAssertTrue(PairingStorage.isNotificationMirroringEnabled)
        PairingStorage.isNotificationMirroringEnabled = false
        XCTAssertFalse(PairingStorage.isNotificationMirroringEnabled)
        PairingStorage.isNotificationMirroringEnabled = true
        
        PairingStorage.playNotificationSound = false
        XCTAssertFalse(PairingStorage.playNotificationSound)
        PairingStorage.playNotificationSound = true
        XCTAssertTrue(PairingStorage.playNotificationSound)
        
        PairingStorage.showNotificationAppIcons = false
        XCTAssertFalse(PairingStorage.showNotificationAppIcons)
        PairingStorage.showNotificationAppIcons = true
        XCTAssertTrue(PairingStorage.showNotificationAppIcons)
        
        // Test Notification message protobuf with app icon
        var notifData = Droidlink_Protocol_NotificationData()
        notifData.id = "notif-12345"
        notifData.packageName = "com.slack"
        notifData.appName = "Slack"
        notifData.title = "Alex"
        notifData.text = "Hey, let's sync up on DroidLink!"
        notifData.timestamp = 1700000000000
        let fakeIcon = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // PNG magic bytes
        notifData.icon = fakeIcon
        
        var notifMsg = Droidlink_Protocol_NotificationMessage()
        notifMsg.event = .posted
        notifMsg.notification = notifData
        
        var rootMsg = Droidlink_Protocol_DroidLinkMessage()
        rootMsg.id = 9999
        rootMsg.timestamp = 1700000000000
        rootMsg.type = .notificationMirror
        rootMsg.notification = notifMsg
        
        let serialized = try rootMsg.serializedData()
        let parsed = try Droidlink_Protocol_DroidLinkMessage(serializedBytes: serialized)
        
        XCTAssertEqual(parsed.type, .notificationMirror)
        XCTAssertEqual(parsed.notification.notification.appName, "Slack")
        XCTAssertEqual(parsed.notification.notification.packageName, "com.slack")
        XCTAssertEqual(parsed.notification.notification.title, "Alex")
        XCTAssertEqual(parsed.notification.notification.text, "Hey, let's sync up on DroidLink!")
        XCTAssertEqual(parsed.notification.notification.icon, fakeIcon)
    }
}
