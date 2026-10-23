package com.droidlink.app.service

import android.app.Notification
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import com.droidlink.core.security.PairingStorage
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap

data class CapturedNotification(
    val id: String,
    val packageName: String,
    val appName: String,
    val title: String,
    val text: String,
    val iconBytes: ByteArray
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is CapturedNotification) return false
        return id == other.id && packageName == other.packageName && title == other.title && text == other.text
    }

    override fun hashCode(): Int = id.hashCode()
}

/**
 * Intelligent filter engine for filtering recurring Android notifications:
 * - Ongoing background tasks and foreground services
 * - Media playback controls (Spotify, YouTube, etc.)
 * - In-call timers / active chronometer updates
 * - Battery and charging status alerts
 * - Progress bars and navigation updates
 * - Redundant messaging group summaries
 * - Rapid duplicate bursts and repeat updates
 */
object NotificationFilter {
    private const val DEDUP_WINDOW_MS = 5000L
    private const val THROTTLE_WINDOW_MS = 1500L

    data class NotificationRecord(
        val title: String,
        val text: String,
        val timestamp: Long
    )

    private val recentNotifications = ConcurrentHashMap<String, NotificationRecord>()

    fun clearCache() {
        recentNotifications.clear()
    }

    /**
     * Determines whether an incoming notification should be filtered out from being mirrored to Mac.
     * Returns a FilterReason string if it should be dropped, or null if it should be mirrored.
     */
    fun shouldFilter(
        packageName: String,
        isOngoing: Boolean,
        flags: Int,
        category: String?,
        channelId: String?,
        title: String,
        text: String,
        extras: Map<String, Any?>? = null,
        isPackageAllowed: Boolean = true,
        filterOngoingEnabled: Boolean = true,
        filterMediaEnabled: Boolean = true,
        filterChargingEnabled: Boolean = true,
        ownPackageName: String? = null,
        nowMs: Long = System.currentTimeMillis(),
        notificationKey: String = "${packageName}_${title.hashCode()}"
    ): String? {
        // 1. Ignore DroidLink's own notification
        if (ownPackageName != null && packageName == ownPackageName) {
            return "own_app"
        }

        // 2. Per-app permissions
        if (!isPackageAllowed) {
            return "package_blocked"
        }

        // 3. Empty text and title
        if (title.isBlank() && text.isBlank()) {
            return "empty_content"
        }

        // 4. Group summary notifications (e.g. WhatsApp / Gmail group header "3 new messages")
        if ((flags and Notification.FLAG_GROUP_SUMMARY) != 0) {
            return "group_summary"
        }

        // 5. Transient Progress, Background Service, and Navigation
        if (category in listOf(
                Notification.CATEGORY_PROGRESS,
                Notification.CATEGORY_SERVICE,
                Notification.CATEGORY_NAVIGATION
            )
        ) {
            return "transient_category_$category"
        }

        // Check if notification is ongoing or foreground service
        val isReallyOngoing = isOngoing ||
            (flags and Notification.FLAG_ONGOING_EVENT != 0) ||
            (flags and Notification.FLAG_NO_CLEAR != 0) ||
            (flags and Notification.FLAG_FOREGROUND_SERVICE != 0)

        // 6. Media Playback Controls
        val hasMediaSession = extras?.containsKey(Notification.EXTRA_MEDIA_SESSION) == true ||
            extras?.containsKey("android.mediaSession") == true
        val isMediaCategory = category == Notification.CATEGORY_TRANSPORT || category == "transport"
        if (filterMediaEnabled && (hasMediaSession || isMediaCategory)) {
            return "media_playback"
        }

        // 7. Active Call Timers (chronometer ticks updating every second)
        val isCallCategory = category == Notification.CATEGORY_CALL || category == "call"
        val hasChronometer = extras?.containsKey(Notification.EXTRA_SHOW_CHRONOMETER) == true
        if (isCallCategory && (isReallyOngoing || hasChronometer)) {
            return "ongoing_call_timer"
        }

        // 8. Ongoing / Persistent Notifications
        if (filterOngoingEnabled && isReallyOngoing) {
            return "ongoing_notification"
        }

        // 9. Battery, Power, and Charging Alerts
        if (filterChargingEnabled) {
            val safeChannel = channelId?.lowercase() ?: ""
            val safeTitle = title.lowercase()
            val safeText = text.lowercase()
            val isSystemPkg = packageName in listOf("android", "com.android.systemui", "com.google.android.systemui")

            val isChargingChannel = safeChannel.contains("battery") || safeChannel.contains("charging") || safeChannel.contains("power")
            val isSystemStatus = isSystemPkg && (category == Notification.CATEGORY_STATUS || category == Notification.CATEGORY_SYSTEM)
            val isChargingText = safeTitle.contains("charging") || safeText.contains("charging") ||
                safeTitle.contains("charged") || safeText.contains("charged") ||
                safeTitle.contains("cable connected") || safeText.contains("cable connected") ||
                (isSystemPkg && (safeTitle.contains("battery") || safeText.contains("battery")))

            if (isChargingChannel || isSystemStatus || isChargingText) {
                return "charging_battery"
            }
        }

        // 10. Deduplication & Burst Throttling
        val previous = recentNotifications[notificationKey]
        if (previous != null) {
            val elapsed = nowMs - previous.timestamp
            // Identical title & text within 5 seconds -> drop duplicate
            if (previous.title == title && previous.text == text && elapsed < DEDUP_WINDOW_MS) {
                return "duplicate_within_window"
            }
            // Rapid burst updates from same key arriving faster than 1.5s -> throttle
            if (elapsed < THROTTLE_WINDOW_MS) {
                return "rapid_burst_throttled"
            }
        }

        // Record for deduplication
        recentNotifications[notificationKey] = NotificationRecord(title, text, nowMs)
        // Cleanup old records if map grows large
        if (recentNotifications.size > 200) {
            recentNotifications.entries.removeIf { nowMs - it.value.timestamp > 15_000L }
        }

        return null
    }
}

