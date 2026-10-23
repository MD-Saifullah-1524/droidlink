package com.droidlink.app.screen

import android.content.Context
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.util.Log
import android.view.Display
import android.view.Surface
import android.view.WindowManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.nio.ByteBuffer

/**
 * Captures the Android screen using MediaProjection, encodes to H.264 via hardware MediaCodec,
 * and streams high-definition video frames with zero ADB requirement.
 * Dynamically handles screen rotation, resolution updates, and High Profile encoding.
 */
class ScreenCaptureManager(
    private val context: Context,
    private val mediaProjection: MediaProjection,
    private val scope: CoroutineScope,
    private val onFrameEncoded: (frameData: ByteArray, isKeyframe: Boolean, frameNumber: Int, timestamp: Long) -> Unit,
    private val onScreenMetricsChanged: (width: Int, height: Int, rotation: Int, dpi: Int) -> Unit
) {

    companion object {
        private const val TAG = "ScreenCaptureManager"
        private const val MIME_TYPE = "video/avc"
        private const val DEFAULT_FPS = 60
        private const val DEFAULT_BITRATE = 8_000_000 // 8 Mbps for smooth real-time stream over Wi-Fi
        private const val I_FRAME_INTERVAL = 1 // 1 second
    }

    private val displayManager = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private var virtualDisplay: VirtualDisplay? = null
    private var mediaCodec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var isStreaming = false
    private var encodeJob: Job? = null
    private var frameCount = 0

    private var currentFps = DEFAULT_FPS
    private var currentBitrate = DEFAULT_BITRATE

    private var spsPpsHeader: ByteArray? = null
    private var displayMetrics = DisplayMetrics()
    private var currentWidth = 1080
    private var currentHeight = 2400
    private var currentDensity = 420
    private var currentRotation = 0

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            Log.i(TAG, "MediaProjection session stopped by system")
            com.droidlink.app.service.DroidLinkService.setMediaProjectionInstance(null)
            stop()
        }
    }

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {}
        override fun onDisplayRemoved(displayId: Int) {}
        override fun onDisplayChanged(displayId: Int) {
            if (displayId == Display.DEFAULT_DISPLAY && isStreaming) {
                handleDisplayOrientationChange()
            }
        }
    }

    init {
        updateDisplayMetrics()
    }

    private fun updateDisplayMetrics(): Boolean {
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val display = wm.defaultDisplay
        display.getRealMetrics(displayMetrics)

        val newRotation = display.rotation * 90
        val newDensity = displayMetrics.densityDpi

        // Align dimensions to multiples of 16 for H.264 encoder compatibility
        var w = displayMetrics.widthPixels
        var h = displayMetrics.heightPixels

        // Clamp max dimension to 1080p (1920) for smooth, low-latency Wi-Fi mirroring
        val maxDim = 1920
        if (Math.max(w, h) > maxDim) {
            val scale = maxDim.toFloat() / Math.max(w, h).toFloat()
            w = (w * scale).toInt()
            h = (h * scale).toInt()
        }

        val alignedW = (w / 16) * 16
        val alignedH = (h / 16) * 16

        val metricsChanged = (alignedW != currentWidth || alignedH != currentHeight || newRotation != currentRotation)

        currentWidth = alignedW
        currentHeight = alignedH
        currentRotation = newRotation
        currentDensity = newDensity

        Log.i(TAG, "Screen metrics: ${currentWidth}x${currentHeight}, rotation=$currentRotation°, dpi=$currentDensity")
        onScreenMetricsChanged(currentWidth, currentHeight, currentRotation, currentDensity)
        return metricsChanged
    }

    /**
     * Starts the H.264 screen capture and hardware encoding pipeline.
     */
    @Synchronized
    fun start(targetFps: Int = DEFAULT_FPS, targetBitrate: Int = DEFAULT_BITRATE) {
        if (isStreaming) {
            Log.w(TAG, "Screen capture already streaming")
            return
        }

        currentFps = if (targetFps > 0) targetFps else DEFAULT_FPS
        currentBitrate = if (targetBitrate > 0) targetBitrate else DEFAULT_BITRATE

        updateDisplayMetrics()

        try {
            Log.i(TAG, "Initializing MediaCodec encoder for ${currentWidth}x${currentHeight} at ${currentFps}fps, ${currentBitrate / 1000}kbps...")
            val codec = createAndStartCodec(currentWidth, currentHeight, currentFps, currentBitrate)
            val surface = codec.createInputSurface()
            codec.start()

            mediaCodec = codec
            inputSurface = surface

            try {
                mediaProjection.registerCallback(projectionCallback, mainHandler)
            } catch (e: Exception) {
                Log.w(TAG, "MediaProjection callback registration error: ${e.message}")
            }

            try {
                displayManager.registerDisplayListener(displayListener, mainHandler)
            } catch (e: Exception) {
                Log.w(TAG, "DisplayListener registration error: ${e.message}")
            }

            val flags = DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR or DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC
            virtualDisplay = mediaProjection.createVirtualDisplay(
                "DroidLinkMirrorDisplay",
                currentWidth,
                currentHeight,
                currentDensity,
                flags,
                surface,
                null,
                null
            )

            isStreaming = true
            frameCount = 0
            spsPpsHeader = null

            encodeJob = scope.launch(Dispatchers.IO) {
                runEncoderLoop()
            }

            Log.i(TAG, "✅ Screen capture & H.264 High-Profile pipeline started at ${currentWidth}x${currentHeight}!")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start screen capture: ${e.message}", e)
            com.droidlink.app.service.DroidLinkService.setMediaProjectionInstance(null)
            stop()
        }
    }

    private fun createAndStartCodec(width: Int, height: Int, fps: Int, bitrate: Int): MediaCodec {
        val format = MediaFormat.createVideoFormat(MIME_TYPE, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, I_FRAME_INTERVAL)
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)

            // High Profile & Level 5.1 for crisp text and high compression quality
            try {
                setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileHigh)
                setInteger(MediaFormat.KEY_LEVEL, MediaCodecInfo.CodecProfileLevel.AVCLevel51)
            } catch (e: Exception) {
                Log.w(TAG, "High profile not supported; falling back to default profile")
            }

            // Low-latency real-time encoding
            try {
                setInteger(MediaFormat.KEY_LATENCY, 0)
                setInteger(MediaFormat.KEY_PRIORITY, 0)
            } catch (e: Exception) {
                // Ignore
            }
        }

        val codec = MediaCodec.createEncoderByType(MIME_TYPE)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        return codec
    }

    private fun handleDisplayOrientationChange() {
        scope.launch(Dispatchers.Main) {
            synchronized(this@ScreenCaptureManager) {
                if (!isStreaming) return@launch

                val oldWidth = currentWidth
                val oldHeight = currentHeight
                val changed = updateDisplayMetrics()

                if (changed && (oldWidth != currentWidth || oldHeight != currentHeight)) {
                    Log.i(TAG, "🔄 Display orientation rotated: adapting encoder to ${currentWidth}x${currentHeight}...")
                    reconfigureEncoder(currentWidth, currentHeight)
                } else {
                    requestKeyframe()
                }
            }
        }
    }

    private fun reconfigureEncoder(newWidth: Int, newHeight: Int) {
        try {
            encodeJob?.cancel()
            encodeJob = null

            mediaCodec?.stop()
            mediaCodec?.release()
            inputSurface?.release()

            val codec = createAndStartCodec(newWidth, newHeight, currentFps, currentBitrate)
            val surface = codec.createInputSurface()
            codec.start()

            mediaCodec = codec
            inputSurface = surface
            spsPpsHeader = null

            virtualDisplay?.surface = surface
            virtualDisplay?.resize(newWidth, newHeight, currentDensity)

            encodeJob = scope.launch(Dispatchers.IO) {
                runEncoderLoop()
            }

            requestKeyframe()
            Log.i(TAG, "✅ Reconfigured encoder for ${newWidth}x${newHeight} successfully")
        } catch (e: Exception) {
            Log.e(TAG, "Error reconfiguring encoder for orientation change: ${e.message}", e)
        }
    }

    private fun runEncoderLoop() {
        val codec = mediaCodec ?: return
        val bufferInfo = MediaCodec.BufferInfo()

        while (isStreaming && scope.isActive) {
            try {
                val outputBufferIndex = codec.dequeueOutputBuffer(bufferInfo, 10_000)
                if (outputBufferIndex >= 0) {
                    val outputBuffer = codec.getOutputBuffer(outputBufferIndex) ?: continue

                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                        // SPS / PPS configuration frame
                        val configData = ByteArray(bufferInfo.size)
                        outputBuffer.position(bufferInfo.offset)
                        outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                        outputBuffer.get(configData)
                        spsPpsHeader = configData
                        Log.i(TAG, "Captured SPS/PPS codec header (${configData.size} bytes)")
                    } else if (bufferInfo.size > 0) {
                        val isKeyframe = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                        val frameSize = bufferInfo.size
                        val spsSize = if (isKeyframe && spsPpsHeader != null) spsPpsHeader!!.size else 0

                        val finalData = ByteArray(spsSize + frameSize)
                        if (spsSize > 0) {
                            System.arraycopy(spsPpsHeader!!, 0, finalData, 0, spsSize)
                        }

                        outputBuffer.position(bufferInfo.offset)
                        outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                        outputBuffer.get(finalData, spsSize, frameSize)

                        frameCount++
                        val timestamp = System.currentTimeMillis()
                        onFrameEncoded(finalData, isKeyframe, frameCount, timestamp)
                    }

                    codec.releaseOutputBuffer(outputBufferIndex, false)
                }
            } catch (e: Exception) {
                if (isStreaming) {
                    Log.e(TAG, "Error in encoder loop: ${e.message}")
                }
                break
            }
        }
    }

    /**
     * Request an immediate IDR Keyframe from the hardware encoder.
     */
    fun requestKeyframe() {
        try {
            val params = android.os.Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            }
            mediaCodec?.setParameters(params)
            Log.d(TAG, "Forced IDR keyframe request")
        } catch (e: Exception) {
            Log.w(TAG, "Could not request keyframe: ${e.message}")
        }
    }

    /**
     * Stops the screen capture and hardware encoder.
     */
    @Synchronized
    fun stop() {
        if (!isStreaming) return
        isStreaming = false
        Log.i(TAG, "Stopping screen capture...")

        encodeJob?.cancel()
        encodeJob = null

        try {
            displayManager.unregisterDisplayListener(displayListener)
        } catch (e: Exception) {
            // Ignore
        }

        try {
            mediaProjection.unregisterCallback(projectionCallback)
        } catch (e: Exception) {
            // Ignore
        }

        try {
            virtualDisplay?.release()
        } catch (e: Exception) {
            Log.w(TAG, "Error releasing virtual display: ${e.message}")
        }
        virtualDisplay = null

        try {
            inputSurface?.release()
        } catch (e: Exception) {
            Log.w(TAG, "Error releasing input surface: ${e.message}")
        }
        inputSurface = null

        try {
            mediaCodec?.stop()
            mediaCodec?.release()
        } catch (e: Exception) {
            Log.w(TAG, "Error releasing media codec: ${e.message}")
        }
        mediaCodec = null

        com.droidlink.app.service.DroidLinkService.setMediaProjectionInstance(null)
        Log.i(TAG, "Screen capture stopped successfully.")
    }
}
