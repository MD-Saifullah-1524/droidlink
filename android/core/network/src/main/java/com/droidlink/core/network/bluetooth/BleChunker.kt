package com.droidlink.core.network.bluetooth

import java.io.ByteArrayOutputStream

/**
 * Handles chunking and reassembly of byte payloads over Bluetooth Low Energy (GATT).
 * Matches the macOS BleChunker framing protocol.
 */
class BleChunker {
    companion object {
        const val FLAG_SINGLE: Byte = 0x00
        const val FLAG_START: Byte = 0x01
        const val FLAG_CONTINUATION: Byte = 0x02
        const val FLAG_END: Byte = 0x03

        fun chunk(data: ByteArray, maxChunkSize: Int): List<ByteArray> {
            if (maxChunkSize <= 1) return listOf(data)
            val payloadCapacity = maxChunkSize - 1

            if (data.size <= payloadCapacity) {
                val single = ByteArray(1 + data.size)
                single[0] = FLAG_SINGLE
                System.arraycopy(data, 0, single, 1, data.size)
                return listOf(single)
            }

            val chunks = mutableListOf<ByteArray>()
            var offset = 0
            val total = data.size

            while (offset < total) {
                val remaining = total - offset
                val count = minOf(remaining, payloadCapacity)
                val chunk = ByteArray(1 + count)

                if (offset == 0) {
                    chunk[0] = FLAG_START
                } else if (offset + count >= total) {
                    chunk[0] = FLAG_END
                } else {
                    chunk[0] = FLAG_CONTINUATION
                }

                System.arraycopy(data, offset, chunk, 1, count)
                chunks.add(chunk)

                offset += count
            }

            return chunks
        }
    }

    private val reassemblyStream = ByteArrayOutputStream()

    /**
     * Feeds a received chunk into the reassembler.
     * Returns the complete payload when the final chunk has arrived, or null if still accumulating.
     */
    fun feed(chunk: ByteArray): ByteArray? {
        if (chunk.isEmpty()) return null
        val flag = chunk[0]
        val payloadLength = chunk.size - 1

        when (flag) {
            FLAG_SINGLE -> {
                reassemblyStream.reset()
                val payload = ByteArray(payloadLength)
                System.arraycopy(chunk, 1, payload, 0, payloadLength)
                return payload
            }
            FLAG_START -> {
                reassemblyStream.reset()
                reassemblyStream.write(chunk, 1, payloadLength)
                return null
            }
            FLAG_CONTINUATION -> {
                reassemblyStream.write(chunk, 1, payloadLength)
                return null
            }
            FLAG_END -> {
                reassemblyStream.write(chunk, 1, payloadLength)
                val complete = reassemblyStream.toByteArray()
                reassemblyStream.reset()
                return complete
            }
            else -> {
                // Unknown flag; reset buffer
                reassemblyStream.reset()
                return null
            }
        }
    }

    fun reset() {
        reassemblyStream.reset()
    }
}
