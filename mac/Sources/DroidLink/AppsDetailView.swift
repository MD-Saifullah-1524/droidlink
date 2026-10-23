import SwiftUI
import AppKit

/// Detail view for the sidebar "Apps" section.
/// Displays a searchable grid of installed Android apps and allows one-click launching and mirroring.
struct AppsDetailView: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var manager = ScreenMirroringManager.shared

    @State private var searchText: String = ""
    @State private var filterMode: AppFilterMode = .all
    @State private var hoveredAppPackage: String? = nil

    enum AppFilterMode: String, CaseIterable, Identifiable {
        case all = "All"
        case user = "User Apps"
        case system = "System"
        var id: String { rawValue }
    }

    var filteredApps: [Droidlink_Protocol_AppInfo] {
        manager.installedApps.filter { app in
            let matchesSearch = searchText.isEmpty ||
                app.appName.localizedCaseInsensitiveContains(searchText) ||
                app.packageName.localizedCaseInsensitiveContains(searchText)

            let matchesFilter = whenFilterMatches(app: app)
            return matchesSearch && matchesFilter
        }
    }

    private func whenFilterMatches(app: Droidlink_Protocol_AppInfo) -> Bool {
        switch filterMode {
        case .all: return true
        case .user: return !app.isSystem
        case .system: return app.isSystem
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            headerView
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // MARK: - Main Content Area
            if case .connected = viewModel.state {
                connectedContent
            } else {
                disconnectedState
            }
        }
        .onAppear {
            if case .connected = viewModel.state, manager.installedApps.isEmpty {
                manager.requestInstalledApps()
            }
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Android Apps")
                        .font(.title2)
                        .fontWeight(.bold)

                    if !manager.installedApps.isEmpty {
                        Text("\(manager.installedApps.count)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }

                Text("Click an app to launch and mirror on Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Refresh Apps Button
            Button(action: {
                manager.requestInstalledApps(force: true)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(manager.isLoadingApps ? 360 : 0))
                        .animation(manager.isLoadingApps ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: manager.isLoadingApps)
                    Text("Refresh")
                }
            }
            .disabled(manager.isLoadingApps)

            // Direct Mirror Screen Button
            Button(action: {
                manager.startMirroring()
            }) {
                Label("Mirror Screen", systemImage: "iphone.and.arrow.forward")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Connected Apps Grid

    private var connectedContent: some View {
        VStack(spacing: 16) {
            // Search Bar & Filter Chips
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search apps...", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Picker("Filter", selection: $filterMode) {
                    ForEach(AppFilterMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            if manager.isLoadingApps && manager.installedApps.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Fetching installed apps from Android...")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if let err = manager.errorMessage, manager.installedApps.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Button("Retry Fetching Apps") {
                        manager.requestInstalledApps(force: true)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            } else if filteredApps.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary.opacity(0.4))
                    Text(searchText.isEmpty ? "No apps found" : "No apps match '\(searchText)'")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 120, maximum: 140), spacing: 16)],
                        spacing: 20
                    ) {
                        ForEach(filteredApps, id: \.packageName) { app in
                            appGridItem(app)
                        }
                    }
                    .padding(24)
                }
            }
        }
    }

    // MARK: - App Grid Item

    private func appGridItem(_ app: Droidlink_Protocol_AppInfo) -> some View {
        let isHovered = (hoveredAppPackage == app.packageName)

        return Button(action: {
            manager.launchApp(app)
        }) {
            VStack(spacing: 8) {
                ZStack {
                    // App Icon
                    if let nsImage = NSImage(data: app.iconPng) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: 64, height: 64)
                            .overlay {
                                Image(systemName: "app.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.secondary)
                            }
                    }

                    // Hover Play Overlay
                    if isHovered {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                            .frame(width: 64, height: 64)
                            .overlay {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white)
                            }
                    }
                }
                .scaleEffect(isHovered ? 1.06 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)

                // App Label
                Text(app.appName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(height: 34, alignment: .top)

                // Package Subtitle
                Text(app.packageName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered ? Color.secondary.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredAppPackage = hovering ? app.packageName : nil
        }
    }

    // MARK: - Disconnected State

    private var disconnectedState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 48))
                .foregroundStyle(.secondary.opacity(0.4))

            Text("Android Device Not Connected")
                .font(.title3)
                .fontWeight(.bold)

            Text("Connect your Android phone over Wi-Fi or Bluetooth to view installed apps and launch screen mirroring.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Spacer()
        }
        .padding(24)
    }
}
