import XCTest
import Foundation
@testable import DroidLink

final class TelemetryAndDisconnectionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PairingStorage.clear()
    }

    override func tearDown() {
        PairingStorage.clear()
        super.tearDown()
    }

    func testPairingStorageManualDisconnectFlag() {
        // Initially should be false
        XCTAssertFalse(PairingStorage.isManuallyDisconnected)

        // Set to true
        PairingStorage.isManuallyDisconnected = true
        XCTAssertTrue(PairingStorage.isManuallyDisconnected)

        // Saving a newly paired device should reset manual disconnect to false
        let device = PairedDeviceInfo(
            deviceId: "test-device",
            deviceName: "Pixel 8",
            deviceModel: "Google Pixel 8",
            sessionKey: Data(repeating: 0x42, count: 32)
        )
        PairingStorage.save(device: device)
        XCTAssertFalse(PairingStorage.isManuallyDisconnected)

        // Setting it to true again
        PairingStorage.isManuallyDisconnected = true
        XCTAssertTrue(PairingStorage.isManuallyDisconnected)

        // Clearing should remove the manual disconnect flag
        PairingStorage.clear()
        XCTAssertFalse(PairingStorage.isManuallyDisconnected)
    }

    func testDeviceStatusInfoSerialization() throws {
        let status = DeviceStatusInfo(
            deviceName: "MacBook Pro",
            deviceModel: "Apple MacBook Pro",
            batteryLevel: 88,
            isCharging: true,
            powerSource: "Charging via AC",
            wifiSsid: "HomeNet",
            wifiSignalLevel: 4,
            wifiRssi: -50,
            hasCellular: false,
            localIpAddress: "192.168.1.50",
            tcpPort: 29170,
            isFinderStorageEnabled: true
        )

        let json = try XCTUnwrap(status.toJsonString())
        let decoded = try XCTUnwrap(DeviceStatusInfo.fromJsonString(json))

        XCTAssertEqual(decoded.deviceName, status.deviceName)
        XCTAssertEqual(decoded.deviceModel, status.deviceModel)
        XCTAssertEqual(decoded.batteryLevel, 88)
        XCTAssertTrue(decoded.isCharging)
        XCTAssertEqual(decoded.powerSource, "Charging via AC")
        XCTAssertEqual(decoded.wifiSsid, "HomeNet")
        XCTAssertEqual(decoded.localIpAddress, "192.168.1.50")
        XCTAssertEqual(decoded.tcpPort, 29170)
        XCTAssertTrue(decoded.isFinderStorageEnabled)
    }

    func testTelemetryDeltaDetection() {
        let initial = DeviceStatusInfo(
            deviceName: "Mac",
            batteryLevel: 80,
            isCharging: false,
            powerSource: "Battery",
            wifiSsid: "Wi-Fi 1"
        )

        let collector = MacTelemetryCollector.shared

        // Same status should not report changed
        XCTAssertFalse(collector.hasStatusChanged(from: initial, to: initial))

        // Nil previous status should report changed
        XCTAssertTrue(collector.hasStatusChanged(from: nil, to: initial))

        // Battery level change
        var changed = initial
        changed.batteryLevel = 79
        XCTAssertTrue(collector.hasStatusChanged(from: initial, to: changed))

        // Charging change
        changed = initial
        changed.isCharging = true
        XCTAssertTrue(collector.hasStatusChanged(from: initial, to: changed))

        // Power source change
        changed = initial
        changed.powerSource = "AC Power"
        XCTAssertTrue(collector.hasStatusChanged(from: initial, to: changed))

        // Wi-Fi SSID change
        changed = initial
        changed.wifiSsid = "OfficeNet"
        XCTAssertTrue(collector.hasStatusChanged(from: initial, to: changed))
    }
}
