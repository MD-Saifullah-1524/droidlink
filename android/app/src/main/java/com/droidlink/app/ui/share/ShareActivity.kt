package com.droidlink.app.ui.share

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import com.droidlink.app.R
import com.droidlink.app.service.DroidLinkService

/**
 * Handles ACTION_SEND and ACTION_SEND_MULTIPLE so that "Send to Mac"
 * appears directly in the Android native system share sheet.
 */
class ShareActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        try {
            val uris = extractUrisFromIntent(intent)
            if (uris.isEmpty()) {
                Toast.makeText(this, "No file selected to share", Toast.LENGTH_SHORT).show()
                finish()
                return
            }

            if (!DroidLinkService.isConnected()) {
                Toast.makeText(this, getString(R.string.not_connected_to_mac), Toast.LENGTH_LONG).show()
                finish()
                return
            }

            // Dispatch background transfer via DroidLinkService
            DroidLinkService.sendSharedFiles(applicationContext, uris)

            val message = if (uris.size == 1) {
                "Sending file to Mac..."
            } else {
                "Sending ${uris.size} files to Mac..."
            }
            Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
        } catch (e: Exception) {
            Toast.makeText(this, "Failed to share: ${e.message}", Toast.LENGTH_SHORT).show()
        } finally {
            finish()
            overridePendingTransition(0, 0)
        }
    }

    private fun extractUrisFromIntent(intent: Intent?): List<Uri> {
        if (intent == null) return emptyList()

        val uris = mutableListOf<Uri>()
        when (intent.action) {
            Intent.ACTION_SEND -> {
                val streamUri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }

                if (streamUri != null) {
                    uris.add(streamUri)
                } else if (intent.data != null) {
                    uris.add(intent.data!!)
                } else if (intent.clipData != null && intent.clipData!!.itemCount > 0) {
                    for (i in 0 until intent.clipData!!.itemCount) {
                        val itemUri = intent.clipData!!.getItemAt(i).uri
                        if (itemUri != null) uris.add(itemUri)
                    }
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val streamUris = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                }
                if (streamUris != null) {
                    uris.addAll(streamUris)
                } else if (intent.clipData != null) {
                    for (i in 0 until intent.clipData!!.itemCount) {
                        val itemUri = intent.clipData!!.getItemAt(i).uri
                        if (itemUri != null) uris.add(itemUri)
                    }
                }
            }
        }
        return uris.filterNotNull()
    }
}
