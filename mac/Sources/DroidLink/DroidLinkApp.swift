import SwiftUI
import AppKit
import Darwin


@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow?
    var viewModel: ContentViewModel?
    var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var incognitoMenuItem: NSMenuItem?
    private var disconnectMenuItem: NSMenuItem?
    private var notifObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("✅ App did finish launching")
        fflush(stdout)
        
        let app = NSApplication.shared
        
        if let iconUrl = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let appIcon = NSImage(contentsOf: iconUrl) {
            app.applicationIconImage = appIcon
        }
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "DroidLink"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 480)
        window.delegate = self
        self.window = window
        
        let vm = ContentViewModel()
        self.viewModel = vm
        
        let contentView = ContentView(viewModel: vm)
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        
        app.activate(ignoringOtherApps: true)
        
        setupMainMenu()
        setupStatusItem()
        setupNotificationObservers()

        // Start listening for direct USB connections via Android Open Accessory (AOA 2.0)
        AoaUsbManager.shared.startMonitoring()

        print("✅ DroidLink window shown & status bar initialized")
        fflush(stdout)
    }
    
    // MARK: - Window Delegate
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        print("🔽 Window closing: ordering out and switching activation policy to .accessory")
        fflush(stdout)
        sender.orderOut(nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        return false
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openMainWindow()
        }
        return true
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        notifObservers.forEach { NotificationCenter.default.removeObserver($0) }
        ExternalDisplayManager.shared.stopExternalDisplay(notifyRemote: false)
        viewModel?.disconnect()
    }
    
    enum MenuBarIconState {
        case connected
        case disconnected
        case syncing
    }
    
    private func updateMenuBarIcon(state: MenuBarIconState) {
        guard let button = statusItem?.button else { return }
        let name: String
        switch state {
        case .connected:
            name = "droidlink_menubar_connected"
        case .disconnected:
            name = "droidlink_menubar_disconnected"
        case .syncing:
            name = "droidlink_menubar_syncing"
        }
        
        if let url = Bundle.main.url(forResource: name, withExtension: "svg"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true
            button.image = img
            return
        }
        
        // Fallback to SF symbol if resource not loaded
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let fallback = NSImage(systemSymbolName: state == .connected ? "iphone.and.arrow.forward" : "iphone.slash", accessibilityDescription: "DroidLink")?.withSymbolConfiguration(symbolConfig)
        fallback?.isTemplate = true
        button.image = fallback
    }

    // MARK: - Menu Bar Status Item
    
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.toolTip = "DroidLink"
        }
        
        let menu = NSMenu()
        
        let initialTitle: String
        if let paired = PairingStorage.loadPairedDevice() {
            initialTitle = "DroidLink: Waiting for \(paired.deviceName)"
        } else {
            initialTitle = "DroidLink: Ready to Pair"
        }
        let statusTitle = NSMenuItem(title: initialTitle, action: nil, keyEquivalent: "")
        statusTitle.isEnabled = false
        menu.addItem(statusTitle)
        self.statusMenuItem = statusTitle
        
        menu.addItem(NSMenuItem.separator())
        
        let openItem = NSMenuItem(title: "Open DroidLink", action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        let incognitoItem = NSMenuItem(title: "🕶️ Incognito Mode (Pause Sync)", action: #selector(toggleIncognitoMode), keyEquivalent: "i")
        incognitoItem.target = self
        incognitoItem.state = PairingStorage.isIncognitoMode ? .on : .off
        menu.addItem(incognitoItem)
        self.incognitoMenuItem = incognitoItem
        
        let disconnectItem = NSMenuItem(title: "Disconnect", action: #selector(disconnectDevice), keyEquivalent: "d")
        disconnectItem.target = self
        disconnectItem.isEnabled = false
        menu.addItem(disconnectItem)
        self.disconnectMenuItem = disconnectItem
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit DroidLink", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        item.menu = menu
        self.statusItem = item
        updateMenuBarIcon(state: .disconnected)
    }

    // MARK: - Main Menu Bar (Apps Menu)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // 1. App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let appName = "DroidLink"
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())

        let hideItem = NSMenuItem(title: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hideItem)
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())

        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // 2. Edit Menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // 3. Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        NSApplication.shared.mainMenu = mainMenu
    }
    
    @objc func openMainWindow() {
        print("🔼 Reopening window from menu bar: switching activation policy to .regular")
        fflush(stdout)
        NSApplication.shared.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc func openSettings() {
        openMainWindow()
        NotificationCenter.default.post(name: .droidlinkOpenSettings, object: nil)
    }

    @objc func toggleIncognitoMode() {
        guard let vm = viewModel else { return }
        vm.toggleIncognitoMode()
        incognitoMenuItem?.state = vm.isIncognitoMode ? .on : .off
        print("🕶️ Incognito Mode toggled: \(vm.isIncognitoMode)")
        fflush(stdout)
    }
    
    @objc func disconnectDevice() {
        print("🔌 Disconnect requested from menu bar")
        fflush(stdout)
        viewModel?.disconnect()
    }
    
    @objc func quitApp() {
        print("🛑 Quitting DroidLink from menu bar")
        fflush(stdout)
        viewModel?.disconnect()
        NSApplication.shared.terminate(nil)
    }
    
    private func setupNotificationObservers() {
        let connectedObserver = NotificationCenter.default.addObserver(
            forName: .droidlinkDeviceConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.statusMenuItem?.title = "DroidLink: Connected"
                self?.disconnectMenuItem?.isEnabled = true
                self?.statusItem?.button?.toolTip = "DroidLink: Connected"
                self?.updateMenuBarIcon(state: .connected)
            }
        }
        
        let disconnectedObserver = NotificationCenter.default.addObserver(
            forName: .droidlinkDeviceDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                let title = PairingStorage.isPaired ? "DroidLink: Waiting for paired device" : "DroidLink: Disconnected"
                self?.statusMenuItem?.title = title
                self?.disconnectMenuItem?.isEnabled = false
                self?.statusItem?.button?.toolTip = title
                self?.updateMenuBarIcon(state: .disconnected)
            }
        }
        
        let incognitoObserver = NotificationCenter.default.addObserver(
            forName: .droidlinkIncognitoChanged,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let isIncognito = notif.object as? Bool else { return }
            Task { @MainActor in
                self?.incognitoMenuItem?.state = isIncognito ? .on : .off
            }
        }
        
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleDistributedOpenMainWindow(_:)),
            name: .droidlinkDistributedOpenMainWindow,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        notifObservers = [connectedObserver, disconnectedObserver, incognitoObserver]
    }

    @objc private func handleDistributedOpenMainWindow(_ notification: Notification) {
        print("📨 Received com.droidlink.mac.openMainWindow notification from secondary instance")
        fflush(stdout)
        Task { @MainActor in
            self.openMainWindow()
        }
    }
}

