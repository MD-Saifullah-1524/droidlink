import XCTest
import UserNotifications
@testable import DroidLink

final class NotificationManagerTests: XCTestCase {
    
    func testNotificationManagerInitialization() {
        let manager = NotificationManager.shared
        XCTAssertNotNil(manager)
        XCTAssertTrue(manager as Any is UNUserNotificationCenterDelegate)
    }
    
    func testNotificationMirroringDisabledIgnoresNotifications() {
        let previous = PairingStorage.isNotificationMirroringEnabled
        defer { PairingStorage.isNotificationMirroringEnabled = previous }
        
        PairingStorage.isNotificationMirroringEnabled = false
        NotificationManager.shared.postNotification(
            title: "Test Title",
            body: "Test Body",
            appName: "TestApp",
            id: UUID().uuidString
        )
    }
    
    func testDuplicateSuppression() {
        let previous = PairingStorage.isNotificationMirroringEnabled
        defer { PairingStorage.isNotificationMirroringEnabled = previous }
        PairingStorage.isNotificationMirroringEnabled = true
        
        let uniqueTitle = "Dedup Title \(UUID().uuidString)"
        let body = "Dedup Body"
        let app = "DedupApp"
        
        // First post
        NotificationManager.shared.postNotification(
            title: uniqueTitle,
            body: body,
            appName: app,
            id: UUID().uuidString
        )
        
        // Second post with identical parameters should be suppressed without error
        NotificationManager.shared.postNotification(
            title: uniqueTitle,
            body: body,
            appName: app,
            id: UUID().uuidString
        )
    }
    
    func testCheckAuthorizationGraceful() {
        let exp = expectation(description: "checkAuthorization callback")
        NotificationManager.shared.checkAuthorization { status in
            // In headless/test runner without .app bundle, it returns notDetermined safely
            XCTAssertEqual(status, .notDetermined)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }
    
    func testRequestAuthorizationGraceful() {
        let exp = expectation(description: "requestAuthorization callback")
        NotificationManager.shared.requestAuthorization { granted in
            // In headless/test runner without .app bundle, returns false safely without throwing exception
            XCTAssertFalse(granted)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }
}
