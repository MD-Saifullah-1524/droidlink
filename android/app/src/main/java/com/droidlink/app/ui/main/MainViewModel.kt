package com.droidlink.app.ui.main

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.compose.ui.graphics.asImageBitmap
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.droidlink.app.model.AppNotificationInfo
import com.droidlink.app.service.CapturedNotification
import com.droidlink.app.service.DroidLinkNotificationListener
import com.droidlink.app.service.DroidLinkService
import com.droidlink.app.service.ServiceConnectionState
import com.droidlink.core.security.PairingStorage
import com.droidlink.core.security.StoredPairedDevice
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import com.droidlink.core.network.bluetooth.BleClient
import com.droidlink.core.network.bluetooth.BleScanner
import com.droidlink.core.network.bluetooth.DiscoveredBleDevice
import com.droidlink.core.security.CryptoChannel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.util.UUID

import android.Manifest
import androidx.core.content.ContextCompat

sealed class MainUiState {
    data object Disconnected : MainUiState()
    data class Paired(val deviceName: String, val deviceModel: String = "Mac") : MainUiState()
    data class BleScanning(val discoveredDevices: List<DiscoveredBleDevice> = emptyList()) : MainUiState()
    data class Connecting(val deviceName: String, val deviceModel: String = "Mac") : MainUiState()
    data class Connected(val deviceName: String, val deviceModel: String = "Mac") : MainUiState()
    data class Error(val message: String) : MainUiState()
}

class MainViewModel(private val context: Context) : ViewModel() {
    private val _uiState = MutableStateFlow<MainUiState>(MainUiState.Disconnected)
    val uiState: StateFlow<MainUiState> = _uiState.asStateFlow()

    private val bleScanner = BleScanner(context)
    private val pairingStorage = PairingStorage(context)

    // Remote Telemetry
    val remoteDeviceStatus: StateFlow<com.droidlink.app.model.DeviceStatusInfo?> = DroidLinkService.remoteDeviceStatus

    // Modules Toggles
    private val _isClipboardSyncEnabled = MutableStateFlow(pairingStorage.isClipboardSyncEnabled())
    val isClipboardSyncEnabled: StateFlow<Boolean> = _isClipboardSyncEnabled.asStateFlow()

    private val _isFinderStorageEnabled = MutableStateFlow(pairingStorage.isFinderStorageEnabled())
    val isFinderStorageEnabled: StateFlow<Boolean> = _isFinderStorageEnabled.asStateFlow()

    // Privacy & Clipboard
    private val _isIncognitoMode = MutableStateFlow(pairingStorage.isIncognitoMode())
    val isIncognitoMode: StateFlow<Boolean> = _isIncognitoMode.asStateFlow()

    private val _autoIgnoreSensitive = MutableStateFlow(pairingStorage.isAutoIgnoreSensitive())
    val autoIgnoreSensitive: StateFlow<Boolean> = _autoIgnoreSensitive.asStateFlow()

    // Notification Mirroring
    private val _isNotificationSyncEnabled = MutableStateFlow(pairingStorage.isNotificationSyncEnabled())
    val isNotificationSyncEnabled: StateFlow<Boolean> = _isNotificationSyncEnabled.asStateFlow()

    private val _isFilterOngoing = MutableStateFlow(pairingStorage.isFilterOngoingEnabled())
    val isFilterOngoing: StateFlow<Boolean> = _isFilterOngoing.asStateFlow()

    private val _isFilterCharging = MutableStateFlow(pairingStorage.isFilterChargingEnabled())
    val isFilterCharging: StateFlow<Boolean> = _isFilterCharging.asStateFlow()

    private val _isFilterMedia = MutableStateFlow(pairingStorage.isFilterMediaEnabled())
    val isFilterMedia: StateFlow<Boolean> = _isFilterMedia.asStateFlow()

    private val _installedApps = MutableStateFlow<List<AppNotificationInfo>>(emptyList())
    val installedApps: StateFlow<List<AppNotificationInfo>> = _installedApps.asStateFlow()

    private val _isLoadingApps = MutableStateFlow(false)
    val isLoadingApps: StateFlow<Boolean> = _isLoadingApps.asStateFlow()

    private val _hasNotificationListenerPermission = MutableStateFlow(checkNotificationListenerPermission())
    val hasNotificationListenerPermission: StateFlow<Boolean> = _hasNotificationListenerPermission.asStateFlow()

    private val _hasBluetoothPermission = MutableStateFlow(checkBluetoothPermission())
    val hasBluetoothPermission: StateFlow<Boolean> = _hasBluetoothPermission.asStateFlow()