@_silgen_name("NSExtensionMain")
func NSExtensionMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

@main
struct DroidLinkApp {
    @MainActor
    private static var strongDelegate: AppDelegate?
    @MainActor
    private static var lockFileDescriptor: Int32 = -1

    static func main() {
        if Bundle.main.bundlePath.hasSuffix(".appex") {
            print("⚡ Starting DroidLinkFileProvider Extension via NSExtensionMain...")
            fflush(stdout)
            _ = NSExtensionMain(CommandLine.argc, CommandLine.unsafeArgv)
            return
        }

        let lockPath = "/tmp/com.droidlink.mac.lock"
        let lockFd = open(lockPath, O_CREAT | O_RDWR, 0o666)
        if lockFd >= 0 {
            if flock(lockFd, LOCK_EX | LOCK_NB) != 0 {
                print("⚠️ Another instance of DroidLink is already running. Requesting main window focus and exiting...")
                fflush(stdout)

                DistributedNotificationCenter.default().postNotificationName(
                    .droidlinkDistributedOpenMainWindow,
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )

                let myPid = getpid()
                let bundleId = Bundle.main.bundleIdentifier ?? "com.droidlink.mac"
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) where app.processIdentifier != myPid {
                    app.activate()
                }

                close(lockFd)
                exit(0)
            }
            lockFileDescriptor = lockFd
        }

        let logPath = "/tmp/droidlink_gui.log"
        freopen(logPath, "a", stdout)
        freopen(logPath, "a", stderr)

        print("🚀 DroidLink starting...")
        fflush(stdout)
        
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        
        let delegate = AppDelegate()
        strongDelegate = delegate
        app.delegate = delegate
        
        print("🔄 Starting run loop...")
        fflush(stdout)
        app.run()
    }
}