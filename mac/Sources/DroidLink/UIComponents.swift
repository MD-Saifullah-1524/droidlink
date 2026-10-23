import SwiftUI
import AppKit

// MARK: - Squircle Icon

struct SquircleIcon: View {
    let icon: String
    let gradient: LinearGradient
    var size: CGFloat = 32
    var iconSize: CGFloat = 16
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(gradient)
                .frame(width: size, height: size)
            
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Static Status Badge (High Performance, No Looping Shaders)

struct StatusBadge: View {
    let title: String
    let color: Color
    var icon: String? = nil
    
    var body: some View {
        HStack(spacing: 5) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

// MARK: - Native Card Container

struct NativeCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(padding)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
