import SwiftUI
import AppKit

struct SettingsDetailView: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject private var fileProviderManager = FileProviderDomainManager.shared
    var onNavigate: ((SidebarSection) -> Void)? = nil
    @State private var myDeviceId: String = ""
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings")
                        .font(.system(size: 22, weight: .bold))
                    Text("Network connection, security diagnostics, and system preferences")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Divider()
                
                // Section: Feature Configuration Navigation Notes
                VStack(alignment: .leading, spacing: 10) {
                    Label("Feature Management", systemImage: "slider.horizontal.3")
                        .font(.headline)
                    
                    NativeCard {
                        VStack(spacing: 0) {
                            Button {
                                onNavigate?(.notifications)
                            } label: {
                                HStack(spacing: 12) {
                                    SquircleIcon(
                                        icon: "bell.badge.fill",
                                        gradient: LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                                        size: 34,
                                        iconSize: 17
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Notifications")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Color.primary)
                                        Text("Configure incoming mirrored alerts, sound, and Mac app sync filters")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.forward")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            
                            Divider()
                                .padding(.vertical, 4)
                            
                            Button {
                                onNavigate?(.clipboard)
                            } label: {
                                HStack(spacing: 12) {
                                    SquircleIcon(
                                        icon: "doc.on.clipboard.fill",
                                        gradient: LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing),
                                        size: 34,
                                        iconSize: 17
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Universal Clipboard")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Color.primary)
                                        Text("Configure Incognito privacy pause, sensitive clip filtering, and direct push")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.forward")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Section: macOS Finder File Provider Integration
                VStack(alignment: .leading, spacing: 10) {
                    Label("macOS Finder Storage", systemImage: "folder.badge.gearshape")
                        .font(.headline)
                    
                    NativeCard {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                SquircleIcon(
                                    icon: "folder.fill",
                                    gradient: LinearGradient(colors: [.blue, .teal], startPoint: .topLeading, endPoint: .bottomTrailing),
                                    size: 34,
                                    iconSize: 17
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Mount in Finder Sidebar")
                                        .font(.system(size: 13, weight: .semibold))
                                    Text("Browse Android /storage/emulated/0 directly inside Finder on demand")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { fileProviderManager.isMounted },
                                    set: { shouldMount in
                                        Task {
                                            let paired = PairingStorage.loadPairedDevice()
                                            let deviceId = paired?.deviceId ?? "default"
                                            let deviceName = paired?.deviceName ?? "Android"
                                            do {
                                                if shouldMount {
                                                    try await fileProviderManager.registerDomain(
                                                        deviceId: deviceId,
                                                        deviceName: deviceName
                                                    )
                                                } else {
                                                    try await fileProviderManager.unregisterDomain(
                                                        deviceId: deviceId
                                                    )
                                                }
                                            } catch {
                                                print("❌ Mount toggle error: \(error)")
                                            }
                                        }
                                    }
                                ))
                                .toggleStyle(.switch)
                            }
                            
                            if let error = fileProviderManager.lastErrorMessage {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.red)
                                        .font(.caption)
                                    Text(error)
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                            }
                            
                            if fileProviderManager.isMounted {
                                Divider()
                                HStack {
                                    Button {
                                        Task {
                                            let paired = PairingStorage.loadPairedDevice()
                                            let deviceId = paired?.deviceId ?? "default"
                                            let deviceName = paired?.deviceName ?? "Android"
                                            try? await fileProviderManager.rebuildDomain(deviceId: deviceId, deviceName: deviceName)
                                        }
                                    } label: {
                                        Label("Re-sync Storage", systemImage: "arrow.triangle.2.circlepath")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Button {
                                        Task {
                                            let paired = PairingStorage.loadPairedDevice()
                                            let deviceId = paired?.deviceId ?? "default"
                                            await fileProviderManager.revealInFinder(deviceId: deviceId)
                                        }
                                    } label: {
                                        Label("Open in Finder", systemImage: "arrow.up.forward.app")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    
                                    Spacer()
                                    
                                    Text("On-demand streaming • 64-bit chunking")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                
                // Section: General & Startup
                VStack(alignment: .leading, spacing: 10) {
                    Label("General & Startup", systemImage: "laptopcomputer")
                        .font(.headline)
                    
                    NativeCard {
                        Toggle(isOn: Binding(
                            get: { viewModel.isLaunchAtLoginEnabled },
                            set: { viewModel.setLaunchAtLogin(enabled: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Launch at Login")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Automatically start DroidLink when you log into your Mac")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }
                
                // Section: Network & Transport
                VStack(alignment: .leading, spacing: 10) {
                    Label("Connection & Transport", systemImage: "network")
                        .font(.headline)
                    
                    NativeCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Host IP Address")
                                    .font(.subheadline)
                                Spacer()
                                Text(viewModel.hostIP)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            
                            Divider()
                            
                            HStack {
                                Text("TCP Listening Port")
                                    .font(.subheadline)
                                Spacer()
                                Text(viewModel.listeningPort > 0 ? "\(viewModel.listeningPort)" : "Dynamic")
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            
                            Divider()
                            
                            HStack {
                                Text("Transport Encryption")
                                    .font(.subheadline)
                                Spacer()
                                Text("AES-256-GCM (Authenticated)")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.green)
                            }
                            
                            Divider()
                            
                            HStack {
                                Text("Connection Status")
                                    .font(.subheadline)
                                Spacer()
                                switch viewModel.state {
                                case .connected(let name, _):
                                    Text("Connected to \(name)")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.green)
                                case .waitingForPairedDevice:
                                    Text("Listening for paired phone")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.orange)
                                case .pairing:
                                    Text("Pairing mode (QR active)")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.blue)
                                case .connecting:
                                    Text("Connecting...")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.purple)
                                case .disconnected:
                                    Text("Disconnected")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                
                // Section: Pairing & Cryptographic Keys
                VStack(alignment: .leading, spacing: 10) {
                    Label("Pairing & Key Storage", systemImage: "lock.shield")
                        .font(.headline)
                    
                    NativeCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Device Identifier")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text(myDeviceId.isEmpty ? PairingStorage.getOrCreateMyDeviceId() : myDeviceId)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            
                            Divider()
                            
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Reset Pairing & Session Keys")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("Clears stored cryptographic key and unpairs current phone.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Reset Keys", role: .destructive) {
                                    viewModel.unpairDevice()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                
                // Section: About DroidLink
                VStack(alignment: .leading, spacing: 10) {
                    Label("About DroidLink", systemImage: "info.circle")
                        .font(.headline)
                    
                    NativeCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("DroidLink for macOS")
                                    .font(.headline)
                                Spacer()
                                Text("v1.1 (Native HIG)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Text("An open-source, local-first Android ↔ macOS bridge. No cloud servers, no account registration, and zero data tracking.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            Divider()
                            
                            HStack {
                                Text("License")
                                    .font(.caption)
                                Spacer()
                                Text("Apache 2.0 Open Source")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Divider()
                            
                            HStack {
                                Text("Architecture")
                                    .font(.caption)
                                Spacer()
                                Text("Local-First P2P (Wi-Fi / USB)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .onAppear {
            myDeviceId = PairingStorage.getOrCreateMyDeviceId()
        }
    }
}
