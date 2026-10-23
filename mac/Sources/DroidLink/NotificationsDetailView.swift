import SwiftUI
import AppKit

struct NotificationsDetailView: View {
    @ObservedObject var viewModel: ContentViewModel
    @State private var testAlertFeedback: Bool = false
    
    private let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notifications")
                            .font(.system(size: 22, weight: .bold))
                        Text("Real-time Android notification mirroring with native macOS alerts")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        triggerTestNotification()
                    }) {
                        Label(testAlertFeedback ? "Notification Sent!" : "Send Test Notification", systemImage: testAlertFeedback ? "checkmark" : "bell.badge")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 14)
            
            // Notification Authorization Banner (if not authorized)
            if !viewModel.isNotificationAuthorized {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.orange)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notification Access Not Granted")
                            .font(.system(size: 12, weight: .semibold))
                        Text(viewModel.notificationAuthorizationStatus == .denied 
                            ? "Notifications are disabled in macOS System Settings. Enable them to display incoming Android alerts on your desktop." 
                            : "DroidLink needs macOS notification permission to display mirrored Android alerts.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Button(viewModel.notificationAuthorizationStatus == .denied ? "Open Settings" : "Allow Notifications") {
                        viewModel.requestNotificationPermission()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.25), lineWidth: 1)
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            
            Divider()
            
            // Quick Preferences Bar
            HStack(spacing: 20) {
                Toggle("Mirror Notifications", isOn: $viewModel.isNotificationMirroringEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                
                Toggle("Play Sound", isOn: $viewModel.playNotificationSound)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!viewModel.isNotificationMirroringEnabled)
                
                Toggle("Show App Icons", isOn: $viewModel.showNotificationAppIcons)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!viewModel.isNotificationMirroringEnabled)
                
                Spacer()
                
                if !viewModel.notificationHistory.isEmpty {
                    Button(action: { viewModel.clearNotificationHistory() }) {
                        Label("Clear History", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            
            Divider()
            
            // Notification History or Empty State
            if viewModel.notificationHistory.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    
                    Image(systemName: "bell.slash")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    
                    Text("No Notifications Mirrored Yet")
                        .font(.headline)
                    
                    Text("When your paired Android phone receives notifications, they will appear here and in macOS Notification Center in real time with the app's icon.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    
                    Button(action: {
                        triggerTestNotification()
                    }) {
                        Label(testAlertFeedback ? "Notification Sent!" : "Send Test Notification", systemImage: testAlertFeedback ? "checkmark" : "bell.badge")
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Spacer()
                }
                .padding(24)
            } else {
                List {
                    ForEach(viewModel.notificationHistory) { item in
                        NotificationRow(item: item, showIcons: viewModel.showNotificationAppIcons, formatter: relativeFormatter)
                            .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
    }
    
    private func triggerTestNotification() {
        NotificationManager.shared.postTestNotification()
        testAlertFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            testAlertFeedback = false
        }
    }
}

// MARK: - Notification Row

private struct NotificationRow: View {
    let item: MirroredNotificationItem
    let showIcons: Bool
    let formatter: RelativeDateTimeFormatter
    
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // App Icon
            if showIcons, let iconData = item.iconData, let img = NSImage(data: iconData) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .cornerRadius(7)
            } else {
                SquircleIcon(
                    icon: "app.badge.fill",
                    gradient: LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                    size: 32,
                    iconSize: 16
                )
            }
            
            // Content
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.appName)
                        .font(.system(size: 13, weight: .bold))
                    
                    Spacer()
                    
                    Text(formatter.localizedString(for: item.timestamp, relativeTo: Date()))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                if !item.title.isEmpty {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                }
                
                if !item.text.isEmpty {
                    Text(item.text)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
