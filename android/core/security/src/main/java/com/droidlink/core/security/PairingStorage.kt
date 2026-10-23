package com.droidlink.core.security

import android.content.Context
import android.util.Base64

data class StoredPairedDevice(
    val deviceId: String,
    val deviceName: String,
    val deviceModel: String = "Mac",
    val bluetoothAddress: String,
    val sessionKey: ByteArray,
    val host: String = "",
    val port: Int = 9999
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is StoredPairedDevice) return false
        return deviceId == other.deviceId && bluetoothAddress == other.bluetoothAddress && sessionKey.contentEquals(other.sessionKey)
    }

    override fun hashCode(): Int {
        var result = deviceId.hashCode()
        result = 31 * result + bluetoothAddress.hashCode()
        result = 31 * result + sessionKey.contentHashCode()
        return result
    }
}

class PairingStorage(context: Context) {
    private val prefs = context.getSharedPreferences("droidlink_pairing_prefs", Context.MODE_PRIVATE)

    companion object {
        private const val KEY_IS_PAIRED = "is_paired"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_DEVICE_NAME = "device_name"
        private const val KEY_DEVICE_MODEL = "device_model"
        private const val KEY_BLUETOOTH_ADDRESS = "bluetooth_address"
        private const val KEY_HOST = "host"
        private const val KEY_PORT = "port"
        private const val KEY_SESSION_KEY = "session_key_base64"
        private const val KEY_CLIPBOARD_SYNC_ENABLED = "clipboard_sync_enabled"
        private const val KEY_INCOGNITO_MODE = "incognito_mode_enabled"
        private const val KEY_AUTO_IGNORE_SENSITIVE = "auto_ignore_sensitive"
        private const val KEY_NOTIFICATION_SYNC_ENABLED = "notification_sync_enabled"
        private const val KEY_FILTER_ONGOING_NOTIFICATIONS = "filter_ongoing_notifications"
        private const val KEY_FILTER_CHARGING_NOTIFICATIONS = "filter_charging_notifications"
        private const val KEY_FILTER_MEDIA_NOTIFICATIONS = "filter_media_notifications"
        private const val KEY_SYNC_ALL_APPS_DEFAULT = "sync_all_apps_default"
        private const val KEY_BLOCKED_NOTIFICATION_PACKAGES = "blocked_notification_packages"
        private const val KEY_FINDER_STORAGE_ENABLED = "finder_storage_enabled"
        private const val KEY_MANUALLY_DISCONNECTED = "manually_disconnected"
    }

    fun isManuallyDisconnected(): Boolean = prefs.getBoolean(KEY_MANUALLY_DISCONNECTED, false)

    fun setManuallyDisconnected(disconnected: Boolean) {
        prefs.edit().putBoolean(KEY_MANUALLY_DISCONNECTED, disconnected).apply()
    }

    fun isFinderStorageEnabled(): Boolean = prefs.getBoolean(KEY_FINDER_STORAGE_ENABLED, true)

