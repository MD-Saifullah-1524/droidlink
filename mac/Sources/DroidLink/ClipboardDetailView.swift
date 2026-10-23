import SwiftUI
import AppKit

struct ClipboardDetailView: View {
    @ObservedObject var viewModel: ContentViewModel
    @State private var manualText: String = ""
    @State private var copiedFeedback = false
    @State private var copiedItemIndex: Int? = nil
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Universal Clipboard")
                            .font(.system(size: 22, weight: .bold))
                        Text("Bi-directional instant clipboard synchronization")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    if !viewModel.isClipboardSyncEnabled {
                        StatusBadge(title: "Disabled", color: .gray, icon: "pause.circle.fill")
                    } else if viewModel.isIncognitoMode {
                        StatusBadge(title: "Incognito (Paused)", color: .orange, icon: "eye.slash.fill")
                    } else {
                        StatusBadge(title: "Sync Active", color: .blue, icon: "checkmark.circle.fill")
                    }
                }
                
                Divider()
                
                // Master Module Toggle Card
                NativeCard {
                    HStack(spacing: 16) {
                        SquircleIcon(
                            icon: "paperclip",
                            gradient: LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing),
                            size: 40,
                            iconSize: 20
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Universal Clipboard Sync")
                                .font(.system(size: 14, weight: .semibold))
                            Text(viewModel.isClipboardSyncEnabled ? "Continuously syncs clipboard content between your Mac and paired phone." : "Clipboard sync is disabled. No data will be sent or received.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $viewModel.isClipboardSyncEnabled)
                            .toggleStyle(.switch)
                    }
                }
                
                // Privacy Controls Bar
                HStack(spacing: 24) {
                    Toggle(isOn: $viewModel.isIncognitoMode) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Incognito Mode")
                                .font(.system(size: 13, weight: .medium))
                            Text("Temporarily pause syncing to protect private data")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(!viewModel.isClipboardSyncEnabled)
                    
                    Toggle(isOn: $viewModel.autoIgnoreSensitive) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Auto-Ignore Sensitive Data")
                                .font(.system(size: 13, weight: .medium))
                            Text("Skip passwords, OTPs, and concealed clips")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(!viewModel.isClipboardSyncEnabled)
                }
                
                // Active Clip Card
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Current Synced Clipboard")
                            .font(.headline)
                        
                        Spacer()
                        
                        if let clip = viewModel.lastClipboardText, !clip.isEmpty, viewModel.isClipboardSyncEnabled {
                            Text("\(clip.count) characters")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    NativeCard {
                        if !viewModel.isClipboardSyncEnabled {
                            HStack(spacing: 12) {
                                Image(systemName: "pause.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.secondary)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Clipboard Sync is Disabled")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Text("Turn on the master toggle above to start synchronizing your clipboard.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                                
                                Button("Enable Sync") {
                                    viewModel.isClipboardSyncEnabled = true
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(.vertical, 8)
                        } else if viewModel.isIncognitoMode {
                            HStack(spacing: 12) {
                                Image(systemName: "eye.slash.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.orange)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Clipboard Sync is Paused")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Text("Turn off Incognito Mode to resume syncing between Android and Mac.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                                
                                Button("Resume Sync") {
                                    viewModel.isIncognitoMode = false
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 8)
                        } else if let clip = viewModel.lastClipboardText, !clip.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(clip)
                                    .font(.system(size: 13, design: .monospaced))
                                    .lineLimit(6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(Color.primary.opacity(0.04))
                                    .cornerRadius(6)
                                
                                HStack {
                                    Spacer()
                                    
                                    Button(action: {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(clip, forType: .string)
                                        copiedFeedback = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                            copiedFeedback = false
                                        }
                                    }) {
                                        Label(copiedFeedback ? "Copied to Mac!" : "Copy to Mac Clipboard", systemImage: copiedFeedback ? "checkmark" : "doc.on.doc")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.regular)
                                }
                            }
                        } else {
                            HStack {
                                Spacer()
                                VStack(spacing: 8) {
                                    Image(systemName: "doc.on.clipboard")
                                        .font(.system(size: 30))
                                        .foregroundStyle(.secondary)
                                    Text("Copy any text on Android or Mac to see it sync here instantly.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 16)
                                Spacer()
                            }
                        }
                    }
                }
                
                // Manual Text Send Section
                VStack(alignment: .leading, spacing: 10) {
                    Text("Push Text Directly to Android")
                        .font(.headline)
                    
                    NativeCard {
                        VStack(spacing: 12) {
                            TextField("Type or paste text/URL to send to Android clipboard...", text: $manualText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13))
                            
                            HStack {
                                Spacer()
                                
                                Button("Push to Phone") {
                                    let textToSend = manualText.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !textToSend.isEmpty {
                                        viewModel.sendManualClipboard(text: textToSend)
                                        manualText = ""
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                }
                
                // Recent Sync History
                if !viewModel.clipboardHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Recent Clips History")
                                .font(.headline)
                            Spacer()
                            Button("Clear History") {
                                viewModel.clearClipboardHistory()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                        
                        VStack(spacing: 8) {
                            ForEach(Array(viewModel.clipboardHistory.enumerated()), id: \.offset) { index, item in
                                NativeCard(padding: 10) {
                                    HStack {
                                        Text(item)
                                            .font(.system(size: 12, design: .monospaced))
                                            .lineLimit(2)
                                        
                                        Spacer()
                                        
                                        Button(action: {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(item, forType: .string)
                                            copiedItemIndex = index
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                                if copiedItemIndex == index { copiedItemIndex = nil }
                                            }
                                        }) {
                                            Image(systemName: copiedItemIndex == index ? "checkmark" : "doc.on.doc")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Copy to clipboard")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}
