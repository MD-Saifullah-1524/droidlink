import SwiftUI
import AppKit

/// Content view of the dedicated Standalone Screen Mirroring Window.
struct ScreenMirrorView: View {
    @ObservedObject var manager = ScreenMirroringManager.shared
    @State private var isAlwaysOnTop: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Navigation & Control Toolbar
            controlToolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // MARK: - Video Mirroring Surface
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)

                let aspectRatio = (manager.screenHeight > 0) ?
                    CGFloat(manager.screenWidth) / CGFloat(manager.screenHeight) : (9.0 / 19.5)

                H264DecoderRepresentable()
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Error overlay if any
                if let error = manager.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                        Button("Retry") {
                            manager.startMirroring(app: manager.currentApp)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial.opacity(0.95))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                // FPS & Stream Info Badge (Top-trailing overlay)
                VStack {
                    HStack {
                        Spacer()
                        streamInfoBadge
                    }
                    Spacer()
                }
                .padding(12)
            }
        }
        .frame(minWidth: 240, minHeight: 380)
        .background(Color.black)
    }

    // MARK: - Controls Toolbar

    private var controlToolbar: some View {
        HStack(spacing: 8) {
            // Android Navigation Controls
            Group {
                Button(action: { manager.sendNav(action: .back) }) {
                    Image(systemName: "chevron.backward")
                        .help("Back (Right Click)")
                }

                Button(action: { manager.sendNav(action: .home) }) {
                    Image(systemName: "circle")
                        .help("Home")
                }

                Button(action: { manager.sendNav(action: .recents) }) {
                    Image(systemName: "square")
                        .help("App Switcher / Recents")
                }

                Button(action: { manager.togglePrivacyMode() }) {
                    Image(systemName: manager.isPrivacyModeActive ? "moon.stars.fill" : "moon")
                        .foregroundStyle(manager.isPrivacyModeActive ? .purple : .primary)
                        .help(manager.isPrivacyModeActive ? "Exit AOD Privacy Mode" : "Activate AOD Privacy Mode (Screen black with clock on desk)")
                }

                Button(action: { manager.sendNav(action: .notifications) }) {
                    Image(systemName: "bell")
                        .help("Pull Down Notifications")
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 14, weight: .semibold))

            Divider().frame(height: 18)

            // Screen Rotation
            Button(action: {
                manager.rotate()
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "rotate.right")
                    Text(manager.rotationMode == .rotationLandscape ? "Landscape" : "Portrait")
                        .font(.system(size: 11, weight: .medium))
                }
                .help("Toggle Orientation (Currently \(manager.rotationMode == .rotationLandscape ? "Landscape" : "Portrait"))")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 14))

            Spacer()

            // Audio Controls (Device Audio & Mac Microphone)
            HStack(spacing: 6) {
                // Device speaker audio
                Button(action: { manager.toggleDeviceAudio() }) {
                    Image(systemName: manager.isDeviceAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(manager.isDeviceAudioMuted ? .secondary : .primary)
                        .help(manager.isDeviceAudioMuted ? "Unmute Phone Audio" : "Mute Phone Audio")
                }
                .buttonStyle(.borderless)

                // Mac Microphone to Android
                Button(action: { manager.toggleMic() }) {
                    HStack(spacing: 3) {
                        Image(systemName: manager.isMicMuted ? "mic.slash.fill" : "mic.fill")
                            .foregroundColor(manager.isMicMuted ? .secondary : .blue)

                        // Live audio level indicator
                        if !manager.isMicMuted {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                                .scaleEffect(1.0 + CGFloat(manager.micLevel) * 0.8)
                        }
                    }
                    .help(manager.isMicMuted ? "Unmute Mac Mic for Phone" : "Mute Mac Mic")
                }
                .buttonStyle(.borderless)
            }

            Divider().frame(height: 18)

            // Always on Top Toggle
            Button(action: {
                isAlwaysOnTop.toggle()
                updateWindowLevel()
            }) {
                Image(systemName: isAlwaysOnTop ? "pin.fill" : "pin")
                    .foregroundStyle(isAlwaysOnTop ? .orange : .secondary)
                    .help(isAlwaysOnTop ? "Unpin Window" : "Keep Window Always on Top")
            }
            .buttonStyle(.borderless)
        }
    }

    private var streamInfoBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(manager.fps > 20 ? Color.green : Color.orange)
                .frame(width: 6, height: 6)

            Text(String(format: "%.0f FPS", manager.fps))
                .font(.system(size: 11, weight: .bold, design: .monospaced))

            if let app = manager.currentApp {
                Text("•")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(app.appName)
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial.opacity(0.85))
        .clipShape(Capsule())
    }

    private func updateWindowLevel() {
        if let window = NSApp.keyWindow {
            window.level = isAlwaysOnTop ? .floating : .normal
        }
    }
}