    private val _hasPostNotificationPermission = MutableStateFlow(checkPostNotificationPermission())
    val hasPostNotificationPermission: StateFlow<Boolean> = _hasPostNotificationPermission.asStateFlow()

    private val _isMediaProjectionGranted = MutableStateFlow(DroidLinkService.mediaProjection != null)
    val isMediaProjectionGranted: StateFlow<Boolean> = _isMediaProjectionGranted.asStateFlow()

    private val _isAccessibilityEnabled = MutableStateFlow(com.droidlink.app.service.DroidLinkAccessibilityService.isEnabled)
    val isAccessibilityEnabled: StateFlow<Boolean> = _isAccessibilityEnabled.asStateFlow()

    private val _isOverlayPermissionGranted = MutableStateFlow(Settings.canDrawOverlays(context))
    val isOverlayPermissionGranted: StateFlow<Boolean> = _isOverlayPermissionGranted.asStateFlow()

    private val _isWriteSettingsGranted = MutableStateFlow(Settings.System.canWrite(context))
    val isWriteSettingsGranted: StateFlow<Boolean> = _isWriteSettingsGranted.asStateFlow()

    private val telemetryCollector = com.droidlink.app.telemetry.AndroidTelemetryCollector(context)
    private val _localDeviceStatus = MutableStateFlow(telemetryCollector.collectStatus())
    val localDeviceStatus: StateFlow<com.droidlink.app.model.DeviceStatusInfo> = _localDeviceStatus.asStateFlow()

    // USB Connection State
    val isUsbConnected: StateFlow<Boolean> = DroidLinkService.isUsbConnected

    // Screen Mirroring State
    val isScreenMirroringActive: StateFlow<Boolean> = DroidLinkService.isScreenMirroringActive

    fun startScreenMirroring() {
        DroidLinkService.startScreenMirroringSession()
    }

    fun stopScreenMirroring() {
        DroidLinkService.stopScreenMirroringSession()
    }

    fun triggerTestClipboardSync(): String {
        val testText = "DroidLink Sync Test #${(1000..9999).random()}"
        val clip = android.content.ClipData.newPlainText("DroidLink", testText)
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
        clipboard.setPrimaryClip(clip)
        DroidLinkService.triggerClipboardSync()
        return testText
    }

    // Shizuku Zero-ADB Privileged Mode
    val shizukuState: StateFlow<com.droidlink.app.shizuku.ShizukuState> = com.droidlink.app.shizuku.ShizukuManager.state

    fun requestShizukuPermission() {
        com.droidlink.app.shizuku.ShizukuManager.requestPermission()
    }

    fun launchExternalDisplay(width: Int = 0, height: Int = 0, scaleFactor: Float = 2.0f) {
        if (!DroidLinkService.isUsbConnected.value) {
            return
        }
        val (detectedW, detectedH) = com.droidlink.app.display.ExternalDisplayActivity.getNativeLandscapeResolution(context)
        val targetW = if (width > 0) width else detectedW
        val targetH = if (height > 0) height else detectedH
        DroidLinkService.requestStartExternalDisplay(targetW, targetH, scaleFactor)
        com.droidlink.app.display.ExternalDisplayActivity.start(context, targetW, targetH, scaleFactor)
    }

    companion object {
        private const val TAG = "MainViewModel"
    }

    init {
        viewModelScope.launch {
            DroidLinkService.connectionState.collect { serviceState ->
                val paired = pairingStorage.getPairedDevice()
                val model = paired?.deviceModel ?: "Mac"
                when (serviceState) {
                    is ServiceConnectionState.Disconnected -> {
                        if (_uiState.value !is MainUiState.BleScanning) {
                            if (paired != null) {
                                _uiState.value = MainUiState.Paired(paired.deviceName, model)
                            } else {
                                _uiState.value = MainUiState.Disconnected
                            }
                        }
                    }
                    is ServiceConnectionState.Connecting -> {
                        _uiState.value = MainUiState.Connecting(serviceState.deviceName, model)
                    }
                    is ServiceConnectionState.Connected -> {
                        _uiState.value = MainUiState.Connected(serviceState.deviceName, model)
                    }
                    is ServiceConnectionState.Error -> {
                        _uiState.value = MainUiState.Error(serviceState.message)
                    }
                }
            }
        }

        viewModelScope.launch {
            DroidLinkService.remoteDeviceStatus.collect { remoteStatus ->
                if (remoteStatus != null && remoteStatus.deviceModel.isNotEmpty()) {
                    val paired = pairingStorage.getPairedDevice()
                    if (paired != null && paired.deviceModel != remoteStatus.deviceModel) {
                        val updated = paired.copy(deviceModel = remoteStatus.deviceModel)
                        pairingStorage.savePairedDevice(updated)
                        if (_uiState.value is MainUiState.Connected) {
                            _uiState.value = MainUiState.Connected(paired.deviceName, remoteStatus.deviceModel)
                        }
                    }
                }
            }
        }

        viewModelScope.launch {
            while (isActive) {
                delay(5000)
                _localDeviceStatus.value = telemetryCollector.collectStatus()
            }
        }

        // Auto-connect to paired device on startup if present and not manually disconnected
        val paired = pairingStorage.getPairedDevice()
        if (paired != null && DroidLinkService.connectionState.value !is ServiceConnectionState.Connected) {
            if (pairingStorage.isManuallyDisconnected()) {
                Log.d(TAG, "Paired device was manually disconnected; staying disconnected on startup.")
                _uiState.value = MainUiState.Paired(paired.deviceName, paired.deviceModel)
            } else {
                Log.d(TAG, "Auto-connecting to stored paired device: ${paired.deviceName} (${paired.bluetoothAddress})")
                connectToDevice(paired)
            }
        }

        loadInstalledApps()
    }

