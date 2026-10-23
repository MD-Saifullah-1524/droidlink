package com.droidlink.app.display

import android.media.MediaCodec
import android.media.MediaFormat
import android.view.Surface
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.nio.ByteBuffer

/**
 * Low-latency hardware H.264 video decoder for external display streaming.
 * Feeds NALUs directly to MediaCodec configured to output onto a SurfaceView Surface,
 * achieving zero-copy hardware presentation with sub-frame latency.
 */
class ExternalDisplayDecoder(
    private val surface: Surface,
    private val width: Int = 1920,
    private val height: Int = 1080,
    private val scope: CoroutineScope
) {
    companion object {
        private const val TAG = "ExternalDisplayDecoder"
        private const val MIME_TYPE = "video/avc"
        private const val INPUT_TIMEOUT_US = 10_000L // 10ms timeout prevents frame drops during burst cursor movements
        private const val OUTPUT_TIMEOUT_US = 1_000L
    }

    private var mediaCodec: MediaCodec? = null
    private var isRunning = false
    private var drainJob: Job? = null
    private var frameCount = 0

    var onFrameRendered: ((frameNum: Int, latencyMs: Long) -> Unit)? = null

    init {
        start()
    }

    /**
     * Initializes the hardware MediaCodec decoder and starts the output rendering loop
     */
    fun start() {
        if (isRunning) return
        var codec: MediaCodec? = null

        try {
            val format = MediaFormat.createVideoFormat(MIME_TYPE, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                // Set low latency decoder options if available (Android 11+)
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                    setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                }
                setInteger(MediaFormat.KEY_PRIORITY, 0) // Realtime priority
                setInteger(MediaFormat.KEY_OPERATING_RATE, 120) // Boost VPU hardware clock rate
            }

            codec = MediaCodec.createDecoderByType(MIME_TYPE)
            codec.configure(format, surface, null, 0)
            codec.start()

            mediaCodec = codec
            isRunning = true
            frameCount = 0

            // Start draining output buffers in background
            startDrainLoop()
            Log.i(TAG, "✅ Hardware H.264 decoder started ($width x $height, low-latency=1, priority=0)")
        } catch (e: Throwable) {
            Log.e(TAG, "Failed to start MediaCodec decoder", e)
            isRunning = false
            try {
                codec?.release()
            } catch (_: Exception) {}
            mediaCodec = null
        }
    }

    /**
     * Feeds an incoming compressed H.264 video frame (Annex B NALUs) into the decoder
     */
    fun queueFrame(frameData: ByteArray, isKeyframe: Boolean, frameNumber: Int, timestamp: Long) {
        if (!isRunning) return
        val codec = mediaCodec ?: return

        try {
            // 1. Eagerly drain ready output buffers non-blocking to keep hardware pipeline clear
            drainOutputBuffers(0L)

            // 2. Dequeue input buffer with 10ms timeout to avoid frame drops during fast cursor motion
            val inputIndex = codec.dequeueInputBuffer(INPUT_TIMEOUT_US)
            if (inputIndex >= 0) {
                val inputBuffer = codec.getInputBuffer(inputIndex) ?: return
                inputBuffer.clear()
                inputBuffer.put(frameData)

                val flags = if (isKeyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                // Use 0L presentation timestamp for immediate hardware surface presentation without vsync jitter
                codec.queueInputBuffer(inputIndex, 0, frameData.size, 0L, flags)
            } else {
                Log.w(TAG, "Decoder input buffer full after ${INPUT_TIMEOUT_US}us; dropping frame $frameNumber")
            }

            // 3. Eagerly drain again immediately after queuing
            drainOutputBuffers(0L)
        } catch (e: Throwable) {
            Log.e(TAG, "Error queuing frame $frameNumber", e)
        }
    }

    private fun drainOutputBuffers(timeoutUs: Long) {
        val codec = mediaCodec ?: return
        val bufferInfo = MediaCodec.BufferInfo()
        try {
            while (isRunning) {
                val outputIndex = codec.dequeueOutputBuffer(bufferInfo, timeoutUs)
                if (outputIndex >= 0) {
                    codec.releaseOutputBuffer(outputIndex, true)
                    frameCount++
                    onFrameRendered?.invoke(frameCount, 0L)
                } else if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    Log.i(TAG, "Decoder output format changed: ${codec.outputFormat}")
                } else {
                    break
                }
            }
        } catch (e: Throwable) {
            if (isRunning) {
                Log.w(TAG, "Drain error: ${e.message}")
            }
        }
    }

    private fun startDrainLoop() {
        drainJob?.cancel()
        drainJob = scope.launch(Dispatchers.Default) {
            while (isActive && isRunning) {
                drainOutputBuffers(OUTPUT_TIMEOUT_US)
            }
        }
    }

    /**
     * Stops and releases the decoder resources
     */
    fun release() {
        isRunning = false
        drainJob?.cancel()
        drainJob = null

        try {
            mediaCodec?.stop()
            mediaCodec?.release()
        } catch (e: Throwable) {
            Log.w(TAG, "Error releasing MediaCodec", e)
        } finally {
            mediaCodec = null
            Log.i(TAG, "🛑 Decoder released")
        }
    }
}
