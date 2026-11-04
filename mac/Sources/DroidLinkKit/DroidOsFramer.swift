import Foundation

/// High-performance stream deframer and encoder for the droidOS 8-byte binary framing protocol.
public final class DroidOsFramer: @unchecked Sendable {
    private var streamBuffer = Data()
    private let lock = NSLock()

    public init() {}

    /// Appends incoming USB chunk data and deframes all complete packets.
    /// Returns an array of parsed messages.
    public func deframe(chunk: Data) -> [(type: DroidOsProtocol.MessageType, flags: UInt8, payload: Data)] {
        lock.lock()
        defer { lock.unlock() }

        streamBuffer.append(chunk)
        var results: [(type: DroidOsProtocol.MessageType, flags: UInt8, payload: Data)] = []

        while streamBuffer.count >= DroidOsProtocol.headerSize {
            // Validate magic bytes
            let b0 = streamBuffer[streamBuffer.startIndex]
            let b1 = streamBuffer[streamBuffer.startIndex + 1]

            if b0 != DroidOsProtocol.magicByte0 || b1 != DroidOsProtocol.magicByte1 {
                // Not aligned with 'D','O' magic. Scan forward for next occurrence of 'D','O'.
                var foundIndex: Int? = nil
                for i in (streamBuffer.startIndex + 1)..<(streamBuffer.endIndex - 1) {
                    if streamBuffer[i] == DroidOsProtocol.magicByte0 && streamBuffer[i + 1] == DroidOsProtocol.magicByte1 {
                        foundIndex = i
                        break
                    }
                }

                if let idx = foundIndex {
                    streamBuffer.removeSubrange(streamBuffer.startIndex..<idx)
                } else {
                    // Discard up to the last byte to keep room for a split magic across chunks
                    let keep = streamBuffer.suffix(1)
                    streamBuffer = Data(keep)
                    break
                }
                continue
            }

            // Extract Header
            let rawType = streamBuffer[streamBuffer.startIndex + 2]
            let flags = streamBuffer[streamBuffer.startIndex + 3]

            let lengthSlice = streamBuffer.subdata(in: (streamBuffer.startIndex + 4)..<(streamBuffer.startIndex + 8))
            let payloadLength = lengthSlice.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

            // Guard against corrupt length exceeding reasonable bounds (e.g. 16MB)
            if payloadLength > 16_777_216 {
                // Drop current magic and resync
                streamBuffer.removeSubrange(streamBuffer.startIndex..<(streamBuffer.startIndex + 2))
                continue
            }

            let totalFrameSize = DroidOsProtocol.headerSize + Int(payloadLength)
            if streamBuffer.count < totalFrameSize {
                // Frame is still being received; wait for next chunk
                break
            }

            // Complete frame arrived
            let payloadStart = streamBuffer.startIndex + DroidOsProtocol.headerSize
            let payloadEnd = payloadStart + Int(payloadLength)
            let payload = streamBuffer.subdata(in: payloadStart..<payloadEnd)

            streamBuffer.removeSubrange(streamBuffer.startIndex..<payloadEnd)

            let msgType = DroidOsProtocol.MessageType(rawValue: rawType) ?? .unknown
            results.append((type: msgType, flags: flags, payload: payload))
        }

        return results
    }

    /// Resets the internal buffer
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        streamBuffer.removeAll()
    }
}
