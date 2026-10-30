package com.droidlink.app.service

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.content.ClipData
import android.content.ClipboardManager as SystemClipboardManager
import android.content.Context
import android.graphics.Path
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.droidlink.core.security.PairingStorage
import droidlink.protocol.ScreenProto.NavigationEvent
import droidlink.protocol.ScreenProto.TouchEvent

/**
 * Android Accessibility Service for zero-ADB remote control and seamless clipboard sync:
 * 1. Automatic background clipboard sync overcoming Android 10+ restrictions.
 * 2. Injects touch gestures, two-finger scrolling, navigation actions (Back, Home, Recents, Power),
 *    and keyboard text input from macOS DroidLink.
 */
class DroidLinkAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "DroidLinkAccessibility"
        var instance: DroidLinkAccessibilityService? = null
            private set

        val isEnabled: Boolean
            get() = instance != null

        private const val EXTRA_IS_SENSITIVE = "android.content.extra.IS_SENSITIVE"
        private const val EXTRA_PRIVATE_BROWSING = "com.android.browser.private_browsing"
        private const val EXTRA_CHROMIUM_INCOGNITO = "org.chromium.chrome.browser.incognito"
        private const val EXTRA_VENDOR_SENSITIVE = "is_sensitive"
    }

    private var downX = 0f
    private var downY = 0f
    private var isGestureActive = false
    private var pendingGesture: GestureDescription? = null

    private var clipboardManager: SystemClipboardManager? = null
    private var lastSentText: String = ""
    private val mainHandler = Handler(Looper.getMainLooper())
    private var isListenerRegistered = false

    private val clipListener = SystemClipboardManager.OnPrimaryClipChangedListener {
        checkAndSyncClipboard("OnPrimaryClipChangedListener")
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.i(TAG, "⚡ DroidLink Accessibility Service connected & active!")

        try {
            val info = serviceInfo ?: AccessibilityServiceInfo()
            info.eventTypes = AccessibilityEvent.TYPE_VIEW_CLICKED or
                    AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED or
                    AccessibilityEvent.TYPE_VIEW_CONTEXT_CLICKED or
                    AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED or
                    AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED
            info.feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            info.notificationTimeout = 100
            info.flags = AccessibilityServiceInfo.DEFAULT or
                    AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                    AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
            serviceInfo = info

            clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as? SystemClipboardManager
            registerClipboardListener()
        } catch (e: Exception) {
            Log.e(TAG, "Error initializing accessibility service info", e)
        }
    }

    private fun registerClipboardListener() {
        if (isListenerRegistered) return
        mainHandler.post {
            try {
                clipboardManager?.addPrimaryClipChangedListener(clipListener)
                isListenerRegistered = true
                Log.d(TAG, "📋 Primary clip listener registered in Accessibility Service")
            } catch (e: Exception) {
                Log.w(TAG, "Could not register primary clip listener in a11y service: ${e.message}")
            }
        }
    }

    private fun unregisterClipboardListener() {
        if (!isListenerRegistered) return
        mainHandler.post {
            try {
                clipboardManager?.removePrimaryClipChangedListener(clipListener)
                isListenerRegistered = false
                Log.d(TAG, "🛑 Primary clip listener unregistered in Accessibility Service")
            } catch (e: Exception) {
                Log.w(TAG, "Could not unregister primary clip listener: ${e.message}")
            }
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val eventType = event?.eventType ?: return
        when (eventType) {
            AccessibilityEvent.TYPE_VIEW_CLICKED,
            AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED,
            AccessibilityEvent.TYPE_VIEW_CONTEXT_CLICKED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED -> {
                mainHandler.removeCallbacksAndMessages(null)
                mainHandler.postDelayed({
                    checkAndSyncClipboard("A11yEvent:$eventType")
                }, 150)
            }
        }
    }

    private fun checkAndSyncClipboard(source: String) {
        try {
            val cm = clipboardManager ?: getSystemService(Context.CLIPBOARD_SERVICE) as? SystemClipboardManager ?: return
            val clip: ClipData = cm.primaryClip ?: return
            if (clip.itemCount == 0) return

            val storage = PairingStorage(applicationContext)
            if (!storage.isClipboardSyncEnabled()) return
            if (storage.isIncognitoMode()) return

            if (storage.isAutoIgnoreSensitive() && isSensitiveClip(clip)) {
                Log.i(TAG, "🔒 Ignoring sensitive/incognito clipboard item from $source")
                return
            }

            val text = clip.getItemAt(0).coerceToText(this)?.toString() ?: ""
            if (text.isNotBlank() && text != lastSentText) {
                lastSentText = text
                Log.d(TAG, "📤 Auto-syncing clipboard to Mac via $source: \"${text.take(30)}...\"")
                DroidLinkService.sendClipboardDirect(text)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error checking clipboard in accessibility service ($source)", e)
        }
    }

    private fun isSensitiveClip(clip: ClipData): Boolean {
        val description = clip.description ?: return false
        val extras = description.extras ?: return false

        if (extras.getBoolean(EXTRA_IS_SENSITIVE, false)) return true
        if (extras.getBoolean(EXTRA_PRIVATE_BROWSING, false)) return true
        if (extras.getBoolean(EXTRA_CHROMIUM_INCOGNITO, false)) return true
        if (extras.getBoolean(EXTRA_VENDOR_SENSITIVE, false)) return true

        return false
    }

    override fun onInterrupt() {
        Log.w(TAG, "DroidLink Accessibility Service interrupted")
    }

    override fun onDestroy() {
        unregisterClipboardListener()
        super.onDestroy()
        if (instance == this) {
            instance = null
        }
        Log.i(TAG, "DroidLink Accessibility Service destroyed")
    }

    /**
     * Safely queues and dispatches gestures without dropping consecutive strokes.
     */
    @Synchronized
    private fun safeDispatchGesture(gesture: GestureDescription) {
        if (isGestureActive) {
            pendingGesture = gesture
            return
        }
        isGestureActive = true
        dispatchGesture(gesture, object : AccessibilityService.GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                synchronized(this@DroidLinkAccessibilityService) {
                    isGestureActive = false
                    val next = pendingGesture
                    pendingGesture = null
                    if (next != null) {
                        safeDispatchGesture(next)
                    }
                }
            }

            override fun onCancelled(gestureDescription: GestureDescription?) {
                synchronized(this@DroidLinkAccessibilityService) {
                    isGestureActive = false
                    val next = pendingGesture
                    pendingGesture = null
                    if (next != null) {
                        safeDispatchGesture(next)
                    }
                }
            }
        }, null)
    }

    /**
     * Injects mouse / trackpad touch events onto the screen.
     */
    fun dispatchTouch(
        normX: Float,
        normY: Float,
        action: TouchEvent.TouchAction,
        scrollDx: Float = 0f,
        scrollDy: Float = 0f
    ) {
        val dm = resources.displayMetrics
        val realX = (normX * dm.widthPixels).coerceIn(0f, dm.widthPixels.toFloat())
        val realY = (normY * dm.heightPixels).coerceIn(0f, dm.heightPixels.toFloat())

        when (action) {
            TouchEvent.TouchAction.DOWN -> {
                downX = realX
                downY = realY
            }
            TouchEvent.TouchAction.UP -> {
                val path = Path().apply {
                    moveTo(downX, downY)
                    lineTo(realX, realY)
                }
                val stroke = GestureDescription.StrokeDescription(path, 0, 50)
                val gesture = GestureDescription.Builder().addStroke(stroke).build()
                safeDispatchGesture(gesture)
            }
            TouchEvent.TouchAction.MOVE -> {
                val path = Path().apply {
                    moveTo(downX, downY)
                    lineTo(realX, realY)
                }
                val stroke = GestureDescription.StrokeDescription(path, 0, 40)
                val gesture = GestureDescription.Builder().addStroke(stroke).build()
                safeDispatchGesture(gesture)
                downX = realX
                downY = realY
            }
            TouchEvent.TouchAction.SCROLL -> {
                // Two-finger scroll: calculate swipe vector with touch slop amplification
                val touchSlop = try {
                    android.view.ViewConfiguration.get(this).scaledTouchSlop.toFloat()
                } catch (e: Exception) {
                    24f
                }
                val minDisplacement = (touchSlop * 4f).coerceAtLeast(160f)

                var deltaY = scrollDy * dm.heightPixels * 3.5f
                var deltaX = scrollDx * dm.widthPixels * 3.5f

                if (Math.abs(deltaY) > 0.001f && Math.abs(deltaY) < minDisplacement) {
                    deltaY = Math.signum(deltaY) * minDisplacement
                }
                if (Math.abs(deltaX) > 0.001f && Math.abs(deltaX) < minDisplacement) {
                    deltaX = Math.signum(deltaX) * minDisplacement
                }

                val startX = realX.coerceIn(minDisplacement + 20f, (dm.widthPixels - minDisplacement - 20f).coerceAtLeast(minDisplacement + 20f))
                val startY = realY.coerceIn(minDisplacement + 20f, (dm.heightPixels - minDisplacement - 20f).coerceAtLeast(minDisplacement + 20f))

                val endX = (startX - deltaX).coerceIn(0f, dm.widthPixels.toFloat())
                val endY = (startY - deltaY).coerceIn(0f, dm.heightPixels.toFloat())

                if (Math.abs(endX - startX) > 5f || Math.abs(endY - startY) > 5f) {
                    val path = Path().apply {
                        moveTo(startX, startY)
                        lineTo(endX, endY)
                    }
                    val stroke = GestureDescription.StrokeDescription(path, 0, 35)
                    val gesture = GestureDescription.Builder().addStroke(stroke).build()
                    safeDispatchGesture(gesture)
                }
            }
            else -> {}
        }
    }

    /**
     * Executes global Android navigation actions.
     */
    fun performNavAction(navAction: NavigationEvent.NavAction): Boolean {
        val globalAction = when (navAction) {
            NavigationEvent.NavAction.BACK -> GLOBAL_ACTION_BACK
            NavigationEvent.NavAction.HOME -> GLOBAL_ACTION_HOME
            NavigationEvent.NavAction.RECENTS -> GLOBAL_ACTION_RECENTS
            NavigationEvent.NavAction.NOTIFICATIONS -> GLOBAL_ACTION_NOTIFICATIONS
            NavigationEvent.NavAction.QUICK_SETTINGS -> GLOBAL_ACTION_QUICK_SETTINGS
            NavigationEvent.NavAction.POWER -> GLOBAL_ACTION_LOCK_SCREEN
            NavigationEvent.NavAction.SCREENSHOT -> GLOBAL_ACTION_TAKE_SCREENSHOT
            else -> return false
        }
        val result = performGlobalAction(globalAction)
        Log.d(TAG, "Executed NavAction: $navAction -> result: $result")
        return result
    }

    /**
     * Types text or handles key events in the currently focused input field.
     */
    fun inputKey(text: String, keyCode: Int) {
        val root = rootInActiveWindow ?: return
        val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)

        if (text.isNotEmpty()) {
            if (focused != null && focused.isEditable) {
                val currentText = focused.text?.toString() ?: ""
                val args = Bundle().apply {
                    putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, currentText + text)
                }
                focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
                Log.d(TAG, "Committed text input: '$text'")
            }
            return
        }

        when (keyCode) {
            67 -> { // KEYCODE_DEL (Backspace)
                if (focused != null && focused.isEditable) {
                    val currentText = focused.text?.toString() ?: ""
                    if (currentText.isNotEmpty()) {
                        val args = Bundle().apply {
                            putCharSequence(
                                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                                currentText.dropLast(1)
                            )
                        }
                        focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
                    }
                }
            }
            111 -> { // KEYCODE_ESCAPE -> Back
                performGlobalAction(GLOBAL_ACTION_BACK)
            }
            66 -> { // KEYCODE_ENTER
                focused?.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            }
        }
    }
}
