import AppKit
import SwiftUI
import AVFoundation
import VideoToolbox

/// High-performance hardware H.264 video decoder engine.
/// Runs entirely on a background queue without AppKit/NSView or @MainActor isolation constraints.
final class H264DecoderEngine: @unchecked Sendable {
    private var formatDescription: CMVideoFormatDescription?
    private var spsData: Data?
    private var ppsData: Data?
    private let queue = DispatchQueue(label: "com.droidlink.videoDecoder", qos: .userInteractive)

    var onSampleBufferReady: (@Sendable (CMSampleBuffer) -> Void)?

    func processFrame(h264Data: Data, isKeyframe: Bool, frameNum: Int32) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let sampleBuffer = self.decode(h264Data: h264Data, isKeyframe: isKeyframe, frameNum: frameNum) {
                self.onSampleBufferReady?(sampleBuffer)
            }
        }
    }

    private func decode(h264Data: Data, isKeyframe: Bool, frameNum: Int32) -> CMSampleBuffer? {
        let nalus = extractNALUs(from: h264Data)
        guard !nalus.isEmpty else { return nil }

        for nalu in nalus {
            guard !nalu.isEmpty else { continue }
            let naluType = nalu[0] & 0x1F

            if naluType == 7 { // SPS
                spsData = nalu
            } else if naluType == 8 { // PPS
                ppsData = nalu
            }
        }

        // Initialize or update format description when SPS & PPS are available
        if let sps = spsData, let pps = ppsData {
            if formatDescription == nil || isKeyframe {
                createFormatDescription(sps: sps, pps: pps)
            }
        }

        guard let format = formatDescription else { return nil }

        // Assemble NALUs with 4-byte length prefix (AVCC format required by CMBlockBuffer)
        var avccData = Data()
        for nalu in nalus {
            let naluType = nalu[0] & 0x1F
            if naluType == 7 || naluType == 8 {
                continue // Skip parameter sets in video sample buffer
            }
            var length = UInt32(nalu.count).bigEndian
            avccData.append(Data(bytes: &length, count: 4))
            avccData.append(nalu)
        }

        guard !avccData.isEmpty else { return nil }

        // Create CMBlockBuffer
        var blockBuffer: CMBlockBuffer?
        let status = avccData.withUnsafeBytes { rawBuffer in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: avccData.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avccData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }

        guard status == kCMBlockBufferNoErr, let buffer = blockBuffer else { return nil }

        avccData.withUnsafeBytes { rawBuffer in
            if let ptr = rawBuffer.baseAddress {
                CMBlockBufferReplaceDataBytes(
                    with: ptr,
                    blockBuffer: buffer,
                    offsetIntoDestination: 0,
                    dataLength: avccData.count
                )
            }
        }

        // Create CMSampleBuffer configured for immediate low-latency presentation
        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avccData.count
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let readySample = sampleBuffer else { return nil }

        // Set immediate display attachment for real-time video display
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(readySample, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        return readySample
    }

    private func createFormatDescription(sps: Data, pps: Data) {
        sps.withUnsafeBytes { spsBuffer in
            pps.withUnsafeBytes { ppsBuffer in
                guard let spsPtr = spsBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let ppsPtr = ppsBuffer.bindMemory(to: UInt8.self).baseAddress else { return }

                let pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                let sizes: [Int] = [sps.count, pps.count]

                var newFormat: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &newFormat
                )

                if status == noErr, let format = newFormat {
                    self.formatDescription = format
                    print("✅ Hardware H.264 CMVideoFormatDescription created successfully")
                } else {
                    print("⚠️ Failed to create CMVideoFormatDescription: \(status)")
                }
            }
        }
    }

    private func extractNALUs(from data: Data) -> [Data] {
        var nalus: [Data] = []
        let count = data.count
        guard count > 4 else { return nalus }

        data.withUnsafeBytes { raw in
            guard let ptr = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var startPositions: [(codeLen: Int, payloadStart: Int)] = []
            var i = 0

            while i < count - 2 {
                if i < count - 3 && ptr[i] == 0 && ptr[i+1] == 0 && ptr[i+2] == 0 && ptr[i+3] == 1 {
                    startPositions.append((codeLen: 4, payloadStart: i + 4))
                    i += 4
                } else if ptr[i] == 0 && ptr[i+1] == 0 && ptr[i+2] == 1 {
                    startPositions.append((codeLen: 3, payloadStart: i + 3))
                    i += 3
                } else {
                    i += 1
                }
            }

            for idx in 0..<startPositions.count {
                let payloadStart = startPositions[idx].payloadStart
                let nextCodeStart = (idx + 1 < startPositions.count) ? (startPositions[idx + 1].payloadStart - startPositions[idx + 1].codeLen) : count
                if nextCodeStart > payloadStart {
                    nalus.append(Data(bytes: ptr.advanced(by: payloadStart), count: nextCodeStart - payloadStart))
                }
            }
        }

        return nalus
    }
}

