package com.droidlink.app.display

import androidx.activity.ComponentActivity
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.view.KeyEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import android.widget.TextView
import android.widget.Button
import android.widget.LinearLayout
import android.widget.SeekBar
import android.animation.ValueAnimator
import android.graphics.Typeface
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import com.droidlink.app.service.DroidLinkService
import droidlink.protocol.ExternalDisplayProto
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * Immersive edge-to-edge Activity rendering the Mac's external monitor.
 * Operates strictly over USB (AOA 2.0 Direct), automatically applies native resolution,
 * and relays multi-touch, stylus, and hardware keyboard events.
 */
class ExternalDisplayActivity : ComponentActivity() {

    companion object {
        private const val TAG = "ExternalDisplayActivity"
        private var activeInstance: ExternalDisplayActivity? = null

        fun getNativeLandscapeResolution(context: Context): Pair<Int, Int> {
            return try {
                val wm = context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
                if (wm != null) {
                    val (rawW, rawH) = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        val bounds = wm.currentWindowMetrics.bounds
                        maxOf(bounds.width(), bounds.height()) to minOf(bounds.width(), bounds.height())
                    } else {
                        val dm = DisplayMetrics()
                        @Suppress("DEPRECATION")
                        wm.defaultDisplay.getRealMetrics(dm)
                        maxOf(dm.widthPixels, dm.heightPixels) to minOf(dm.widthPixels, dm.heightPixels)
                    }
                    val alignedW = (rawW / 16) * 16
                    val alignedH = if (rawH == 1080) 1080 else (rawH / 16) * 16
                    alignedW to alignedH
                } else {
                    1920 to 1080
                }
            } catch (e: Exception) {
                1920 to 1080
            }
        }

        fun start(context: Context, width: Int = 0, height: Int = 0, scaleFactor: Float = 2.0f) {
            val (nativeW, nativeH) = if (width <= 0 || height <= 0) {
                getNativeLandscapeResolution(context)
            } else {
                val maxDim = maxOf(width, height)
                val minDim = minOf(width, height)
                val alignedW = (maxDim / 16) * 16
                val alignedH = if (minDim == 1080) 1080 else (minDim / 16) * 16
                alignedW to alignedH
            }
            val intent = Intent(context, ExternalDisplayActivity::class.java).apply {
                putExtra("WIDTH", nativeW)
                putExtra("HEIGHT", nativeH)
                putExtra("SCALE_FACTOR", scaleFactor)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            context.startActivity(intent)
        }

        fun updateScale(scaleFactor: Float) {
            activeInstance?.let { activity ->
                activity.scaleFactor = scaleFactor
                activity.runOnUiThread {
                    activity.fpsTextView?.text = "${activity.displayWidth}×${activity.displayHeight} (${scaleFactor}x)"
                    DroidLinkService.showExternalDisplayNotification(activity.displayWidth, activity.displayHeight, scaleFactor)
                }
            }
        }

        fun dispatchVideoFrame(frameData: ByteArray, isKeyframe: Boolean, frameNumber: Int, timestamp: Long) {
            activeInstance?.surfaceView?.queueVideoFrame(frameData, isKeyframe, frameNumber, timestamp)
        }

        fun stop() {
            activeInstance?.finish()
        }

        fun onBrightnessUpdate(targetNits: Float, macAmbientLux: Float) {
            activeInstance?.let { activity ->
                activity.runOnUiThread {
                    activity.handleMacBrightnessUpdate(targetNits, macAmbientLux)
                }
            }
        }

        fun onCalibrationRequested(referenceNits: Float, forceRecalibrate: Boolean) {
            activeInstance?.let { activity ->
                activity.runOnUiThread {
                    if (forceRecalibrate || !LuminanceEngine.isCalibrated(activity)) {
                        activity.showMandatoryCalibrationOverlay(referenceNits)
                    }
                }
            }
        }

        val isActive: Boolean get() = activeInstance != null
    }

    private var surfaceView: ExternalDisplaySurfaceView? = null
    private var hudOverlay: View? = null
    private var fpsTextView: TextView? = null
    private var rootLayout: FrameLayout? = null

    // Luminance & ALS (Way 2 & Way 4)
    private var alsManager: AmbientLightSensorManager? = null
    private var currentTargetNits: Float = 200.0f
    private var currentMacLux: Float = 150.0f
    private var currentBacklight: Float = 0.5f
    private var backlightAnimator: ValueAnimator? = null
    private var calibrationOverlay: View? = null
    private var isCalibrating: Boolean = false
    private var luminanceStatusTextView: TextView? = null
    private var alsButton: Button? = null

