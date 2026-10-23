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
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import com.droidlink.app.service.DroidLinkService
import com.droidlink.app.shizuku.ShizukuManager
import com.droidlink.app.shizuku.ShizukuState
import droidlink.protocol.ExternalDisplayProto
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * Immersive edge-to-edge Activity rendering the Mac's external monitor.
 * Operates strictly over USB (AOA 2.0 Direct), automatically applies native resolution
 * and Zero-ADB Shizuku optimizations, and relays multi-touch, stylus, and hardware keyboard events.
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

        val isActive: Boolean get() = activeInstance != null
    }

    private var surfaceView: ExternalDisplaySurfaceView? = null
    private var hudOverlay: View? = null
    private var fpsTextView: TextView? = null
    private var shizukuStatusView: TextView? = null

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

        setContentView(rootLayout)

        // 7. Watch for USB disconnection (AOA USB disconnect terminates activity)
        lifecycleScope.launch {
            DroidLinkService.isUsbConnected.collectLatest { isConnected ->
                if (!isConnected && activeInstance != null) {
                    finish()
                }
            }
        }

        // 8. Apply Zero-ADB optimizations via Shizuku
        lifecycleScope.launch {
            ShizukuManager.applyExternalDisplayOptimizations()
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

        val shizukuBadge = TextView(this).apply {
            val isAuthorized = ShizukuManager.state.value == ShizukuState.Authorized
            text = if (isAuthorized) "🟢 Zero-ADB 120Hz Active" else "⚪ Standard Mode"
            setTextColor(if (isAuthorized) Color.GREEN else Color.GRAY)
            textSize = 10f
        }
        this.shizukuStatusView = shizukuBadge
        contentLayout.addView(shizukuBadge)

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
        mainHandler.removeCallbacks(autoHideRunnable)
        activeInstance = null
        surfaceView?.release()
        surfaceView = null

        // Dismiss persistent external display notification
        DroidLinkService.dismissExternalDisplayNotification()

        // Restore system display settings via Shizuku
        lifecycleScope.launch {
            ShizukuManager.restoreDisplaySettings()
        }

        // Notify Mac synchronously so WindowServer instantly unplugs the virtual monitor
        DroidLinkService.notifyExternalDisplayStopped()
    }
}
