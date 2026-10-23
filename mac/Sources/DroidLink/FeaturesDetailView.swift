import SwiftUI
import AppKit

struct FeaturesDetailView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Roadmap & Planned Features")
                        .font(.system(size: 22, weight: .bold))
                    Text("Upcoming local-first capabilities for Android & macOS integration")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Divider()
                
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    featureItem(
                        icon: "arrow.left.arrow.right",
                        color: .blue,
                        title: "File Transfer",
                        description: "High-speed local Wi-Fi and USB drag-and-drop file transfers with zero cloud relay.",
                        status: "Phase 1 - In Progress"
                    )
                    
                    featureItem(
                        icon: "display",
                        color: .indigo,
                        title: "Screen Mirroring",
                        description: "Low-latency H.264 screen mirroring with remote touch and keyboard input control.",
                        status: "Phase 1 - In Progress"
                    )
                    
                    featureItem(
                        icon: "video.fill",
                        color: .purple,
                        title: "Virtual Webcam & Mic",
                        description: "Use your Android high-resolution camera and microphone in Zoom, Meet, and FaceTime via AVFoundation.",
                        status: "Phase 2 - Planned"
                    )
                }
            }
            .padding(24)
        }
    }
    
    private func featureItem(icon: String, color: Color, title: String, description: String, status: String) -> some View {
        NativeCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SquircleIcon(
                        icon: icon,
                        gradient: LinearGradient(colors: [color, color.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        size: 36,
                        iconSize: 18
                    )
                    
                    Spacer()
                    
                    Text(status)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(color.opacity(0.12))
                        .clipShape(Capsule())
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
