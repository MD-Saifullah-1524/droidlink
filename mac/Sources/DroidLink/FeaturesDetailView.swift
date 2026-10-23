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
                        icon: "folder.fill",
                        color: .blue,
                        title: "Android Storage in Finder",
                        description: "Native macOS NSFileProvider integration with supercharged AOA 2.0 wire speed and local Wi-Fi fallback.",
                        status: "Available Now"
                    )
                    
                    featureItem(
                        icon: "iphone",
                        color: .teal,
                        title: "Phone Screen & Control",
                        description: "Low-latency reverse screen mirroring with native hardware USB HID mouse & keyboard and AOD privacy mode.",
                        status: "Available Now"
                    )
                    
                    featureItem(
                        icon: "display.2",
                        color: .indigo,
                        title: "External Display for Mac",
                        description: "Use your Android tablet or phone as an ultra-low latency extended macOS monitor over direct USB.",
                        status: "Available Now"
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