/// High-performance hardware-accelerated H.264 video decoder & interactive input view.
final class H264DecoderView: NSView {
    private let sampleBufferLayer = AVSampleBufferDisplayLayer()
    private let decoderEngine = H264DecoderEngine()

    private var accumulatedScrollDx: CGFloat = 0
    private var accumulatedScrollDy: CGFloat = 0
    private var scrollThrottleTimer: Timer?
    private var lastScrollPt: (x: Float, y: Float) = (0.5, 0.5)
    private var lastMouseLocation: NSPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
        setupFrameObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
        setupFrameObserver()
    }

    private func setupLayer() {
        wantsLayer = true
        let rootLayer = CALayer()
        rootLayer.backgroundColor = NSColor.black.cgColor
        layer = rootLayer

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        rootLayer.contentsScale = scale
        sampleBufferLayer.contentsScale = scale

        sampleBufferLayer.videoGravity = .resizeAspect
        sampleBufferLayer.frame = bounds
        sampleBufferLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        rootLayer.addSublayer(sampleBufferLayer)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        updateBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingScale()
    }

    private func updateBackingScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        layer?.contentsScale = scale
        sampleBufferLayer.contentsScale = scale
    }

    override var acceptsFirstResponder: Bool { true }

    private func setupFrameObserver() {
        decoderEngine.onSampleBufferReady = { [weak self] sampleBuffer in
            nonisolated(unsafe) let buffer = sampleBuffer
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.sampleBufferLayer.status == .failed {
                    self.sampleBufferLayer.flush()
                }
                self.sampleBufferLayer.enqueue(buffer)
            }
        }

        ScreenMirroringManager.shared.onVideoFrameReceived = { [weak self] frameData, isKeyframe, frameNum in
            self?.decoderEngine.processFrame(h264Data: frameData, isKeyframe: isKeyframe, frameNum: frameNum)
        }
    }

    // MARK: - User Input & Coordinate Normalization

    private func normalizedPoint(from locationInView: NSPoint) -> (x: Float, y: Float) {
        let w = Float(bounds.width)
        let h = Float(bounds.height)
        guard w > 0, h > 0 else { return (0, 0) }

        let normX = max(0.0, min(1.0, Float(locationInView.x) / w))
        let normY = max(0.0, min(1.0, Float(bounds.height - locationInView.y) / h)) // Invert Y for Android
        return (normX, normY)
    }

    override func mouseDown(with event: NSEvent) {
        let pt = normalizedPoint(from: convert(event.locationInWindow, from: nil))
        lastMouseLocation = convert(event.locationInWindow, from: nil)
        ScreenMirroringManager.shared.sendTouch(normX: pt.x, normY: pt.y, action: .down)
        if AoaUsbManager.shared.isConnected {
            AoaHidController.shared.sendMouseMove(dx: 0, dy: 0, buttons: 0x01)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = normalizedPoint(from: convert(event.locationInWindow, from: nil))
        let currentLoc = convert(event.locationInWindow, from: nil)
        if let lastLoc = lastMouseLocation {
            let dx = Int8(max(-127, min(127, Int(currentLoc.x - lastLoc.x))))
            let dy = Int8(max(-127, min(127, Int(lastLoc.y - currentLoc.y))))
            if AoaUsbManager.shared.isConnected {
                AoaHidController.shared.sendMouseMove(dx: dx, dy: dy, buttons: 0x01)
            }
        }
        lastMouseLocation = currentLoc
        ScreenMirroringManager.shared.sendTouch(normX: pt.x, normY: pt.y, action: .move)
    }

    override func mouseUp(with event: NSEvent) {
        let pt = normalizedPoint(from: convert(event.locationInWindow, from: nil))
        lastMouseLocation = nil
        ScreenMirroringManager.shared.sendTouch(normX: pt.x, normY: pt.y, action: .up)
        if AoaUsbManager.shared.isConnected {
            AoaHidController.shared.sendMouseMove(dx: 0, dy: 0, buttons: 0x00)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if AoaUsbManager.shared.isConnected {
            AoaHidController.shared.sendMouseMove(dx: 0, dy: 0, buttons: 0x02)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                AoaHidController.shared.sendMouseMove(dx: 0, dy: 0, buttons: 0x00)
            }
        }
        // Right click triggers Android Back button
        ScreenMirroringManager.shared.sendNav(action: .back)
    }

    override func scrollWheel(with event: NSEvent) {
        let pt = normalizedPoint(from: convert(event.locationInWindow, from: nil))
        lastScrollPt = pt

        if AoaUsbManager.shared.isConnected {
            let wheel = Int8(max(-127, min(127, Int(event.scrollingDeltaY))))
            if wheel != 0 {
                AoaHidController.shared.sendMouseMove(dx: 0, dy: 0, buttons: 0x00, wheel: wheel)
            }
        }

        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY

        if !event.hasPreciseScrollingDeltas {
            // Physical notched mouse wheel: scale 1 notch to a noticeable scroll burst
            dx *= 50
            dy *= 50
        }

        accumulatedScrollDx += dx
        accumulatedScrollDy += dy

        // Flush immediately if gesture is large, or throttle over 35ms
        if abs(accumulatedScrollDy) > 60 || abs(accumulatedScrollDx) > 60 {
            flushAccumulatedScroll()
        } else if scrollThrottleTimer == nil {
            scrollThrottleTimer = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: false) { [weak self] _ in
                self?.flushAccumulatedScroll()
            }
        }
    }

    private func flushAccumulatedScroll() {
        scrollThrottleTimer?.invalidate()
        scrollThrottleTimer = nil

        guard abs(accumulatedScrollDx) > 0.5 || abs(accumulatedScrollDy) > 0.5 else {
            accumulatedScrollDx = 0
            accumulatedScrollDy = 0
            return
        }

        let w = Float(bounds.width)
        let h = Float(bounds.height)
        guard w > 0, h > 0 else { return }

        let scrollDx = Float(accumulatedScrollDx) / w
        let scrollDy = Float(accumulatedScrollDy) / h

        ScreenMirroringManager.shared.sendTouch(
            normX: lastScrollPt.x,
            normY: lastScrollPt.y,
            action: .scroll,
            scrollDx: scrollDx,
            scrollDy: scrollDy
        )

        accumulatedScrollDx = 0
        accumulatedScrollDy = 0
    }

    private func hidKeyCode(for event: NSEvent) -> UInt8? {
        switch event.keyCode {
        case 51: return 0x2A // Backspace
        case 36, 76: return 0x28 // Return / Enter
        case 48: return 0x2B // Tab
        case 49: return 0x2C // Space
        case 53: return 0x29 // Escape
        case 123: return 0x50 // Left Arrow
        case 124: return 0x4F // Right Arrow
        case 125: return 0x51 // Down Arrow
        case 126: return 0x52 // Up Arrow
        default:
            guard let char = event.characters?.first else { return nil }
            if char >= "a" && char <= "z" {
                return UInt8(char.asciiValue! - Character("a").asciiValue! + 4)
            }
            if char >= "A" && char <= "Z" {
                return UInt8(char.asciiValue! - Character("A").asciiValue! + 4)
            }
            if char >= "1" && char <= "9" {
                return UInt8(char.asciiValue! - Character("1").asciiValue! + 0x1E)
            }
            if char == "0" { return 0x27 }
            return nil
        }
    }

    private func hidModifiers(for event: NSEvent) -> UInt8 {
        var mod: UInt8 = 0
        if event.modifierFlags.contains(.control) { mod |= 0x01 }
        if event.modifierFlags.contains(.shift) { mod |= 0x02 }
        if event.modifierFlags.contains(.option) { mod |= 0x04 }
        if event.modifierFlags.contains(.command) { mod |= 0x08 }
        return mod
    }

    override func keyDown(with event: NSEvent) {
        if AoaUsbManager.shared.isConnected, let hidCode = hidKeyCode(for: event) {
            let mod = hidModifiers(for: event)
            AoaHidController.shared.sendKeyboardReport(modifiers: mod, keyCodes: [hidCode])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                AoaHidController.shared.sendKeyboardReleaseAll()
            }
        }

        switch event.keyCode {
        case 51: // Backspace / Delete
            ScreenMirroringManager.shared.sendKey(text: "", keyCode: 67) // KEYCODE_DEL
        case 36: // Return / Enter
            ScreenMirroringManager.shared.sendKey(text: "", keyCode: 66) // KEYCODE_ENTER
        case 53: // Escape
            ScreenMirroringManager.shared.sendNav(action: .back)
        default:
            if let chars = event.characters, !chars.isEmpty {
                ScreenMirroringManager.shared.sendKey(text: chars)
            }
        }
    }
}

// MARK: - SwiftUI Representable

struct H264DecoderRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> H264DecoderView {
        return H264DecoderView()
    }

    func updateNSView(_ nsView: H264DecoderView, context: Context) {}
}
