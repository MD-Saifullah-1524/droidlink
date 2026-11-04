import AppKit
import SwiftUI

/// Dedicated floating window controller hosting the droidOS workstation display view and overlay HUD.
@MainActor
public final class DroidOsDisplayWindowController: NSWindowController, NSWindowDelegate {
    private var displayView: DroidOsDisplayView?
    private var resizeDebounceTimer: Timer?

    public convenience init() {
        let contentRect = NSRect(x: 100, y: 100, width: 1280, height: 720)
        let styleMask: NSWindow.StyleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView
        ]
        let window = NSWindow(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
        window.title = "droidOS Workstation — Realme 2"
        window.minSize = NSSize(width: 800, height: 480)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible

        self.init(window: window)
        window.delegate = self
        setupContentView()

        // Send initial display configuration to initiate keyframe streaming from droidOS
        let w = UInt16(contentRect.width)
        let h = UInt16(contentRect.height)
        DroidOsManager.shared.sendDisplayConfig(width: (w / 16) * 16, height: (h / 16) * 16)
    }

    private func setupContentView() {
        guard let window = window else { return }

        let rect = window.contentLayoutRect.size.width > 0 ? window.contentLayoutRect : NSRect(origin: .zero, size: window.frame.size)
        let view = DroidOsDisplayView(frame: rect)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        self.displayView = view
    }

    public func windowDidResize(_ notification: Notification) {
        resizeDebounceTimer?.invalidate()
        resizeDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let win = self.window else { return }
                let size = win.contentView?.bounds.size ?? win.frame.size
                let rawW = UInt16(max(640, min(size.width, 3840)))
                let rawH = UInt16(max(480, min(size.height, 2160)))
                // Hardware H.264 video encoders require 16-pixel macroblock alignment
                let w = (rawW / 16) * 16
                let h = (rawH / 16) * 16
                DroidOsManager.shared.sendDisplayConfig(width: w, height: h)
            }
        }
    }

    public func windowWillClose(_ notification: Notification) {
        resizeDebounceTimer?.invalidate()
        resizeDebounceTimer = nil
    }
}
