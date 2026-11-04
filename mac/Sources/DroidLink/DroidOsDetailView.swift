import SwiftUI

/// Detail screen for droidOS Workstation settings, real-time telemetry, display reconfiguration, and window launch.
struct DroidOsDetailView: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject private var aoaUsbManager = AoaUsbManager.shared
    @ObservedObject private var droidOsManager = DroidOsManager.shared
    @ObservedObject private var tetherBridge = ReverseTetherBridge.shared

    @State private var selectedProfile: AoaAccessoryProfile = AoaAccessoryProfile.current
    @State private var selectedResolutionIndex: Int = 1 // 720p default
    @State private var selectedFps: UInt16 = 60
    @State private var selectedBitrateMbps: UInt32 = 12

    struct ResolutionPreset {
        let label: String
        let width: UInt16
        let height: UInt16
        let dpi: UInt16
    }

    private let presets: [ResolutionPreset] = [
        ResolutionPreset(label: "1080p Full HD (1920 × 1080)", width: 1920, height: 1080, dpi: 240),
        ResolutionPreset(label: "720p Standard (1280 × 720)", width: 1280, height: 720, dpi: 180),
        ResolutionPreset(label: "Realme 2 Native (1520 × 720)", width: 1520, height: 720, dpi: 270),
        ResolutionPreset(label: "High Density (1600 × 900)", width: 1600, height: 900, dpi: 220)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header Banner
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("droidOS Workstation")
                            .font(.system(size: 22, weight: .bold))
                        Text("Direct Qualcomm Snapdragon desktop streaming & input bridge over USB")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusBadge
                }
                .padding(.bottom, 4)

                Divider()

                // 1. Connection & Launch Control Card
                NativeCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 16) {
                            SquircleIcon(
                                icon: "desktopcomputer",
                                gradient: LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing),
                                size: 48,
                                iconSize: 24
                            )

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(aoaUsbManager.isConnected ? (aoaUsbManager.connectedDeviceName.isEmpty ? "droidOS Device" : aoaUsbManager.connectedDeviceName) : "No USB Device Connected")
                                        .font(.system(size: 16, weight: .bold))

                                    if droidOsManager.isWorkstationActive {
                                        StatusBadge(title: "STREAMING", color: .green)
                                    } else if aoaUsbManager.isConnected {
                                        StatusBadge(title: "READY", color: .blue)
                                    }
                                }

                                Text("Direct USB (AOA 2.0) • 60 FPS Low-Latency Pipeline • Zero-ADB")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                droidOsManager.launchWorkstationWindow()
                            } label: {
                                Label("Launch Workstation", systemImage: "play.display")
                                    .fontWeight(.semibold)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                        }

                        Divider()

                        // Accessory Profile Selector
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("AOA Accessory Handshake Profile")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Selects the accessory strings sent during USB connection negotiation")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Picker("", selection: $selectedProfile) {
                                ForEach(AoaAccessoryProfile.allCases) { profile in
                                    Text(profile.rawValue).tag(profile)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 320)
                            .onChange(of: selectedProfile) { newProfile in
                                AoaAccessoryProfile.current = newProfile
                                aoaUsbManager.activeProfile = newProfile
                            }
                        }
                    }
                }

                // 2. Real-Time Telemetry Cards
                VStack(alignment: .leading, spacing: 10) {
                    Label("Workstation Telemetry", systemImage: "gauge.with.needle")
                        .font(.headline)

                    HStack(spacing: 12) {
                        // FPS
                        NativeCard {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "speedometer")
                                        .foregroundStyle(.green)
                                    Text("Display Frame Rate")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                Text("\(droidOsManager.currentFps) FPS")
                                    .font(.system(size: 20, weight: .bold))
                                Text("Target: 60 FPS Hardware")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Bitrate
                        NativeCard {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "waveform")
                                        .foregroundStyle(.blue)
                                    Text("Video Throughput")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                Text("\(String(format: "%.1f", Double(droidOsManager.currentBitrateKbps) / 1000.0)) Mbps")
                                    .font(.system(size: 20, weight: .bold))
                                Text("H.264 VideoToolbox")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Reverse Tether
                        NativeCard {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "network")
                                        .foregroundStyle(.purple)
                                    Text("Reverse Tethering")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                Text("↓ \(formatBytes(droidOsManager.tetherBytesIn))  ↑ \(formatBytes(droidOsManager.tetherBytesOut))")
                                    .font(.system(size: 15, weight: .bold))
                                    .lineLimit(1)
                                Text(tetherBridge.isEnabled ? "Active Userspace NAT" : "Disabled")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                // 3. Display Configuration
                VStack(alignment: .leading, spacing: 10) {
                    Label("Display & Resolution Settings", systemImage: "display")
                        .font(.headline)

                    NativeCard {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("Resolution Preset")
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Picker("", selection: $selectedResolutionIndex) {
                                    ForEach(0..<presets.count, id: \.self) { idx in
                                        Text(presets[idx].label).tag(idx)
                                    }
                                }
                                .frame(width: 260)
                            }

                            HStack {
                                Text("Bitrate")
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Picker("", selection: $selectedBitrateMbps) {
                                    Text("8 Mbps (Performance)").tag(UInt32(8))
                                    Text("12 Mbps (Balanced)").tag(UInt32(12))
                                    Text("16 Mbps (High Quality)").tag(UInt32(16))
                                    Text("20 Mbps (Maximum)").tag(UInt32(20))
                                }
                                .frame(width: 260)
                            }

                            Divider()

                            HStack {
                                Spacer()
                                Button("Apply Resolution") {
                                    let p = presets[selectedResolutionIndex]
                                    droidOsManager.sendDisplayConfig(
                                        width: p.width,
                                        height: p.height,
                                        dpi: p.dpi,
                                        fps: selectedFps,
                                        bitrate: selectedBitrateMbps * 1_000_000
                                    )
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }

                // 4. Reverse Tethering Options
                VStack(alignment: .leading, spacing: 10) {
                    Label("Reverse Tethering (Type 0x06)", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.headline)

                    NativeCard {
                        HStack(spacing: 14) {
                            SquircleIcon(
                                icon: "arrow.triangle.2.circlepath",
                                gradient: LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                                size: 36,
                                iconSize: 18
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Share Mac Internet Connection over USB")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Routes phone internet traffic through this Mac via userspace socket proxy without requiring root permissions")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Toggle("", isOn: $tetherBridge.isEnabled)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if droidOsManager.isWorkstationActive {
            StatusBadge(title: "Active Workstation", color: .green)
        } else if aoaUsbManager.isConnected {
            StatusBadge(title: "USB Connected", color: .blue)
        } else {
            StatusBadge(title: "Disconnected", color: .secondary)
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824.0)
        } else if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
        } else if bytes >= 1024 {
            return String(format: "%.0f KB", Double(bytes) / 1024.0)
        } else {
            return "\(bytes) B"
        }
    }
}
