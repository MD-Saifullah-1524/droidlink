package com.droidlink.app.screen

import android.content.Context
import android.content.pm.ActivityInfo
import android.graphics.PixelFormat
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.view.Surface
import android.view.View
import android.view.WindowManager
import droidlink.protocol.ScreenProto

/**
 * Manages global device orientation without requiring root or ADB.
 * Uses a 1x1 system overlay window (TYPE_APPLICATION_OVERLAY) with LayoutParams.screenOrientation
 * which WindowManager enforces globally across all applications.
 */
class OrientationManager(private val context: Context) {

    companion object {
        private const val TAG = "OrientationManager"
    }

    private val windowManager = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private var overlayView: View? = null
    private var currentOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED

    /**
     * Applies orientation based on RotateRequest mode:
     * - ROTATION_LANDSCAPE: Forces landscape orientation
     * - ROTATION_PORTRAIT: Forces portrait orientation
     * - ROTATION_AUTO: Restores sensor-based auto rotation
     */
    @Synchronized
    fun setRotationMode(mode: ScreenProto.RotateRequest.RotationMode) {
        val targetOrientation = when (mode) {
            ScreenProto.RotateRequest.RotationMode.ROTATION_LANDSCAPE -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            ScreenProto.RotateRequest.RotationMode.ROTATION_PORTRAIT -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            ScreenProto.RotateRequest.RotationMode.ROTATION_AUTO,
            ScreenProto.RotateRequest.RotationMode.UNRECOGNIZED -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }

        applyOrientation(targetOrientation)
        tryModifySystemSettings(mode)
    }

    @Synchronized
    fun applyOrientation(orientation: Int) {
        if (currentOrientation == orientation && overlayView != null) {
            return
        }

        currentOrientation = orientation

        if (orientation == ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED) {
            removeOverlay()
            Log.i(TAG, "Restored auto-rotation (overlay removed)")
            return
        }

        try {
            if (overlayView == null) {
                val view = View(context)
                val layoutType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                } else {
                    @Suppress("DEPRECATION")
                    WindowManager.LayoutParams.TYPE_PHONE
                }

                val params = WindowManager.LayoutParams(
                    1, 1,
                    layoutType,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                        WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                        WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                    PixelFormat.TRANSLUCENT
                ).apply {
                    screenOrientation = orientation
                }

                windowManager.addView(view, params)
                overlayView = view
                Log.i(TAG, "Applied global orientation $orientation via overlay")
            } else {
                val params = overlayView!!.layoutParams as WindowManager.LayoutParams
                params.screenOrientation = orientation
                windowManager.updateViewLayout(overlayView, params)
                Log.i(TAG, "Updated global orientation $orientation via overlay")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to apply orientation via overlay: ${e.message}")
        }
    }

    private fun tryModifySystemSettings(mode: ScreenProto.RotateRequest.RotationMode) {
        try {
            if (Settings.System.canWrite(context)) {
                val cr = context.contentResolver
                when (mode) {
                    ScreenProto.RotateRequest.RotationMode.ROTATION_LANDSCAPE -> {
                        Settings.System.putInt(cr, Settings.System.ACCELEROMETER_ROTATION, 0)
                        Settings.System.putInt(cr, Settings.System.USER_ROTATION, Surface.ROTATION_90)
                        Log.i(TAG, "Applied LANDSCAPE via Settings.System (accelerometer=0, user_rotation=90)")
                    }
                    ScreenProto.RotateRequest.RotationMode.ROTATION_PORTRAIT -> {
                        Settings.System.putInt(cr, Settings.System.ACCELEROMETER_ROTATION, 0)
                        Settings.System.putInt(cr, Settings.System.USER_ROTATION, Surface.ROTATION_0)
                        Log.i(TAG, "Applied PORTRAIT via Settings.System (accelerometer=0, user_rotation=0)")
                    }
                    ScreenProto.RotateRequest.RotationMode.ROTATION_AUTO,
                    ScreenProto.RotateRequest.RotationMode.UNRECOGNIZED -> {
                        Settings.System.putInt(cr, Settings.System.ACCELEROMETER_ROTATION, 1)
                        Log.i(TAG, "Applied AUTO via Settings.System (accelerometer=1)")
                    }
                }
            } else {
                Log.w(TAG, "Settings.System.canWrite is false; cannot modify system rotation settings")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Could not update Settings.System: ${e.message}", e)
        }
    }

    @Synchronized
    fun reset() {
        removeOverlay()
        currentOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    }

    private fun removeOverlay() {
        overlayView?.let {
            try {
                windowManager.removeView(it)
            } catch (e: Exception) {
                Log.w(TAG, "Error removing orientation overlay: ${e.message}")
            }
        }
        overlayView = null
    }
}
