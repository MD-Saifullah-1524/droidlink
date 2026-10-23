import Foundation

/// Handles chunking and reassembly of byte payloads over Bluetooth Low Energy (GATT).
public final class BleChunker {
    public enum ChunkFlag: UInt8 {
        case single = 0x00
        case start = 0x01
        case continuation = 0x02
        case end = 0x03
    }
    
    private var reassemblyBuffer = Data()
    
    public init() {}
    
    /// Splits a data payload into chunks that fit within maxPayloadSize (accounting for 1-byte header).
    public static func chunk(data: Data, maxChunkSize: Int) -> [Data] {
        guard maxChunkSize > 1 else { return [data] }
        let payloadCapacity = maxChunkSize - 1
        
        if data.count <= payloadCapacity {
            var singleChunk = Data(capacity: 1 + data.count)
            singleChunk.append(ChunkFlag.single.rawValue)
            singleChunk.append(data)
            return [singleChunk]
        }
        
        var chunks: [Data] = []
        var offset = 0
        let total = data.count
        
        while offset < total {
            let remaining = total - offset
            let count = min(remaining, payloadCapacity)
            let slice = data.subdata(in: offset..<(offset + count))
            
            var chunkData = Data(capacity: 1 + count)
            if offset == 0 {
                chunkData.append(ChunkFlag.start.rawValue)
            } else if offset + count >= total {
                chunkData.append(ChunkFlag.end.rawValue)
            } else {
                chunkData.append(ChunkFlag.continuation.rawValue)
            }
            chunkData.append(slice)
            chunks.append(chunkData)
            
            offset += count
        }
        
        return chunks
    }
    
    /// Feeds a received chunk into the reassembler.
    /// Returns the complete payload Data when the final chunk has arrived, or nil if still accumulating.
    public func feed(chunk: Data) -> Data? {
        guard !chunk.isEmpty else { return nil }
        guard let flag = ChunkFlag(rawValue: chunk[chunk.startIndex]) else {
            // Malformed chunk flag; discard buffer
            reassemblyBuffer.removeAll()
            return nil
        }
        
        let payload = chunk.subdata(in: (chunk.startIndex + 1)..<chunk.endIndex)
        
        switch flag {
        case .single:
            reassemblyBuffer.removeAll()
            return payload
            
        case .start:
            reassemblyBuffer = payload
            return nil
            
        case .continuation:
            reassemblyBuffer.append(payload)
            return nil
            
        case .end:
            reassemblyBuffer.append(payload)
            let complete = reassemblyBuffer
            reassemblyBuffer.removeAll()
            return complete
        }
    }
    
    /// Resets any accumulated reassembly state.
    public func reset() {
        reassemblyBuffer.removeAll()
    }
}
