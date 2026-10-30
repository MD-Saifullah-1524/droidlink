package com.droidlink.core.clipboard

import android.content.ClipData
import android.content.ClipboardManager as SystemClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Modern event-driven Clipboard manager for Android 15+ using OnPrimaryClipChangedListener
 */
class ClipboardManager(
    private val context: Context,
    private val onClipboardChanged: (String) -> Unit
) {
    private val clipboard: SystemClipboardManager =
        context.getSystemService(Context.CLIPBOARD_SERVICE) as SystemClipboardManager
    private val mainHandler = Handler(Looper.getMainLooper())

    var isIncognitoMode: Boolean = false
    var autoIgnoreSensitive: Boolean = true

    private var lastContent: String = ""
    private var isListening = false

    private val clipListener = SystemClipboardManager.OnPrimaryClipChangedListener {
        handleClipChanged()
    }

    companion object {
        private const val TAG = "ClipboardManager"
        const val EXTRA_IS_SENSITIVE = "android.content.extra.IS_SENSITIVE"
        const val EXTRA_PRIVATE_BROWSING = "com.android.browser.private_browsing"
        const val EXTRA_CHROMIUM_INCOGNITO = "org.chromium.chrome.browser.incognito"
        const val EXTRA_VENDOR_SENSITIVE = "is_sensitive"
    }

    /**
     * Checks if the clip contains sensitive data or was copied from an incognito/private session
     */
    private fun isSensitiveClip(clip: ClipData): Boolean {
        val description = clip.description ?: return false
        val extras = description.extras ?: return false

        if (extras.getBoolean(EXTRA_IS_SENSITIVE, false)) return true
        if (extras.getBoolean(EXTRA_PRIVATE_BROWSING, false)) return true
        if (extras.getBoolean(EXTRA_CHROMIUM_INCOGNITO, false)) return true
        if (extras.getBoolean(EXTRA_VENDOR_SENSITIVE, false)) return true

        return false
    }

    /**
     * Starts listening for system clipboard changes on the main looper
     */
    fun startMonitoring() {
        if (isListening) return
        mainHandler.post {
            try {
                lastContent = getCurrentContent()
                clipboard.addPrimaryClipChangedListener(clipListener)
                isListening = true
                Log.d(TAG, "📋 Native clipboard listener registered on main looper")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to register clip listener", e)
            }
        }
    }

    /**
     * Stops listening for system clipboard changes
     */
    fun stopMonitoring() {
        if (!isListening) return
        mainHandler.post {
            try {
                clipboard.removePrimaryClipChangedListener(clipListener)
                isListening = false
                Log.d(TAG, "🛑 Native clipboard listener unregistered")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to unregister clip listener", e)
            }
        }
    }

    /**
     * Actively checks clipboard content right now and dispatches update if changed.
     * Useful when triggered by accessibility selection or window focus change.
     */
    fun checkClipboardNow() {
        mainHandler.post {
            handleClipChanged()
        }
    }

    /**
     * Sets clipboard content received from Mac without re-echoing back.
     * Dropped if Incognito Mode is active.
     */
    fun setContent(text: String) {
        if (isIncognitoMode) {
            Log.d(TAG, "🕶️ Remote clipboard update dropped: Incognito mode is active")
            return
        }
        if (text.isBlank() || text == lastContent) return
        mainHandler.post {
            try {
                lastContent = text
                val clip = ClipData.newPlainText("DroidLink", text)
                clipboard.setPrimaryClip(clip)
                Log.d(TAG, "✅ Clipboard updated from remote: \"${text.take(30)}...\"")
            } catch (e: Exception) {
                Log.e(TAG, "Error setting clipboard from remote", e)
            }
        }
    }

    /**
     * Updates the last recorded content to prevent duplicate echoes
     * when clipboard is sent or updated by an external dispatcher.
     */
    fun updateLastContent(text: String) {
        lastContent = text
    }

    private fun handleClipChanged() {
        try {
            if (isIncognitoMode) {
                Log.d(TAG, "🕶️ Clipboard change ignored: Incognito mode is active")
                return
            }

            val clip = clipboard.primaryClip
            if (clip != null && clip.itemCount > 0) {
                if (autoIgnoreSensitive && isSensitiveClip(clip)) {
                    Log.i(TAG, "🔒 Ignoring sensitive/incognito clipboard item (not synced)")
                    return
                }

                val current = clip.getItemAt(0).coerceToText(context)?.toString() ?: ""
                if (current.isNotBlank() && current != lastContent) {
                    lastContent = current
                    Log.d(TAG, "📝 Local clipboard changed: \"${current.take(30)}...\"")
                    onClipboardChanged(current)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error handling clipboard change", e)
        }
    }

    private fun getCurrentContent(): String {
        return try {
            val clip = clipboard.primaryClip
            if (clip != null && clip.itemCount > 0) {
                clip.getItemAt(0).coerceToText(context)?.toString() ?: ""
            } else {
                ""
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error getting current clip content", e)
            ""
        }
    }
}