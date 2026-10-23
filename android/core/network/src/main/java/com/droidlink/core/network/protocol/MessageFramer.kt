package com.droidlink.core.network.protocol

import java.io.ByteArrayOutputStream

/**
 * Frames and deframes messages with a 4-byte header.
 *
 * Frame format:
 * ┌────────────────────────────────────────┐
 * │  Header (4 bytes)                      │
 * │  ├─ Length (3 bytes, big-endian)      │
 * │  └─ Type (1 byte)                     │
 * ├────────────────────────────────────────┤
 * │  Payload (variable length)            │
 * └────────────────────────────────────────┘
 */
class MessageFramer {

    companion object {
        const val HEADER_SIZE = 4
        const val MAX_FRAME_SIZE = 16 * 1024 * 1024 // 16MB
    }

    enum class FrameType(val code: Int) {
        DATA(0x01),
        HEARTBEAT(0x02),
        ERROR(0x03);

        companion object {
            fun fromCode(code: Int): FrameType? = entries.find { it.code == code }
        }
    }

    /**
     * Frame a message with a 4-byte header.
     */
    fun frame(message: ByteArray, type: FrameType = FrameType.DATA): ByteArray {
        val length = message.size
        require(length <= MAX_FRAME_SIZE) {
            "Message too large: $length bytes (max $MAX_FRAME_SIZE)"
        }

        val frame = ByteArray(HEADER_SIZE + length)
        frame[0] = ((length shr 16) and 0xFF).toByte()
        frame[1] = ((length shr 8) and 0xFF).toByte()
        frame[2] = (length and 0xFF).toByte()
        frame[3] = type.code.toByte()

        System.arraycopy(message, 0, frame, HEADER_SIZE, length)
        return frame
    }

    /**
     * Frame a heartbeat ping.
     */
    fun frameHeartbeat(): ByteArray {
        return ByteArray(HEADER_SIZE).apply {
            this[3] = FrameType.HEARTBEAT.code.toByte()
        }
    }

    /**
     * Accumulates incoming stream bytes and extracts complete frames.
     * Consumes complete frames from [buffer] and returns them as a list of raw byte payloads.
     */
    fun deframe(buffer: ByteArrayOutputStream): List<ByteArray> {
        val currentBytes = buffer.toByteArray()
        if (currentBytes.size < HEADER_SIZE) return emptyList()

        val completeMessages = mutableListOf<ByteArray>()
        var offset = 0

        while (currentBytes.size - offset >= HEADER_SIZE) {
            val b1 = currentBytes[offset].toInt() and 0xFF
            val b2 = currentBytes[offset + 1].toInt() and 0xFF
            val b3 = currentBytes[offset + 2].toInt() and 0xFF
            val length = (b1 shl 16) or (b2 shl 8) or b3
            val typeCode = currentBytes[offset + 3].toInt() and 0xFF

            if (length > MAX_FRAME_SIZE) {
                buffer.reset()
                throw FrameException("Frame too large: $length bytes (max $MAX_FRAME_SIZE)")
            }

            val totalFrameSize = HEADER_SIZE + length
            if (currentBytes.size - offset < totalFrameSize) {
                // Incomplete frame, wait for more data
                break
            }

            val type = FrameType.fromCode(typeCode)
            if (type == null) {
                buffer.reset()
                throw FrameException("Unknown frame type: $typeCode")
            }

            val payload = ByteArray(length)
            System.arraycopy(currentBytes, offset + HEADER_SIZE, payload, 0, length)
            offset += totalFrameSize

            when (type) {
                FrameType.DATA -> completeMessages.add(payload)
                FrameType.HEARTBEAT -> Unit // Keep-alive ping, no payload
                FrameType.ERROR -> throw FrameException("Remote error: ${String(payload, Charsets.UTF_8)}")
            }
        }

        // Retain unconsumed bytes in buffer
        val remainingBytes = currentBytes.size - offset
        buffer.reset()
        if (remainingBytes > 0) {
            buffer.write(currentBytes, offset, remainingBytes)
        }

        return completeMessages
    }
}

class FrameException(message: String) : Exception(message)