    fun setFinderStorageEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_FINDER_STORAGE_ENABLED, enabled).apply()
    }

    fun isClipboardSyncEnabled(): Boolean = prefs.getBoolean(KEY_CLIPBOARD_SYNC_ENABLED, true)

    fun setClipboardSyncEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_CLIPBOARD_SYNC_ENABLED, enabled).apply()
    }

    fun isNotificationSyncEnabled(): Boolean = prefs.getBoolean(KEY_NOTIFICATION_SYNC_ENABLED, true)

    fun setNotificationSyncEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_NOTIFICATION_SYNC_ENABLED, enabled).apply()
    }

    fun isFilterOngoingEnabled(): Boolean = prefs.getBoolean(KEY_FILTER_ONGOING_NOTIFICATIONS, true)

    fun setFilterOngoingEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_FILTER_ONGOING_NOTIFICATIONS, enabled).apply()
    }

    fun isFilterChargingEnabled(): Boolean = prefs.getBoolean(KEY_FILTER_CHARGING_NOTIFICATIONS, true)

    fun setFilterChargingEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_FILTER_CHARGING_NOTIFICATIONS, enabled).apply()
    }

    fun isFilterMediaEnabled(): Boolean = prefs.getBoolean(KEY_FILTER_MEDIA_NOTIFICATIONS, true)

    fun setFilterMediaEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_FILTER_MEDIA_NOTIFICATIONS, enabled).apply()
    }

    fun isSyncAllAppsByDefault(): Boolean = prefs.getBoolean(KEY_SYNC_ALL_APPS_DEFAULT, true)

    fun setSyncAllAppsByDefault(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_SYNC_ALL_APPS_DEFAULT, enabled).apply()
    }

    fun getBlockedNotificationPackages(): Set<String> {
        return prefs.getStringSet(KEY_BLOCKED_NOTIFICATION_PACKAGES, emptySet()) ?: emptySet()
    }

    fun setBlockedNotificationPackages(packages: Set<String>) {
        prefs.edit().putStringSet(KEY_BLOCKED_NOTIFICATION_PACKAGES, packages).apply()
    }

    fun isPackageNotificationAllowed(packageName: String): Boolean {
        if (!isNotificationSyncEnabled()) return false
        val blocked = getBlockedNotificationPackages()
        return !blocked.contains(packageName)
    }

    fun setPackageNotificationAllowed(packageName: String, allowed: Boolean) {
        val currentBlocked = getBlockedNotificationPackages().toMutableSet()
        if (allowed) {
            currentBlocked.remove(packageName)
        } else {
            currentBlocked.add(packageName)
        }
        setBlockedNotificationPackages(currentBlocked)
    }

    fun isIncognitoMode(): Boolean = prefs.getBoolean(KEY_INCOGNITO_MODE, false)

    fun setIncognitoMode(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_INCOGNITO_MODE, enabled).apply()
    }

    fun isAutoIgnoreSensitive(): Boolean = prefs.getBoolean(KEY_AUTO_IGNORE_SENSITIVE, true)

    fun setAutoIgnoreSensitive(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_AUTO_IGNORE_SENSITIVE, enabled).apply()
    }

    fun isPaired(): Boolean = prefs.getBoolean(KEY_IS_PAIRED, false)

    fun savePairedDevice(device: StoredPairedDevice) {
        val base64Key = Base64.encodeToString(device.sessionKey, Base64.NO_WRAP)
        prefs.edit()
            .putBoolean(KEY_IS_PAIRED, true)
            .putBoolean(KEY_MANUALLY_DISCONNECTED, false)
            .putString(KEY_DEVICE_ID, device.deviceId)
            .putString(KEY_DEVICE_NAME, device.deviceName)
            .putString(KEY_DEVICE_MODEL, device.deviceModel)
            .putString(KEY_BLUETOOTH_ADDRESS, device.bluetoothAddress)
            .putString(KEY_HOST, device.host)
            .putInt(KEY_PORT, device.port)
            .putString(KEY_SESSION_KEY, base64Key)
            .apply()
    }

    fun getPairedDevice(): StoredPairedDevice? {
        if (!isPaired()) return null
        val deviceId = prefs.getString(KEY_DEVICE_ID, null) ?: return null
        val deviceName = prefs.getString(KEY_DEVICE_NAME, "Mac") ?: "Mac"
        val deviceModel = prefs.getString(KEY_DEVICE_MODEL, "Mac") ?: "Mac"
        val bluetoothAddress = prefs.getString(KEY_BLUETOOTH_ADDRESS, "") ?: ""
        val host = prefs.getString(KEY_HOST, "") ?: ""
        val port = prefs.getInt(KEY_PORT, 9999)
        val base64Key = prefs.getString(KEY_SESSION_KEY, null) ?: return null
        val sessionKey = try {
            Base64.decode(base64Key, Base64.DEFAULT)
        } catch (e: Exception) {
            return null
        }
        return StoredPairedDevice(deviceId, deviceName, deviceModel, bluetoothAddress, sessionKey, host, port)
    }

    fun clear() {
        prefs.edit().clear().apply()
    }
}
