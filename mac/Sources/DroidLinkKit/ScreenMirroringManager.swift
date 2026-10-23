import Foundation
import SwiftUI
import Combine

/// Central coordinator for Screen Mirroring, App Drawer, Remote Interaction, and Bi-directional Audio.
@MainActor
final class ScreenMirroringManager: ObservableObject {
    static let shared = ScreenMirroringManager()

    @Published var isMirroringActive: Bool = false
    @Published var installedApps: [Droidlink_Protocol_AppInfo] = []
    @Published var isLoadingApps: Bool = false
    @Published var currentApp: Droidlink_Protocol_AppInfo? = nil

    @Published var screenWidth: Int32 = 1080
    @Published var screenHeight: Int32 = 2400
    @Published var rotation: Int32 = 0
    @Published var dpi: Int32 = 420
    @Published var fps: Double = 0.0
    @Published var errorMessage: String? = nil

    @Published var isDeviceAudioMuted: Bool = false
    @Published var isMicMuted: Bool = true
    @Published var micLevel: Float = 0.0
    @Published var rotationMode: Droidlink_Protocol_RotateRequest.RotationMode = .rotationPortrait
    @Published var isPrivacyModeActive: Bool = false

    let audioEngine = ScreenAudioEngine()

    var onSendScreenMessage: ((Droidlink_Protocol_ScreenMessage) -> Void)?
    var onVideoFrameReceived: ((Data, Bool, Int32) -> Void)?
    var onRequestOpenMirrorWindow: (() -> Void)?

    private var frameCounter: Int = 0
    private var lastFpsCalculationTime: TimeInterval = Date().timeIntervalSince1970
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Forward audio engine state
        audioEngine.$isDeviceAudioMuted
            .assign(to: \.isDeviceAudioMuted, on: self)
            .store(in: &cancellables)

        audioEngine.$isMicMuted
            .assign(to: \.isMicMuted, on: self)
            .store(in: &cancellables)

        audioEngine.$micLevel
            .assign(to: \.micLevel, on: self)
            .store(in: &cancellables)

