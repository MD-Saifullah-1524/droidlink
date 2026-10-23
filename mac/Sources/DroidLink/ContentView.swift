import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement

// MARK: - Notification Item Model

struct MirroredNotificationItem: Identifiable, Equatable {
    let id: String
    let appName: String
    let title: String
    let text: String
    let timestamp: Date
    let iconData: Data?
}

// MARK: - Sidebar Navigation Sections

enum SidebarSection: String, CaseIterable, Identifiable {
    case home = "Home"
    case externalDisplay = "External Display"
    case screenMirror = "Phone Screen & Control"
    case apps = "Apps"
    case notifications = "Notifications"
    case clipboard = "Universal Clipboard"
    case features = "Features Roadmap"
    case settings = "Settings"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .home: return "macbook.and.iphone"
        case .externalDisplay: return "display.2"
        case .screenMirror: return "iphone"
        case .apps: return "square.grid.2x2"
        case .notifications: return "bell.badge"
        case .clipboard: return "doc.on.clipboard"
        case .features: return "sparkles"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Main ContentView with Native NavigationSplitView

@MainActor
struct ContentView: View {
    @ObservedObject var viewModel: ContentViewModel
    @State private var selectedSection: SidebarSection? = .home
    
    var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } detail: {
            detailContent
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 780, minHeight: 520)
        .onReceive(NotificationCenter.default.publisher(for: .droidlinkOpenSettings)) { _ in
            selectedSection = .settings
        }
    }
    
    // MARK: - Native Sidebar
    
    private var sidebarContent: some View {
        List(selection: $selectedSection) {
            Section("DroidLink") {
                NavigationLink(value: SidebarSection.home) {
                    Label {
                        HStack {
                            Text("Home")
                            Spacer()
                            connectionIndicator
                        }
                    } icon: {
                        Image(systemName: SidebarSection.home.icon)
                            .foregroundStyle(.blue)
                    }
                }
                
                NavigationLink(value: SidebarSection.externalDisplay) {
                    Label {
                        HStack {
                            Text("External Display")
                            Spacer()
                            if ExternalDisplayManager.shared.isDisplayActive {
                                Circle().fill(Color.green).frame(width: 8, height: 8)
                            }
                        }
                    } icon: {
                        Image(systemName: SidebarSection.externalDisplay.icon)
                            .foregroundStyle(.indigo)
                    }
                }

                NavigationLink(value: SidebarSection.screenMirror) {
                    Label {
                        HStack {
                            Text("Phone Screen & Control")
                            Spacer()
                            if ScreenMirroringManager.shared.isMirroringActive {
                                Circle().fill(Color.green).frame(width: 8, height: 8)
                            } else if AoaUsbManager.shared.isConnected {
                                Image(systemName: "bolt.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                            }
                        }
                    } icon: {
                        Image(systemName: SidebarSection.screenMirror.icon)
                            .foregroundStyle(.teal)
                    }
                }
                
                NavigationLink(value: SidebarSection.apps) {
                    Label {
                        HStack {
                            Text("Apps")
                            Spacer()
                            if !ScreenMirroringManager.shared.installedApps.isEmpty {
                                Text("\(ScreenMirroringManager.shared.installedApps.count)")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                    } icon: {
                        Image(systemName: SidebarSection.apps.icon)
                            .foregroundStyle(.orange)
                    }
                }
                
                NavigationLink(value: SidebarSection.notifications) {
                    Label {
                        HStack {
                            Text("Notifications")
                            Spacer()
                            if !viewModel.notificationHistory.isEmpty {
                                Text("\(viewModel.notificationHistory.count)")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                    } icon: {
                        Image(systemName: SidebarSection.notifications.icon)
                            .foregroundStyle(.purple)
                    }
                }
                
                NavigationLink(value: SidebarSection.clipboard) {
                    Label {
                        HStack {
                            Text("Clipboard")
                            Spacer()
                            if viewModel.isIncognitoMode {
                                Image(systemName: "eye.slash.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    } icon: {
                        Image(systemName: SidebarSection.clipboard.icon)
                            .foregroundStyle(.cyan)
                    }
                }

                
                NavigationLink(value: SidebarSection.features) {
                    Label("Roadmap", systemImage: SidebarSection.features.icon)
                }
            }
            
            Section("Preferences") {
                NavigationLink(value: SidebarSection.settings) {
                    Label("Settings", systemImage: SidebarSection.settings.icon)
                }
            }
        }
        .listStyle(.sidebar)
    }
    
    @ViewBuilder
    private var connectionIndicator: some View {
        switch viewModel.state {
        case .connected:
            Circle().fill(Color.green).frame(width: 8, height: 8)
        case .waitingForPairedDevice:
            Circle().fill(Color.orange).frame(width: 8, height: 8)
        case .pairing:
            Circle().fill(Color.blue).frame(width: 8, height: 8)
        case .connecting:
            ProgressView().controlSize(.mini)
        case .disconnected:
            Circle().fill(Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
        }
    }
    
    // MARK: - Detail Content Switcher
    
    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection ?? .home {
        case .home:
            HomeDetailView(viewModel: viewModel, onNavigate: { selectedSection = $0 })
        case .externalDisplay:
            ExternalDisplayDetailView(viewModel: viewModel)
        case .screenMirror:
            ScreenMirrorDetailView(viewModel: viewModel)
        case .apps:
            AppsDetailView(viewModel: viewModel)
        case .notifications:
            NotificationsDetailView(viewModel: viewModel)
        case .clipboard:
            ClipboardDetailView(viewModel: viewModel)
        case .features:
            FeaturesDetailView()
        case .settings:
            SettingsDetailView(viewModel: viewModel, onNavigate: { selectedSection = $0 })
        }
    }
}

// MARK: - Connection State

enum ConnectionState: Equatable {
    case disconnected
    case pairing
    case waitingForPairedDevice(name: String, model: String)
    case connecting
    case connected(name: String, model: String)
}

// MARK: - Content View Model

@MainActor
final class ContentViewModel: ObservableObject {
    @Published var state: ConnectionState = .disconnected
    @Published var qrCode: NSImage? = nil
    @Published var hostIP: String = "Detecting..."
    @Published var listeningPort: UInt16 = 29170
    @Published var isLaunchAtLoginEnabled: Bool = (SMAppService.mainApp.status == .enabled)
    @Published var lastClipboardText: String? = nil
    @Published var lastNotification: MirroredNotificationItem? = nil
    @Published var notificationHistory: [MirroredNotificationItem] = []
    @Published var clipboardHistory: [String] = []
    @Published var remoteDeviceStatus: DeviceStatusInfo? = nil
    @Published var isBluetoothEnabled: Bool = true
    @Published var isNotificationAuthorized: Bool = false
    @Published var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    private var wakeupTimer: Timer?
    private var telemetryTimer: Timer?
    private var lastSentTelemetry: DeviceStatusInfo?
    
    @Published var isClipboardSyncEnabled: Bool = PairingStorage.isClipboardSyncEnabled {
        didSet {
            PairingStorage.isClipboardSyncEnabled = isClipboardSyncEnabled
        }
    }
    
    @Published var isIncognitoMode: Bool = PairingStorage.isIncognitoMode {
        didSet {
            PairingStorage.isIncognitoMode = isIncognitoMode
            clipboardManager.isIncognitoMode = isIncognitoMode
            NotificationCenter.default.post(name: .droidlinkIncognitoChanged, object: isIncognitoMode)
        }
    }
    
    @Published var autoIgnoreSensitive: Bool = PairingStorage.autoIgnoreSensitive {
        didSet {
            PairingStorage.autoIgnoreSensitive = autoIgnoreSensitive
            clipboardManager.autoIgnoreSensitive = autoIgnoreSensitive
        }
    }
    
    @Published var isNotificationMirroringEnabled: Bool = PairingStorage.isNotificationMirroringEnabled {
        didSet {
            PairingStorage.isNotificationMirroringEnabled = isNotificationMirroringEnabled
            if isNotificationMirroringEnabled && !isNotificationAuthorized {
                requestNotificationPermission()
            }
        }
    }
    
    @Published var playNotificationSound: Bool = PairingStorage.playNotificationSound {
        didSet {
            PairingStorage.playNotificationSound = playNotificationSound
        }
    }
    
    @Published var showNotificationAppIcons: Bool = PairingStorage.showNotificationAppIcons {
        didSet {
            PairingStorage.showNotificationAppIcons = showNotificationAppIcons
        }
    }
    
    private let bleServer = BleServer()
    private let tcpServer = TcpServer()
    private let clipboardManager = ClipboardManager()
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    private var currentSessionKey: Data?
    
    init() {
        checkAndRequestNotificationPermissions()
        setupNotificationObservers()
        setupClipboardHandler()
        clipboardManager.isIncognitoMode = isIncognitoMode
        clipboardManager.autoIgnoreSensitive = autoIgnoreSensitive
        refreshHostIP()
        _ = ScreenMirroringWindowController.shared

        FileProviderDomainManager.shared.ipcServer.onFileMessageRelay = { [weak self] req in
            guard let self = self else {
                throw NSError(domain: "DroidLink", code: -1, userInfo: [NSLocalizedDescriptionKey: "App unavailable"])
            }
            if AoaUsbManager.shared.isConnected {
                return try await AoaUsbManager.shared.requestFileOperation(req)
            } else if self.tcpServer.hasActiveClient {
                return try await self.tcpServer.requestFileOperation(req)
            }
            return try await self.bleServer.requestFileOperation(req)
        }

        ScreenMirroringManager.shared.onSendScreenMessage = { [weak self] msg in
            guard let self = self else { return }
            if AoaUsbManager.shared.isConnected {
                var rootMsg = Droidlink_Protocol_DroidLinkMessage()
                rootMsg.id = UInt64(Date().timeIntervalSince1970 * 1000)
                rootMsg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
                rootMsg.type = .screenStream
                rootMsg.screen = msg
                AoaUsbManager.shared.send(message: rootMsg)
            } else if self.tcpServer.hasActiveClient {
                self.tcpServer.sendScreen(message: msg)
            } else {
                var rootMsg = Droidlink_Protocol_DroidLinkMessage()
                rootMsg.id = UInt64(Date().timeIntervalSince1970 * 1000)
                rootMsg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
                rootMsg.type = .screenStream
                rootMsg.screen = msg
                self.bleServer.send(message: rootMsg)
            }
        }
        
        MacTelemetryCollector.startObservingPowerChanges()
        
        if let paired = PairingStorage.loadPairedDevice() {
            if PairingStorage.isManuallyDisconnected {
                print("⏸️ Paired device \(paired.deviceName) was manually disconnected; staying disconnected on launch.")
                fflush(stdout)
                state = .disconnected
            } else {
                startListeningForPairedDevice(paired)
            }
        } else {
            startPairing()
        }
    }
    
    func refreshHostIP() {
        if let ip = NetworkUtilities.getLocalIPAddress(), !ip.isEmpty {
            self.hostIP = ip
        } else if self.hostIP == "Detecting..." {
            self.hostIP = "Unavailable"
        }
    }
    
    func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            isLaunchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        } catch {
            print("⚠️ Failed to update launch at login: \(error)")
            isLaunchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        }
    }
    
    func checkPermissions() {
        NotificationManager.shared.checkAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.notificationAuthorizationStatus = status
                self.isNotificationAuthorized = (status == .authorized || status == .provisional)
            }
        }
    }
    
    func checkAndRequestNotificationPermissions() {
        NotificationManager.shared.checkAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.notificationAuthorizationStatus = status
                self.isNotificationAuthorized = (status == .authorized || status == .provisional)
                if status == .notDetermined {
                    NotificationManager.shared.requestAuthorization { granted in
                        DispatchQueue.main.async {
                            self.checkPermissions()
                        }
                    }
                }
            }
        }
    }
    
    func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }
    
    func requestNotificationPermission() {
        NotificationManager.shared.checkAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.notificationAuthorizationStatus = status
                if status == .notDetermined {
                    NotificationManager.shared.requestAuthorization { granted in
                        DispatchQueue.main.async {
                            self.checkPermissions()
                        }
                    }
                } else if status == .denied {
                    NotificationManager.shared.openSystemNotificationSettings()
                } else {
                    self.isNotificationAuthorized = (status == .authorized || status == .provisional)
                }
            }
        }
    }
    
    func toggleIncognitoMode() {
        isIncognitoMode.toggle()
    }
    
    func toggleAutoIgnoreSensitive() {
        autoIgnoreSensitive.toggle()
    }
    
    func clearNotificationHistory() {
        notificationHistory.removeAll()
        lastNotification = nil
    }
    
    func clearClipboardHistory() {
        clipboardHistory.removeAll()
    }
    
    func sendManualClipboard(text: String) {
        lastClipboardText = text
        if !clipboardHistory.contains(text) {
            clipboardHistory.insert(text, at: 0)
            if clipboardHistory.count > 15 { clipboardHistory.removeLast() }
        }
        
        var clipMsg = Droidlink_Protocol_ClipboardMessage()
        var clipData = Droidlink_Protocol_ClipboardData()
        clipData.type = .dataText
        clipData.text = text
        clipData.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        clipMsg.data = clipData
        clipMsg.isRemote = false
        
        var rootMsg = Droidlink_Protocol_DroidLinkMessage()
        rootMsg.id = UInt64(Date().timeIntervalSince1970 * 1000)
        rootMsg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        rootMsg.type = .clipboardSync
        rootMsg.clipboard = clipMsg
        
        bleServer.send(message: rootMsg)
    }
    
    func startListeningForPairedDevice(_ paired: PairedDeviceInfo, isManualRequest: Bool = false) {
        print("🔄 Resuming BLE listening for saved device: \(paired.deviceName) (isManualRequest=\(isManualRequest))")
        fflush(stdout)
        let model = paired.deviceModel ?? "Android Device"
        state = .waitingForPairedDevice(name: paired.deviceName, model: model)
        qrCode = nil
        self.currentSessionKey = paired.sessionKey
        refreshHostIP()
        if let crypto = try? CryptoChannel(keyData: paired.sessionKey) {
            bleServer.cryptoChannel = crypto
            try? tcpServer.start(port: 29170, cryptoChannel: crypto)
            self.listeningPort = tcpServer.listeningPort
        }
        let myName = Host.current().localizedName ?? "Mac"
        bleServer.startAdvertising(deviceName: myName, pairingMode: false)
        
        // Immediately notify paired Android device & pulse beacon periodically
        broadcastWakeupBeacon(paired: paired, isManualRequest: isManualRequest)
        startWakeupTimer(paired: paired, isManualRequest: isManualRequest)
    }
    
    private func broadcastWakeupBeacon(paired: PairedDeviceInfo, isManualRequest: Bool = false) {
        refreshHostIP()
        print("📡 Sending auto-connect beacon to \(paired.deviceName) at \(hostIP):\(listeningPort) (isManualRequest=\(isManualRequest))")
        fflush(stdout)
        DeviceWakeupNotifier.notifyAndroidPeer(pairedDevice: paired, currentHostIP: hostIP, listeningPort: listeningPort, isManualRequest: isManualRequest)
    }
    
    private func startWakeupTimer(paired: PairedDeviceInfo, isManualRequest: Bool = false) {
        stopWakeupTimer()
        wakeupTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if case .waitingForPairedDevice = self.state {
                    self.broadcastWakeupBeacon(paired: paired, isManualRequest: isManualRequest)
                } else {
                    self.stopWakeupTimer()
                }
            }
        }
    }
    
    private func stopWakeupTimer() {
        wakeupTimer?.invalidate()
        wakeupTimer = nil
    }

    func sendCurrentTelemetry(force: Bool = false) {
        let status = MacTelemetryCollector.shared.collectStatus(tcpPort: Int(listeningPort))
        if force || MacTelemetryCollector.shared.hasStatusChanged(from: lastSentTelemetry, to: status) {
            lastSentTelemetry = status
            if tcpServer.hasActiveClient {
                tcpServer.sendTelemetry(status)
            } else {
                bleServer.sendLocalTelemetry()
            }
        }
    }

    private func startTelemetryTimer() {
        stopTelemetryTimer()
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if case .connected = self.state {
                    self.sendCurrentTelemetry(force: false)
                } else {
                    self.stopTelemetryTimer()
                }
            }
        }
    }

    private func stopTelemetryTimer() {
        telemetryTimer?.invalidate()
        telemetryTimer = nil
    }
    
    func startPairing() {
        if case .connected = state { return }
        stopWakeupTimer()
        stopTelemetryTimer()
        print("▶️ startPairing invoked over Bluetooth")
        fflush(stdout)
        state = .pairing
        qrCode = nil
        let myName = Host.current().localizedName ?? "Mac"
        bleServer.startAdvertising(deviceName: myName, pairingMode: true)
    }
    
    func cancelPairing() {
        stopWakeupTimer()
        stopTelemetryTimer()
        bleServer.stopAdvertising()
        clipboardManager.stopObserving()
        state = .disconnected
        qrCode = nil
    }
    
    func disconnect() {
        print("🔌 User manually disconnected device")
        fflush(stdout)
        PairingStorage.isManuallyDisconnected = true
        stopWakeupTimer()
        stopTelemetryTimer()
        bleServer.disconnect(isManual: true)
        tcpServer.sendGoodbyeAndStop(isManual: true)
        clipboardManager.stopObserving()
        remoteDeviceStatus = nil
        state = .disconnected
    }

    func reconnect() {
        guard let paired = PairingStorage.loadPairedDevice() else {
            startPairing()
            return
        }
        print("🔄 User explicitly requested reconnection to \(paired.deviceName)")
        fflush(stdout)
        PairingStorage.isManuallyDisconnected = false
        startListeningForPairedDevice(paired, isManualRequest: true)
    }
    
    func unpairDevice() {
        print("🗑️ Unpairing device and restarting BLE advertising")
        fflush(stdout)
        stopWakeupTimer()
        stopTelemetryTimer()
        PairingStorage.clear()
        bleServer.disconnect(isManual: true)
        tcpServer.sendGoodbyeAndStop(isManual: true)
        clipboardManager.stopObserving()
        remoteDeviceStatus = nil
        currentSessionKey = nil
        startPairing()
    }
    
    private func setupClipboardHandler() {
        clipboardManager.onClipboardChanged = { [weak self] newText in
            guard let self = self else { return }
            guard self.isClipboardSyncEnabled else {
                print("📋 Clipboard sync is disabled in settings; skipping sync.")
                return
            }
            self.lastClipboardText = newText
            if !self.clipboardHistory.contains(newText) {
                self.clipboardHistory.insert(newText, at: 0)
                if self.clipboardHistory.count > 15 { self.clipboardHistory.removeLast() }
            }
            
            var clipMsg = Droidlink_Protocol_ClipboardMessage()
            var clipData = Droidlink_Protocol_ClipboardData()
            clipData.type = .dataText
            clipData.text = newText
            clipData.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
            clipMsg.data = clipData
            clipMsg.isRemote = false
            
            var rootMsg = Droidlink_Protocol_DroidLinkMessage()
            rootMsg.id = UInt64(Date().timeIntervalSince1970 * 1000)
            rootMsg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
            rootMsg.type = .clipboardSync
            rootMsg.clipboard = clipMsg
            
            self.bleServer.send(message: rootMsg)
        }
    }
    
    private func setupNotificationObservers() {
        let connectedObserver = NotificationCenter.default.addObserver(
            forName: .droidlinkDeviceConnected,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let paired = PairingStorage.loadPairedDevice()
            let deviceName = (notif.object as? String) ?? paired?.deviceName ?? "Android Phone"
            let savedModel = paired?.deviceModel
            Task { @MainActor in
                guard let self = self else { return }
                self.stopWakeupTimer()
                self.startTelemetryTimer()
                self.sendCurrentTelemetry(force: true)
                let deviceModel = savedModel ?? self.remoteDeviceStatus?.deviceModel ?? "Android Device"
                self.state = .connected(name: deviceName, model: deviceModel)
                self.clipboardManager.startObserving()

                // Check if Android has Finder storage disabled in settings
                if let status = self.remoteDeviceStatus, !status.isFinderStorageEnabled {
                    print("📁 Android peer has Finder storage disabled in settings. Skipping mount.")
                    fflush(stdout)
                    return
                }

                // Auto-mount Android storage in macOS Finder (silently in background)
                // Guard: only register when we have the real paired device ID (not "default")
                guard let realDeviceId = paired?.deviceId else {
                    print("⏳ Skipping auto-mount: paired device not yet loaded, will retry on next connect event")
                    fflush(stdout)
                    return
                }
                let deviceId = realDeviceId
                print("📁 Auto-registering Finder FileProvider for \(deviceName) (\(deviceId))...")
                fflush(stdout)
                do {
                    try await FileProviderDomainManager.shared.registerDomain(deviceId: deviceId, deviceName: deviceName)
                    print("✅ Successfully mounted Android storage in Finder!")
                    fflush(stdout)
                } catch {
                    print("⚠️ Auto-mount error: \(error)")
                    fflush(stdout)
                }

                ScreenMirroringManager.shared.requestInstalledApps()
            }
        }
        
        let disconnectedObserver = NotificationCenter.default.addObserver(
            forName: .droidlinkDeviceDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.stopTelemetryTimer()
                self.remoteDeviceStatus = nil
                self.clipboardManager.stopObserving()
                ScreenMirroringManager.shared.stopMirroring()
                if let paired = PairingStorage.loadPairedDevice() {
                    if PairingStorage.isManuallyDisconnected {
                        print("⏸️ Paired device disconnected manually; not re-listening.")
                        self.state = .disconnected
                    } else {
                        self.startListeningForPairedDevice(paired)
                    }
                } else {
                    self.state = .disconnected
                }
            }
        }
        
        let statusObserver = NotificationCenter.default.addObserver(
            forName: .droidlinkDeviceStatusReceived,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let status = notif.object as? DeviceStatusInfo else { return }
            Task { @MainActor in
                guard let self = self else { return }
                self.remoteDeviceStatus = status
                if !status.isFinderStorageEnabled && FileProviderDomainManager.shared.isMounted {
                    if let paired = PairingStorage.loadPairedDevice() {
                        print("🛑 Unmounting Finder domain because Android disabled storage access in settings")
                        fflush(stdout)
                        try? await FileProviderDomainManager.shared.unregisterDomain(deviceId: paired.deviceId)
                    }
                }
                if let paired = PairingStorage.loadPairedDevice(), !status.deviceModel.isEmpty {
                    var updated = paired
                    updated.deviceModel = status.deviceModel
                    PairingStorage.save(device: updated)
                    if case .connected(let name, _) = self.state {
                        self.state = .connected(name: name, model: status.deviceModel)
                    }
                }
            }
        }
        
        let clipboardObserver = NotificationCenter.default.addObserver(
            forName: .droidlinkClipboardReceived,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let self = self else { return }
            guard self.isClipboardSyncEnabled else {
                print("📋 Clipboard sync disabled in settings; ignoring incoming remote clipboard from Android.")
                return
            }
            guard let clip = notif.object as? Droidlink_Protocol_ClipboardMessage else { return }
            let text = clip.data.text
            Task { @MainActor in
                self.lastClipboardText = text
                if !self.clipboardHistory.contains(text) {
                    self.clipboardHistory.insert(text, at: 0)
                    if self.clipboardHistory.count > 15 { self.clipboardHistory.removeLast() }
                }
                self.clipboardManager.setRemoteContent(text)
            }
        }
        
        let notifObserver = NotificationCenter.default.addObserver(
            forName: .droidlinkNotificationReceived,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let self = self else { return }
            guard self.isNotificationMirroringEnabled else {
                print("🔔 Notification mirroring disabled in settings; ignoring incoming Android alert.")
                return
            }
            guard let msg = notif.object as? Droidlink_Protocol_NotificationMessage else { return }
            let iconData = msg.notification.icon.isEmpty ? nil : msg.notification.icon
            
            let item = MirroredNotificationItem(
                id: msg.notification.id,
                appName: msg.notification.appName,
                title: msg.notification.title,
                text: msg.notification.text,
                timestamp: Date(),
                iconData: iconData
            )
            
            Task { @MainActor in
                self.lastNotification = item
                self.notificationHistory.insert(item, at: 0)
                if self.notificationHistory.count > 30 {
                    self.notificationHistory.removeLast()
                }
            }
            
            NotificationManager.shared.postNotification(
                title: msg.notification.title,
                body: msg.notification.text,
                appName: msg.notification.appName,
                id: msg.notification.id,
                iconData: iconData
            )
        }
        
        let activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkPermissions()
        }

        let telemetryObserver = NotificationCenter.default.addObserver(
            forName: .droidlinkLocalTelemetryChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if case .connected = self.state {
                    self.sendCurrentTelemetry(force: true)
                }
            }
        }

        let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.refreshHostIP()
                if case .connected = self.state {
                    self.sendCurrentTelemetry(force: true)
                } else if let paired = PairingStorage.loadPairedDevice(), !PairingStorage.isManuallyDisconnected {
                    self.startListeningForPairedDevice(paired)
                }
            }
        }
        
        observers = [connectedObserver, disconnectedObserver, statusObserver, clipboardObserver, notifObserver, activeObserver, telemetryObserver, wakeObserver]
    }
    
    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}