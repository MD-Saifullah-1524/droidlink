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
        // Default to a sleek portrait phone geometry (e.g. 330x740)
        let window = NSWindow(
            contentRect: NSRect(x: 150, y: 150, width: 330, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "DroidLink Mirror"
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 240, height: 380)

        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ScreenMirrorView())

        observeManager()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func observeManager() {
        let manager = ScreenMirroringManager.shared

        // Wire up trigger to open mirror window
        manager.onRequestOpenMirrorWindow = { [weak self] in
            self?.openMirrorWindow()
        }

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
                    window.contentAspectRatio = NSSize(width: Int(newContentWidth), height: Int(newContentHeight))

                    let newFrame = NSRect(
                        x: currentCenter.x - newContentWidth / 2,
                        y: currentCenter.y - newContentHeight / 2,
                        width: newContentWidth,
                        height: newContentHeight + (window.frame.height - (window.contentView?.frame.height ?? newContentHeight))
                    )
                    window.setFrame(newFrame, display: true, animate: true)
                }
            }
            .store(in: &cancellables)
    }

    func openMirrorWindow() {
        guard let window = self.window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        print("🔽 Screen Mirroring window closed by user")
        ScreenMirroringManager.shared.stopMirroring()
    }
}
