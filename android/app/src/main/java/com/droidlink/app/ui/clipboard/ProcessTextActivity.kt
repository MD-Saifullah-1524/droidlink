package com.droidlink.app.ui.clipboard

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import com.droidlink.app.service.DroidLinkService

/**
 * Handles ACTION_PROCESS_TEXT so that "Send to Mac" appears directly
 * in the system floating text selection menu across all apps.
 */
class ProcessTextActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        try {
            val selectedText = intent?.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
            if (!selectedText.isNullOrBlank()) {
                // Ensure local clipboard also has it
                val cm = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                cm?.setPrimaryClip(ClipData.newPlainText("DroidLink", selectedText))

                DroidLinkService.sendClipboardDirect(selectedText)
                val preview = if (selectedText.length > 25) "${selectedText.take(25)}..." else selectedText
                Toast.makeText(this, "📋 Sent to Mac: \"$preview\"", Toast.LENGTH_SHORT).show()
            }
        } catch (e: Exception) {
            Toast.makeText(this, "Failed to send text: ${e.message}", Toast.LENGTH_SHORT).show()
        } finally {
            finish()
            overridePendingTransition(0, 0)
        }
    }
}