        // Stream Mac mic data to Android
        audioEngine.onMicAudioCaptured = { [weak self] pcmData, sampleRate, channels in
            guard let self = self, self.isMirroringActive else { return }
            var micFrame = Droidlink_Protocol_MicAudioFrame()
            micFrame.audioData = pcmData
            micFrame.sampleRate = sampleRate
            micFrame.channels = channels
            micFrame.timestamp = Int64(Date().timeIntervalSince1970 * 1000)

            var msg = Droidlink_Protocol_ScreenMessage()
            msg.event = .micData
            msg.micFrame = micFrame
            self.onSendScreenMessage?(msg)
        }
    }

    // MARK: - App Drawer & Launching

    func requestInstalledApps(force: Bool = false) {
        if !force && isLoadingApps { return }
        isLoadingApps = true
        errorMessage = nil

        var msg = Droidlink_Protocol_ScreenMessage()
        msg.event = .listAppsRequest
        onSendScreenMessage?(msg)
        print("📱 Requested installed apps from Android")

        // 8-second timeout fallback to prevent permanent spinner
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self = self else { return }
            if self.isLoadingApps && self.installedApps.isEmpty {
                self.isLoadingApps = false
                self.errorMessage = "Timed out fetching apps. Click Retry to load apps."
                print("⚠️ Timeout fetching apps from Android")
            }
        }
    }

    func onTcpConnected() {
        print("⚡ ScreenMirroringManager: TCP connected, refreshing app list...")
        if installedApps.isEmpty {
            requestInstalledApps(force: true)
        }
    }

    func launchApp(_ app: Droidlink_Protocol_AppInfo) {
        self.currentApp = app
        self.isMirroringActive = true
        self.errorMessage = nil
        self.frameCounter = 0
        self.lastFpsCalculationTime = Date().timeIntervalSince1970

        var req = Droidlink_Protocol_LaunchAppRequest()
        req.packageName = app.packageName

        var msg = Droidlink_Protocol_ScreenMessage()
        msg.event = .launchAppRequest
        msg.launchAppRequest = req
        onSendScreenMessage?(msg)

        audioEngine.startPlayback()
        audioEngine.startMicCapture()
        onRequestOpenMirrorWindow?()
        print("🚀 Requested launch of app: \(app.appName) (\(app.packageName))")
    }

    // MARK: - Mirroring Session Lifecycle

    func startMirroring(app: Droidlink_Protocol_AppInfo? = nil) {
        self.currentApp = app
        self.isMirroringActive = true
        self.errorMessage = nil
        self.frameCounter = 0
        self.lastFpsCalculationTime = Date().timeIntervalSince1970

        var config = Droidlink_Protocol_StreamConfig()
        if rotationMode == .rotationLandscape {
            config.width = 2400
            config.height = 1080
        } else {
            config.width = 1080
            config.height = 2400
        }
        config.fps = 60
        config.bitrate = 8000 // 8 Mbps for smooth real-time stream over Wi-Fi
        config.codec = .h264
        config.enableAudio = true
        config.enableMic = true

        var msg = Droidlink_Protocol_ScreenMessage()
        msg.event = .startRequest
        msg.config = config
        onSendScreenMessage?(msg)

        audioEngine.startPlayback()
        audioEngine.startMicCapture()

        onRequestOpenMirrorWindow?()
        print("▶️ Screen mirroring started for \(app?.appName ?? "Phone Screen") at 8 Mbps")
    }

    func stopMirroring(notifyRemote: Bool = true) {
        guard isMirroringActive else { return }
        isMirroringActive = false
        currentApp = nil
        isPrivacyModeActive = false

        if notifyRemote {
            var msg = Droidlink_Protocol_ScreenMessage()
            msg.event = .stop
            onSendScreenMessage?(msg)
        }

        audioEngine.stopPlayback()
        audioEngine.stopMicCapture()
        print("⏹️ Screen mirroring stopped")
    }

    // MARK: - Remote Navigation & Input

    func sendNav(action: Droidlink_Protocol_NavigationEvent.NavAction) {
        var nav = Droidlink_Protocol_NavigationEvent()
        nav.action = action

        var msg = Droidlink_Protocol_ScreenMessage()
        msg.event = .navEvent
        msg.navEvent = nav
        onSendScreenMessage?(msg)
    }

    func sendTouch(
        normX: Float,
        normY: Float,
        action: Droidlink_Protocol_TouchEvent.TouchAction,
        scrollDx: Float = 0,
        scrollDy: Float = 0,
        pointerId: Int32 = 0
    ) {
        var touch = Droidlink_Protocol_TouchEvent()
        touch.action = action
        touch.x = normX
        touch.y = normY
        touch.scrollDx = scrollDx
        touch.scrollDy = scrollDy
        touch.pointerID = pointerId

        var msg = Droidlink_Protocol_ScreenMessage()
        msg.event = .touchEvent
        msg.touchEvent = touch
        onSendScreenMessage?(msg)
    }

    func sendKey(text: String, keyCode: Int32 = 0, metaState: Int32 = 0) {
        var key = Droidlink_Protocol_KeyEvent()
        key.action = text.isEmpty ? .keyDown : .textInput
        key.keyCode = keyCode
        key.text = text
        key.metaState = metaState

        var msg = Droidlink_Protocol_ScreenMessage()
        msg.event = .keyEvent
        msg.keyEvent = key
        onSendScreenMessage?(msg)
    }

    func rotate() {
        let nextMode: Droidlink_Protocol_RotateRequest.RotationMode = (rotationMode == .rotationPortrait) ? .rotationLandscape : .rotationPortrait
        sendRotate(mode: nextMode)
    }

    func sendRotate(mode: Droidlink_Protocol_RotateRequest.RotationMode) {
        rotationMode = mode
        var req = Droidlink_Protocol_RotateRequest()
        req.mode = mode

        var msg = Droidlink_Protocol_ScreenMessage()
        msg.event = .rotateRequest
        msg.rotateRequest = req
        onSendScreenMessage?(msg)
        print("🔄 Sent RotateRequest mode=\(mode)")
    }

    func togglePrivacyMode() {
        isPrivacyModeActive.toggle()
        sendNav(action: .power)
        print("🌙 Toggled Privacy Mode: \(isPrivacyModeActive)")
    }

    func toggleDeviceAudio() {
        audioEngine.isDeviceAudioMuted.toggle()
    }

    func toggleMic() {
        audioEngine.isMicMuted.toggle()
        var ctrl = Droidlink_Protocol_MicControl()
        ctrl.isMuted = audioEngine.isMicMuted
        ctrl.isRecording = !audioEngine.isMicMuted

        var msg = Droidlink_Protocol_ScreenMessage()
        msg.event = .micControl
        msg.micControl = ctrl
        onSendScreenMessage?(msg)
    }

    // MARK: - Inbound Message Dispatcher

    func handleScreenMessage(_ msg: Droidlink_Protocol_ScreenMessage) {
        switch msg.event {
        case .listAppsResponse:
            self.isLoadingApps = false
            self.installedApps = msg.listAppsResponse.apps
            print("📱 Received \(msg.listAppsResponse.apps.count) installed apps from Android")

        case .launchAppResponse:
            if !msg.launchAppResponse.success {
                self.errorMessage = msg.launchAppResponse.errorMessage.isEmpty ?
                    "Failed to launch app" : msg.launchAppResponse.errorMessage
            }

        case .screenInfo:
            let info = msg.screenInfo
            self.screenWidth = info.width
            self.screenHeight = info.height
            self.rotation = info.rotation
            self.dpi = info.dpi
            print("📱 Updated Android screen info: \(info.width)x\(info.height), rot=\(info.rotation)°")
            fflush(stdout)
            if !isMirroringActive {
                self.isMirroringActive = true
                self.audioEngine.startPlayback()
                self.audioEngine.startMicCapture()
            }
            print("📱 Calling onRequestOpenMirrorWindow?()...")
            fflush(stdout)
            self.onRequestOpenMirrorWindow?()

        case .frame:
            if !isMirroringActive {
                self.isMirroringActive = true
                self.audioEngine.startPlayback()
                self.audioEngine.startMicCapture()
                self.onRequestOpenMirrorWindow?()
            }
            frameCounter += 1
            let now = Date().timeIntervalSince1970
            let elapsed = now - lastFpsCalculationTime
            if elapsed >= 1.0 {
                self.fps = Double(frameCounter) / elapsed
                frameCounter = 0
                lastFpsCalculationTime = now
            }
            onVideoFrameReceived?(msg.frameData, msg.isKeyframe, msg.frameNumber)

        case .audioFrame:
            let audio = msg.audioFrame
            audioEngine.playAudioFrame(
                pcmData: audio.audioData,
                sampleRate: audio.sampleRate,
                channels: audio.channels
            )

        case .streamError:
            self.errorMessage = msg.errorMessage
            print("⚠️ Screen stream error: \(msg.errorMessage)")

        case .stop:
            print("⏹️ Received STOP for screen stream from Android")
            stopMirroring(notifyRemote: false)

        default:
            break
        }
    }
}
