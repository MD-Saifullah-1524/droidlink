import SwiftUI

/// Bluetooth pairing status view for macOS
struct BluetoothPairingView: View {
    let deviceName: String
    var isAdvertising: Bool = true
    
    @State private var isPulsing: Bool = false
    
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Color.blue.opacity(0.15), lineWidth: 2)
                    .frame(width: 140, height: 140)
                    .scaleEffect(isPulsing ? 1.25 : 1.0)
                    .opacity(isPulsing ? 0.0 : 0.8)
                    .animation(
                        Animation.easeOut(duration: 2.0).repeatForever(autoreverses: false),
                        value: isPulsing
                    )
                
                Circle()
                    .stroke(Color.blue.opacity(0.3), lineWidth: 2)
                    .frame(width: 100, height: 100)
                    .scaleEffect(isPulsing ? 1.15 : 1.0)
                    .opacity(isPulsing ? 0.2 : 0.9)
                    .animation(
                        Animation.easeOut(duration: 2.0).repeatForever(autoreverses: false).delay(0.5),
                        value: isPulsing
                    )
                
                Circle()
                    .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 72, height: 72)
                    .shadow(color: .blue.opacity(0.3), radius: 8, x: 0, y: 4)
                
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 160, height: 160)
            .onAppear {
                isPulsing = true
            }
            
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isAdvertising ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(isAdvertising ? "Broadcasting over Bluetooth" : "Bluetooth Ready")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(isAdvertising ? .green : .orange)
                }
                
                Text(deviceName)
                    .font(.system(size: 20, weight: .bold))
                
                Text("Open DroidLink on your Android phone and tap 'Scan for Devices'.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "1.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Turn on Bluetooth on both devices")
                        .font(.caption)
                }
                HStack(spacing: 10) {
                    Image(systemName: "2.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Scan from DroidLink on Android")
                        .font(.caption)
                }
                HStack(spacing: 10) {
                    Image(systemName: "3.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Tap to pair with zero codes or passwords")
                        .font(.caption)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(10)
        }
        .padding(16)
    }
}