    private var displayWidth = 1920
    private var displayHeight = 1080
    private var scaleFactor = 2.0f

    private val mainHandler = Handler(Looper.getMainLooper())
    private val autoHideRunnable = Runnable {
        hudOverlay?.animate()?.alpha(0f)?.setDuration(250)?.withEndAction {
            hudOverlay?.visibility = View.GONE
            hudOverlay?.alpha = 1f
        }?.start()
    }

    private fun showHudTemporarily() {
        mainHandler.removeCallbacks(autoHideRunnable)
        hudOverlay?.alpha = 1f
        hudOverlay?.visibility = View.VISIBLE
        mainHandler.postDelayed(autoHideRunnable, 4000)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        activeInstance = this

        // 1. Force landscape orientation (sensorLandscape allows 180° flip for cable placement)
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE

        val detected = getNativeLandscapeResolution(this)
        val rawWidth = intent.getIntExtra("WIDTH", detected.first)
        val rawHeight = intent.getIntExtra("HEIGHT", detected.second)
        val maxDim = maxOf(rawWidth, rawHeight)
        val minDim = minOf(rawWidth, rawHeight)
        displayWidth = (maxDim / 16) * 16
        displayHeight = if (minDim == 1080) 1080 else (minDim / 16) * 16
        scaleFactor = intent.getFloatExtra("SCALE_FACTOR", 2.0f)

        // 2. Keep display awake & hide system bars
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        hideSystemBars()

        // 3. Show ongoing notification with direct Disconnect action button
        DroidLinkService.showExternalDisplayNotification(displayWidth, displayHeight, scaleFactor)

        // 4. Create root layout and surface view
        val rootLayout = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
        }

