import SwiftUI
import AppKit

/// Dedicated macOS detail view for Android Screen Mirroring & Hardware Remote Control.
/// Provides direct 1-click mirroring launch, Native AOA 2.0 HID status,
/// orientation toggling, AOD privacy mode, and audio routing controls.
struct ScreenMirrorDetailView: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var manager = ScreenMirroringManager.shared
    @ObservedObject var usbManager = AoaUsbManager.shared
    @ObservedObject var hidController = AoaHidController.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // MARK: - Header
                headerSection

                Divider()

                // MARK: - Hardware Link & Transport Status Banner
                transportStatusBanner

                // MARK: - Primary Action & Mirror Window Launcher
                primaryActionCard

                // MARK: - Native AOA 2.0 HID Status Card
                hidStatusCard

                // MARK: - Display & Session Controls
                sessionControlsCard

                // MARK: - Audio & Stream Telemetry
                streamTelemetryCard
            }
            .padding(24)
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Phone Screen & Control")
                    .font(.system(size: 22, weight: .bold))

                Spacer()

                if manager.isMirroringActive {
                    StatusBadge(title: "Mirroring Active", color: .green, icon: "record.circle")
                } else {
                    StatusBadge(title: "Standby", color: .secondary)
                }

                if usbManager.isConnected {
                    StatusBadge(title: "⚡ AOA 2.0 USB", color: .blue)
                }
            }

            Text("Reverse display from Android to macOS with native hardware USB HID mouse & keyboard")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Transport Status Banner

    private var transportStatusBanner: some View {
        NativeCard {
            HStack(spacing: 14) {
                SquircleIcon(
                    icon: usbManager.isConnected ? "cable.connector.horizontal" : "wifi",
                    gradient: LinearGradient(
                        colors: usbManager.isConnected ? [.green, .teal] : [.blue, .cyan],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    size: 40,
                    iconSize: 20
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(usbManager.isConnected ? "Direct USB Connection (AOA 2.0 Mode)" : "Local Wi-Fi Network Mode")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(usbManager.isConnected ? Color.green : Color.primary)

                    Text(usbManager.isConnected ?
                         "Ultra-low latency H.264 stream over USB Bulk. Hardware HID mouse & keyboard active." :
                         "Streaming over local network. Connect a USB-C cable to unlock zero-latency wire speed and hardware HID.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if usbManager.isConnected {
                    Text("WIRE SPEED")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Primary Action Card

    private var primaryActionCard: some View {
        NativeCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Screen Mirroring Session")
                            .font(.system(size: 15, weight: .bold))
                        Text(manager.isMirroringActive ?
                             "Streaming Android screen at \(Int(manager.fps)) FPS to macOS window" :
                             "Click Start to project your Android display to Mac with full mouse, touch & keyboard control.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if manager.isMirroringActive {
                        Button(role: .destructive) {
                            manager.stopMirroring()
                        } label: {
                            Label("Stop Mirroring", systemImage: "stop.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.regular)
                    } else {
                        Button {
                            manager.startMirroring()
                        } label: {
                            Label("Start Phone Mirroring", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                }

                if manager.isMirroringActive {
                    Divider()

                    HStack(spacing: 10) {
                        Button {
                            ScreenMirroringWindowController.shared.openMirrorWindow()
                        } label: {
                            Label("Bring Mirror Window to Front", systemImage: "macwindow.on.rectangle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()

                        Text("\(manager.screenWidth) × \(manager.screenHeight) • 60 Hz")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Native AOA 2.0 HID Status Card

    private var hidStatusCard: some View {
        NativeCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Native Hardware USB HID Control", systemImage: "computermouse.fill")
                        .font(.system(size: 14, weight: .semibold))

                    Spacer()

                    if usbManager.isConnected {
                        StatusBadge(title: "Hardware Mode Active", color: .green, icon: "bolt.fill")
                    } else {
                        StatusBadge(title: "Accessibility Mode (Wi-Fi)", color: .orange)
                    }
                }

                Divider()

                HStack(spacing: 20) {
                    // Mouse Status
                    HStack(spacing: 10) {
                        Image(systemName: "cursorarrow")
                            .font(.system(size: 18))
                            .foregroundStyle(usbManager.isConnected ? Color.green : Color.secondary)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("USB Mouse")
                                .font(.system(size: 12, weight: .semibold))
                            Text(usbManager.isConnected ? "Hardware AOA 2.0 (1000Hz Report)" : "Simulated Touch over Wi-Fi")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider().frame(height: 32)

                    // Keyboard Status
                    HStack(spacing: 10) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 18))
                            .foregroundStyle(usbManager.isConnected ? Color.green : Color.secondary)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("USB Keyboard")
                                .font(.system(size: 12, weight: .semibold))
                            Text(usbManager.isConnected ? "104-Key Physical USB Matrix" : "IME Key Events over Wi-Fi")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider().frame(height: 32)

                    // Right Click Action
                    HStack(spacing: 10) {
                        Image(systemName: "hand.tap")
                            .font(.system(size: 18))
                            .foregroundStyle(.blue)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("Right Click")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Android Back Navigation")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Display & Session Controls

    private var sessionControlsCard: some View {
        NativeCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Display & Privacy Controls")
                    .font(.system(size: 14, weight: .semibold))

                Divider()

                HStack(spacing: 16) {
                    // Orientation Toggle
                    Button {
                        manager.rotate()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: manager.rotationMode == .rotationLandscape ? "rectangle.landscape" : "rectangle.portrait")
                            Text(manager.rotationMode == .rotationLandscape ? "Landscape Mode" : "Portrait Mode")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    // AOD Privacy Mode Toggle
                    Button {
                        manager.togglePrivacyMode()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: manager.isPrivacyModeActive ? "moon.stars.fill" : "moon")
                                .foregroundStyle(manager.isPrivacyModeActive ? .purple : .primary)
                            Text(manager.isPrivacyModeActive ? "Privacy Mode Active" : "Screen-Off Privacy Mode")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Spacer()

                    // Quick Navigation Buttons
                    HStack(spacing: 6) {
                        Button { manager.sendNav(action: .back) } label: {
                            Image(systemName: "chevron.backward")
                        }
                        .help("Back")

                        Button { manager.sendNav(action: .home) } label: {
                            Image(systemName: "circle")
                        }
                        .help("Home")

                        Button { manager.sendNav(action: .recents) } label: {
                            Image(systemName: "square")
                        }
                        .help("Recent Apps")

                        Button { manager.sendNav(action: .notifications) } label: {
                            Image(systemName: "bell")
                        }
                        .help("Notifications")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Stream Telemetry & Audio

    private var streamTelemetryCard: some View {
        NativeCard {
            HStack(spacing: 16) {
                // FPS Meter
                VStack(alignment: .leading, spacing: 4) {
                    Text("Framerate")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(Int(manager.fps)) FPS")
                        .font(.system(size: 16, weight: .bold))
                }

                Divider().frame(height: 28)

                // Resolution
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stream Resolution")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(manager.screenWidth) × \(manager.screenHeight)")
                        .font(.system(size: 16, weight: .bold))
                }

                Divider().frame(height: 28)

                // Bitrate
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codec & Bitrate")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("H.264 Baseline • 8 Mbps")
                        .font(.system(size: 13, weight: .semibold))
                }

                Spacer()

                // Audio Routing
                HStack(spacing: 8) {
                    Button {
                        manager.isDeviceAudioMuted.toggle()
                    } label: {
                        Image(systemName: manager.isDeviceAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(manager.isDeviceAudioMuted ? "Unmute Phone Audio" : "Mute Phone Audio")

                    Button {
                        manager.isMicMuted.toggle()
                    } label: {
                        Image(systemName: manager.isMicMuted ? "mic.slash.fill" : "mic.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(manager.isMicMuted ? "Unmute Mac Mic Stream to Phone" : "Mute Mac Mic")
                }
            }
        }
    }
}
