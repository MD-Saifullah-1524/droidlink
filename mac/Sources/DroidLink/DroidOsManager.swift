import Foundation
import Combine
import AppKit

/// Central coordinator managing the droidOS Workstation session, streaming statistics, and input dispatch.
public final class DroidOsManager: ObservableObject, @unchecked Sendable {
    public static let shared = DroidOsManager()

    @Published public private(set) var isWorkstationActive: Bool = false
    @Published public private(set) var currentFps: Int = 0
    @Published public private(set) var currentBitrateKbps: Int = 0
    @Published public private(set) var tetherBytesIn: UInt64 = 0
    @Published public private(set) var tetherBytesOut: UInt64 = 0

    public var onVideoFrameReceived: ((_ isKeyframe: Bool, _ data: Data) -> Void)?

    private var frameCount: Int = 0
    private var byteCount: Int = 0
    private var statsTimer: Timer?
    private var windowController: DroidOsDisplayWindowController?
    private let stateLock = NSLock()
    private var _rawIsWorkstationActive: Bool = false

    private init() {
        setupUsbListener()
        setupTetherBridge()
    }

    private func setupUsbListener() {
        AoaUsbManager.shared.onDroidOsPacketReceived = { [weak self] type, flags, payload in
            self?.handleIncomingPacket(type: type, flags: flags, payload: payload)
        }

        NotificationCenter.default.addObserver(
            forName: .droidlinkUsbDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopSession()
        }
    }

    private func setupTetherBridge() {
        ReverseTetherBridge.shared.onOutboundIpPacket = { ipPacket in
            AoaUsbManager.shared.send(droidOsType: .reverseTether, flags: 0, payload: ipPacket)
        }
    }

    private func handleIncomingPacket(type: DroidOsProtocol.MessageType, flags: UInt8, payload: Data) {
        switch type {
        case .videoFrame:
            stateLock.lock()
            let shouldActivate = !_rawIsWorkstationActive
            if shouldActivate {
                _rawIsWorkstationActive = true
            }
            frameCount += 1
            byteCount += payload.count
            stateLock.unlock()

            if shouldActivate {
                DispatchQueue.main.async { [weak self] in
                    self?.isWorkstationActive = true
                    self?.startStatsTimer()
                }
            }
            let isKeyframe = (flags & 0x01) != 0
            DispatchQueue.main.async { [weak self] in
                self?.onVideoFrameReceived?(isKeyframe, payload)
            }

        case .reverseTether:
            ReverseTetherBridge.shared.handleIncomingIpPacket(payload)

        case .audioStream:
            break // PCM Audio sink planned for Phase 5

        case .clipboard:
            if let text = String(data: payload, encoding: .utf8) {
                DispatchQueue.main.async {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }

        default:
            break
        }
    }

    // MARK: - Workstation Session Controls

    public func launchWorkstationWindow() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.windowController == nil {
                self.windowController = DroidOsDisplayWindowController()
            }
            self.windowController?.showWindow(nil)
            self.windowController?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    public func closeWorkstationWindow() {
        DispatchQueue.main.async { [weak self] in
            self?.windowController?.close()
            self?.windowController = nil
        }
    }

    public func stopSession() {
        stateLock.lock()
        _rawIsWorkstationActive = false
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isWorkstationActive = false
            self.currentFps = 0
            self.currentBitrateKbps = 0
            self.stopStatsTimer()
            self.closeWorkstationWindow()
        }
    }

    private func startStatsTimer() {
        stopStatsTimer()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.stateLock.lock()
            let fps = self.frameCount
            let bitrate = (self.byteCount * 8) / 1000
            self.frameCount = 0
            self.byteCount = 0
            self.stateLock.unlock()

            let bytesIn = ReverseTetherBridge.shared.totalBytesReceived
            let bytesOut = ReverseTetherBridge.shared.totalBytesSent

            DispatchQueue.main.async {
                self.currentFps = fps
                self.currentBitrateKbps = bitrate
                self.tetherBytesIn = bytesIn
                self.tetherBytesOut = bytesOut
            }
        }
    }

    private func stopStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    // MARK: - Outbound Controls

    public func sendDisplayConfig(width: UInt16, height: UInt16, dpi: UInt16 = 240, fps: UInt16 = 60, bitrate: UInt32 = 12_000_000) {
        let payload = DroidOsProtocol.DisplayConfigPayload(width: width, height: height, dpi: dpi, fps: fps, bitrateBps: bitrate).serialize()
        AoaUsbManager.shared.send(droidOsType: .displayConfig, flags: 0, payload: payload)
    }

    public func sendMouseEvent(action: DroidOsProtocol.MouseAction, button: DroidOsProtocol.MouseButton, scrollDeltaY: Int16 = 0, normalizedX: UInt16, normalizedY: UInt16) {
        let payload = DroidOsProtocol.MousePayload(action: action, button: button, scrollDeltaY: scrollDeltaY, normalizedX: normalizedX, normalizedY: normalizedY).serialize()
        AoaUsbManager.shared.send(droidOsType: .mouseEvent, flags: 0, payload: payload)
    }

    public func sendKeyboardEvent(action: DroidOsProtocol.KeyAction, modifiers: DroidOsProtocol.KeyModifiers, androidKeyCode: UInt16, unicodeCodepoint: UInt32) {
        let payload = DroidOsProtocol.KeyboardPayload(action: action, modifiers: modifiers, androidKeyCode: androidKeyCode, unicodeCodepoint: unicodeCodepoint).serialize()
        AoaUsbManager.shared.send(droidOsType: .keyboardEvent, flags: 0, payload: payload)
    }
}
