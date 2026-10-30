package com.droidlink.app.ui.clipboard

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.widget.Toast
import com.droidlink.app.service.DroidLinkService

/**
 * Lightweight translucent trampoline activity launched by the notification "Send Clipboard" action.
 * Takes momentary window focus to legally read the Android clipboard on Android 10+ and push it to Mac.
 */
class ClipboardSyncActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            val clip = cm?.primaryClip
            if (clip != null && clip.itemCount > 0) {
                val text = clip.getItemAt(0).coerceToText(this)?.toString() ?: ""
                if (text.isNotBlank()) {
                    DroidLinkService.sendClipboardDirect(text)
                    val preview = if (text.length > 25) "${text.take(25)}..." else text
                    Toast.makeText(this, "📋 Sent to Mac: \"$preview\"", Toast.LENGTH_SHORT).show()
                } else {
                    Toast.makeText(this, "Clipboard is empty", Toast.LENGTH_SHORT).show()
                }
            } else {
                Toast.makeText(this, "Clipboard is empty", Toast.LENGTH_SHORT).show()
            }
        } catch (e: Exception) {
            Toast.makeText(this, "Failed to read clipboard: ${e.message}", Toast.LENGTH_SHORT).show()
        } finally {
            finish()
            overridePendingTransition(0, 0)
        }
    }
}
