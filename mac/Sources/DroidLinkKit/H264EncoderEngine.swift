import Foundation
import CoreMedia
import VideoToolbox

/// High-performance hardware-accelerated H.264 video encoder engine using Apple VideoToolbox.
/// Optimized for ultra-low latency real-time screen streaming with zero B-frames.
final class H264EncoderEngine: @unchecked Sendable {
    private var compressionSession: VTCompressionSession?
    private var frameCount: Int32 = 0
    private var spsData: Data?
    private var ppsData: Data?
    private let queue = DispatchQueue(label: "com.droidlink.h264Encoder", qos: .userInteractive)

    var onFrameEncoded: (@Sendable (Data, Bool, Int32, Int64) -> Void)?

    init() {}

    deinit {
        stop()
    }

    /// Initializes and starts the hardware H.264 compression session
    func start(width: Int32, height: Int32, fps: Int32 = 60, bitrateKbps: Int32 = 10000) -> Bool {
        stop()

        var session: VTCompressionSession?
        let encoderSpecification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue as Any
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            print("❌ H264EncoderEngine: Failed to create compression session (status: \(status))")
            return false
        }

        // Configure ultra-low-latency real-time properties
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 2))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 0))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)

        let avgBitrate = NSNumber(value: bitrateKbps * 1000)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: avgBitrate)

        // Set max data rate limits
        let limits: [NSNumber] = [NSNumber(value: Int(Double(bitrateKbps * 1000) / 8.0 * 1.5)), 1]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            print("❌ H264EncoderEngine: PrepareToEncodeFrames failed (status: \(prepareStatus))")
            return false
        }

        self.compressionSession = session
        self.frameCount = 0
        print("🎬 H264EncoderEngine: Started (\(width)x\(height) @ \(fps)fps, \(bitrateKbps) kbps)")
        return true
    }

    /// Enforces hardware encoding on an incoming CMSampleBuffer
    func encode(sampleBuffer: CMSampleBuffer) {
        guard let session = compressionSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let presentationTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        var flags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTimestamp,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )

        if status != noErr {
            print("⚠️ H264EncoderEngine: Failed to encode frame (status: \(status))")
        }
    }

    /// Stops the compression session and flushes any pending frames
    func stop() {
        guard let session = compressionSession else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        compressionSession = nil
        spsData = nil
        ppsData = nil
        print("🎬 H264EncoderEngine: Stopped")
    }

    /// Internal handler processing compressed sample buffers from VideoToolbox
    fileprivate func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        // Check if keyframe
        let isKeyframe: Bool
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            isKeyframe = !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        } else {
            isKeyframe = true
        }

        // Extract format description for SPS and PPS
        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            extractParameters(from: formatDesc)
        }

        // Read encoded AVCC payload and convert to Annex B
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let blockStatus = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard blockStatus == noErr, let rawPointer = dataPointer, totalLength > 0 else { return }

        var annexBData = Data()
        let startCode = Data([0x00, 0x00, 0x00, 0x01])

        // Prepend SPS and PPS on keyframes for instant decoder startup
        if isKeyframe {
            if let sps = spsData {
                annexBData.append(startCode)
                annexBData.append(sps)
            }
            if let pps = ppsData {
                annexBData.append(startCode)
                annexBData.append(pps)
            }
        }

        // Parse AVCC length-prefixed NALUs (4-byte length headers)
        var offset: Int = 0
        while offset < totalLength - 4 {
            var naluLengthBigEndian: UInt32 = 0
            memcpy(&naluLengthBigEndian, rawPointer.advanced(by: offset), 4)
            let naluLength = Int(UInt32(bigEndian: naluLengthBigEndian))
            offset += 4

            guard offset + naluLength <= totalLength else { break }

            let naluBytes = Data(bytes: rawPointer.advanced(by: offset), count: naluLength)
            annexBData.append(startCode)
            annexBData.append(naluBytes)

            offset += naluLength
        }

        frameCount += 1
        let pts = Int64(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 1000)
        let currentFrameNum = frameCount

        onFrameEncoded?(annexBData, isKeyframe, currentFrameNum, pts)
    }

    private func extractParameters(from formatDesc: CMVideoFormatDescription) {
        var spsSize: Int = 0
        var spsCount: Int = 0
        var spsPointer: UnsafePointer<UInt8>?

        if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &spsCount,
            nalUnitHeaderLengthOut: nil
        ) == noErr, let ptr = spsPointer {
            spsData = Data(bytes: ptr, count: spsSize)
        }

        var ppsSize: Int = 0
        var ppsCount: Int = 0
        var ppsPointer: UnsafePointer<UInt8>?

        if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: &ppsCount,
            nalUnitHeaderLengthOut: nil
        ) == noErr, let ptr = ppsPointer {
            ppsData = Data(bytes: ptr, count: ppsSize)
        }
    }
}

private func compressionCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard status == noErr, let sampleBuffer = sampleBuffer, let refCon = outputCallbackRefCon else { return }
    let engine = Unmanaged<H264EncoderEngine>.fromOpaque(refCon).takeUnretainedValue()
    engine.handleEncodedSampleBuffer(sampleBuffer)
}