/**
 * NotificationListenerService that mirrors Android notifications to Mac
 * with app icons, labels, smart noise filtering, and deduplication.
 */
class DroidLinkNotificationListener : NotificationListenerService() {

    companion object {
        private const val TAG = "NotificationListener"
        var onNotificationCaptured: ((CapturedNotification) -> Unit)? = null
        var currentInstance: DroidLinkNotificationListener? = null
            private set
    }

    private val pairingStorage by lazy { PairingStorage(applicationContext) }

    override fun onListenerConnected() {
        super.onListenerConnected()
        currentInstance = this
        Log.i(TAG, "Notification listener connected")
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        if (currentInstance == this) {
            currentInstance = null
        }
        Log.i(TAG, "Notification listener disconnected")
    }

    override fun onDestroy() {
        super.onDestroy()
        if (currentInstance == this) {
            currentInstance = null
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        super.onNotificationPosted(sbn)
        if (sbn == null) return
        if (!pairingStorage.isNotificationSyncEnabled()) {
            Log.d(TAG, "Notification mirroring disabled in settings; ignoring.")
            return
        }

        val extras = sbn.notification.extras
        val title = extras?.getString(Notification.EXTRA_TITLE) ?: ""
        val bigText = extras?.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
        val regularText = extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString()
        val text = bigText?.takeIf { it.isNotBlank() } ?: regularText ?: ""

        val extrasMap = mutableMapOf<String, Any?>()
        extras?.keySet()?.forEach { k ->
            extrasMap[k] = extras.get(k)
        }

        val filterReason = NotificationFilter.shouldFilter(
            packageName = sbn.packageName,
            isOngoing = sbn.isOngoing,
            flags = sbn.notification.flags,
            category = sbn.notification.category,
            channelId = sbn.notification.channelId,
            title = title,
            text = text,
            extras = extrasMap,
            isPackageAllowed = pairingStorage.isPackageNotificationAllowed(sbn.packageName),
            filterOngoingEnabled = pairingStorage.isFilterOngoingEnabled(),
            filterMediaEnabled = pairingStorage.isFilterMediaEnabled(),
            filterChargingEnabled = pairingStorage.isFilterChargingEnabled(),
            ownPackageName = packageName,
            notificationKey = sbn.key ?: "${sbn.packageName}_${sbn.id}"
        )

        if (filterReason != null) {
            Log.d(TAG, "🚫 Filtered notification ($filterReason) from ${sbn.packageName}: '$title'")
            return
        }

        val appName = try {
            val pm = packageManager
            val appInfo = pm.getApplicationInfo(sbn.packageName, 0)
            pm.getApplicationLabel(appInfo).toString()
        } catch (e: Exception) {
            sbn.packageName
        }

        val iconBytes = extractIconBytes(sbn)

        val captured = CapturedNotification(
            id = sbn.key ?: sbn.id.toString(),
            packageName = sbn.packageName,
            appName = appName,
            title = title,
            text = text,
            iconBytes = iconBytes
        )

        Log.d(TAG, "🔔 Captured notification from $appName: $title - $text (icon size: ${iconBytes.size} bytes)")
        onNotificationCaptured?.invoke(captured)
    }

    private fun extractIconBytes(sbn: StatusBarNotification): ByteArray {
        return try {
            val drawable = sbn.notification.getLargeIcon()?.loadDrawable(this)
                ?: packageManager.getApplicationIcon(sbn.packageName)
            val bitmap = drawableToBitmap(drawable)
            val maxDimension = 64
            val scale = Math.min(maxDimension.toFloat() / bitmap.width, maxDimension.toFloat() / bitmap.height)
            val scaledWidth = Math.max(1, (bitmap.width * Math.min(1f, scale)).toInt())
            val scaledHeight = Math.max(1, (bitmap.height * Math.min(1f, scale)).toInt())
            val scaledBitmap = if (scaledWidth != bitmap.width || scaledHeight != bitmap.height) {
                Bitmap.createScaledBitmap(bitmap, scaledWidth, scaledHeight, true)
            } else {
                bitmap
            }
            val out = ByteArrayOutputStream()
            scaledBitmap.compress(Bitmap.CompressFormat.PNG, 80, out)
            val bytes = out.toByteArray()
            if (bytes.size > 15_000) {
                val jpegOut = ByteArrayOutputStream()
                scaledBitmap.compress(Bitmap.CompressFormat.JPEG, 75, jpegOut)
                jpegOut.toByteArray()
            } else {
                bytes
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to extract icon for ${sbn.packageName}: ${e.message}")
            ByteArray(0)
        }
    }

    private fun drawableToBitmap(drawable: Drawable): Bitmap {
        if (drawable is BitmapDrawable && drawable.bitmap != null) {
            return drawable.bitmap
        }
        val width = if (drawable.intrinsicWidth > 0) drawable.intrinsicWidth else 96
        val height = if (drawable.intrinsicHeight > 0) drawable.intrinsicHeight else 96
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, canvas.width, canvas.height)
        drawable.draw(canvas)
        return bitmap
    }
}
