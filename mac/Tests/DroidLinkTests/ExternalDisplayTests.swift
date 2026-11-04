import XCTest
import CoreGraphics
@testable import DroidLink

final class ExternalDisplayTests: XCTestCase {

    func testExternalDisplayConfigSerialization() throws {
        var config = Droidlink_Protocol_ExternalDisplayConfig()
        config.width = 2560
        config.height = 1600
        config.fps = 120
        config.dpi = 320
        config.hiDpi = true
        config.bitrateKbps = 15000
        config.codec = .displayH264
        config.enableInput = true

        let data = try config.serializedData()
        let decoded = try Droidlink_Protocol_ExternalDisplayConfig(serializedBytes: data)

        XCTAssertEqual(decoded.width, 2560)
        XCTAssertEqual(decoded.height, 1600)
        XCTAssertEqual(decoded.fps, 120)
        XCTAssertEqual(decoded.dpi, 320)
        XCTAssertTrue(decoded.hiDpi)
        XCTAssertEqual(decoded.bitrateKbps, 15000)
        XCTAssertEqual(decoded.codec, .displayH264)
        XCTAssertTrue(decoded.enableInput)
    }

    func testExternalDisplayFrameSerialization() throws {
        var frame = Droidlink_Protocol_ExternalDisplayFrame()
        frame.frameData = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x1F])
        frame.frameNumber = 42
        frame.timestamp = 1700000000000
        frame.isKeyframe = true
        frame.width = 1920
        frame.height = 1080

        var msg = Droidlink_Protocol_ExternalDisplayMessage()
        msg.event = .videoFrame
        msg.frame = frame
        msg.timestamp = 1700000000000

        var rootMsg = Droidlink_Protocol_DroidLinkMessage()
        rootMsg.id = 12345
        rootMsg.timestamp = 1700000000000
        rootMsg.type = .externalDisplay
        rootMsg.externalDisplay = msg

        let data = try rootMsg.serializedData()
        let decodedRoot = try Droidlink_Protocol_DroidLinkMessage(serializedBytes: data)

        XCTAssertEqual(decodedRoot.type, .externalDisplay)
        XCTAssertEqual(decodedRoot.externalDisplay.event, .videoFrame)
        XCTAssertEqual(decodedRoot.externalDisplay.frame.frameNumber, 42)
        XCTAssertTrue(decodedRoot.externalDisplay.frame.isKeyframe)
        XCTAssertEqual(decodedRoot.externalDisplay.frame.width, 1920)
        XCTAssertEqual(decodedRoot.externalDisplay.frame.height, 1080)
        XCTAssertEqual(decodedRoot.externalDisplay.frame.frameData, frame.frameData)
    }

    func testExternalDisplayInputEventSerialization() throws {
        var input = Droidlink_Protocol_ExternalDisplayInput()
        input.action = .down
        input.toolType = .stylus
        input.pointerID = 1
        input.normalizedX = 0.5
        input.normalizedY = 0.75
        input.pressure = 0.85
        input.tiltX = 15.0
        input.tiltY = -5.0
        input.buttonState = 1

        let data = try input.serializedData()
        let decoded = try Droidlink_Protocol_ExternalDisplayInput(serializedBytes: data)

        XCTAssertEqual(decoded.action, .down)
        XCTAssertEqual(decoded.toolType, .stylus)
        XCTAssertEqual(decoded.pointerID, 1)
        XCTAssertEqual(decoded.normalizedX, 0.5, accuracy: 0.001)
        XCTAssertEqual(decoded.normalizedY, 0.75, accuracy: 0.001)
        XCTAssertEqual(decoded.pressure, 0.85, accuracy: 0.001)
        XCTAssertEqual(decoded.tiltX, 15.0, accuracy: 0.001)
        XCTAssertEqual(decoded.tiltY, -5.0, accuracy: 0.001)
        XCTAssertEqual(decoded.buttonState, 1)
    }

    func testExternalDisplayKeyboardEventSerialization() throws {
        var input = Droidlink_Protocol_ExternalDisplayInput()
        input.action = .keyDown
        input.keyCode = 66 // KEYCODE_ENTER
        input.modifiers = 8 // Command key
        input.characters = "Hello World"

        let data = try input.serializedData()
        let decoded = try Droidlink_Protocol_ExternalDisplayInput(serializedBytes: data)

        XCTAssertEqual(decoded.action, .keyDown)
        XCTAssertEqual(decoded.keyCode, 66)
        XCTAssertEqual(decoded.modifiers, 8)
        XCTAssertEqual(decoded.characters, "Hello World")
    }

    @MainActor
    func testExternalDisplayManagerSingleton() {
        let manager = ExternalDisplayManager.shared
        XCTAssertNotNil(manager)
        XCTAssertFalse(manager.isDisplayActive)
        XCTAssertTrue(manager.isNitsSyncEnabled)
    }

    func testExternalDisplayCalibrationSerialization() throws {
        var calib = Droidlink_Protocol_ExternalDisplayCalibration()
        calib.isCalibrating = true
        calib.macReferenceNits = 200.0
        calib.macAmbientLux = 150.0
        calib.forceRecalibrate = false
        calib.calibratedBacklight = 0.42

        var msg = Droidlink_Protocol_ExternalDisplayMessage()
        msg.event = .calibrationStart
        msg.calibration = calib
        msg.timestamp = 1700000000000

        let data = try msg.serializedData()
        let decoded = try Droidlink_Protocol_ExternalDisplayMessage(serializedBytes: data)

        XCTAssertEqual(decoded.event, .calibrationStart)
        XCTAssertTrue(decoded.calibration.isCalibrating)
        XCTAssertEqual(decoded.calibration.macReferenceNits, 200.0, accuracy: 0.001)
        XCTAssertEqual(decoded.calibration.macAmbientLux, 150.0, accuracy: 0.001)
        XCTAssertFalse(decoded.calibration.forceRecalibrate)
        XCTAssertEqual(decoded.calibration.calibratedBacklight, 0.42, accuracy: 0.001)
    }

    func testExternalDisplayBrightnessSerialization() throws {
        var brightness = Droidlink_Protocol_ExternalDisplayBrightness()
        brightness.targetNits = 195.5
        brightness.macAmbientLux = 120.0
        brightness.macLinearBrightness = 0.38
        brightness.timestamp = 1700000000000

        var msg = Droidlink_Protocol_ExternalDisplayMessage()
        msg.event = .brightnessUpdate
        msg.brightness = brightness
        msg.timestamp = 1700000000000

        let data = try msg.serializedData()
        let decoded = try Droidlink_Protocol_ExternalDisplayMessage(serializedBytes: data)

        XCTAssertEqual(decoded.event, .brightnessUpdate)
        XCTAssertEqual(decoded.brightness.targetNits, 195.5, accuracy: 0.001)
        XCTAssertEqual(decoded.brightness.macAmbientLux, 120.0, accuracy: 0.001)
        XCTAssertEqual(decoded.brightness.macLinearBrightness, 0.38, accuracy: 0.001)
        XCTAssertEqual(decoded.brightness.timestamp, 1700000000000)
    }

    @MainActor
    func testMacLuminanceMonitorCalculations() {
        let monitor = MacLuminanceMonitor.shared
        XCTAssertEqual(monitor.referenceCalibrationNits, 200.0)
        let minNits = monitor.getEstimatedMinNits()
        let maxNits = monitor.getEstimatedMaxSdrNits()
        XCTAssertGreaterThan(maxNits, minNits)
        let currentNits = monitor.getCurrentPhysicalNits()
        XCTAssertGreaterThanOrEqual(currentNits, minNits)
        XCTAssertLessThanOrEqual(currentNits, maxNits)
    }
}
