package com.droidlink.core.network

import android.util.Log
import com.droidlink.core.network.protocol.MessageFramer
import com.droidlink.core.security.CryptoChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Robust, encrypted, length-prefixed ultra-low latency TCP client for Android 15+
 */
class TcpClient(
    private val host: String,
    private val port: Int,
    private val cryptoChannel: CryptoChannel? = null
) {
    private var socket: Socket? = null
    private var dataInputStream: DataInputStream? = null
    private var outputStream: OutputStream? = null
    private val framer = MessageFramer()
    private val sendMutex = Mutex()

    companion object {
        private const val TAG = "TcpClient"
        private const val CONNECT_TIMEOUT_MS = 5000
    }

    /**
     * Connects to the remote Mac TCP server with timeout
     */
    suspend fun connect() = withContext(Dispatchers.IO) {
        Log.d(TAG, "Connecting to $host:$port...")
        val newSocket = Socket()
        newSocket.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
        newSocket.tcpNoDelay = true
        newSocket.receiveBufferSize = 1024 * 1024
        newSocket.sendBufferSize = 1024 * 1024

        socket = newSocket
        dataInputStream = DataInputStream(BufferedInputStream(newSocket.getInputStream(), 256 * 1024))
        outputStream = BufferedOutputStream(newSocket.getOutputStream(), 256 * 1024)
        Log.d(TAG, "✅ Connected to $host:$port (TCP_NODELAY=true, Buf=1MB)")
    }

    /**
     * Encrypts (if CryptoChannel present), frames, and sends raw payload bytes.
     * Synchronized via Mutex to prevent byte interleaving on the socket across concurrent coroutines.
     */
    suspend fun send(payload: ByteArray) = withContext(Dispatchers.IO) {
        val encrypted = cryptoChannel?.encrypt(payload) ?: payload
        val frame = framer.frame(encrypted)
        sendMutex.withLock {
            val out = outputStream ?: throw IllegalStateException("Not connected")
            out.write(frame)
            out.flush()
        }
    }

    /**
     * Reads incoming stream bytes directly with zero intermediate array copying or GC thrashing.
     * Blocks until a complete frame is deframed and decrypted, or returns empty list if stream closed.
     */
    suspend fun receiveMessages(): List<ByteArray> = withContext(Dispatchers.IO) {
        val input = dataInputStream ?: return@withContext emptyList()
        val header = ByteArray(MessageFramer.HEADER_SIZE)

        try {
            while (true) {
                // 1. Read exact 4-byte header
                input.readFully(header)

                val b1 = header[0].toInt() and 0xFF
                val b2 = header[1].toInt() and 0xFF
                val b3 = header[2].toInt() and 0xFF
                val length = (b1 shl 16) or (b2 shl 8) or b3
                val typeCode = header[3].toInt() and 0xFF

                if (length > MessageFramer.MAX_FRAME_SIZE) {
                    Log.e(TAG, "Frame too large: $length bytes; closing connection")
                    close()
                    return@withContext emptyList()
                }

                // 2. Read payload directly into array
                val payload = if (length > 0) {
                    val buf = ByteArray(length)
                    input.readFully(buf)
                    buf
                } else {
                    ByteArray(0)
                }

                when (MessageFramer.FrameType.fromCode(typeCode)) {
                    MessageFramer.FrameType.DATA -> {
                        val decrypted = cryptoChannel?.decrypt(payload) ?: payload
                        return@withContext listOf(decrypted)
                    }
                    MessageFramer.FrameType.HEARTBEAT -> {
                        // Heartbeat frame; loop to next frame
                    }
                    MessageFramer.FrameType.ERROR -> {
                        Log.e(TAG, "Remote error frame received: ${String(payload, Charsets.UTF_8)}")
                        return@withContext emptyList()
                    }
                    null -> {
                        Log.w(TAG, "Unknown frame type code $typeCode")
                    }
                }
            }
        } catch (e: EOFException) {
            Log.d(TAG, "Socket stream closed (EOF)")
            close()
        } catch (e: Exception) {
            if (isConnected) {
                Log.e(TAG, "Socket read error: ${e.message}")
            }
            close()
        }
        return@withContext emptyList()
    }

    /**
     * Closes the connection and releases resources
     */
    suspend fun close() = withContext(Dispatchers.IO) {
        try {
            dataInputStream?.close()
            outputStream?.close()
            socket?.close()
        } catch (e: Exception) {
            Log.e(TAG, "Error closing socket", e)
        } finally {
            socket = null
            dataInputStream = null
            outputStream = null
            Log.d(TAG, "Connection closed")
        }
    }

    val isConnected: Boolean
        get() = socket?.isConnected == true && socket?.isClosed == false
}