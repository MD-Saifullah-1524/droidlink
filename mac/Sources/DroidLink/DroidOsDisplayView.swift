import AppKit
import AVFoundation
import VideoToolbox

/// High-performance hardware video decoding view rendering droidOS H.264 desktop stream
/// and capturing mouse and keyboard input for injection back into Android.
public final class DroidOsDisplayView: NSView {
    private var displayLayer = AVSampleBufferDisplayLayer()
    private var lastReportedStatus: AVQueuedSampleBufferRenderingStatus?
    private var trackingArea: NSTrackingArea?
    private var hintOverlay: NSTextField?
    private var formatDescription: CMVideoFormatDescription?
    private var spsData: Data?
    private var ppsData: Data?

    /// VMware-style input grab state
    public private(set) var isGrabbed: Bool = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
        setupOverlay()
        setupVideoReceiver()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
        setupOverlay()
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

    private func setupOverlay() {
        let label = NSTextField(labelWithString: "Press ⌃⌘ (Control-Command) to release mouse")
        label.isBezeled = false
        label.drawsBackground = true
        label.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        label.textColor = .white
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.cornerRadius = 8
        label.layer?.masksToBounds = true
        label.isHidden = true
        label.alphaValue = 0.0
        addSubview(label)
        self.hintOverlay = label
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

        if let hint = hintOverlay {
            let width: CGFloat = 360
            let height: CGFloat = 34
            hint.frame = NSRect(
                x: (bounds.width - width) / 2,
                y: bounds.height - height - 20,
                width: width,
                height: height
            )
        }
    }

    // MARK: - Input Grab & Release (VMware Parity)