        val sView = ExternalDisplaySurfaceView(this).apply {
            configure(displayWidth, displayHeight, lifecycleScope)
            onInputEventCaptured = { inputMsg ->
                DroidLinkService.sendExternalDisplayInput(inputMsg)
            }
            onFrameRendered = { frameNum, latencyMs ->
                runOnUiThread {
                    fpsTextView?.text = "${displayWidth}×${displayHeight} (${scaleFactor}x) | ${latencyMs}ms"
                }
            }
        }
        this.surfaceView = sView
        rootLayout.addView(sView, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))

        // 5. Subtle translucent toggle pill (tap to reveal Disconnect / Keyboard / HUD for 4s)
        val pillButton = createPillButton()
        rootLayout.addView(
            pillButton,
            FrameLayout.LayoutParams(dpToPx(38), dpToPx(38), Gravity.TOP or Gravity.END).apply {
                setMargins(0, dpToPx(16), dpToPx(16), 0)
            }
        )

        // 6. HUD overlay (starts GONE; auto-hides after 4 seconds of inactivity)
        val hud = createHudOverlay()
        this.hudOverlay = hud
        hud.visibility = View.GONE
        rootLayout.addView(
            hud,
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.END).apply {
                setMargins(0, dpToPx(60), dpToPx(16), 0)
            }
        )

        this.rootLayout = rootLayout
        setContentView(rootLayout)

        // 7. Watch for USB disconnection (AOA USB disconnect terminates activity)
        lifecycleScope.launch {
            DroidLinkService.isUsbConnected.collectLatest { isConnected ->
                if (!isConnected && activeInstance != null) {
                    finish()
                }
            }
        }

        // 8. Luminance and Ambient Light Sensor Setup (Way 2 & Way 4)
        alsManager = AmbientLightSensorManager(this)
        if (!LuminanceEngine.isCalibrated(this)) {
            showMandatoryCalibrationOverlay(referenceNits = 200.0f)
        } else {
            startAmbientLightTracking()
            val initialBacklight = LuminanceEngine.calculateBacklight(this, currentTargetNits, alsManager?.currentLux ?: 150.0f)
            setScreenBrightness(initialBacklight)
        }
    }

    private fun dpToPx(dp: Int): Int {
        val density = resources.displayMetrics.density
        return (dp * density).toInt()
    }

    private fun createPillButton(): View {
        return TextView(this).apply {
            text = "⚙️"
            textSize = 15f
            gravity = Gravity.CENTER
            val bg = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.argb(120, 20, 20, 25))
                setStroke(dpToPx(1), Color.argb(100, 255, 255, 255))
            }
            background = bg
            setOnClickListener {
                if (hudOverlay?.visibility == View.VISIBLE) {
                    mainHandler.removeCallbacks(autoHideRunnable)
                    hudOverlay?.visibility = View.GONE
                } else {
                    showHudTemporarily()
                }
            }
        }
    }

    private fun hideSystemBars() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        controller.hide(WindowInsetsCompat.Type.systemBars())
        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
    }

    private fun createHudOverlay(): View {
        val container = FrameLayout(this).apply {
            val bg = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dpToPx(14).toFloat()
                setColor(Color.argb(220, 20, 22, 28))
                setStroke(dpToPx(1), Color.argb(80, 255, 255, 255))
            }
            background = bg
            setPadding(dpToPx(16), dpToPx(12), dpToPx(16), dpToPx(12))
        }

        val contentLayout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }

        val titleView = TextView(this).apply {
            text = "Mac External Display (USB)"
            setTextColor(Color.WHITE)
            textSize = 13f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        }
        contentLayout.addView(titleView)

        val fpsView = TextView(this).apply {
            text = "${displayWidth}×${displayHeight} | Connected"
            setTextColor(Color.LTGRAY)
            textSize = 11f
        }
        this.fpsTextView = fpsView
        contentLayout.addView(fpsView)

        // Real-time luminance & ALS indicator
        val nitsView = TextView(this).apply {
            text = "Mac: ${currentTargetNits.toInt()} nits ↔ Backlight: ${(currentBacklight * 100).toInt()}%"
            setTextColor(Color.argb(255, 100, 210, 255))
            textSize = 11f
            setPadding(0, dpToPx(2), 0, 0)
        }
        this.luminanceStatusTextView = nitsView
        contentLayout.addView(nitsView)

        // Mandatory Visual Calibration Re-trigger Button (Way 2)
        val recalibBtn = Button(this).apply {
            text = "🎯 Re-calibrate Brightness"
            setTextColor(Color.WHITE)
            val btnBg = GradientDrawable().apply {
                cornerRadius = dpToPx(8).toFloat()
                setColor(Color.argb(200, 35, 90, 160))
            }
            background = btnBg
            setPadding(dpToPx(12), dpToPx(6), dpToPx(12), dpToPx(6))
            textSize = 11f
            setOnClickListener {
                showMandatoryCalibrationOverlay(currentTargetNits)
            }
        }
        val calibParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            dpToPx(32)
        ).apply {
            topMargin = dpToPx(6)
        }
        contentLayout.addView(recalibBtn, calibParams)

        // ALS Dynamic Adaptation Toggle Button (Way 4)
        val alsBtn = Button(this).apply {
            val alsState = if (LuminanceEngine.isAlsEnabled(this@ExternalDisplayActivity)) "ON" else "OFF"
            text = "⚡ ALS Dynamic Sync: $alsState"
            setTextColor(Color.WHITE)
            val btnBg = GradientDrawable().apply {
                cornerRadius = dpToPx(8).toFloat()
                setColor(Color.argb(200, 50, 100, 80))
            }
            background = btnBg
            setPadding(dpToPx(12), dpToPx(6), dpToPx(12), dpToPx(6))
            textSize = 11f
            setOnClickListener {
                val newState = !LuminanceEngine.isAlsEnabled(this@ExternalDisplayActivity)
                LuminanceEngine.setAlsEnabled(this@ExternalDisplayActivity, newState)
                text = "⚡ ALS Dynamic Sync: ${if (newState) "ON" else "OFF"}"
                updateHudLuminanceText()
                if (newState) {
                    val targetBacklight = LuminanceEngine.calculateBacklight(this@ExternalDisplayActivity, currentTargetNits, alsManager?.currentLux ?: 150.0f)
                    animateBacklightTransition(targetBacklight)
                }
            }
        }
        this.alsButton = alsBtn
        contentLayout.addView(alsBtn, calibParams)

        // Soft Keyboard Toggle Button
        val keyboardBtn = Button(this).apply {
            text = "⌨️ Show Soft Keyboard"
            setTextColor(Color.WHITE)
            val btnBg = GradientDrawable().apply {
                cornerRadius = dpToPx(8).toFloat()
                setColor(Color.argb(200, 50, 70, 110))
            }
            background = btnBg
            setPadding(dpToPx(12), dpToPx(6), dpToPx(12), dpToPx(6))
            textSize = 11f
            setOnClickListener {
                val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
                surfaceView?.requestFocus()
                imm?.toggleSoftInput(InputMethodManager.SHOW_FORCED, 0)
            }
        }
        val kbdParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            dpToPx(32)
        ).apply {
            topMargin = dpToPx(6)
        }
        contentLayout.addView(keyboardBtn, kbdParams)

        // Disconnect Button
        val disconnectBtn = Button(this).apply {
            text = "Disconnect"
            setTextColor(Color.WHITE)
            val btnBg = GradientDrawable().apply {
                cornerRadius = dpToPx(8).toFloat()
                setColor(Color.argb(230, 210, 45, 45))
            }
            background = btnBg
            setPadding(dpToPx(12), dpToPx(6), dpToPx(12), dpToPx(6))
            textSize = 12f
            setOnClickListener {
                mainHandler.removeCallbacks(autoHideRunnable)
                finish()
            }
        }
        val btnParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            dpToPx(34)
        ).apply {
            topMargin = dpToPx(6)
        }
        contentLayout.addView(disconnectBtn, btnParams)

        container.addView(contentLayout)
        return container
    }

    // MARK: - Hardware & Soft Keyboard Event Relaying

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        // Back button exits external display mode cleanly
        if (event.keyCode == KeyEvent.KEYCODE_BACK) {
            if (event.action == KeyEvent.ACTION_UP) {
                finish()
            }
            return true
        }

        val action = when (event.action) {
            KeyEvent.ACTION_DOWN -> ExternalDisplayProto.ExternalDisplayInput.ActionType.KEY_DOWN
            KeyEvent.ACTION_UP -> ExternalDisplayProto.ExternalDisplayInput.ActionType.KEY_UP
            else -> null
        }

        if (action != null) {
            var modifiers = 0
            if (event.isShiftPressed) modifiers = modifiers or 1
            if (event.isCtrlPressed) modifiers = modifiers or 2
            if (event.isAltPressed) modifiers = modifiers or 4
            if (event.isMetaPressed) modifiers = modifiers or 8

            val unicodeChar = event.unicodeChar
            val chars = if (unicodeChar != 0 && !Character.isISOControl(unicodeChar)) {
                String(Character.toChars(unicodeChar))
            } else {
                event.characters ?: ""
            }

            val inputMsg = ExternalDisplayProto.ExternalDisplayInput.newBuilder()
                .setAction(action)
                .setToolType(ExternalDisplayProto.ExternalDisplayInput.ToolType.TOOL_UNKNOWN)
                .setKeyCode(event.keyCode)
                .setModifiers(modifiers)
                .setCharacters(chars)
                .build()

            DroidLinkService.sendExternalDisplayInput(inputMsg)
            return true
        }

        return super.dispatchKeyEvent(event)
    }

    override fun onDestroy() {
        super.onDestroy()
        alsManager?.stop()
        alsManager = null
        backlightAnimator?.cancel()
        backlightAnimator = null

        // Revert window brightness override cleanly
        val lp = window.attributes
        lp.screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
        window.attributes = lp

        mainHandler.removeCallbacks(autoHideRunnable)
        activeInstance = null
        surfaceView?.release()
        surfaceView = null

        // Dismiss persistent external display notification
        DroidLinkService.dismissExternalDisplayNotification()

        // Notify Mac synchronously so WindowServer instantly unplugs the virtual monitor
        DroidLinkService.notifyExternalDisplayStopped()
    }

    // MARK: - Luminance Matching & Visual Calibration (Way 2 & Way 4)

    private fun setScreenBrightness(brightness: Float) {
        val safe = maxOf(0.01f, minOf(1.0f, brightness))
        currentBacklight = safe
        val lp = window.attributes
        lp.screenBrightness = safe
        window.attributes = lp
    }

    private fun animateBacklightTransition(targetBacklight: Float) {
        val safeTarget = maxOf(0.01f, minOf(1.0f, targetBacklight))
        backlightAnimator?.cancel()
        val animator = ValueAnimator.ofFloat(currentBacklight, safeTarget).apply {
            duration = 150
            addUpdateListener { anim ->
                val v = anim.animatedValue as Float
                setScreenBrightness(v)
            }
        }
        backlightAnimator = animator
        animator.start()
    }

    private fun handleMacBrightnessUpdate(targetNits: Float, macAmbientLux: Float) {
        this.currentTargetNits = targetNits
        this.currentMacLux = macAmbientLux
        if (LuminanceEngine.isCalibrated(this) && !isCalibrating) {
            val currentLux = alsManager?.currentLux ?: 150.0f
            val targetBacklight = LuminanceEngine.calculateBacklight(this, targetNits, currentLux)
            animateBacklightTransition(targetBacklight)
            updateHudLuminanceText()
        }
    }

    private fun startAmbientLightTracking() {
        alsManager?.start { smoothedLux ->
            runOnUiThread {
                if (LuminanceEngine.isCalibrated(this) && !isCalibrating) {
                    val targetBacklight = LuminanceEngine.calculateBacklight(this, currentTargetNits, smoothedLux)
                    animateBacklightTransition(targetBacklight)
                    updateHudLuminanceText()
                }
            }
        }
    }

    private fun updateHudLuminanceText() {
        val alsStatus = if (LuminanceEngine.isAlsEnabled(this)) "ALS: ${(alsManager?.currentLux ?: 150f).toInt()} lx" else "ALS: OFF"
        luminanceStatusTextView?.text = "Mac: ${currentTargetNits.toInt()} nits ↔ Backlight: ${(currentBacklight * 100).toInt()}% ($alsStatus)"
    }

    private fun showMandatoryCalibrationOverlay(referenceNits: Float) {
        if (calibrationOverlay != null) return
        isCalibrating = true
        mainHandler.removeCallbacks(autoHideRunnable)
        hudOverlay?.visibility = View.GONE

        val overlay = FrameLayout(this).apply {
            // Neutral 50% gray background (#808080) matching Mac's reference patch
            setBackgroundColor(Color.rgb(128, 128, 128))
            isClickable = true
            isFocusable = true
        }

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val bg = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dpToPx(16).toFloat()
                setColor(Color.argb(235, 24, 26, 32))
                setStroke(dpToPx(1), Color.argb(100, 255, 255, 255))
            }
            background = bg
            setPadding(dpToPx(24), dpToPx(20), dpToPx(24), dpToPx(20))
            gravity = Gravity.CENTER_HORIZONTAL
        }

        val title = TextView(this).apply {
            text = "🎯 Display Brightness Calibration"
            textSize = 16f
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
            gravity = Gravity.CENTER
        }
        card.addView(title)

        val subtitle = TextView(this).apply {
            text = "Look at your Mac and this screen side-by-side.\nMove the slider until this screen matches the brightness of your Mac."
            textSize = 12f
            setTextColor(Color.LTGRAY)
            gravity = Gravity.CENTER
            setPadding(0, dpToPx(8), 0, dpToPx(16))
        }
        card.addView(subtitle)

        val readout = TextView(this).apply {
            textSize = 13f
            setTextColor(Color.argb(255, 100, 200, 255))
            typeface = Typeface.MONOSPACE
            gravity = Gravity.CENTER
        }

        val initialSlider = LuminanceEngine.getCalibratedBacklight(this)
        val initialProgress = (initialSlider * 100).toInt().coerceIn(1, 100)
        setScreenBrightness(initialSlider)
        readout.text = "Target: ${referenceNits.toInt()} nits (Mac)  |  Backlight: $initialProgress%"

        val seekBar = SeekBar(this).apply {
            max = 100
            progress = initialProgress
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(sb: SeekBar?, prog: Int, fromUser: Boolean) {
                    val safeProg = maxOf(1, prog)
                    val floatVal = safeProg / 100.0f
                    setScreenBrightness(floatVal)
                    readout.text = "Target: ${referenceNits.toInt()} nits (Mac)  |  Backlight: $safeProg%"
                }
                override fun onStartTrackingTouch(sb: SeekBar?) {}
                override fun onStopTrackingTouch(sb: SeekBar?) {}
            })
        }
        val sbParams = LinearLayout.LayoutParams(
            dpToPx(320),
            LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply {
            bottomMargin = dpToPx(16)
        }
        card.addView(readout)
        card.addView(seekBar, sbParams)

        val saveBtn = Button(this).apply {
            text = "Save Calibration"
            setTextColor(Color.WHITE)
            val btnBg = GradientDrawable().apply {
                cornerRadius = dpToPx(10).toFloat()
                setColor(Color.argb(255, 30, 110, 240))
            }
            background = btnBg
            setPadding(dpToPx(24), dpToPx(10), dpToPx(24), dpToPx(10))
            textSize = 13f
            setTypeface(typeface, Typeface.BOLD)
            setOnClickListener {
                val finalBacklight = maxOf(1, seekBar.progress) / 100.0f
                val ambientLux = alsManager?.currentLux ?: 150.0f
                LuminanceEngine.saveCalibration(this@ExternalDisplayActivity, finalBacklight, referenceNits, ambientLux)
                DroidLinkService.sendExternalDisplayCalibrationComplete(finalBacklight)
                dismissCalibrationOverlay()
            }
        }
        card.addView(saveBtn)

        val cardParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.CENTER
        )
        overlay.addView(card, cardParams)

        rootLayout?.addView(overlay, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        this.calibrationOverlay = overlay
    }

    private fun dismissCalibrationOverlay() {
        calibrationOverlay?.let { ov ->
            rootLayout?.removeView(ov)
            calibrationOverlay = null
        }
        isCalibrating = false
        startAmbientLightTracking()
        updateHudLuminanceText()
    }
}
