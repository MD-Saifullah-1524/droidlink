import XCTest
@testable import DroidLink

final class DroidOsTests: XCTestCase {

    // MARK: - AoaAccessoryProfile Tests

    func testAoaAccessoryProfileStrings() {
        let droidOs = AoaAccessoryProfile.droidOS
        XCTAssertEqual(droidOs.manufacturer, "droidOS")
        XCTAssertEqual(droidOs.model, "droidOS Desktop")
        XCTAssertEqual(droidOs.descriptionString, "droidOS Workstation Bridge")
        XCTAssertEqual(droidOs.version, "1.0")
        XCTAssertEqual(droidOs.uri, "https://github.com/droidOS")
        XCTAssertEqual(droidOs.serialNumber, "0000000012345678")

        let droidLink = AoaAccessoryProfile.droidLink
        XCTAssertEqual(droidLink.manufacturer, "DroidLink")
        XCTAssertEqual(droidLink.model, "DroidLink Display")
        XCTAssertEqual(droidLink.descriptionString, "Mac Display Bridge")

        let autoDetect = AoaAccessoryProfile.autoDetect
        XCTAssertEqual(autoDetect.manufacturer, "DroidLink") // Safe default fallback for standard Android

        // Dynamic resolution based on detected device name
        let resolvedGeneric = autoDetect.resolve(forDeviceName: "Pixel 8 Pro")
        XCTAssertEqual(resolvedGeneric.manufacturer, "DroidLink")
        XCTAssertEqual(resolvedGeneric.model, "DroidLink Display")
        XCTAssertFalse(resolvedGeneric.isDroidOs)

        let resolvedDroidOs = autoDetect.resolve(forDeviceName: "droidOS Phone HD")
        XCTAssertEqual(resolvedDroidOs.manufacturer, "droidOS")
        XCTAssertEqual(resolvedDroidOs.model, "droidOS Desktop")
        XCTAssertTrue(resolvedDroidOs.isDroidOs)
    }

    // MARK: - DroidOsProtocol Payload Tests

    func testMousePayloadSerialization() {
        let mouse = DroidOsProtocol.MousePayload(
            action: .down,
            button: .primary,
            scrollDeltaY: -5,
            normalizedX: 32768,
            normalizedY: 16384
        )
        let data = mouse.serialize()
        XCTAssertEqual(data.count, 12)
        XCTAssertEqual(data[0], DroidOsProtocol.MouseAction.down.rawValue)
        XCTAssertEqual(data[1], DroidOsProtocol.MouseButton.primary.rawValue)

        let scroll = data.subdata(in: 2..<4).withUnsafeBytes { $0.load(as: Int16.self).bigEndian }
        XCTAssertEqual(scroll, -5)

        let x = data.subdata(in: 4..<6).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        XCTAssertEqual(x, 32768)

        let y = data.subdata(in: 6..<8).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        XCTAssertEqual(y, 16384)
    }

    func testKeyboardPayloadSerialization() {
        var mods = DroidOsProtocol.KeyModifiers()
        mods.insert(.shift)
        mods.insert(.meta)

        let kb = DroidOsProtocol.KeyboardPayload(
            action: .down,
            modifiers: mods,
            androidKeyCode: 29, // AKEYCODE_A
            unicodeCodepoint: 65 // 'A'
        )
        let data = kb.serialize()
        XCTAssertEqual(data.count, 8)
        XCTAssertEqual(data[0], DroidOsProtocol.KeyAction.down.rawValue)
        XCTAssertEqual(data[1], 0x01 | 0x08) // Shift + Meta

        let code = data.subdata(in: 2..<4).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        XCTAssertEqual(code, 29)

        let cp = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        XCTAssertEqual(cp, 65)
    }

    func testDisplayConfigPayloadSerialization() {
        let config = DroidOsProtocol.DisplayConfigPayload(
            width: 1520,
            height: 720,
            dpi: 270,
            fps: 60,
            bitrateBps: 12_000_000
        )
        let data = config.serialize()
        XCTAssertEqual(data.count, 12)

        let w = data.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        XCTAssertEqual(w, 1520)

        let h = data.subdata(in: 2..<4).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        XCTAssertEqual(h, 720)

        let dpi = data.subdata(in: 4..<6).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        XCTAssertEqual(dpi, 270)

        let fps = data.subdata(in: 6..<8).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        XCTAssertEqual(fps, 60)

        let br = data.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        XCTAssertEqual(br, 12_000_000)
    }

    // MARK: - DroidOsFramer Tests

    func testFramerSinglePacket() {
        let framer = DroidOsFramer()
        let samplePayload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let packed = DroidOsProtocol.packFrame(type: .videoFrame, flags: 0x01, payload: samplePayload)

        let results = framer.deframe(chunk: packed)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].type, .videoFrame)
        XCTAssertEqual(results[0].flags, 0x01)
        XCTAssertEqual(results[0].payload, samplePayload)
    }

    func testFramerChunkedAcrossUsbPackets() {
        let framer = DroidOsFramer()
        let largePayload = Data(repeating: 0xAA, count: 20000)
        let packed = DroidOsProtocol.packFrame(type: .reverseTether, flags: 0x00, payload: largePayload)

        // Split into 4 chunks (e.g. 5000 bytes each)
        let chunk1 = packed.subdata(in: 0..<5000)
        let chunk2 = packed.subdata(in: 5000..<10000)
        let chunk3 = packed.subdata(in: 10000..<15000)
        let chunk4 = packed.subdata(in: 15000..<packed.count)

        XCTAssertTrue(framer.deframe(chunk: chunk1).isEmpty)
        XCTAssertTrue(framer.deframe(chunk: chunk2).isEmpty)
        XCTAssertTrue(framer.deframe(chunk: chunk3).isEmpty)

        let finalResults = framer.deframe(chunk: chunk4)
        XCTAssertEqual(finalResults.count, 1)
        XCTAssertEqual(finalResults[0].type, .reverseTether)
        XCTAssertEqual(finalResults[0].payload.count, 20000)
        XCTAssertEqual(finalResults[0].payload, largePayload)
    }

    func testFramerResynchronizationOnCorruptPrefix() {
        let framer = DroidOsFramer()
        var corruptData = Data([0x12, 0x34, 0x56, 0x78]) // Garbage bytes
        let samplePayload = Data([0x01, 0x02, 0x03])
        let validPacked = DroidOsProtocol.packFrame(type: .mouseEvent, flags: 0, payload: samplePayload)
        corruptData.append(validPacked)

        let results = framer.deframe(chunk: corruptData)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].type, .mouseEvent)
        XCTAssertEqual(results[0].payload, samplePayload)
    }

    // MARK: - MacToAndroidKeyMap Tests

    func testKeyMapping() {
        XCTAssertEqual(MacToAndroidKeyMap.androidKeyCode(from: 0), 29)  // 'A' -> AKEYCODE_A
        XCTAssertEqual(MacToAndroidKeyMap.androidKeyCode(from: 36), 66) // Return -> AKEYCODE_ENTER
        XCTAssertEqual(MacToAndroidKeyMap.androidKeyCode(from: 51), 67) // Backspace -> AKEYCODE_DEL
        XCTAssertEqual(MacToAndroidKeyMap.androidKeyCode(from: 53), 111) // Escape -> AKEYCODE_ESCAPE
        XCTAssertEqual(MacToAndroidKeyMap.androidKeyCode(from: 126), 19) // Up -> AKEYCODE_DPAD_UP
    }
}
