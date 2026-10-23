import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// QR code generator for device pairing with dynamic host IP and session key
public class QRCodeGenerator {
    private let context = CIContext()
    
    public init() {}
    
    /// Generate QR code for pairing
    public func generateQRCode(
        deviceId: String,
        deviceName: String,
        host: String,
        port: UInt16,
        sessionKey: Data
    ) -> (image: NSImage, token: PairingToken)? {
        let token = PairingToken(
            version: "2.0.0",
            deviceId: deviceId,
            deviceName: deviceName,
            host: host,
            port: port,
            sessionKey: sessionKey.base64EncodedString(),
            timestamp: Int(Date().timeIntervalSince1970)
        )
        
        guard let tokenData = try? JSONEncoder().encode(token),
              let tokenString = String(data: tokenData, encoding: .utf8) else {
            return nil
        }
        
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(tokenString.utf8)
        filter.correctionLevel = "M"
        
        guard let outputImage = filter.outputImage else {
            return nil
        }
        
        // Scale to 300x300 for crisp scanning
        let scale = 300.0 / outputImage.extent.width
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }
        
        return (NSImage(cgImage: cgImage, size: NSSize(width: 300, height: 300)), token)
    }
}

/// Pairing token encoded in QR code
public struct PairingToken: Codable {
    public let version: String
    public let deviceId: String
    public let deviceName: String
    public let host: String
    public let port: UInt16
    public let sessionKey: String
    public let timestamp: Int
}