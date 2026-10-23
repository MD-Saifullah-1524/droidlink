package com.droidlink.app.service

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Bundle
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import droidlink.protocol.ScreenProto.NavigationEvent
import droidlink.protocol.ScreenProto.TouchEvent

/**
 * Android Accessibility Service for zero-ADB remote control:
 * Injects touch gestures, two-finger scrolling, navigation actions (Back, Home, Recents, Power),
 * and keyboard text input from macOS DroidLink.
 */
class DroidLinkAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "DroidLinkAccessibility"
        var instance: DroidLinkAccessibilityService? = null
            private set

        val isEnabled: Boolean
            get() = instance != null
    }

    private var downX = 0f
    private var downY = 0f
    private var isGestureActive = false
    private var pendingGesture: GestureDescription? = null
    private val clipboardDebounceHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val clipboardCheckRunnable = Runnable {
        DroidLinkService.triggerClipboardSync()
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.i(TAG, "⚡ DroidLink Accessibility Service connected & active!")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val eventType = event?.eventType ?: return
        when (eventType) {
            AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED,
            AccessibilityEvent.TYPE_VIEW_CLICKED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> {
                clipboardDebounceHandler.removeCallbacks(clipboardCheckRunnable)
                clipboardDebounceHandler.postDelayed(clipboardCheckRunnable, 200)
            }
        }
    }

    override fun onInterrupt() {
        Log.w(TAG, "DroidLink Accessibility Service interrupted")
    }

    override fun onDestroy() {
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

                // In macOS natural scrolling, scrollingDeltaY > 0 when fingers push UP.
                // On Android, a swipe UP (startY -> startY - deltaY) scrolls the list down to reveal lower content.
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

        // Handle special keycodes: Backspace (67), Enter (66), Escape (111)
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
