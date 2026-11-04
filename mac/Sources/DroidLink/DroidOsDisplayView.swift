import AppKit
import AVFoundation
import VideoToolbox

/// High-performance hardware video decoding view rendering droidOS H.264 desktop stream
/// and capturing mouse and keyboard input for injection back into Android.
public final class DroidOsDisplayView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var trackingArea: NSTrackingArea?
    private var formatDescription: CMVideoFormatDescription?
    private var spsData: Data?
    private var ppsData: Data?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
        setupVideoReceiver()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
        setupVideoReceiver()
    }

    private func setupLayer() {
        wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.frame = bounds
        root.addSublayer(displayLayer)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    public override var acceptsFirstResponder: Bool {
        return true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let options: NSTrackingArea.Options = [
            .mouseMoved,
            .mouseEnteredAndExited,
            .activeInKeyWindow,
            .inVisibleRect
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Video Pipeline

    private func setupVideoReceiver() {
        DroidOsManager.shared.onVideoFrameReceived = { [weak self] isKeyframe, h264Data in
            if Thread.isMainThread {
                self?.processH264Data(h264Data, isKeyframe: isKeyframe)
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.processH264Data(h264Data, isKeyframe: isKeyframe)
                }
            }
        }
    }

    deinit {
        DroidOsManager.shared.onVideoFrameReceived = nil
    }

    @MainActor
    private func processH264Data(_ data: Data, isKeyframe: Bool) {
        let nalus = extractNALUs(from: data)
        guard !nalus.isEmpty else { return }

        for nalu in nalus {
            guard !nalu.isEmpty else { continue }
            let naluType = nalu[0] & 0x1F
            if naluType == 7 { // SPS
                spsData = nalu
            } else if naluType == 8 { // PPS
                ppsData = nalu
            }
        }

        if let sps = spsData, let pps = ppsData {
            if formatDescription == nil || isKeyframe {
                createFormatDescription(sps: sps, pps: pps)
            }
        }

        guard let format = formatDescription else { return }

        // Assemble AVCC length-prefixed slice data
        var avccData = Data()
        for nalu in nalus {
            let naluType = nalu[0] & 0x1F
            if naluType == 7 || naluType == 8 {
                continue // Parameter sets not included in video sample buffer
            }
            var lengthBE = UInt32(nalu.count).bigEndian
            withUnsafeBytes(of: &lengthBE) { avccData.append(contentsOf: $0) }
            avccData.append(nalu)
        }

        guard !avccData.isEmpty else { return }

        guard let sampleBuffer = createSampleBuffer(from: avccData, format: format) else { return }

        if self.displayLayer.status == .failed {
            print("⚠️ DroidOsDisplayView: displayLayer failed: \(String(describing: self.displayLayer.error))")
            self.displayLayer.flush()
        }
        self.displayLayer.enqueue(sampleBuffer)
    }

    @MainActor
    private func createFormatDescription(sps: Data, pps: Data) {
        sps.withUnsafeBytes { spsBuffer in
            pps.withUnsafeBytes { ppsBuffer in
                guard let spsPtr = spsBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let ppsPtr = ppsBuffer.bindMemory(to: UInt8.self).baseAddress else { return }

                let pointers = [spsPtr, ppsPtr]
                let sizes = [sps.count, pps.count]

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
                    print("🖥️ DroidOsDisplayView: Created H.264 format description (\(sps.count)b SPS, \(pps.count)b PPS)")
                } else {
                    print("⚠️ DroidOsDisplayView: Failed to create format description, status: \(status)")
                }
            }
        }
    }

    private func createSampleBuffer(from avccData: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let memAlloc = kCFAllocatorDefault

        let status = avccData.withUnsafeBytes { rawBuffer in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: memAlloc,
                memoryBlock: nil,
                blockLength: avccData.count,
                blockAllocator: memAlloc,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avccData.count,
                flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &blockBuffer
            )
        }

        guard status == kCMBlockBufferNoErr, let buffer = blockBuffer else { return nil }

        avccData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: avccData.count
            )
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var sampleSize = avccData.count
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sBuf = sampleBuffer else {
            print("⚠️ DroidOsDisplayView: CMSampleBufferCreateReady failed with status: \(sampleStatus)")
            return nil
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sBuf, createIfNecessary: true) {
            let count = CFArrayGetCount(attachments)
            if count > 0 {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }

        return sBuf
    }

    private func extractNALUs(from data: Data) -> [Data] {
        var nalus: [Data] = []
        var i = 0
        var lastStart = 0

        while i < data.count - 3 {
            if data[i] == 0 && data[i + 1] == 0 {
                if data[i + 2] == 1 { // 3-byte start code 00 00 01
                    if i > lastStart {
                        nalus.append(data.subdata(in: lastStart..<i))
                    }
                    i += 3
                    lastStart = i
                    continue
                } else if data[i + 2] == 0 && data[i + 3] == 1 { // 4-byte start code 00 00 00 01
                    if i > lastStart {
                        nalus.append(data.subdata(in: lastStart..<i))
                    }
                    i += 4
                    lastStart = i
                    continue
                }
            }
            i += 1
        }

        if lastStart < data.count {
            nalus.append(data.subdata(in: lastStart..<data.count))
        }
        return nalus
    }

    // MARK: - Input Interception (Mouse & Keyboard)

    private func normalizedCoords(from event: NSEvent) -> (UInt16, UInt16) {
        let location = convert(event.locationInWindow, from: nil)
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return (0, 0) }

        // Clamp to bounds
        let clampedX = max(0, min(location.x, width))
        // Invert Y because macOS coordinates start at bottom-left, while Android starts at top-left
        let clampedY = max(0, min(height - location.y, height))

        let normX = UInt16(clampedX / width * 65535.0)
        let normY = UInt16(clampedY / height * 65535.0)
        return (normX, normY)
    }

    public override func mouseMoved(with event: NSEvent) {
        let (x, y) = normalizedCoords(from: event)
        DroidOsManager.shared.sendMouseEvent(action: .move, button: .none, normalizedX: x, normalizedY: y)
    }

    public override func mouseDragged(with event: NSEvent) {
        let (x, y) = normalizedCoords(from: event)
        DroidOsManager.shared.sendMouseEvent(action: .move, button: .primary, normalizedX: x, normalizedY: y)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        let (x, y) = normalizedCoords(from: event)
        DroidOsManager.shared.sendMouseEvent(action: .move, button: .secondary, normalizedX: x, normalizedY: y)
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let (x, y) = normalizedCoords(from: event)
        DroidOsManager.shared.sendMouseEvent(action: .down, button: .primary, normalizedX: x, normalizedY: y)
    }

    public override func mouseUp(with event: NSEvent) {
        let (x, y) = normalizedCoords(from: event)
        DroidOsManager.shared.sendMouseEvent(action: .up, button: .primary, normalizedX: x, normalizedY: y)
    }

    public override func rightMouseDown(with event: NSEvent) {
        let (x, y) = normalizedCoords(from: event)
        DroidOsManager.shared.sendMouseEvent(action: .down, button: .secondary, normalizedX: x, normalizedY: y)
    }

    public override func rightMouseUp(with event: NSEvent) {
        let (x, y) = normalizedCoords(from: event)
        DroidOsManager.shared.sendMouseEvent(action: .up, button: .secondary, normalizedX: x, normalizedY: y)
    }

    public override func otherMouseDown(with event: NSEvent) {
        let (x, y) = normalizedCoords(from: event)
        DroidOsManager.shared.sendMouseEvent(action: .down, button: .tertiary, normalizedX: x, normalizedY: y)
    }

    public override func otherMouseUp(with event: NSEvent) {
        let (x, y) = normalizedCoords(from: event)
        DroidOsManager.shared.sendMouseEvent(action: .up, button: .tertiary, normalizedX: x, normalizedY: y)
    }

    public override func scrollWheel(with event: NSEvent) {
        let (x, y) = normalizedCoords(from: event)
        let scrollDelta = Int16(clamping: Int(event.scrollingDeltaY * 10))
        DroidOsManager.shared.sendMouseEvent(action: .scroll, button: .none, scrollDeltaY: scrollDelta, normalizedX: x, normalizedY: y)
    }

    public override func keyDown(with event: NSEvent) {
        let androidCode = MacToAndroidKeyMap.androidKeyCode(from: event.keyCode)
        let mods = MacToAndroidKeyMap.modifiers(from: event.modifierFlags)
        let codepoint = MacToAndroidKeyMap.unicodeCodepoint(from: event)
        DroidOsManager.shared.sendKeyboardEvent(action: .down, modifiers: mods, androidKeyCode: androidCode, unicodeCodepoint: codepoint)
    }

    public override func keyUp(with event: NSEvent) {
        let androidCode = MacToAndroidKeyMap.androidKeyCode(from: event.keyCode)
        let mods = MacToAndroidKeyMap.modifiers(from: event.modifierFlags)
        let codepoint = MacToAndroidKeyMap.unicodeCodepoint(from: event)
        DroidOsManager.shared.sendKeyboardEvent(action: .up, modifiers: mods, androidKeyCode: androidCode, unicodeCodepoint: codepoint)
    }
}
