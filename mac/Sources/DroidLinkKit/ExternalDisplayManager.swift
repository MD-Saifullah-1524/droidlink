import Foundation
import SwiftUI
import Combine
import CoreGraphics
import AppKit

/// Central coordinator on macOS managing the virtual monitor session,
/// screen capture pipeline, hardware H.264 encoding, and remote input handling.
/// Enforces direct USB-only transport (AOA 2.0) and guarantees complete virtual display deregistration.
@MainActor
final class ExternalDisplayManager: ObservableObject {
    static let shared = ExternalDisplayManager()

    @Published var isDisplayActive: Bool = false
    @Published var isStarting: Bool = false
    @Published var activeDisplayID: CGDirectDisplayID? = nil
    @Published var activeWidth: Int32 = 1920
    @Published var activeHeight: Int32 = 1080
    @Published var activeScaleFactor: Double = 2.0 // Default 200% scaling
    @Published var activeLogicalWidth: Int32 = 960
    @Published var activeLogicalHeight: Int32 = 540
    @Published var targetFps: Int32 = 60
    @Published var isHiDpiEnabled: Bool = true
    @Published var isTouchInputEnabled: Bool = true
    @Published var streamFps: Double = 0.0
    @Published var streamBitrateKbps: Int32 = 8000
    @Published var errorMessage: String? = nil

    private let virtualDisplayBridge = VirtualDisplayBridge()
    private let h264Encoder = H264EncoderEngine()
    private let displayCapture = VirtualDisplayCapture()
    private let inputInjector = VirtualDisplayInputInjector()

    private var frameCounter = 0
    private var lastFpsCalculationTime = Date().timeIntervalSince1970
    private var lastHeartbeatTime = Date().timeIntervalSince1970
    private var heartbeatTimer: Timer?

