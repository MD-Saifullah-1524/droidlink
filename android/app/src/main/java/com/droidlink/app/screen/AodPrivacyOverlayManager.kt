package com.droidlink.app.screen

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Manages an AMOLED-friendly pitch black AOD (Always On Display) overlay with clock,
 * date, and battery level. Dims the hardware screen brightness to minimum to provide
 * complete privacy on the physical phone while keeping MediaProjection mirroring alive.
 */
class AodPrivacyOverlayManager(private val context: Context) {

    companion object {
        private const val TAG = "AodPrivacyOverlay"
    }

    private val windowManager = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private var overlayLayout: LinearLayout? = null
    private var clockView: TextView? = null
    private var dateView: TextView? = null
    private var batteryView: TextView? = null

    var isShowing: Boolean = false
        private set

    private val timeFormat = SimpleDateFormat("HH:mm", Locale.getDefault())
    private val dateFormat = SimpleDateFormat("EEEE, MMMM d", Locale.getDefault())

    private val clockUpdateRunnable = object : Runnable {
        override fun run() {
            updateTimeAndBattery()
            if (isShowing) {
                mainHandler.postDelayed(this, 10_000) // Update every 10 seconds
            }
        }
    }

    @Synchronized
    fun toggle() {
        if (isShowing) {
            hide()
        } else {
            show()
        }
    }

    @Synchronized
    fun show() {
        if (isShowing) return

        mainHandler.post {
            try {
                val layout = createAodView()

                val layoutType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                } else {
                    @Suppress("DEPRECATION")
                    WindowManager.LayoutParams.TYPE_PHONE
                }

                val params = WindowManager.LayoutParams(
                    WindowManager.LayoutParams.MATCH_PARENT,
                    WindowManager.LayoutParams.MATCH_PARENT,
                    layoutType,
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                        WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                        WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                    PixelFormat.TRANSLUCENT
                ).apply {
                    gravity = Gravity.CENTER
                    // Drop physical display backlight to minimum possible
                    screenBrightness = 0.01f
                }

                windowManager.addView(layout, params)
                overlayLayout = layout
                isShowing = true

                updateTimeAndBattery()
                mainHandler.postDelayed(clockUpdateRunnable, 10_000)

                Log.i(TAG, "🌙 AOD Privacy Overlay shown (screen dimmed to 1%)")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to display AOD privacy overlay: ${e.message}", e)
            }
        }
    }

    @Synchronized
    fun hide() {
        if (!isShowing) return

        mainHandler.post {
            try {
                mainHandler.removeCallbacks(clockUpdateRunnable)
                overlayLayout?.let {
                    windowManager.removeView(it)
                }
                overlayLayout = null
                clockView = null
                dateView = null
                batteryView = null
                isShowing = false
                Log.i(TAG, "☀️ AOD Privacy Overlay hidden (normal display restored)")
            } catch (e: Exception) {
                Log.w(TAG, "Failed to remove AOD privacy overlay: ${e.message}")
            }
        }
    }

    private fun createAodView(): LinearLayout {
        val root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.BLACK) // True OLED pitch black
            isClickable = true
            isFocusable = true
            setOnClickListener {
                Log.d(TAG, "AOD overlay tapped by user; dismissing")
                hide()
            }
        }

        val clock = TextView(context).apply {
            setTextColor(Color.argb(200, 255, 255, 255))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 64f)
            typeface = Typeface.create("sans-serif-thin", Typeface.NORMAL)
            gravity = Gravity.CENTER
        }
        clockView = clock
        root.addView(clock)

        val date = TextView(context).apply {
            setTextColor(Color.argb(140, 255, 255, 255))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            typeface = Typeface.create("sans-serif-light", Typeface.NORMAL)
            gravity = Gravity.CENTER
            setPadding(0, 8, 0, 0)
        }
        dateView = date
        root.addView(date)

        val battery = TextView(context).apply {
            setTextColor(Color.argb(120, 255, 255, 255))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            typeface = Typeface.create("sans-serif-light", Typeface.NORMAL)
            gravity = Gravity.CENTER
            setPadding(0, 16, 0, 0)
        }
        batteryView = battery
        root.addView(battery)

        val hint = TextView(context).apply {
            text = "• DroidLink Mirroring Active •"
            setTextColor(Color.argb(80, 255, 255, 255))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            gravity = Gravity.CENTER
            setPadding(0, 36, 0, 0)
        }
        root.addView(hint)

        return root
    }

    private fun updateTimeAndBattery() {
        val now = Date()
        clockView?.text = timeFormat.format(now)
        dateView?.text = dateFormat.format(now)

        try {
            val batteryStatus: Intent? = context.registerReceiver(
                null,
                IntentFilter(Intent.ACTION_BATTERY_CHANGED)
            )
            val level = batteryStatus?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = batteryStatus?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
            val status = batteryStatus?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
            val isCharging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                status == BatteryManager.BATTERY_STATUS_FULL

            val batteryPct = if (level >= 0 && scale > 0) (level * 100 / scale) else -1
            if (batteryPct >= 0) {
                batteryView?.text = if (isCharging) "⚡ $batteryPct% Charging" else "🔋 $batteryPct%"
            }
        } catch (e: Exception) {
            Log.d(TAG, "Battery info error: ${e.message}")
        }
    }
}
