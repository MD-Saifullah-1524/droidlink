import Foundation
import ScreenCaptureKit
import CoreGraphics
import CoreMedia
import AppKit

/// Captures display frames of the virtual monitor using Apple's modern ScreenCaptureKit framework.
final class VirtualDisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var isCapturing = false
    private let captureQueue = DispatchQueue(label: "com.droidlink.displayCapture", qos: .userInteractive)

    var onSampleBufferCaptured: (@Sendable (CMSampleBuffer) -> Void)?

    override init() {
        super.init()
    }

    deinit {
        stopCapture()
    }

    /// Starts capturing frames from the specified CGDirectDisplayID
    func startCapture(
        displayID: CGDirectDisplayID,
        width: Int32,
        height: Int32,
        fps: Int32 = 60
    ) async throws {
        stopCapture()

        // 1. Fetch shareable content to find target SCDisplay with robust retry loop
        let mainID = CGMainDisplayID()
        var targetDisplay: SCDisplay?
        let maxAttempts = 30 // 30 * 150ms = 4.5s
        for attempt in 1...maxAttempts {
            do {
                let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                // First attempt: exact displayID match
                if let display = shareableContent.displays.first(where: { $0.displayID == displayID }) {
                    targetDisplay = display
                    print("🎥 VirtualDisplayCapture: Matched exact virtual display ID \(displayID) on attempt \(attempt)")
                    break
                }
                // Second attempt: Match any non-primary display that matches requested dimensions
                if let display = shareableContent.displays.first(where: {
                    $0.displayID != mainID && (
                        ($0.width == Int(width) && $0.height == Int(height)) ||
                        ($0.width == Int(height) && $0.height == Int(width))
                    )
                }) {
                    targetDisplay = display
                    print("🎥 VirtualDisplayCapture: Matched non-primary virtual display \(display.displayID) by dimensions on attempt \(attempt)")
                    break
                }
            } catch {
                print("⚠️ VirtualDisplayCapture: Attempt \(attempt) failed: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        guard let displayToStream = targetDisplay else {
            print("❌ VirtualDisplayCapture: Target virtual display ID \(displayID) not found in SCShareableContent after \(maxAttempts) attempts. Primary display fallback strictly prevented.")
            throw NSError(
                domain: "VirtualDisplayCapture",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Virtual extended display not found in WindowServer. Primary display fallback prevented."]
            )
        }

        // Strict guard: NEVER stream the Mac's primary display for Extended Display mode
        guard displayToStream.displayID != mainID else {
            print("❌ VirtualDisplayCapture: Security violation: Attempted to stream primary Mac display (ID \(mainID)) as external extended display")
            throw NSError(
                domain: "VirtualDisplayCapture",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Attempted to capture primary screen instead of extended display."]
            )
        }

        try await startStream(for: displayToStream, width: width, height: height, fps: fps)
    }

    private func startStream(for display: SCDisplay, width: Int32, height: Int32, fps: Int32) async throws {
        // 2. Configure content filter and stream configuration
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = Int(width)
        streamConfig.height = Int(height)
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        streamConfig.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        streamConfig.queueDepth = 3 // Triple-buffering: eliminates buffer starvation while keeping latency <16ms
        streamConfig.shouldBeOpaque = true
        streamConfig.scalesToFit = true
        streamConfig.showsCursor = true // Render macOS cursor directly into video frames
        streamConfig.capturesAudio = false

        // 3. Create and start SCStream with self as delegate
        let newStream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await newStream.startCapture()

        self.stream = newStream
        self.isCapturing = true
        print("🎥 VirtualDisplayCapture: Started SCStream on display \(display.displayID) (\(width)x\(height) @ \(fps)fps, cursor=enabled)")
    }

    /// Stops display capture asynchronously ensuring resources are completely released
    func stopCaptureAsync() async {
        guard isCapturing, let stream = stream else { return }
        self.stream = nil
        self.isCapturing = false
        do {
            try await stream.stopCapture()
            print("🎥 VirtualDisplayCapture: Stopped cleanly via async")
        } catch {
            print("⚠️ VirtualDisplayCapture: Stop capture returned: \(error)")
        }
    }

    /// Synchronous stop for deinit / teardown
    func stopCapture() {
        guard isCapturing, let stream = stream else { return }
        self.stream = nil
        self.isCapturing = false
        stream.stopCapture { error in
            if let error = error {
                print("⚠️ VirtualDisplayCapture: Stop capture returned: \(error)")
            }
        }
        print("🎥 VirtualDisplayCapture: Stopped")
    }

    // MARK: - SCStreamOutput
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        onSampleBufferCaptured?(sampleBuffer)
    }

    // MARK: - SCStreamDelegate
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("⚠️ VirtualDisplayCapture: SCStream stopped with error: \(error.localizedDescription)")
    }
}
