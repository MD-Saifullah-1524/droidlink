import Foundation
import CryptoKit

/// Hardware-accelerated AES-256-GCM authenticated encryption channel
public final class CryptoChannel: Sendable {
    private let key: SymmetricKey
    
    public init(keyData: Data) throws {
        guard keyData.count == 32 else {
            throw CryptoError.invalidKeyLength(expected: 32, actual: keyData.count)
        }
        self.key = SymmetricKey(data: keyData)
    }
    
    /// Encrypt plaintext with AES-256-GCM.
    /// Wire output format: [12 bytes nonce] + [ciphertext] + [16 bytes tag]
    public func encrypt(_ plaintext: Data) throws -> Data {
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        guard let combined = sealedBox.combined else {
            throw CryptoError.encryptionFailed
        }
        return combined
    }
    
    /// Decrypt ciphertext with AES-256-GCM.
    /// Expects wire format: [12 bytes nonce] + [ciphertext] + [16 bytes tag]
    public func decrypt(_ combinedCiphertext: Data) throws -> Data {
        guard combinedCiphertext.count >= 28 else { // 12-byte nonce + 16-byte tag
            throw CryptoError.invalidCiphertextLength
        }
        let sealedBox = try AES.GCM.SealedBox(combined: combinedCiphertext)
        return try AES.GCM.open(sealedBox, using: key)
    }
    
    /// Generates a secure random 256-bit (32 bytes) session key.
    public static func generateSessionKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
}

public enum CryptoError: Error, LocalizedError {
    case invalidKeyLength(expected: Int, actual: Int)
    case invalidCiphertextLength
    case encryptionFailed
    
    public var errorDescription: String? {
        switch self {
        case .invalidKeyLength(let exp, let act):
            return "Invalid key length: expected \(exp), got \(act)"
        case .invalidCiphertextLength:
            return "Ciphertext too short (minimum 28 bytes required for AES-GCM)"
        case .encryptionFailed:
            return "AES-GCM encryption failed"
        }
    }
}