    /// Grabs input, hides the host cursor, and routes mouse and keyboard exclusively to droidOS
    public func grabInput() {
        guard !isGrabbed else { return }
        isGrabbed = true
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
        window?.makeFirstResponder(self)

        guard let hint = hintOverlay else { return }
        hint.alphaValue = 1.0
        hint.isHidden = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 2.0
            hint.animator().alphaValue = 0.0
        }, completionHandler: { [weak hint] in
            Task { @MainActor in
                if hint?.alphaValue == 0.0 {
                    hint?.isHidden = true
                }
            }
        })
    }

    /// Releases input grab, unhides the host cursor, and restores macOS control
    public func releaseInput() {
        guard isGrabbed else { return }
        isGrabbed = false
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        NSCursor.unhide()
        hintOverlay?.isHidden = true
        hintOverlay?.alphaValue = 0.0
    }

    public override func resignFirstResponder() -> Bool {
        releaseInput()
        return super.resignFirstResponder()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let win = newWindow {
            win.acceptsMouseMovedEvents = true
        }
        if newWindow == nil && isGrabbed {
            releaseInput()
        }
    }

    deinit {
        DroidOsManager.shared.onVideoFrameReceived = nil
        if isGrabbed {
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
            NSCursor.unhide()
        }
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

    @MainActor
    private func processH264Data(_ data: Data, isKeyframe: Bool) {
        let nalus = Self.extractAnnexBNALUs(from: data)
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

        // Assemble AVCC length-prefixed slice data (Annex-B 00 00 00 01 delimiters replaced with 4-byte lengths)
        let avccData = Self.convertToAVCC(nalus: nalus)
        guard !avccData.isEmpty else { return }

        guard let sampleBuffer = createSampleBuffer(from: avccData, format: format) else { return }

        // Check diagnostic status before enqueue
        _ = checkLayerDiagnosticsAndRecover()

        self.displayLayer.enqueue(sampleBuffer)

        // Check diagnostic status after enqueue to catch immediate decoder errors (e.g. -12909)
        _ = checkLayerDiagnosticsAndRecover()
    }

    @MainActor
    private func checkLayerDiagnosticsAndRecover() -> Bool {
        let status = displayLayer.status
        if status != lastReportedStatus {
            let statusName: String
            switch status {
            case .unknown: statusName = "Unknown"
            case .rendering: statusName = "Rendering"
            case .failed: statusName = "Failed"
            @unknown default: statusName = "UnknownStatus(\(status.rawValue))"
            }
            print("📊 DroidOsDisplayView: Layer status transitioned to \(statusName)")
            lastReportedStatus = status
        }

        if status == .failed {
            let nsErr = displayLayer.error as NSError?
            let code = nsErr?.code ?? 0
            let desc = nsErr?.localizedDescription ?? "No description"
            let domain = nsErr?.domain ?? "UnknownDomain"
            print("❌ DroidOsDisplayView: AVSampleBufferDisplayLayer failed! Code: \(code), Domain: \(domain), Desc: \(desc)")
            if code == -12909 {
                print("⚠️ DroidOsDisplayView: Error -12909 (kVTVideoDecoderBadDataErr) detected! AVCC framing corrupted or start codes unreplaced.")
            }
            recreateDisplayLayer()
            return false
        }
        return true
    }

    @MainActor
    private func recreateDisplayLayer() {
        print("🔄 DroidOsDisplayView: Discarding failed layer and creating fresh AVSampleBufferDisplayLayer...")
        displayLayer.removeFromSuperlayer()
        displayLayer.stopRequestingMediaData()
        displayLayer.flushAndRemoveImage()

        let newLayer = AVSampleBufferDisplayLayer()
        newLayer.videoGravity = .resizeAspect
        newLayer.backgroundColor = NSColor.black.cgColor
        newLayer.frame = bounds
        layer?.addSublayer(newLayer)
        self.displayLayer = newLayer
        self.lastReportedStatus = nil

        // Re-request keyframe from droidOS
        DroidOsManager.shared.sendDisplayConfig(width: 1920, height: 1080, fps: 60, bitrate: 8_000_000)
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

    /// Scans an Annex-B elementary stream, extracting all NAL units cleanly without start codes or trailing zero-padding.
    nonisolated public static func extractAnnexBNALUs(from data: Data) -> [Data] {
        var nalus: [Data] = []
        let count = data.count
        guard count >= 3 else { return [] }

        data.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }

            var startCodeIndices: [(index: Int, length: Int)] = []
            var i = 0
            while i <= count - 3 {
                if bytes[i] == 0 && bytes[i + 1] == 0 {
                    if bytes[i + 2] == 1 {
                        // 3-byte start code 00 00 01
                        startCodeIndices.append((index: i, length: 3))
                        i += 3
                        continue
                    } else if i <= count - 4 && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                        // 4-byte start code 00 00 00 01
                        startCodeIndices.append((index: i, length: 4))
                        i += 4
                        continue
                    }
                }
                i += 1
            }

            guard !startCodeIndices.isEmpty else {
                // If no start codes are found, check if this is already an isolated NAL unit
                let naluType = bytes[0] & 0x1F
                if naluType >= 1 && naluType <= 31 {
                    nalus.append(Data(bytes: bytes, count: count))
                }
                return
            }

            for idx in 0..<startCodeIndices.count {
                let start = startCodeIndices[idx].index + startCodeIndices[idx].length
                let end = (idx + 1 < startCodeIndices.count) ? startCodeIndices[idx + 1].index : count

                // Strip trailing zeros often left by encoders/buffers
                var validEnd = end
                while validEnd > start && bytes[validEnd - 1] == 0 {
                    validEnd -= 1
                }

                if validEnd > start {
                    let len = validEnd - start
                    let naluData = Data(bytes: bytes.advanced(by: start), count: len)
                    nalus.append(naluData)
                }
            }
        }
        return nalus
    }

    /// Converts extracted NALUs to AVCC format by prepending each slice NALU with its 4-byte big-endian length.
    /// Parameter sets (SPS type 7, PPS type 8) are excluded from the AVCC slice buffer.
    nonisolated public static func convertToAVCC(nalus: [Data]) -> Data {
        var avccData = Data()
        for nalu in nalus {
            guard !nalu.isEmpty else { continue }
            let naluType = nalu[0] & 0x1F
            // Exclude SPS (7) and PPS (8) parameter sets from AVCC sample buffer
            if naluType == 7 || naluType == 8 {
                continue
            }
            var lengthBE = UInt32(nalu.count).bigEndian
            withUnsafeBytes(of: &lengthBE) { avccData.append(contentsOf: $0) }
            avccData.append(nalu)
        }
        return avccData
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

        let normX = UInt16(clamping: Int((clampedX / width) * 65535.0))
        let normY = UInt16(clamping: Int((clampedY / height) * 65535.0))
        return (normX, normY)
    }

    public override func mouseDown(with event: NSEvent) {
        if !isGrabbed {
            grabInput()
        }
        let (x, y) = normalizedCoords(from: event)
        let dx = Int16(clamping: Int(event.deltaX))
        let dy = Int16(clamping: Int(event.deltaY))
        DroidOsManager.shared.sendMouseEvent(action: .down, button: .primary, normalizedX: x, normalizedY: y, deltaX: dx, deltaY: dy)
    }

    public override func mouseUp(with event: NSEvent) {
        if isGrabbed {
            let (x, y) = normalizedCoords(from: event)
            let dx = Int16(clamping: Int(event.deltaX))
            let dy = Int16(clamping: Int(event.deltaY))
            DroidOsManager.shared.sendMouseEvent(action: .up, button: .primary, normalizedX: x, normalizedY: y, deltaX: dx, deltaY: dy)
        }
    }

    public override func rightMouseDown(with event: NSEvent) {
        if isGrabbed {
            let (x, y) = normalizedCoords(from: event)
            let dx = Int16(clamping: Int(event.deltaX))
            let dy = Int16(clamping: Int(event.deltaY))
            DroidOsManager.shared.sendMouseEvent(action: .down, button: .secondary, normalizedX: x, normalizedY: y, deltaX: dx, deltaY: dy)
        }
    }

    public override func rightMouseUp(with event: NSEvent) {
        if isGrabbed {
            let (x, y) = normalizedCoords(from: event)
            let dx = Int16(clamping: Int(event.deltaX))
            let dy = Int16(clamping: Int(event.deltaY))
            DroidOsManager.shared.sendMouseEvent(action: .up, button: .secondary, normalizedX: x, normalizedY: y, deltaX: dx, deltaY: dy)
        }
    }

    public override func otherMouseDown(with event: NSEvent) {
        if isGrabbed {
            let (x, y) = normalizedCoords(from: event)
            let dx = Int16(clamping: Int(event.deltaX))
            let dy = Int16(clamping: Int(event.deltaY))
            DroidOsManager.shared.sendMouseEvent(action: .down, button: .tertiary, normalizedX: x, normalizedY: y, deltaX: dx, deltaY: dy)
        }
    }

    public override func otherMouseUp(with event: NSEvent) {
        if isGrabbed {
            let (x, y) = normalizedCoords(from: event)
            let dx = Int16(clamping: Int(event.deltaX))
            let dy = Int16(clamping: Int(event.deltaY))
            DroidOsManager.shared.sendMouseEvent(action: .up, button: .tertiary, normalizedX: x, normalizedY: y, deltaX: dx, deltaY: dy)
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        if isGrabbed {
            let (x, y) = normalizedCoords(from: event)
            let dx = Int16(clamping: Int(event.deltaX))
            let dy = Int16(clamping: Int(event.deltaY))
            DroidOsManager.shared.sendMouseEvent(action: .move, button: .none, normalizedX: x, normalizedY: y, deltaX: dx, deltaY: dy)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        if isGrabbed {
            let (x, y) = normalizedCoords(from: event)
            let dx = Int16(clamping: Int(event.deltaX))
            let dy = Int16(clamping: Int(event.deltaY))
            DroidOsManager.shared.sendMouseEvent(action: .move, button: .primary, normalizedX: x, normalizedY: y, deltaX: dx, deltaY: dy)
        }
    }

    public override func rightMouseDragged(with event: NSEvent) {
        if isGrabbed {
            let (x, y) = normalizedCoords(from: event)
            let dx = Int16(clamping: Int(event.deltaX))
            let dy = Int16(clamping: Int(event.deltaY))
            DroidOsManager.shared.sendMouseEvent(action: .move, button: .secondary, normalizedX: x, normalizedY: y, deltaX: dx, deltaY: dy)
        }
    }

    public override func otherMouseDragged(with event: NSEvent) {
        if isGrabbed {
            let (x, y) = normalizedCoords(from: event)
            let dx = Int16(clamping: Int(event.deltaX))
            let dy = Int16(clamping: Int(event.deltaY))
            DroidOsManager.shared.sendMouseEvent(action: .move, button: .tertiary, normalizedX: x, normalizedY: y, deltaX: dx, deltaY: dy)
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        if isGrabbed {
            let (x, y) = normalizedCoords(from: event)
            let scrollDelta = Int16(clamping: Int(event.scrollingDeltaY * 10))
            let dx = Int16(clamping: Int(event.deltaX))
            let dy = Int16(clamping: Int(event.deltaY))
            DroidOsManager.shared.sendMouseEvent(action: .scroll, button: .none, scrollDeltaY: scrollDelta, normalizedX: x, normalizedY: y, deltaX: dx, deltaY: dy)
        }
    }

    // MARK: - Keyboard & Emergency Exit Interception

    public override func flagsChanged(with event: NSEvent) {
        // Emergency Exit Check: Control + Command pressed together
        let flags = event.modifierFlags
        if flags.contains(.control) && flags.contains(.command) {
            releaseInput()
            return
        }

        if isGrabbed {
            let androidCode = MacToAndroidKeyMap.androidKeyCode(from: event.keyCode)
            let mods = MacToAndroidKeyMap.modifiers(from: flags)
            let codepoint = MacToAndroidKeyMap.unicodeCodepoint(from: event)
            DroidOsManager.shared.sendKeyboardEvent(action: .down, modifiers: mods, androidKeyCode: androidCode, unicodeCodepoint: codepoint)
        }
    }

    public override func keyDown(with event: NSEvent) {
        // Emergency Exit Check: Control + Command
        let flags = event.modifierFlags
        if flags.contains(.control) && flags.contains(.command) {
            releaseInput()
            return
        }

        if isGrabbed {
            let androidCode = MacToAndroidKeyMap.androidKeyCode(from: event.keyCode)
            let mods = MacToAndroidKeyMap.modifiers(from: flags)
            let codepoint = MacToAndroidKeyMap.unicodeCodepoint(from: event)
            DroidOsManager.shared.sendKeyboardEvent(action: .down, modifiers: mods, androidKeyCode: androidCode, unicodeCodepoint: codepoint)
        } else {
            super.keyDown(with: event)
        }
    }

    public override func keyUp(with event: NSEvent) {
        if isGrabbed {
            let androidCode = MacToAndroidKeyMap.androidKeyCode(from: event.keyCode)
            let mods = MacToAndroidKeyMap.modifiers(from: event.modifierFlags)
            let codepoint = MacToAndroidKeyMap.unicodeCodepoint(from: event)
            DroidOsManager.shared.sendKeyboardEvent(action: .up, modifiers: mods, androidKeyCode: androidCode, unicodeCodepoint: codepoint)
        } else {
            super.keyUp(with: event)
        }
    }
}
