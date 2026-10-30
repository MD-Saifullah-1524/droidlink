package com.droidlink.app.display

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.util.Log
import kotlin.math.abs

/**
 * Manages the device's hardware Ambient Light Sensor (ALS - Sensor.TYPE_LIGHT).
 * Applies an Exponential Moving Average (EMA) low-pass filter to reject sensor noise
 * and transient shadows from hands/stylus before notifying listeners.
 */
class AmbientLightSensorManager(private val context: Context) : SensorEventListener {

    companion object {
        private const val TAG = "AmbientLightSensor"
        // Filter smoothing factor: 0.15 gives a responsive yet smooth transition over ~1-2 seconds
        private const val FILTER_ALPHA = 0.15f
        // Minimum delta to emit an update (avoids tiny micro-adjustments)
        private const val MIN_LUX_DELTA = 5.0f
    }

    private val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
    private val lightSensor = sensorManager?.getDefaultSensor(Sensor.TYPE_LIGHT)

    private var smoothedLux: Float = 150.0f
    private var lastEmittedLux: Float = -1.0f
    private var isListening: Boolean = false

    var onLuxChanged: ((Float) -> Unit)? = null

    val currentLux: Float
        get() = smoothedLux

    val isSensorAvailable: Boolean
        get() = lightSensor != null

    fun start(callback: (Float) -> Unit) {
        if (isListening) return
        this.onLuxChanged = callback

        if (lightSensor == null || sensorManager == null) {
            Log.w(TAG, "Hardware light sensor (Sensor.TYPE_LIGHT) unavailable on this device; using 150 lux fallback")
            smoothedLux = 150.0f
            callback(smoothedLux)
            return
        }

        val success = sensorManager.registerListener(this, lightSensor, SensorManager.SENSOR_DELAY_NORMAL)
        if (success) {
            isListening = true
            Log.i(TAG, "Ambient Light Sensor monitoring started")
        } else {
            Log.w(TAG, "Failed to register Sensor.TYPE_LIGHT listener")
        }
    }

    fun stop() {
        if (!isListening) return
        sensorManager?.unregisterListener(this)
        isListening = false
        onLuxChanged = null
        Log.i(TAG, "Ambient Light Sensor monitoring stopped")
    }

    override fun onSensorChanged(event: SensorEvent?) {
        if (event == null || event.sensor.type != Sensor.TYPE_LIGHT) return
        val rawLux = event.values[0]

        // Apply low-pass exponential moving average
        if (lastEmittedLux < 0) {
            smoothedLux = rawLux
            lastEmittedLux = rawLux
            onLuxChanged?.invoke(smoothedLux)
            return
        }

        smoothedLux = FILTER_ALPHA * rawLux + (1.0f - FILTER_ALPHA) * smoothedLux

        if (abs(smoothedLux - lastEmittedLux) >= MIN_LUX_DELTA) {
            lastEmittedLux = smoothedLux
            onLuxChanged?.invoke(smoothedLux)
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        // No-op
    }
}
