import SwiftUI

struct QRCodeView: View {
    let qrCode: NSImage?
    var size: CGFloat = 220
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white)
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
            
            if let qrCode = qrCode {
                Image(nsImage: qrCode)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size - 28, height: size - 28)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Generating key...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: size, height: size)
            }
        }
        .padding(8)
    }
}