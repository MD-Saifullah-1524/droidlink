package com.droidlink.app.screen

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.os.Build
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Captures internal Android audio (media, games, notifications) on Android 10+ (API 29+)
 * via AudioPlaybackCaptureConfiguration and streams raw 16-bit PCM audio to Mac.
 */
class AudioCaptureManager(
    private val context: Context,
    private val mediaProjection: MediaProjection,
    private val scope: CoroutineScope,
    private val onAudioCaptured: (audioData: ByteArray, sampleRate: Int, channels: Int, timestamp: Long) -> Unit
) {

    companion object {
        private const val TAG = "AudioCaptureManager"
        const val SAMPLE_RATE = 48000
        const val CHANNELS = 2 // Stereo
        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_STEREO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
    }

    private var audioRecord: AudioRecord? = null
    private var isRecording = false
    private var recordJob: Job? = null

    @Synchronized
    fun start() {
        if (isRecording) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            Log.w(TAG, "AudioPlaybackCapture is only supported on Android 10+ (API 29+)")
            return
        }

        try {
            val captureConfig = AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()

            val minBufferSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
            val bufferSize = Math.max(minBufferSize, 4096)

            val audioFormat = AudioFormat.Builder()
                .setEncoding(AUDIO_FORMAT)
                .setSampleRate(SAMPLE_RATE)
                .setChannelMask(CHANNEL_CONFIG)
                .build()

            val record = AudioRecord.Builder()
                .setAudioPlaybackCaptureConfig(captureConfig)
                .setAudioFormat(audioFormat)
                .setBufferSizeInBytes(bufferSize)
                .build()

            if (record.state != AudioRecord.STATE_INITIALIZED) {
                Log.e(TAG, "AudioRecord initialization failed")
                return
            }

            record.startRecording()
            audioRecord = record
            isRecording = true

            recordJob = scope.launch(Dispatchers.IO) {
                val buffer = ByteArray(bufferSize)
                while (isRecording && scope.isActive) {
                    val bytesRead = record.read(buffer, 0, buffer.size)
                    if (bytesRead > 0) {
                        val chunk = ByteArray(bytesRead)
                        System.arraycopy(buffer, 0, chunk, 0, bytesRead)
                        val timestamp = System.currentTimeMillis()
                        onAudioCaptured(chunk, SAMPLE_RATE, CHANNELS, timestamp)
                    }
                }
            }

            Log.i(TAG, "✅ Internal audio capture started at ${SAMPLE_RATE}Hz stereo PCM")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start internal audio capture: ${e.message}", e)
            stop()
        }
    }

    @Synchronized
    fun stop() {
        if (!isRecording) return
        isRecording = false
        Log.i(TAG, "Stopping audio capture...")

        recordJob?.cancel()
        recordJob = null

        try {
            audioRecord?.stop()
            audioRecord?.release()
        } catch (e: Exception) {
            Log.w(TAG, "Error stopping AudioRecord: ${e.message}")
        }
        audioRecord = null
    }
}
