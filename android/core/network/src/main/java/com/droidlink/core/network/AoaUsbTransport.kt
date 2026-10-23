package com.droidlink.core.network

import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.ParcelFileDescriptor
import android.util.Log
import com.droidlink.core.network.protocol.MessageFramer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream

/**
 * High-speed direct point-to-point USB transport utilizing Android Open Accessory (AOA 2.0).
 * Does NOT require ADB, USB debugging, developer options, or Wi-Fi networking.
 */
class AoaUsbTransport(
    private val usbManager: UsbManager
) {
    private var pfd: ParcelFileDescriptor? = null
    private var rawInputStream: FileInputStream? = null
    private var rawOutputStream: FileOutputStream? = null
    private val framer = MessageFramer()
    private val sendMutex = Mutex()
    private val rxStreamBuffer = java.io.ByteArrayOutputStream()
    private val readBuffer = ByteArray(65536)

    var isConnected: Boolean = false
        private set

    companion object {
        private const val TAG = "AoaUsbTransport"
        const val ACCESSORY_MANUFACTURER = "DroidLink"
        const val ACCESSORY_MODEL = "DroidLink Display"
    }

    /**
     * Connects to the given UsbAccessory using UsbManager.openAccessory()
     */
    suspend fun connect(accessory: UsbAccessory) = withContext(Dispatchers.IO) {
        close()
        Log.i(TAG, "🔌 Opening AOA accessory: ${accessory.manufacturer} - ${accessory.model} (v${accessory.version})...")

        val descriptor = usbManager.openAccessory(accessory)
        if (descriptor == null) {
            Log.e(TAG, "❌ Failed to open UsbAccessory. Permission denied or accessory unavailable.")
            return@withContext false
        }

        pfd = descriptor
        val fd = descriptor.fileDescriptor
        // Android AOA kernel driver (/dev/usb_accessory) requires raw streaming with chunk sizes <= 16384 bytes
        rawInputStream = FileInputStream(fd)
        rawOutputStream = FileOutputStream(fd)
        isConnected = true
        Log.i(TAG, "⚡ AOA USB Transport connected successfully! Bulk streams initialized (16KB kernel aligned).")
        true
    }

    /**
     * Frames and sends payload bytes across the USB bulk pipe in strict 16KB chunks
     */
    suspend fun send(payload: ByteArray) = withContext(Dispatchers.IO) {
        if (!isConnected) return@withContext
        val frame = framer.frame(payload)
        sendMutex.withLock {
            val out = rawOutputStream ?: return@withLock
            try {
                var offset = 0
                while (offset < frame.size) {
                    val chunk = minOf(frame.size - offset, 16384)
                    out.write(frame, offset, chunk)
                    offset += chunk
                }
                out.flush()
            } catch (e: Exception) {
                Log.e(TAG, "Error writing to AOA USB bulk stream", e)
                close()
            }
        }
    }

    /**
     * Reads incoming deframed Protocol Buffer messages directly from the USB bulk endpoint.
     * Uses a full packet buffer read to prevent Linux kernel gadget driver packet truncation.
     */
    suspend fun receiveMessages(): List<ByteArray> = withContext(Dispatchers.IO) {
        val input = rawInputStream ?: return@withContext emptyList()
        try {
            while (isConnected) {
                // First drain any complete messages already queued in stream buffer
                val existing = framer.deframe(rxStreamBuffer)
                if (existing.isNotEmpty()) {
                    return@withContext existing
                }

                val bytesRead = input.read(readBuffer)
                if (bytesRead < 0) {
                    throw EOFException("AOA USB unexpected EOF")
                }
                if (bytesRead > 0) {
                    rxStreamBuffer.write(readBuffer, 0, bytesRead)
                    val messages = framer.deframe(rxStreamBuffer)
                    if (messages.isNotEmpty()) {
                        return@withContext messages
                    }
                }
            }
            emptyList()
        } catch (e: EOFException) {
            Log.i(TAG, "AOA USB stream reached EOF; disconnected")
            close()
            emptyList()
        } catch (e: Exception) {
            if (isConnected) {
                Log.e(TAG, "AOA USB read error: ${e.message}")
            }
            close()
            emptyList()
        }
    }

    /**
     * Closes the accessory file descriptor and clears buffers
     */
    fun close() {
        isConnected = false
        rxStreamBuffer.reset()
        try {
            rawInputStream?.close()
        } catch (_: Exception) {}
        try {
            rawOutputStream?.close()
        } catch (_: Exception) {}
        try {
            pfd?.close()
        } catch (_: Exception) {}
        rawInputStream = null
        rawOutputStream = null
        pfd = null
        Log.d(TAG, "AOA USB Transport closed")
    }
}
