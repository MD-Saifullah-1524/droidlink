package com.droidlink.app.model

import android.graphics.Bitmap
import androidx.compose.ui.graphics.ImageBitmap

/**
 * Represents an installed app's notification mirroring status
 */
data class AppNotificationInfo(
    val packageName: String,
    val appName: String,
    val isSystemAllowed: Boolean,
    val isSyncEnabled: Boolean,
    val iconBitmap: Bitmap? = null,
    val iconImageBitmap: ImageBitmap? = null
)
