package com.droidlink.app.service

import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.service.quicksettings.TileService
import android.widget.Toast

/**
 * Android Quick Settings Tile allowing 1-tap clipboard push to Mac directly
 * from the status bar pull-down shade.
 */
class DroidLinkTileService : TileService() {

    override fun onClick() {
        super.onClick()
        if (isLocked) {
            unlockAndRun {
                sendCurrentClipboard()
            }
        } else {
            sendCurrentClipboard()
        }
    }

    private fun sendCurrentClipboard() {
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
            Toast.makeText(this, "Failed to send clipboard: ${e.message}", Toast.LENGTH_SHORT).show()
        }
    }
}