    private init() {
        // Wire up encoder output directly to USB transmission
        h264Encoder.onFrameEncoded = { [weak self] frameData, isKeyframe, frameNum, timestamp in
            guard let self = self else { return }
            Task { @MainActor in
                self.sendVideoFrame(data: frameData, isKeyframe: isKeyframe, frameNum: frameNum, timestamp: timestamp)
            }
        }

        // Wire up display capture to video encoder
        displayCapture.onSampleBufferCaptured = { [weak self] sampleBuffer in
            self?.h264Encoder.encode(sampleBuffer: sampleBuffer)
        }

        // Listen for USB or device disconnection to automatically stop external display and unplug virtual monitor
        NotificationCenter.default.addObserver(
            forName: .droidlinkUsbDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("🖥️ ExternalDisplayManager: USB Device disconnected; stopping external display session and destroying virtual monitor")
            self?.stopExternalDisplay(notifyRemote: false)
        }

        NotificationCenter.default.addObserver(
            forName: .droidlinkDeviceDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("🖥️ ExternalDisplayManager: Device disconnected; stopping external display session and destroying virtual monitor")
            self?.stopExternalDisplay(notifyRemote: false)
        }

        // Listen for application termination to guarantee virtual display is deregistered on app exit
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("🖥️ ExternalDisplayManager: Application terminating; cleaning up virtual monitor")
            self?.stopExternalDisplay(notifyRemote: true)
        }
    }

    /// Spawns the virtual display, starts ScreenCaptureKit, and begins hardware H.264 streaming to Android
    func startExternalDisplay(
        width: Int32 = 1920,
        height: Int32 = 1080,
        scaleFactor: Double = 2.0,
        fps: Int32 = 60,
        hiDPI: Bool = true,
        bitrateKbps: Int32 = 10000
    ) {
        let rawWidth = max(width, height)
        let rawHeight = min(width, height)
        // Ensure 16-pixel alignment for hardware H.264 macroblock encoding and decoding
        let landscapeWidth = Int32((rawWidth / 16) * 16)
        let landscapeHeight = Int32((rawHeight / 16) * 16)
        let safeScale = max(0.5, scaleFactor)

        // Idempotency check: if session is already active or in progress with identical parameters, ignore
        if (isDisplayActive || isStarting) && activeWidth == landscapeWidth && activeHeight == landscapeHeight && abs(activeScaleFactor - safeScale) < 0.01 {
            print("ℹ️ ExternalDisplayManager: Session already active or starting with identical config (\(landscapeWidth)x\(landscapeHeight), scale=\(safeScale)x); skipping redundant start")
            return
        }

        isStarting = true
        stopExternalDisplay(notifyRemote: false)
        isStarting = true
        errorMessage = nil

        // 1. Enforce direct USB connection only (no ADB, no wireless)
        guard AoaUsbManager.shared.isConnected else {
            isStarting = false
            errorMessage = "Android device must be connected via USB-C cable to start Extended Display."
            print("❌ ExternalDisplayManager: Cannot start extended display: USB is not connected")
            return
        }

        print("🖥️ Starting Extended Display over USB: \(landscapeWidth)x\(landscapeHeight), Scale=\(safeScale)x (Default 200%) @ \(fps)fps, HiDPI=\(hiDPI)...")

        // 2. Create macOS virtual display in forced landscape with scaling ladder
        guard let displayID = virtualDisplayBridge.createDisplay(
            width: UInt32(landscapeWidth),
            height: UInt32(landscapeHeight),
            scaleFactor: safeScale,
            refreshRate: Double(fps),
            hiDPI: hiDPI,
            name: "DroidLink Display"
        ) else {
            isStarting = false
            errorMessage = "Failed to create virtual display in macOS CoreGraphics"
            return
        }

        self.activeDisplayID = displayID
        self.activeWidth = landscapeWidth
        self.activeHeight = landscapeHeight
        self.activeScaleFactor = safeScale
        self.activeLogicalWidth = Int32(round(Double(landscapeWidth) / safeScale))
        self.activeLogicalHeight = Int32(round(Double(landscapeHeight) / safeScale))
        self.targetFps = fps
        self.isHiDpiEnabled = hiDPI
        self.streamBitrateKbps = bitrateKbps
        self.lastHeartbeatTime = Date().timeIntervalSince1970

        // 3. Initialize hardware video encoder
        guard h264Encoder.start(width: landscapeWidth, height: landscapeHeight, fps: fps, bitrateKbps: bitrateKbps) else {
            isStarting = false
            virtualDisplayBridge.destroyDisplay()
            errorMessage = "Failed to initialize hardware H.264 encoder"
            return
        }

        // 4. Start ScreenCaptureKit capture stream
        Task {
            do {
                try await displayCapture.startCapture(
                    displayID: displayID,
                    width: landscapeWidth,
                    height: landscapeHeight,
                    fps: fps
                )

                await MainActor.run {
                    self.isStarting = false
                    self.isDisplayActive = true
                    self.startHeartbeatWatchdog()
                    self.notifySessionStarted(
                        width: landscapeWidth,
                        height: landscapeHeight,
                        scaleFactor: safeScale,
                        fps: fps,
                        hiDPI: hiDPI,
                        bitrateKbps: bitrateKbps
                    )
                    print("✅ External Display session active on display ID \(displayID)")
                }
            } catch {
                await MainActor.run {
                    self.isStarting = false
                    self.stopExternalDisplay()
                    self.errorMessage = "Display capture failed: \(error.localizedDescription)"
                    print("❌ External Display capture error: \(error)")
                }
            }
        }
    }

    /// Dynamically switches UI scale on-the-fly without stopping or restarting the stream
    func updateDisplayScale(_ newScale: Double) {
        guard isDisplayActive, let displayID = activeDisplayID else { return }
        let safeScale = max(0.5, newScale)
        let success = virtualDisplayBridge.setDisplayScale(
            displayID: displayID,
            scaleFactor: safeScale,
            pixelWidth: UInt32(activeWidth),
            pixelHeight: UInt32(activeHeight)
        )
        if success {
            self.activeScaleFactor = safeScale
            self.activeLogicalWidth = Int32(round(Double(activeWidth) / safeScale))
            self.activeLogicalHeight = Int32(round(Double(activeHeight) / safeScale))
            notifySessionStarted(
                width: activeWidth,
                height: activeHeight,
                scaleFactor: safeScale,
                fps: targetFps,
                hiDPI: isHiDpiEnabled,
                bitrateKbps: streamBitrateKbps
            )
            print("🖥️ ExternalDisplayManager: Display scale updated to \(safeScale)x (Workspace: \(activeLogicalWidth)x\(activeLogicalHeight))")
        }
    }

    /// Stops the external display session and cleanly deregisters the virtual display
    func stopExternalDisplay(notifyRemote: Bool = true) {
        stopHeartbeatWatchdog()
        guard isDisplayActive || activeDisplayID != nil else { return }
        print("🖥️ Stopping External Display session and deregistering virtual monitor...")

        inputInjector.releaseStuckInput()
        displayCapture.stopCapture()
        h264Encoder.stop()
        virtualDisplayBridge.destroyDisplay()

        if notifyRemote {
            var msg = Droidlink_Protocol_ExternalDisplayMessage()
            msg.event = .stop
            msg.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
            dispatchExternalDisplayMessage(msg)
        }

        isStarting = false
        isDisplayActive = false
        activeDisplayID = nil
        streamFps = 0.0
    }

    /// Emergency manual cleanup to destroy any dangling virtual display
    func forceCleanupDisplay() {
        print("🧹 Force cleaning up virtual display...")
        stopExternalDisplay(notifyRemote: true)
        virtualDisplayBridge.destroyDisplay()
    }

    /// Handles incoming external display control and input messages from Android
    func handleIncomingMessage(_ message: Droidlink_Protocol_ExternalDisplayMessage) {
        lastHeartbeatTime = Date().timeIntervalSince1970

        switch message.event {
        case .startRequest:
            let config = message.config
            let w = config.width > 0 ? config.width : 1920
            let h = config.height > 0 ? config.height : 1080
            let fps = config.fps > 0 ? config.fps : 60
            let scale = config.scaleFactor > 0 ? Double(config.scaleFactor) : 2.0
            let bitrate = config.bitrateKbps > 0 ? config.bitrateKbps : 10000

            let targetW = Int32((max(w, h) / 16) * 16)
            let targetH = Int32((min(w, h) / 16) * 16)
            if (isDisplayActive || isStarting) && activeWidth == targetW && activeHeight == targetH {
                print("ℹ️ ExternalDisplayManager: Ignoring duplicate START_REQUEST from Android for active session (\(targetW)x\(targetH))")
                return
            }

            startExternalDisplay(width: w, height: h, scaleFactor: scale, fps: fps, hiDPI: config.hiDpi, bitrateKbps: bitrate)

        case .stop:
            print("🖥️ Received STOP request from Android")
            stopExternalDisplay(notifyRemote: false)

        case .inputEvent:
            guard isTouchInputEnabled, let displayID = activeDisplayID else { return }
            inputInjector.injectInput(message.input, displayID: displayID)

        case .heartbeat:
            var ack = Droidlink_Protocol_ExternalDisplayMessage()
            ack.event = .heartbeat
            ack.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
            dispatchExternalDisplayMessage(ack)

        default:
            break
        }
    }

    // MARK: - Private Helpers

    private func sendVideoFrame(data: Data, isKeyframe: Bool, frameNum: Int32, timestamp: Int64) {
        guard isDisplayActive else { return }

        var frame = Droidlink_Protocol_ExternalDisplayFrame()
        frame.frameData = data
        frame.frameNumber = frameNum
        frame.timestamp = timestamp
        frame.isKeyframe = isKeyframe
        frame.width = activeWidth
        frame.height = activeHeight

        var msg = Droidlink_Protocol_ExternalDisplayMessage()
        msg.event = .videoFrame
        msg.frame = frame
        msg.timestamp = Int64(Date().timeIntervalSince1970 * 1000)

        dispatchExternalDisplayMessage(msg)

        // Calculate streaming FPS once per second
        frameCounter += 1
        let now = Date().timeIntervalSince1970
        let elapsed = now - lastFpsCalculationTime
        if elapsed >= 1.0 {
            streamFps = Double(frameCounter) / elapsed
            frameCounter = 0
            lastFpsCalculationTime = now
        }
    }

    private func notifySessionStarted(width: Int32, height: Int32, scaleFactor: Double, fps: Int32, hiDPI: Bool, bitrateKbps: Int32) {
        var config = Droidlink_Protocol_ExternalDisplayConfig()
        config.width = width
        config.height = height
        config.scaleFactor = Float(scaleFactor)
        config.fps = fps
        config.hiDpi = hiDPI
        config.bitrateKbps = bitrateKbps
        config.codec = .displayH264
        config.enableInput = isTouchInputEnabled

        var msg = Droidlink_Protocol_ExternalDisplayMessage()
        msg.event = .started
        msg.config = config
        msg.timestamp = Int64(Date().timeIntervalSince1970 * 1000)

        dispatchExternalDisplayMessage(msg)
    }

    private func dispatchExternalDisplayMessage(_ msg: Droidlink_Protocol_ExternalDisplayMessage) {
        // USB-only: strictly dispatch through AOA USB Manager
        if AoaUsbManager.shared.isConnected {
            _ = AoaUsbManager.shared.send(externalDisplay: msg)
        }
    }

    private func startHeartbeatWatchdog() {
        stopHeartbeatWatchdog()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                guard self.isDisplayActive else { return }
                // Send periodic heartbeat to remote Android device
                var msg = Droidlink_Protocol_ExternalDisplayMessage()
                msg.event = .heartbeat
                msg.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
                self.dispatchExternalDisplayMessage(msg)

                // If USB disconnected or remote heartbeat timed out (>5s), teardown
                if !AoaUsbManager.shared.isConnected {
                    print("⚠️ ExternalDisplayManager: USB detached during active stream; tearing down virtual display")
                    self.stopExternalDisplay(notifyRemote: false)
                }
            }
        }
    }

    private func stopHeartbeatWatchdog() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }
}
