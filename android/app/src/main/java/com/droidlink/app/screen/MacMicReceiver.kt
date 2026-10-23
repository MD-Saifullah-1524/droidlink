package com.droidlink.app.screen

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.util.Log

/**
 * Receives microphone audio streamed upstream from Mac and plays/routes it on Android.
 */
class MacMicReceiver {

    companion object {
        private const val TAG = "MacMicReceiver"
        private const val DEFAULT_SAMPLE_RATE = 48000
    }

    private var audioTrack: AudioTrack? = null
    private var isPlaying = false

    @Synchronized
    fun start(sampleRate: Int = DEFAULT_SAMPLE_RATE, channels: Int = 1) {
        if (isPlaying) return

        try {
            val channelConfig = if (channels == 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
            val minBufferSize = AudioTrack.getMinBufferSize(
                sampleRate,
                channelConfig,
                AudioFormat.ENCODING_PCM_16BIT
            )

            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(channelConfig)
                        .build()
                )
                .setBufferSizeInBytes(Math.max(minBufferSize, 4096))
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()

            track.play()
            audioTrack = track
            isPlaying = true
            Log.i(TAG, "✅ MacMicReceiver started: $sampleRate Hz, channels=$channels")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize AudioTrack for Mac Mic: ${e.message}", e)
        }
    }

    /**
     * Feeds incoming PCM audio chunks from Mac.
     */
    fun onMicDataReceived(pcmData: ByteArray, sampleRate: Int = DEFAULT_SAMPLE_RATE, channels: Int = 1) {
        if (!isPlaying || audioTrack == null) {
            start(sampleRate, channels)
        }
        try {
            audioTrack?.write(pcmData, 0, pcmData.size)
        } catch (e: Exception) {
            Log.w(TAG, "Error writing Mac mic chunk to AudioTrack: ${e.message}")
        }
    }

    @Synchronized
    fun stop() {
        if (!isPlaying) return
        isPlaying = false
        try {
            audioTrack?.stop()
            audioTrack?.release()
        } catch (e: Exception) {
            Log.w(TAG, "Error stopping Mac mic AudioTrack: ${e.message}")
        }
        audioTrack = null
        Log.i(TAG, "MacMicReceiver stopped.")
    }
}
