import AppKit
import SwiftUI
import Combine

/// Manages the lifecycle of the standalone Screen Mirroring window.
@MainActor
final class ScreenMirroringWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ScreenMirroringWindowController()

    private var cancellables = Set<AnyCancellable>()
    private var hasAppliedInitialGeometry = false

    init() {
        print("🪟 [ScreenMirroringWindowController] Initializing window controller...")
        fflush(stdout)

        // Default to a sleek portrait phone geometry (e.g. 330x740)
        let window = NSWindow(
            contentRect: NSRect(x: 150, y: 150, width: 330, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "DroidLink • Android Screen"
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.canHide = false
        window.minSize = NSSize(width: 240, height: 380)

        super.init(window: window)
        self.window = window
        window.delegate = self
        window.contentView = NSHostingView(rootView: ScreenMirrorView())

        observeManager()
        print("🪟 [ScreenMirroringWindowController] Initialized successfully. Window: \(window)")
        fflush(stdout)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func observeManager() {
        let manager = ScreenMirroringManager.shared

        // Wire up trigger to open mirror window
        manager.onRequestOpenMirrorWindow = { [weak self] in
            print("🪟 [ScreenMirroringWindowController] onRequestOpenMirrorWindow called!")
            fflush(stdout)
            self?.openMirrorWindow()
        }

        manager.$isMirroringActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                print("🪟 [ScreenMirroringWindowController] isMirroringActive changed to: \(active)")
                fflush(stdout)
                if active {
                    self?.openMirrorWindow()
                } else {
                    self?.window?.orderOut(nil)
                }
            }
            .store(in: &cancellables)

        // Dynamically update window title when app changes
        manager.$currentApp
            .receive(on: DispatchQueue.main)
            .sink { [weak self] app in
                if let app = app {
                    self?.window?.title = "DroidLink • \(app.appName)"
                } else {
                    self?.window?.title = "DroidLink • Android Screen"
                }
            }
            .store(in: &cancellables)

        // Dynamically adjust aspect ratio and window frame on orientation / screen metric changes
        Publishers.CombineLatest(manager.$screenWidth, manager.$screenHeight)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] width, height in
                guard width > 0, height > 0, let self = self, let window = self.window else { return }

                let isLandscape = width > height
                let currentIsLandscape = window.contentView?.frame.width ?? window.frame.width > (window.contentView?.frame.height ?? window.frame.height)

                if !self.hasAppliedInitialGeometry || isLandscape != currentIsLandscape {
                    self.hasAppliedInitialGeometry = true

                    let aspect = CGFloat(width) / CGFloat(height)
                    let toolbarHeight: CGFloat = 44
                    let screen = window.screen ?? NSScreen.main
                    let maxH = (screen?.visibleFrame.height ?? 900) - 100
                    let maxW = (screen?.visibleFrame.width ?? 1440) - 100

                    let newContentWidth: CGFloat
                    let newContentHeight: CGFloat

                    if !isLandscape {
                        // Portrait mode
                        let targetVideoH = min(720, maxH - toolbarHeight)
                        let targetVideoW = round(targetVideoH * aspect)
                        newContentWidth = max(240, targetVideoW)
                        newContentHeight = targetVideoH + toolbarHeight
                    } else {
                        // Landscape mode
                        let targetVideoW = min(960, maxW)
                        let targetVideoH = round(targetVideoW / aspect)
                        newContentWidth = targetVideoW
                        newContentHeight = targetVideoH + toolbarHeight
                    }

                    let currentCenter = NSPoint(x: window.frame.midX, y: window.frame.midY)
                    let targetContentRect = NSRect(
                        x: currentCenter.x - newContentWidth / 2,
                        y: currentCenter.y - newContentHeight / 2,
                        width: newContentWidth,
                        height: newContentHeight
                    )
                    let newWindowFrame = window.frameRect(forContentRect: targetContentRect)
                    window.contentAspectRatio = NSSize(width: Int(newContentWidth), height: Int(newContentHeight))
                    window.setFrame(newWindowFrame, display: true, animate: false)
                }
            }
            .store(in: &cancellables)
    }

    func openMirrorWindow() {
        guard let window = self.window else {
            print("❌ [ScreenMirroringWindowController] openMirrorWindow failed: self.window is nil!")
            fflush(stdout)
            return
        }
        print("🪟 [ScreenMirroringWindowController] openMirrorWindow executing. isVisible=\(window.isVisible), frame=\(window.frame)")
        fflush(stdout)
        self.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        print("🪟 [ScreenMirroringWindowController] window now isVisible=\(window.isVisible), frame=\(window.frame)")
        fflush(stdout)
    }

    func windowWillClose(_ notification: Notification) {
        print("🔽 Screen Mirroring window closed by user")
        fflush(stdout)
        ScreenMirroringManager.shared.stopMirroring()
    }
}
