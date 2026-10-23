import SwiftUI
import AppKit
import CoreGraphics
import ApplicationServices

struct ExternalDisplayDetailView: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var displayManager = ExternalDisplayManager.shared
    @ObservedObject var usbManager = AoaUsbManager.shared

    @State private var selectedResolutionIndex = 0
    @State private var selectedFps: Int32 = 60
    @State private var selectedScale: Double = 2.0 // Default 200% scaling
    @State private var enableHiDpi: Bool = true
    @State private var enableTouch: Bool = true
    @State private var performanceMode: Int = 0 // 0: Ultra-Low Latency, 1: Balanced, 2: High Quality

    @State private var hasScreenRecordingPermission: Bool = CGPreflightScreenCaptureAccess()
    @State private var hasAccessibilityPermission: Bool = AXIsProcessTrusted()

    struct ScaleOption: Hashable {
        let label: String
        let value: Double
        let description: String
    }

    private let scaleOptions: [ScaleOption] = [
        ScaleOption(label: "2.0x (200% - Recommended)", value: 2.0, description: "Default 200% Retina scaling. Crisp text and optimal tap targets."),
        ScaleOption(label: "1.75x (175%)", value: 1.75, description: "75% larger workspace. Great balance for dense phone screens."),
        ScaleOption(label: "1.5x (150%)", value: 1.5, description: "50% larger workspace. Balanced canvas for tablets."),
        ScaleOption(label: "1.25x (125%)", value: 1.25, description: "25% larger workspace. Compact high-density view."),
        ScaleOption(label: "1.0x (100% - Native Space)", value: 1.0, description: "1:1 pixel scaling. Maximum screen real estate."),
        ScaleOption(label: "2.25x (225%)", value: 2.25, description: "Large text and large controls for smaller phone displays."),
        ScaleOption(label: "2.5x (250%)", value: 2.5, description: "Maximum magnification for ultra-high-density mobile screens.")
    ]

    struct ResolutionOption {
        let label: String
        let width: Int32
        let height: Int32
        let isNative: Bool
    }

    private var resolutions: [ResolutionOption] {
        var list: [ResolutionOption] = []
        if let status = viewModel.remoteDeviceStatus,
           let w = status.screenWidth, let h = status.screenHeight,
           w > 0, h > 0 {
            let maxDim = Int32(max(w, h))
            let minDim = Int32(min(w, h))
            let devName = status.deviceModel.isEmpty ? "Connected Android Device" : status.deviceModel
            list.append(ResolutionOption(
                label: "📱 \(devName) Native (\(maxDim) × \(minDim))",
                width: maxDim,
                height: minDim,
                isNative: true
            ))
        }
        list.append(contentsOf: [
            ResolutionOption(label: "1080p Full HD (1920 × 1080)", width: 1920, height: 1080, isNative: false),
            ResolutionOption(label: "2K WQHD (2560 × 1440)", width: 2560, height: 1440, isNative: false),
            ResolutionOption(label: "Tablet Native (2560 × 1600 - 16:10)", width: 2560, height: 1600, isNative: false),
            ResolutionOption(label: "Phone Native (2400 × 1080 - 20:9)", width: 2400, height: 1080, isNative: false),
            ResolutionOption(label: "Compact (1280 × 800)", width: 1280, height: 800, isNative: false)
        ])
        return list
    }

    private var canStartDisplay: Bool {
        usbManager.isConnected && hasScreenRecordingPermission && hasAccessibilityPermission
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("External Display")
                            .font(.system(size: 24, weight: .bold))
                        Text("Turn your Android phone or tablet into an extended monitor for this Mac via USB")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    if displayManager.isDisplayActive {
                        HStack(spacing: 6) {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                            Text("ACTIVE")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.green)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                    }
                }

                Divider()

                // USB Connection Status Banner
                usbConnectionStatusBanner

                // Permissions Checklist Card
                if !hasScreenRecordingPermission || !hasAccessibilityPermission {
                    permissionsChecklistCard
                }

                if let err = displayManager.errorMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if displayManager.isDisplayActive {
                    activeSessionCard
                } else {
                    displayConfigurationCard
                }

                cleanupFailsafeCard
            }
            .padding(24)
        }
        .onAppear {
            refreshPermissions()
            autoSelectNativeResolution()
        }
        .onChange(of: viewModel.remoteDeviceStatus?.screenWidth) { _ in
            autoSelectNativeResolution()
        }
    }

    // MARK: - USB Connection Status Banner

    private var usbConnectionStatusBanner: some View {
        NativeCard {
            HStack(spacing: 14) {
                SquircleIcon(
                    icon: usbManager.isConnected ? "cable.connector.horizontal" : "cable.connector",
                    gradient: LinearGradient(
                        colors: usbManager.isConnected ? [.green, .mint] : [.orange, .red],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    size: 40,
                    iconSize: 20
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(usbManager.isConnected ? "USB Cable Connected (AOA 2.0 Direct)" : "USB Connection Required (No ADB)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(usbManager.isConnected ? Color.primary : Color.orange)

                    Text(usbManager.isConnected
                         ? "High-speed direct point-to-point connection active. Maximum framerate and minimum latency."
                         : "Connect your Android device to this Mac with a USB-C cable. Extended Display runs exclusively over USB for zero lag.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if usbManager.isConnected {
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("READY")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.1))
                    .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Permissions Checklist Card

    private var permissionsChecklistCard: some View {
        NativeCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.orange)
                    Text("Required macOS Permissions")
                        .font(.system(size: 14, weight: .bold))
                    Spacer()
                    Button("Check Permissions") {
                        refreshPermissions()
                    }
                    .font(.caption)
                }

                Divider()

                // Screen Recording Permission
                HStack(spacing: 12) {
                    Image(systemName: hasScreenRecordingPermission ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(hasScreenRecordingPermission ? .green : .red)
                        .font(.system(size: 16))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Screen Recording Permission")
                            .font(.system(size: 13, weight: .medium))
                        Text("Required for ScreenCaptureKit to capture the virtual display frames.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !hasScreenRecordingPermission {
                        Button("Open Settings") {
                            openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                }

                // Accessibility Permission
                HStack(spacing: 12) {
                    Image(systemName: hasAccessibilityPermission ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(hasAccessibilityPermission ? .green : .red)
                        .font(.system(size: 16))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility Permission (Mouse & Keyboard)")
                            .font(.system(size: 13, weight: .medium))
                        Text("Required to inject touch, mouse clicks, trackpad scrolls, and keyboard inputs from Android.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !hasAccessibilityPermission {
                        Button("Open Settings") {
                            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                            _ = AXIsProcessTrustedWithOptions(options)
                            openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    // MARK: - Active Session Card

    private var activeSessionCard: some View {
        NativeCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    SquircleIcon(
                        icon: "display.2",
                        gradient: LinearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing),
                        size: 44,
                        iconSize: 22
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Virtual Monitor Connected")
                            .font(.system(size: 16, weight: .bold))
                        if let did = displayManager.activeDisplayID {
                            Text("macOS Display ID: 0x\(String(did, radix: 16).uppercased())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button(action: {
                        displayManager.stopExternalDisplay(notifyRemote: true)
                    }) {
                        Label("Stop Display", systemImage: "stop.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.bordered)
                }

                Divider()

                HStack(spacing: 24) {
                    metricItem(title: "Physical Stream", value: "\(displayManager.activeWidth) × \(displayManager.activeHeight)")
                    metricItem(title: "UI Workspace", value: "\(displayManager.activeLogicalWidth) × \(displayManager.activeLogicalHeight) (\(String(format: "%.1fx", displayManager.activeScaleFactor)))")
                    metricItem(title: "Stream FPS", value: String(format: "%.1f FPS", displayManager.streamFps))
                    metricItem(title: "Bitrate", value: "\(displayManager.streamBitrateKbps) kbps")
                    metricItem(title: "Mouse & Keyboard", value: displayManager.isTouchInputEnabled ? "Active" : "Disabled")
                }

                Divider()

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live Display Scaling")
                            .font(.caption)
                            .fontWeight(.medium)
                        Text("Switch scale factors live without reconnecting")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Picker("Scale", selection: Binding(
                        get: { displayManager.activeScaleFactor },
                        set: { newScale in
                            displayManager.updateDisplayScale(newScale)
                        }
                    )) {
                        Text("2.5x").tag(2.5)
                        Text("2.25x").tag(2.25)
                        Text("2.0x (Default)").tag(2.0)
                        Text("1.75x").tag(1.75)
                        Text("1.5x").tag(1.5)
                        Text("1.25x").tag(1.25)
                        Text("1.0x").tag(1.0)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)
                }

                HStack {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                    Text("Drag Mac windows onto your Android screen. Trackpad moves smoothly across screens; touch, stylus, and keyboard are mapped directly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Display Arrangement...") {
                        openSystemSettings("x-apple.systempreferences:com.apple.Displays-Settings.extension")
                    }
                    .font(.caption)
                }
                .padding(10)
                .background(Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func metricItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
        }
    }

    // MARK: - Display Configuration Card

    private var displayConfigurationCard: some View {
        NativeCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Monitor Configuration")
                    .font(.system(size: 15, weight: .bold))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Display Resolution (Auto-detected from Android)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Resolution", selection: $selectedResolutionIndex) {
                        ForEach(0..<resolutions.count, id: \.self) { idx in
                            Text(resolutions[idx].label).tag(idx)
                        }
                    }
                    .pickerStyle(.menu)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("UI Display Scaling (Default: 200%)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        let res = resolutions[min(selectedResolutionIndex, max(0, resolutions.count - 1))]
                        let logW = Int(round(Double(res.width) / selectedScale))
                        let logH = Int(round(Double(res.height) / selectedScale))
                        Text("Desktop Space: \(logW) × \(logH) points")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Picker("Scaling", selection: $selectedScale) {
                        ForEach(scaleOptions, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                    .pickerStyle(.menu)

                    if let desc = scaleOptions.first(where: { $0.value == selectedScale })?.description {
                        Text(desc)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Target Refresh Rate")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("FPS", selection: $selectedFps) {
                            Text("60 FPS (Standard)").tag(Int32(60))
                            Text("120 FPS (Ultra Smooth)").tag(Int32(120))
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Display Options")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 16) {
                            Toggle("HiDPI (Retina)", isOn: $enableHiDpi)
                            Toggle("Touch & Keyboard Input", isOn: $enableTouch)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Performance & Latency Mode")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(performanceMode == 0 ? "⚡ Minimum Lag (~15-25ms)" : (performanceMode == 1 ? "⚖️ Balanced (~30-40ms)" : "🎨 Max Sharpness"))
                            .font(.caption2)
                            .foregroundStyle(performanceMode == 0 ? .green : .secondary)
                    }

                    Picker("Mode", selection: $performanceMode) {
                        Text("⚡ Ultra-Low Latency").tag(0)
                        Text("⚖️ Balanced").tag(1)
                        Text("🎨 High Quality").tag(2)
                    }
                    .pickerStyle(.segmented)
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("USB Only (No ADB)")
                            .font(.caption)
                            .fontWeight(.medium)
                        Text("Direct point-to-point hardware stream with zero Wi-Fi interference.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(action: {
                        let idx = min(selectedResolutionIndex, max(0, resolutions.count - 1))
                        let res = resolutions[idx]
                        displayManager.isTouchInputEnabled = enableTouch

                        let bitrate: Int32
                        switch performanceMode {
                        case 0: bitrate = selectedFps == 120 ? 9000 : 7000
                        case 1: bitrate = selectedFps == 120 ? 14000 : 10000
                        default: bitrate = selectedFps == 120 ? 18000 : 14000
                        }

                        displayManager.startExternalDisplay(
                            width: res.width,
                            height: res.height,
                            scaleFactor: selectedScale,
                            fps: selectedFps,
                            hiDPI: enableHiDpi,
                            bitrateKbps: bitrate
                        )
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("Start External Display")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(!canStartDisplay)
                }
            }
        }
    }

    // MARK: - Cleanup Failsafe Card

    private var cleanupFailsafeCard: some View {
        NativeCard {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Display Troubleshooting & Reset")
                        .font(.system(size: 13, weight: .bold))
                    Text("If an extended display session didn't clean up or a ghost monitor is lingering in macOS WindowServer, reset it here.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Reset Virtual Displays") {
                    displayManager.forceCleanupDisplay()
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Helper Methods

    private func refreshPermissions() {
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    private func autoSelectNativeResolution() {
        if let idx = resolutions.firstIndex(where: { $0.isNative }) {
            selectedResolutionIndex = idx
        }
    }

    private func openSystemSettings(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
