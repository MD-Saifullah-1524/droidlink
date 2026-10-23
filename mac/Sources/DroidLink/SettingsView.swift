import SwiftUI
import AppKit

@MainActor
struct SettingsView: View {
    @ObservedObject var viewModel: ContentViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text("Settings")
                        .font(.system(size: 16, weight: .bold))
                }
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            
            Divider()
            
            SettingsDetailView(viewModel: viewModel, onNavigate: { _ in
                dismiss()
            })
        }
        .frame(minWidth: 540, minHeight: 480)
    }
}
