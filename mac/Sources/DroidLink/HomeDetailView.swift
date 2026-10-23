import SwiftUI
import AppKit

struct HomeDetailView: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject private var fileProviderManager = FileProviderDomainManager.shared
    @ObservedObject private var aoaUsbManager = AoaUsbManager.shared
    var onNavigate: ((SidebarSection) -> Void)? = nil
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header Banner
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Device Connection")
                            .font(.system(size: 22, weight: .bold))
                        Text("Direct local Wi-Fi and Bluetooth LE bridge between Android and macOS")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    statusPill
                }
                .padding(.bottom, 4)
                
                Divider()
                
                // Main State View
                switch viewModel.state {
                case .connected(let deviceName, let deviceModel):
                    connectedSection(deviceName: deviceName, deviceModel: deviceModel)
                    
                case .waitingForPairedDevice(let deviceName, let deviceModel):
                    waitingSection(deviceName: deviceName, deviceModel: deviceModel)
                    
                case .pairing:
                    pairingSection
                    
                case .connecting:
                    connectingSection
                    
                case .disconnected:
                    disconnectedSection
                }
            }
            .padding(24)
        }
    }
    
    // MARK: - Status Pill
    
    @ViewBuilder
    private var statusPill: some View {
        switch viewModel.state {
        case .connected(let name, _):
            StatusBadge(title: "Connected: \(name)", color: .green)
        case .waitingForPairedDevice:
            StatusBadge(title: "Waiting for Phone", color: .orange)
        case .pairing:
            StatusBadge(title: "Pairing Mode", color: .blue)
        case .connecting:
            StatusBadge(title: "Connecting...", color: .purple)
        case .disconnected:
            StatusBadge(title: "Disconnected", color: .secondary)
        }
    }
    
    // MARK: - Connected Section
    
    private func connectedSection(deviceName: String, deviceModel: String) -> some View {
        let effectiveModel = (viewModel.remoteDeviceStatus?.deviceModel.isEmpty == false ? viewModel.remoteDeviceStatus?.deviceModel : (!deviceModel.isEmpty ? deviceModel : "Android Device")) ?? "Android Device"
        let status = viewModel.remoteDeviceStatus
        
        return VStack(alignment: .leading, spacing: 20) {
            // 1. Paired Device Header Card with Name & Model
            NativeCard {
                HStack(spacing: 16) {
                    SquircleIcon(
                        icon: "smartphone",
                        gradient: LinearGradient(colors: [.green, .teal], startPoint: .topLeading, endPoint: .bottomTrailing),
                        size: 48,
                        iconSize: 24
                    )
                    
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(deviceName)
                                .font(.system(size: 18, weight: .bold))
                            
                            Text("ACTIVE")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        
                        Text(effectiveModel)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        
                        Text("Connected via Bluetooth LE • DroidLink GATT • AES-256-GCM")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    
                    Spacer()
                    
                    Button("Disconnect") {
                        viewModel.disconnect()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
            
            // 2. Telemetry Cards: Battery, Network/Wi-Fi, Cellular & SIM
            VStack(alignment: .leading, spacing: 10) {
                Label("Device Telemetry & Status", systemImage: "gauge.with.needle")
                    .font(.headline)
                
                HStack(spacing: 12) {
                    // Battery Card
                    NativeCard {
                        let batteryLevel = status?.batteryLevel ?? -1
                        let isCharging = status?.isCharging ?? false
                        let powerSource = status?.powerSource ?? "Battery"
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: batteryIcon(level: batteryLevel, isCharging: isCharging))
                                    .font(.system(size: 16))
                                    .foregroundStyle(batteryColor(level: batteryLevel, isCharging: isCharging))
                                Text("Battery")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if isCharging {
                                    Text("CHARGING")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.green)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.green.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                            }
                            
                            Text(batteryLevel >= 0 ? "\(batteryLevel)%" : "Unknown")
                                .font(.system(size: 18, weight: .bold))
                            
                            Text(isCharging ? "Charging (\(powerSource))" : (batteryLevel >= 0 ? "On Battery" : "Awaiting status"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    // Wi-Fi Network Card
                    NativeCard {
                        let wifiSsid = status?.wifiSsid ?? ""
                        let wifiSignalLevel = status?.wifiSignalLevel ?? 0
                        let wifiRssi = status?.wifiRssi ?? 0
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "wifi")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.blue)
                                Text("Wi-Fi Network")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                SignalBarsView(level: wifiSignalLevel, activeColor: .blue)
                            }
                            
                            Text(wifiSsid.isEmpty ? (wifiSignalLevel > 0 ? "Connected" : "Not Connected") : wifiSsid)
                                .font(.system(size: 15, weight: .bold))
                                .lineLimit(1)
                            
                            Text(wifiRssi != 0 ? "\(wifiRssi) dBm (\(wifiSignalLevel)/4 bars)" : (wifiSignalLevel > 0 ? "\(wifiSignalLevel)/4 bars" : "Wi-Fi link inactive"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    // Cellular & SIM Card
                    NativeCard {
                        let carrier = status?.carrierName ?? ""
                        let netType = status?.cellularNetworkType ?? ""
                        let cellLevel = status?.cellularSignalLevel ?? 0
                        let simName = status?.simDisplayName ?? ""
                        let hasCell = status?.hasCellular ?? false
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.purple)
                                Text("Cellular & SIM")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                SignalBarsView(level: cellLevel, activeColor: .purple)
                            }
                            
                            Text(carrier.isEmpty ? (hasCell ? "Cellular" : "No SIM / Service") : "\(carrier)\(netType.isEmpty ? "" : " " + netType)")
                                .font(.system(size: 15, weight: .bold))
                                .lineLimit(1)
                            
                            Text(simName.isEmpty ? (cellLevel > 0 ? "\(cellLevel)/4 bars strength" : "SIM slot inactive") : "\(simName) • \(cellLevel)/4 bars")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            
            // 3. Bridge Modules with Direct Toggles
            VStack(alignment: .leading, spacing: 10) {
                Label("Bridge Modules", systemImage: "square.grid.2x2")
                    .font(.headline)
                
                NativeCard {
                    VStack(spacing: 0) {
                        // Universal Clipboard Module
                        HStack(spacing: 14) {
                            SquircleIcon(
                                icon: "paperclip",
                                gradient: LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing),
                                size: 36,
                                iconSize: 18
                            )
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Universal Clipboard")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(viewModel.isClipboardSyncEnabled ? (viewModel.isIncognitoMode ? "Paused (Incognito Mode Active)" : "Active Real-Time Clipboard Sync") : "Module Disabled")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            
                            Toggle("", isOn: $viewModel.isClipboardSyncEnabled)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                            
                            Button {
                                onNavigate?(.clipboard)
                            } label: {
                                Image(systemName: "chevron.forward")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 4)
                        }
                        .padding(.vertical, 8)
                        
                        Divider()
                            .padding(.vertical, 4)
                        
                        // Notification Mirroring Module
                        HStack(spacing: 14) {
                            SquircleIcon(
                                icon: "bell.badge.fill",
                                gradient: LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                                size: 36,
                                iconSize: 18
                            )
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Notification Sync")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(viewModel.isNotificationMirroringEnabled ? "Delivering Android alerts natively to Mac" : "Module Disabled")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            
                            Toggle("", isOn: $viewModel.isNotificationMirroringEnabled)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                            
                            Button {
                                onNavigate?(.notifications)
                            } label: {
                                Image(systemName: "chevron.forward")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 4)
                        }
                        .padding(.vertical, 8)
                        
                        Divider()
                            .padding(.vertical, 4)
                        
                        // Android Storage in Finder Module
                        HStack(spacing: 14) {
                            SquircleIcon(
                                icon: "folder.fill",
                                gradient: LinearGradient(colors: [.blue, .teal], startPoint: .topLeading, endPoint: .bottomTrailing),
                                size: 36,
                                iconSize: 18
                            )
                            
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Android Storage in Finder")
                                        .font(.system(size: 13, weight: .semibold))
                                    if fileProviderManager.isMounted {
                                        StatusBadge(title: "Mounted", color: .green, icon: "checkmark")
                                    }
                                    if aoaUsbManager.isConnected {
                                        StatusBadge(title: "⚡ Supercharged USB", color: .blue)
                                    }
                                }
                                Text(fileProviderManager.isMounted ? "Browse /storage/emulated/0 in Finder sidebar" : "On-demand read/write access to Android files")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            
                            if fileProviderManager.isMounted {
                                Button("Open") {
                                    Task {
                                        let paired = PairingStorage.loadPairedDevice()
                                        let deviceId = paired?.deviceId ?? "default"
                                        await fileProviderManager.revealInFinder(deviceId: deviceId)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            
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
                            .controlSize(.small)
                        }
                        .padding(.vertical, 8)
                        
                        Divider()
                            .padding(.vertical, 4)
                        
                        // Screen Mirroring Module
                        HStack(spacing: 14) {
                            SquircleIcon(
                                icon: "iphone",
                                gradient: LinearGradient(colors: [.teal, .mint], startPoint: .topLeading, endPoint: .bottomTrailing),
                                size: 36,
                                iconSize: 18
                            )
                            
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Phone Screen & Control")
                                        .font(.system(size: 13, weight: .semibold))
                                    if ScreenMirroringManager.shared.isMirroringActive {
                                        StatusBadge(title: "Active", color: .green)
                                    } else if aoaUsbManager.isConnected {
                                        StatusBadge(title: "⚡ USB HID Ready", color: .blue)
                                    }
                                }
                                Text(ScreenMirroringManager.shared.isMirroringActive ?
                                     "Streaming live Android screen with hardware USB HID" :
                                     (aoaUsbManager.isConnected ? "Hardware AOA 2.0 USB mouse & keyboard control ready" : "Reverse display & control over Wi-Fi/USB"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            
                            if ScreenMirroringManager.shared.isMirroringActive {
                                Button("Stop") {
                                    ScreenMirroringManager.shared.stopMirroring()
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                                .controlSize(.small)
                            } else {
                                Button("Start") {
                                    ScreenMirroringManager.shared.startMirroring()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }

                            Button {
                                onNavigate?(.screenMirror)
                            } label: {
                                Image(systemName: "chevron.forward")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 4)
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            
            // 4. Disconnect & Forget Device Actions
            Divider()
                .padding(.top, 4)
            
            HStack(spacing: 16) {
                Button("Disconnect Device") {
                    viewModel.disconnect()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Forget Device", role: .destructive) {
                    viewModel.unpairDevice()
                }
                .buttonStyle(.bordered)
            }
        }
    }
    
    // MARK: - Waiting Section
    
    private func waitingSection(deviceName: String, deviceModel: String) -> some View {
        let displayModel = !deviceModel.isEmpty ? deviceModel : "Paired Android Device"
        
        return VStack(spacing: 20) {
            NativeCard {
                VStack(spacing: 18) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)
                    
                    VStack(spacing: 6) {
                        Text("Waiting for \(deviceName)")
                            .font(.system(size: 18, weight: .bold))
                        Text(displayModel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Broadcasting DroidLink BLE Service.\nOpen DroidLink on your Android phone to reconnect automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    
                    HStack(spacing: 14) {
                        Button("Forget Device", role: .destructive) {
                            viewModel.unpairDevice()
                        }
                        .buttonStyle(.bordered)
                        
                        Button("Pair Different Device") {
                            viewModel.unpairDevice()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
    }
    
    // MARK: - Pairing Section
    
    private var pairingSection: some View {
        VStack(spacing: 20) {
            NativeCard {
                VStack(spacing: 18) {
                    BluetoothPairingView(
                        deviceName: Host.current().localizedName ?? "Mac",
                        isAdvertising: true
                    )
                    
                    Button("Cancel") {
                        viewModel.cancelPairing()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            
            // When unpaired / pairing: show Necessary Permissions checklist below
            necessaryPermissionsSection
        }
    }
    
    // MARK: - Connecting Section
    
    private var connectingSection: some View {
        NativeCard {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.regular)
                Text("Connecting to device...")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        }
    }
    
    // MARK: - Disconnected Section
    
    private var disconnectedSection: some View {
        VStack(spacing: 20) {
            if let paired = PairingStorage.loadPairedDevice() {
                // Paired but Manually Disconnected Card
                NativeCard {
                    VStack(spacing: 18) {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        
                        VStack(spacing: 6) {
                            Text("Disconnected from \(paired.deviceName)")
                                .font(.system(size: 18, weight: .bold))
                            Text(paired.deviceModel ?? "Android Device")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("The connection was manually disconnected. Click Connect to re-establish the connection over local Wi-Fi and Bluetooth.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 440)
                        }
                        
                        HStack(spacing: 12) {
                            Button("Connect") {
                                viewModel.reconnect()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            
                            Button("Forget Device", role: .destructive) {
                                viewModel.unpairDevice()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                // No Paired Device Card
                NativeCard {
                    VStack(spacing: 18) {
                        Image(systemName: "macbook.and.iphone")
                            .font(.system(size: 48))
                            .foregroundStyle(.blue)
                        
                        VStack(spacing: 6) {
                            Text("No Android Device Connected")
                                .font(.system(size: 18, weight: .bold))
                            Text("Connect your Android phone to share clipboard, mirror notifications, and transfer data over local Wi-Fi.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 420)
                        }
                        
                        Button("Pair Android Device") {
                            viewModel.startPairing()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            }
            
            // Necessary Permissions checklist beneath pairing (no modules!)
            necessaryPermissionsSection
        }
    }
    
    // MARK: - Necessary Permissions Section
    
    private var necessaryPermissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Necessary Permissions", systemImage: "checkmark.shield.fill")
                .font(.headline)
            
            Text("Ensure these system permissions are enabled on your Mac to establish connections and mirror notifications.")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            VStack(spacing: 10) {
                // Bluetooth Permission
                NativeCard {
                    HStack(spacing: 14) {
                        SquircleIcon(
                            icon: "wave.3.right.circle.fill",
                            gradient: LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                            size: 36,
                            iconSize: 18
                        )
                        
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Bluetooth LE")
                                    .font(.system(size: 13, weight: .semibold))
                                if viewModel.isBluetoothEnabled {
                                    StatusBadge(title: "Granted", color: .green, icon: "checkmark")
                                } else {
                                    StatusBadge(title: "Required", color: .orange, icon: "exclamationmark.triangle")
                                }
                            }
                            Text("Used for local device discovery, secure QR pairing, and encrypted data transfer.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        if !viewModel.isBluetoothEnabled {
                            Button("Grant") {
                                viewModel.openBluetoothSettings()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
                
                // Notifications Permission
                NativeCard {
                    HStack(spacing: 14) {
                        SquircleIcon(
                            icon: "bell.badge.fill",
                            gradient: LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing),
                            size: 36,
                            iconSize: 18
                        )
                        
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("macOS Notifications")
                                    .font(.system(size: 13, weight: .semibold))
                                if viewModel.isNotificationAuthorized {
                                    StatusBadge(title: "Granted", color: .green, icon: "checkmark")
                                } else {
                                    StatusBadge(title: "Required", color: .orange, icon: "exclamationmark.triangle")
                                }
                            }
                            Text("Allows DroidLink to deliver incoming Android notifications natively to your Mac desktop.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        if !viewModel.isNotificationAuthorized {
                            Button(viewModel.notificationAuthorizationStatus == .denied ? "Open Settings" : "Grant") {
                                viewModel.requestNotificationPermission()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    private func batteryIcon(level: Int, isCharging: Bool) -> String {
        if isCharging {
            return "battery.100.bolt"
        }
        if level < 0 {
            return "battery.0"
        } else if level <= 20 {
            return "battery.25"
        } else if level <= 50 {
            return "battery.50"
        } else if level <= 75 {
            return "battery.75"
        } else {
            return "battery.100"
        }
    }
    
    private func batteryColor(level: Int, isCharging: Bool) -> Color {
        if isCharging {
            return .green
        }
        if level < 0 {
            return .secondary
        } else if level <= 20 {
            return .red
        } else if level <= 40 {
            return .orange
        } else {
            return .green
        }
    }
}

// MARK: - Signal Strength Bars Component

struct SignalBarsView: View {
    let level: Int
    let maxLevel: Int = 4
    let activeColor: Color
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...maxLevel, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar <= level ? activeColor : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: CGFloat(bar * 3 + 3))
            }
        }
    }
}