    fun setClipboardSyncEnabled(enabled: Boolean) {
        pairingStorage.setClipboardSyncEnabled(enabled)
        _isClipboardSyncEnabled.value = enabled
        DroidLinkService.broadcastTelemetry(context)
    }

    fun refreshPermissionStatus() {
        _hasNotificationListenerPermission.value = checkNotificationListenerPermission()
        _hasBluetoothPermission.value = checkBluetoothPermission()
        _hasPostNotificationPermission.value = checkPostNotificationPermission()
        _isMediaProjectionGranted.value = (DroidLinkService.mediaProjection != null)
        _isAccessibilityEnabled.value = com.droidlink.app.service.DroidLinkAccessibilityService.isEnabled
        _isOverlayPermissionGranted.value = Settings.canDrawOverlays(context)
        _isWriteSettingsGranted.value = Settings.System.canWrite(context)
    }

    fun openOverlaySettings() {
        try {
            val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${context.packageName}")).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open overlay settings", e)
        }
    }

    fun openWriteSettings() {
        try {
            val intent = Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS, Uri.parse("package:${context.packageName}")).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open write settings", e)
        }
    }

    fun updateMediaProjectionGranted(granted: Boolean) {
        _isMediaProjectionGranted.value = granted
    }

    fun openAccessibilitySettings() {
        try {
            val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open accessibility settings", e)
        }
    }

    fun checkBluetoothPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val scan = ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
            val connect = ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
            scan && connect
        } else {
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        }
    }

    fun checkPostNotificationPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private fun checkNotificationListenerPermission(): Boolean {
        return try {
            val flat = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners")
            flat != null && flat.contains(context.packageName)
        } catch (e: Exception) {
            false
        }
    }

    fun getNotificationListenerSettingsIntent(): Intent {
        return Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
    }

    fun loadInstalledApps() {
        viewModelScope.launch(Dispatchers.IO) {
            _isLoadingApps.value = true
            try {
                val pm = context.packageManager
                val installedPackages = pm.getInstalledPackages(PackageManager.GET_META_DATA)
                val blocked = pairingStorage.getBlockedNotificationPackages()
                val list = mutableListOf<AppNotificationInfo>()
                val notificationManager = NotificationManagerCompat.from(context)

                for (pkg in installedPackages) {
                    val appInfo = pkg.applicationInfo ?: continue
                    val launchIntent = pm.getLaunchIntentForPackage(pkg.packageName)
                    val isSystemApp = (appInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0

                    // Keep launchable user apps or apps with notification capability
                    if (launchIntent == null && isSystemApp) {
                        continue
                    }
                    if (pkg.packageName == context.packageName) continue

                    val appName = try {
                        pm.getApplicationLabel(appInfo).toString()
                    } catch (e: Exception) {
                        pkg.packageName
                    }

                    val isSystemAllowed = notificationManager.areNotificationsEnabled()
                    val isBlockedInDroidLink = blocked.contains(pkg.packageName)
                    val isSyncEnabled = isSystemAllowed && !isBlockedInDroidLink

                    val iconBitmap = try {
                        val drawable = pm.getApplicationIcon(appInfo)
                        drawableToBitmap(drawable)
                    } catch (e: Exception) {
                        null
                    }

                    val imageBitmap = try {
                        iconBitmap?.asImageBitmap()
                    } catch (e: Exception) {
                        null
                    }

                    list.add(
                        AppNotificationInfo(
                            packageName = pkg.packageName,
                            appName = appName,
                            isSystemAllowed = isSystemAllowed,
                            isSyncEnabled = isSyncEnabled,
                            iconBitmap = iconBitmap,
                            iconImageBitmap = imageBitmap
                        )
                    )
                }

                list.sortBy { it.appName.lowercase() }
                _installedApps.value = list
            } catch (e: Exception) {
                Log.e(TAG, "Error loading installed apps", e)
            } finally {
                _isLoadingApps.value = false
            }
        }
    }

    fun setAppNotificationAllowed(packageName: String, allowed: Boolean) {
        pairingStorage.setPackageNotificationAllowed(packageName, allowed)
        val updated = _installedApps.value.map { app ->
            if (app.packageName == packageName) {
                app.copy(isSyncEnabled = allowed)
            } else {
                app
            }
        }
        _installedApps.value = updated
    }

    fun selectAllApps(allowed: Boolean) {
        if (allowed) {
            pairingStorage.setBlockedNotificationPackages(emptySet())
        } else {
            val allPackages = _installedApps.value.map { it.packageName }.toSet()
            pairingStorage.setBlockedNotificationPackages(allPackages)
        }
        val updated = _installedApps.value.map { it.copy(isSyncEnabled = allowed) }
        _installedApps.value = updated
    }

    fun resetAppsToSystemDefaults() {
        pairingStorage.setBlockedNotificationPackages(emptySet())
        val updated = _installedApps.value.map { it.copy(isSyncEnabled = it.isSystemAllowed) }
        _installedApps.value = updated
    }

    fun setNotificationSyncEnabled(enabled: Boolean) {
        pairingStorage.setNotificationSyncEnabled(enabled)
        _isNotificationSyncEnabled.value = enabled
        DroidLinkService.broadcastTelemetry(context)
    }

    fun setFilterOngoing(enabled: Boolean) {
        pairingStorage.setFilterOngoingEnabled(enabled)
        _isFilterOngoing.value = enabled
    }

    fun setFilterCharging(enabled: Boolean) {
        pairingStorage.setFilterChargingEnabled(enabled)
        _isFilterCharging.value = enabled
    }

    fun setFilterMedia(enabled: Boolean) {
        pairingStorage.setFilterMediaEnabled(enabled)
        _isFilterMedia.value = enabled
    }

    fun sendTestNotificationToMac() {
        viewModelScope.launch {
            try {
                val iconBytes = try {
                    val drawable = context.packageManager.getApplicationIcon(context.packageName)
                    val bitmap = drawableToBitmap(drawable)
                    val out = ByteArrayOutputStream()
                    bitmap.compress(Bitmap.CompressFormat.PNG, 80, out)
                    out.toByteArray()
                } catch (e: Exception) {
                    ByteArray(0)
                }

                val test = CapturedNotification(
                    id = "test_${System.currentTimeMillis()}",
                    packageName = context.packageName,
                    appName = "DroidLink Test",
                    title = "Test Notification from Android",
                    text = "Notification mirroring is working seamlessly!",
                    iconBytes = iconBytes
                )
                DroidLinkNotificationListener.onNotificationCaptured?.invoke(test)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to trigger test notification", e)
            }
        }
    }

    private fun drawableToBitmap(drawable: Drawable): Bitmap {
        val targetSize = 64
        if (drawable is BitmapDrawable && drawable.bitmap != null) {
            val b = drawable.bitmap
            if (b.width <= targetSize && b.height <= targetSize) {
                return b
            }
            return Bitmap.createScaledBitmap(b, targetSize, targetSize, true)
        }
        val bitmap = Bitmap.createBitmap(targetSize, targetSize, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, targetSize, targetSize)
        drawable.draw(canvas)
        return bitmap
    }

    private fun connectToDevice(device: StoredPairedDevice) {
        pairingStorage.setManuallyDisconnected(false)
        _uiState.value = MainUiState.Connecting(device.deviceName)
        DroidLinkService.start(
            context = context,
            bluetoothAddress = device.bluetoothAddress,
            deviceName = device.deviceName,
            sessionKey = device.sessionKey,
            host = device.host,
            port = device.port
        )
    }

    fun reconnect() {
        pairingStorage.setManuallyDisconnected(false)
        val paired = pairingStorage.getPairedDevice()
        if (paired != null) {
            connectToDevice(paired)
        } else {
            startPairing()
        }
    }

    fun startPairing() {
        startBluetoothScan()
    }

    fun startBluetoothScan() {
        Log.d(TAG, "startBluetoothScan called")
        val discoveredList = mutableListOf<DiscoveredBleDevice>()
        _uiState.value = MainUiState.BleScanning(emptyList())

        bleScanner.startScan(
            onDeviceFound = { discovered ->
                viewModelScope.launch {
                    val index = discoveredList.indexOfFirst { it.address == discovered.address }
                    if (index >= 0) {
                        discoveredList[index] = discovered
                    } else {
                        discoveredList.add(discovered)
                    }
                    _uiState.value = MainUiState.BleScanning(discoveredList.toList())
                }
            },
            onError = { errMsg ->
                viewModelScope.launch {
                    _uiState.value = MainUiState.Error(errMsg)
                }
            }
        )
    }

    fun stopBluetoothScan() {
        bleScanner.stopScan()
    }

    fun pairWithDevice(device: DiscoveredBleDevice) {
        Log.d(TAG, "pairWithDevice called: ${device.name} (${device.address})")
        bleScanner.stopScan()
        _uiState.value = MainUiState.Connecting("Pairing with ${device.name}...")

        viewModelScope.launch {
            try {
                val sessionKey = CryptoChannel.generateSessionKey()
                val client = BleClient(context, device.address, null)
                withContext(Dispatchers.IO) {
                    client.connect()
                    val myDeviceId = Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
                        ?: UUID.randomUUID().toString()
                    val myDeviceName = Build.MODEL ?: "Android Device"
                    val success = client.performPairingHandshake(myDeviceId, myDeviceName, sessionKey)
                    client.close()
                    if (!success) {
                        throw IllegalStateException("Failed to exchange pairing keys with ${device.name}")
                    }
                }

                // Brief pause to allow remote peripheral to finalize pairing state
                kotlinx.coroutines.delay(500)

                val stored = StoredPairedDevice(
                    deviceId = device.address,
                    deviceName = device.name,
                    deviceModel = "Mac",
                    bluetoothAddress = device.address,
                    sessionKey = sessionKey
                )
                pairingStorage.savePairedDevice(stored)
                connectToDevice(stored)
            } catch (e: Exception) {
                Log.e(TAG, "Pairing failed", e)
                _uiState.value = MainUiState.Error("Pairing failed: ${e.message}")
            }
        }
    }

    fun disconnect() {
        pairingStorage.setManuallyDisconnected(true)
        DroidLinkService.stop(context)
        val paired = pairingStorage.getPairedDevice()
        if (paired != null) {
            _uiState.value = MainUiState.Paired(paired.deviceName, paired.deviceModel)
        } else {
            _uiState.value = MainUiState.Disconnected
        }
    }

    fun forgetDevice() {
        Log.d(TAG, "forgetDevice called")
        pairingStorage.clear()
        DroidLinkService.stop(context)
        _uiState.value = MainUiState.Disconnected
    }

    fun cancelPairing() {
        bleScanner.stopScan()
        val paired = pairingStorage.getPairedDevice()
        if (paired != null) {
            _uiState.value = MainUiState.Paired(paired.deviceName, paired.deviceModel)
        } else {
            _uiState.value = MainUiState.Disconnected
        }
    }

    override fun onCleared() {
        super.onCleared()
        bleScanner.stopScan()
    }

    fun toggleIncognitoMode() {
        setIncognitoMode(!_isIncognitoMode.value)
    }

    fun setIncognitoMode(enabled: Boolean) {
        pairingStorage.setIncognitoMode(enabled)
        _isIncognitoMode.value = enabled
        DroidLinkService.updatePrivacyPreferences(
            context,
            isIncognito = enabled,
            autoIgnoreSensitive = _autoIgnoreSensitive.value
        )
    }

    fun toggleAutoIgnoreSensitive() {
        setAutoIgnoreSensitive(!_autoIgnoreSensitive.value)
    }

    fun setAutoIgnoreSensitive(enabled: Boolean) {
        pairingStorage.setAutoIgnoreSensitive(enabled)
        _autoIgnoreSensitive.value = enabled
        DroidLinkService.updatePrivacyPreferences(
            context,
            isIncognito = _isIncognitoMode.value,
            autoIgnoreSensitive = enabled
        )
    }

    fun copyToClipboard(text: String) {
        try {
            val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
            val clip = android.content.ClipData.newPlainText("DroidLink", text)
            cm.setPrimaryClip(clip)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to set clipboard", e)
        }
    }

    fun setFinderStorageEnabled(enabled: Boolean) {
        pairingStorage.setFinderStorageEnabled(enabled)
        _isFinderStorageEnabled.value = enabled
        DroidLinkService.broadcastTelemetry(context)
    }
}