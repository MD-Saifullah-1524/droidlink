package com.droidlink.app.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.BroadcastReceiver
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.widget.Toast
import java.io.File
import android.content.pm.ServiceInfo
import android.graphics.BitmapFactory
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import com.droidlink.app.R
import com.droidlink.app.MainActivity
import com.droidlink.core.clipboard.ClipboardManager
import com.droidlink.core.network.bluetooth.BleClient
import com.droidlink.core.security.CryptoChannel
import com.droidlink.app.filesystem.AndroidFileSystemManager
import com.droidlink.app.filesystem.AndroidFileWatcher
import com.google.protobuf.ByteString
import droidlink.protocol.ClipboardProto
import droidlink.protocol.DroidlinkMessages
import droidlink.protocol.FileProto
import droidlink.protocol.NotificationProto
import droidlink.protocol.SystemProto
import droidlink.protocol.ExternalDisplayProto
import droidlink.protocol.ScreenProto
import com.droidlink.app.display.ExternalDisplayActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

sealed class ServiceConnectionState {
    data object Disconnected : ServiceConnectionState()
    data class Connecting(val deviceName: String) : ServiceConnectionState()
    data class Connected(val deviceName: String) : ServiceConnectionState()
    data class Error(val message: String) : ServiceConnectionState()
}

/**
 * Android 15+ Foreground Service using foregroundServiceType="connectedDevice".
 * Maintains single persistent encrypted Bluetooth LE connection with Mac, clipboard sync, and notification mirroring.
 */
class DroidLinkService : Service() {

    private val serviceScope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private var bleClient: BleClient? = null
    private var tcpClient: com.droidlink.core.network.TcpClient? = null
    private var aoaTransport: com.droidlink.core.network.AoaUsbTransport? = null
    private var sessionKey: ByteArray? = null
    private var clipboardManager: ClipboardManager? = null
    private val fileSystemManager = AndroidFileSystemManager()
    private var fileWatcher: AndroidFileWatcher? = null
    private var batteryReceiver: BroadcastReceiver? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var telemetryTickerJob: Job? = null
    private var lastSentTelemetry: com.droidlink.app.model.DeviceStatusInfo? = null

    companion object {
        private var activeServiceInstance: DroidLinkService? = null

        fun sendExternalDisplayInput(input: ExternalDisplayProto.ExternalDisplayInput) {
            val service = activeServiceInstance ?: return
            service.serviceScope.launch {
                try {
                    val msg = ExternalDisplayProto.ExternalDisplayMessage.newBuilder()
                        .setEvent(ExternalDisplayProto.ExternalDisplayMessage.DisplayEventType.INPUT_EVENT)
                        .setInput(input)
                        .setTimestamp(System.currentTimeMillis())
                        .build()

                    val rootMsg = DroidlinkMessages.DroidLinkMessage.newBuilder()
                        .setId(System.currentTimeMillis())
                        .setTimestamp(System.currentTimeMillis())
                        .setType(DroidlinkMessages.MessageType.EXTERNAL_DISPLAY)
                        .setExternalDisplay(msg)
                        .build()

                    service.sendHighSpeedMessage(rootMsg.toByteArray())
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to send external display input", e)
                }
            }
        }

        fun notifyExternalDisplayStopped() {
            val service = activeServiceInstance ?: return
            service.serviceScope.launch {
                try {
                    val msg = ExternalDisplayProto.ExternalDisplayMessage.newBuilder()
                        .setEvent(ExternalDisplayProto.ExternalDisplayMessage.DisplayEventType.STOP)
                        .setTimestamp(System.currentTimeMillis())
                        .build()

                    val rootMsg = DroidlinkMessages.DroidLinkMessage.newBuilder()
                        .setId(System.currentTimeMillis())
                        .setTimestamp(System.currentTimeMillis())
                        .setType(DroidlinkMessages.MessageType.EXTERNAL_DISPLAY)
                        .setExternalDisplay(msg)
                        .build()

                    service.sendHighSpeedMessage(rootMsg.toByteArray())
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to notify external display stopped", e)
                }
            }
        }

        fun sendExternalDisplayCalibrationComplete(calibratedBacklight: Float) {
            val service = activeServiceInstance ?: return
            service.serviceScope.launch {
                try {
                    val calib = ExternalDisplayProto.ExternalDisplayCalibration.newBuilder()
                        .setIsCalibrating(false)
                        .setCalibratedBacklight(calibratedBacklight)
                        .build()

                    val msg = ExternalDisplayProto.ExternalDisplayMessage.newBuilder()
                        .setEvent(ExternalDisplayProto.ExternalDisplayMessage.DisplayEventType.CALIBRATION_COMPLETE)
                        .setCalibration(calib)
                        .setTimestamp(System.currentTimeMillis())
                        .build()

                    val rootMsg = DroidlinkMessages.DroidLinkMessage.newBuilder()
                        .setId(System.currentTimeMillis())
                        .setTimestamp(System.currentTimeMillis())
                        .setType(DroidlinkMessages.MessageType.EXTERNAL_DISPLAY)
                        .setExternalDisplay(msg)
                        .build()

                    service.sendHighSpeedMessage(rootMsg.toByteArray())
                    Log.i(TAG, "🎯 Sent CALIBRATION_COMPLETE to Mac (backlight=$calibratedBacklight)")
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to send calibration complete to Mac", e)
                }
            }
        }

        fun requestStartExternalDisplay(width: Int = 0, height: Int = 0, scaleFactor: Float = 2.0f, fps: Int = 60, hiDpi: Boolean = true) {
            val service = activeServiceInstance ?: return
            service.serviceScope.launch {
                try {
                    val (detectedW, detectedH) = ExternalDisplayActivity.getNativeLandscapeResolution(service.applicationContext)
                    val targetW = if (width > 0) width else detectedW
                    val targetH = if (height > 0) height else detectedH

                    val config = ExternalDisplayProto.ExternalDisplayConfig.newBuilder()
                        .setWidth(targetW)
                        .setHeight(targetH)
                        .setScaleFactor(scaleFactor)
                        .setFps(fps)
                        .setHiDpi(hiDpi)
                        .setCodec(ExternalDisplayProto.DisplayCodec.DISPLAY_H264)
                        .setEnableInput(true)
                        .build()

                    val msg = ExternalDisplayProto.ExternalDisplayMessage.newBuilder()
                        .setEvent(ExternalDisplayProto.ExternalDisplayMessage.DisplayEventType.START_REQUEST)
                        .setConfig(config)
                        .setTimestamp(System.currentTimeMillis())
                        .build()

                    val rootMsg = DroidlinkMessages.DroidLinkMessage.newBuilder()
                        .setId(System.currentTimeMillis())
                        .setTimestamp(System.currentTimeMillis())
                        .setType(DroidlinkMessages.MessageType.EXTERNAL_DISPLAY)
                        .setExternalDisplay(msg)
                        .build()

                    service.sendHighSpeedMessage(rootMsg.toByteArray())
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to send START_REQUEST for external display", e)
                }
            }
        }

        fun showExternalDisplayNotification(width: Int, height: Int, scaleFactor: Float = 2.0f) {
            val service = activeServiceInstance ?: return
            try {
                val nm = service.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
                val openIntent = Intent(service, ExternalDisplayActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                }
                val openPendingIntent = PendingIntent.getActivity(
                    service,
                    201,
                    openIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )

                val stopIntent = Intent(service, DroidLinkService::class.java).apply {
                    action = ACTION_STOP_EXTERNAL_DISPLAY
                }
                val stopPendingIntent = PendingIntent.getService(
                    service,
                    202,
                    stopIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )

                val scaleText = if (scaleFactor > 0f) " • Scale ${scaleFactor}x" else ""
                val notif = NotificationCompat.Builder(service, CHANNEL_ID)
                    .setContentTitle("Mac External Display Active")
                    .setContentText("Streaming at ${width}×${height}${scaleText} • Tap to view or disconnect")
                    .setSmallIcon(R.drawable.ic_stat_droidlink)
                    .setOngoing(true)
                    .setPriority(NotificationCompat.PRIORITY_LOW)
                    .setContentIntent(openPendingIntent)
                    .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Disconnect", stopPendingIntent)
                    .build()

                nm.notify(NOTIFICATION_ID_EXTERNAL_DISPLAY, notif)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to show external display notification", e)
            }
        }

        fun dismissExternalDisplayNotification() {
            val service = activeServiceInstance ?: return
            try {
                val nm = service.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
                nm.cancel(NOTIFICATION_ID_EXTERNAL_DISPLAY)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to dismiss external display notification", e)
            }
        }

        private const val TAG = "DroidLinkService"
        private const val NOTIFICATION_ID = 1001
        private const val NOTIFICATION_ID_EXTERNAL_DISPLAY = 3003
        private const val NOTIFICATION_ID_FILE_TRANSFER = 4004
        private const val CHANNEL_ID = "droidlink_channel"
        private const val CHANNEL_ID_FILE_TRANSFER = "droidlink_file_transfer"

        fun isConnected(): Boolean {
            val service = activeServiceInstance ?: return false
            return service.isTransportConnected()
        }

        fun sendSharedFiles(context: Context, uris: List<Uri>) {
            val service = activeServiceInstance
            if (service == null || !service.isTransportConnected()) {
                Toast.makeText(context, context.getString(R.string.not_connected_to_mac), Toast.LENGTH_LONG).show()
                return
            }
            service.sendSharedFiles(uris)
        }

        const val ACTION_CONNECT = "com.droidlink.ACTION_CONNECT"
        const val ACTION_DISCONNECT = "com.droidlink.ACTION_DISCONNECT"
        const val ACTION_STOP_EXTERNAL_DISPLAY = "com.droidlink.ACTION_STOP_EXTERNAL_DISPLAY"
        const val ACTION_UPDATE_PRIVACY = "com.droidlink.ACTION_UPDATE_PRIVACY"
        const val ACTION_BROADCAST_TELEMETRY = "com.droidlink.ACTION_BROADCAST_TELEMETRY"
        const val ACTION_CONNECT_USB = "com.droidlink.ACTION_CONNECT_USB"

        const val EXTRA_BLUETOOTH_ADDRESS = "extra_bluetooth_address"
        const val EXTRA_HOST = "extra_host"
        const val EXTRA_PORT = "extra_port"
        const val EXTRA_DEVICE_NAME = "extra_device_name"
        const val EXTRA_SESSION_KEY = "extra_session_key"
        const val EXTRA_INCOGNITO_MODE = "extra_incognito_mode"
        const val EXTRA_AUTO_IGNORE_SENSITIVE = "extra_auto_ignore_sensitive"
        const val EXTRA_USB_ACCESSORY = "extra_usb_accessory"

        fun handleUsbAccessoryAttached(context: Context, accessory: android.hardware.usb.UsbAccessory) {
            Log.i(TAG, "🔌 handleUsbAccessoryAttached: ${accessory.manufacturer} - ${accessory.model}")
            val instance = activeServiceInstance
            if (instance != null) {
                instance.connectAoa(accessory)
            } else {
                val intent = Intent(context, DroidLinkService::class.java).apply {
                    action = ACTION_CONNECT_USB
                    putExtra(EXTRA_USB_ACCESSORY, accessory)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            }
        }

        fun handleUsbAccessoryDetached(context: Context) {
            Log.i(TAG, "🔌 handleUsbAccessoryDetached")
            activeServiceInstance?.disconnectAoa()
        }

        fun triggerClipboardSync() {
            activeServiceInstance?.checkClipboard()
        }

        fun sendClipboardDirect(text: String) {
            activeServiceInstance?.sendClipboardDirect(text)
        }

        private val _connectionState = MutableStateFlow<ServiceConnectionState>(ServiceConnectionState.Disconnected)
        val connectionState: StateFlow<ServiceConnectionState> = _connectionState.asStateFlow()

        private val _isUsbConnected = MutableStateFlow<Boolean>(false)
        val isUsbConnected: StateFlow<Boolean> = _isUsbConnected.asStateFlow()

        private val _remoteDeviceStatus = MutableStateFlow<com.droidlink.app.model.DeviceStatusInfo?>(null)
        val remoteDeviceStatus: StateFlow<com.droidlink.app.model.DeviceStatusInfo?> = _remoteDeviceStatus.asStateFlow()

        fun start(
            context: Context,
            bluetoothAddress: String,
            deviceName: String,
            sessionKey: ByteArray,
            host: String = "",
            port: Int = 9999
        ) {
            val intent = Intent(context, DroidLinkService::class.java).apply {
                action = ACTION_CONNECT
                putExtra(EXTRA_BLUETOOTH_ADDRESS, bluetoothAddress)
                putExtra(EXTRA_HOST, host)
                putExtra(EXTRA_PORT, port)
                putExtra(EXTRA_DEVICE_NAME, deviceName)
                putExtra(EXTRA_SESSION_KEY, sessionKey)
            }
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, DroidLinkService::class.java).apply {
                action = ACTION_DISCONNECT
            }
            context.startService(intent)
        }

        fun broadcastTelemetry(context: Context) {
            val intent = Intent(context, DroidLinkService::class.java).apply {
                action = ACTION_BROADCAST_TELEMETRY
            }
            try {
                context.startService(intent)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to send telemetry update intent to service: ${e.message}")
            }
        }

        fun updatePrivacyPreferences(context: Context, isIncognito: Boolean, autoIgnoreSensitive: Boolean) {
            val intent = Intent(context, DroidLinkService::class.java).apply {
                action = ACTION_UPDATE_PRIVACY
                putExtra(EXTRA_INCOGNITO_MODE, isIncognito)
                putExtra(EXTRA_AUTO_IGNORE_SENSITIVE, autoIgnoreSensitive)
            }
            try {
                context.startService(intent)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to send privacy update intent to service: ${e.message}")
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        activeServiceInstance = this
        createNotificationChannel()
        registerTelemetryObservers()
        checkAndConnectAttachedUsbAccessory()
    }

    private fun registerTelemetryObservers() {
        try {
            val filter = IntentFilter().apply {
                addAction(Intent.ACTION_BATTERY_CHANGED)
                addAction(Intent.ACTION_POWER_CONNECTED)
                addAction(Intent.ACTION_POWER_DISCONNECTED)
            }
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    sendLocalTelemetry(force = false)
                }
            }
            registerReceiver(receiver, filter)
            batteryReceiver = receiver

            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    sendLocalTelemetry(force = false)
                }
                override fun onLost(network: Network) {
                    sendLocalTelemetry(force = false)
                }
                override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
                    sendLocalTelemetry(force = false)
                }
            }
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            cm?.registerNetworkCallback(request, callback)
            networkCallback = callback
        } catch (e: Exception) {
            Log.w(TAG, "Failed to register telemetry observers: ${e.message}")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CONNECT -> {
                val bluetoothAddress = intent.getStringExtra(EXTRA_BLUETOOTH_ADDRESS) ?: ""
                val host = intent.getStringExtra(EXTRA_HOST) ?: ""
                val port = intent.getIntExtra(EXTRA_PORT, 9999)
                val deviceName = intent.getStringExtra(EXTRA_DEVICE_NAME) ?: "Mac"
                val sessionKey = intent.getByteArrayExtra(EXTRA_SESSION_KEY) ?: return START_NOT_STICKY

                startAsForeground(deviceName)
                initiateConnection(bluetoothAddress, host, port, deviceName, sessionKey)
            }
            ACTION_DISCONNECT -> {
                teardown(isManual = true)
                stopSelf()
            }
            ACTION_STOP_EXTERNAL_DISPLAY -> {
                Log.i(TAG, "🛑 Stopping external display via notification action")
                ExternalDisplayActivity.stop()
                dismissExternalDisplayNotification()
            }
            ACTION_UPDATE_PRIVACY -> {
                val isIncognito = intent.getBooleanExtra(EXTRA_INCOGNITO_MODE, false)
                val autoIgnore = intent.getBooleanExtra(EXTRA_AUTO_IGNORE_SENSITIVE, true)
                clipboardManager?.isIncognitoMode = isIncognito
                clipboardManager?.autoIgnoreSensitive = autoIgnore
                Log.d(TAG, "Privacy settings updated: Incognito=$isIncognito, AutoIgnoreSensitive=$autoIgnore")
            }
            ACTION_BROADCAST_TELEMETRY -> {
                sendLocalTelemetry(force = true)
            }
            ACTION_CONNECT_USB -> {
                startAsForeground("Mac (Direct USB)")
                val accessory = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(EXTRA_USB_ACCESSORY, android.hardware.usb.UsbAccessory::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(EXTRA_USB_ACCESSORY)
                }
                if (accessory != null) {
                    connectAoa(accessory)
                } else {
                    checkAndConnectAttachedUsbAccessory()
                }
            }
        }
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        Log.d(TAG, "Task removed from Recents; maintaining persistent foreground connection.")
    }

    private var lastDeviceName: String = "Mac"

    private fun buildServiceNotification(deviceName: String, isConnected: Boolean = true): android.app.Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentPendingIntent = PendingIntent.getActivity(
            this,
            0,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val disconnectIntent = Intent(this, DroidLinkService::class.java).apply {
            action = ACTION_DISCONNECT
        }
        val disconnectPendingIntent = PendingIntent.getService(
            this,
            1,
            disconnectIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val statusText = if (isConnected) "Connected to $deviceName" else "Searching for $deviceName..."
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("DroidLink Active")
            .setContentText(statusText)
            .setSmallIcon(R.drawable.ic_stat_droidlink)
            .setLargeIcon(BitmapFactory.decodeResource(resources, R.mipmap.ic_launcher))
            .setOngoing(true)
            .setContentIntent(contentPendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)

        if (isConnected) {
            val syncClipboardIntent = Intent(this, com.droidlink.app.ui.clipboard.ClipboardSyncActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val syncPendingIntent = PendingIntent.getActivity(
                this,
                2,
                syncClipboardIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            builder.addAction(android.R.drawable.ic_menu_send, "Send Clipboard", syncPendingIntent)
        }

        builder.addAction(android.R.drawable.ic_menu_close_clear_cancel, "Disconnect", disconnectPendingIntent)
        return builder.build()
    }

    private fun updateForegroundNotification(deviceName: String, isConnected: Boolean = true) {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            nm.notify(NOTIFICATION_ID, buildServiceNotification(deviceName, isConnected))
        } catch (e: Exception) {
            Log.w(TAG, "Failed to update notification: ${e.message}")
        }
    }

    private fun startAsForeground(deviceName: String) {
        this.lastDeviceName = deviceName
        val notification = buildServiceNotification(deviceName, isConnected = false)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private var connectionJob: kotlinx.coroutines.Job? = null

    private suspend fun sendHelloHandshake(aoa: com.droidlink.core.network.AoaUsbTransport? = null, transportClient: BleClient? = null, tcp: com.droidlink.core.network.TcpClient? = null) {
        try {
            val myDeviceId = android.provider.Settings.Secure.getString(contentResolver, android.provider.Settings.Secure.ANDROID_ID)
                ?: java.util.UUID.randomUUID().toString()
            val myDeviceName = android.os.Build.MODEL ?: "Android Device"

            val hello = SystemProto.HelloMessage.newBuilder()
                .setProtocolVersion("3.0.0")
                .setDeviceId(myDeviceId)
                .setDeviceName(myDeviceName)
                .setDeviceType(SystemProto.DeviceType.ANDROID)
                .build()

            val sysMsg = SystemProto.SystemMessage.newBuilder()
                .setEvent(SystemProto.SystemMessage.SystemEventType.HELLO)
                .setHello(hello)
                .build()

            val rootMsg = DroidlinkMessages.DroidLinkMessage.newBuilder()
                .setId(System.currentTimeMillis())
                .setTimestamp(System.currentTimeMillis())
                .setType(DroidlinkMessages.MessageType.SYSTEM)
                .setSystem(sysMsg)
                .build()

            val bytes = rootMsg.toByteArray()
            if (aoa != null && aoa.isConnected) {
                sendHighSpeedMessage(bytes)
                Log.d(TAG, "🤝 Sent HELLO handshake to Mac via AOA USB")
            } else if (tcp != null && tcp.isConnected) {
                tcp.send(bytes)
                Log.d(TAG, "🤝 Sent HELLO handshake to Mac via TCP")
            } else if (transportClient != null && transportClient.isConnected) {
                transportClient.send(bytes)
                Log.d(TAG, "🤝 Sent HELLO handshake to Mac via BLE")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to send HELLO handshake: ${e.message}")
        }
    }

    private fun initiateConnection(
        bluetoothAddress: String,
        host: String,
        port: Int,
        deviceName: String,
        sessionKey: ByteArray
    ) {
        if (_connectionState.value is ServiceConnectionState.Connected && (tcpClient?.isConnected == true || aoaTransport?.isConnected == true)) {
            Log.d(TAG, "Device is already connected via active transport ($deviceName); skipping redundant initiateConnection.")
            return
        }

        this.sessionKey = sessionKey
        this.lastDeviceName = deviceName
        val base64Key = android.util.Base64.encodeToString(sessionKey, android.util.Base64.NO_WRAP)
        Log.d(TAG, "🔑 Current Android session key: $base64Key, target BLE: $bluetoothAddress, host: $host:$port")
        connectionJob?.cancel()
        _connectionState.value = ServiceConnectionState.Connecting(deviceName)

        // 1. Immediately probe ultra-low latency direct USB loopback and Wi-Fi TCP
        val targetPort = if (port > 0) port else 29170
        connectHighSpeedTcp(host, targetPort, deviceName)

        if (bluetoothAddress.isBlank()) {
            return
        }

        connectionJob = serviceScope.launch {
            if (tcpClient?.isConnected == true || aoaTransport?.isConnected == true) {
                Log.d(TAG, "High-speed transport active; skipping BLE connection loop.")
                return@launch
            }

            var retryCount = 0
            val maxRetries = 5
            var connected = false

            while (retryCount < maxRetries && !connected && isActive) {
                if (tcpClient?.isConnected == true || aoaTransport?.isConnected == true) {
                    Log.d(TAG, "High-speed transport active; exiting BLE connection loop.")
                    break
                }

                try {
                    // Clean up previous client if any
                    bleClient?.close()

                    val crypto = CryptoChannel(sessionKey)
                    val client = BleClient(applicationContext, bluetoothAddress, crypto)
                    client.connect()
                    bleClient = client
                    connected = true

                    // Send local Android telemetry & HELLO handshake to Mac
                    sendHelloHandshake(transportClient = client)
                    sendLocalTelemetry(force = true)
                    startTelemetryTicker()
                    setupConnectedFeatures()

                    _connectionState.value = ServiceConnectionState.Connected(deviceName)
                    updateForegroundNotification(deviceName, isConnected = true)

                    // Receive incoming Protobuf messages from Mac
                    listenForIncoming(client, deviceName)
                } catch (e: Exception) {
                    if (tcpClient?.isConnected == true || aoaTransport?.isConnected == true) {
                        Log.d(TAG, "High-speed transport active; ignoring BLE attempt error: ${e.message}")
                        break
                    }
                    retryCount++
                    Log.w(TAG, "BLE Connection attempt $retryCount failed: ${e.message}")
                    if (retryCount < maxRetries && isActive) {
                        _connectionState.value = ServiceConnectionState.Connecting(deviceName)
                        kotlinx.coroutines.delay(2000)
                    } else {
                        Log.w(TAG, "All BLE connection attempts in this cycle failed")
                        if (tcpClient?.isConnected != true && aoaTransport?.isConnected != true) {
                            _connectionState.value = ServiceConnectionState.Disconnected
                            updateForegroundNotification(deviceName, isConnected = false)
                            teardown()
                        }
                    }
                }
            }
        }
    }

    private fun setupConnectedFeatures() {
        // 1. Observe local clipboard changes and forward to Mac via Protobuf
        clipboardManager?.stopMonitoring()
        val clipManager = ClipboardManager(applicationContext) { newContent ->
            sendClipboardDirect(newContent)
        }
        val storage = com.droidlink.core.security.PairingStorage(applicationContext)
        clipManager.isIncognitoMode = storage.isIncognitoMode()
        clipManager.autoIgnoreSensitive = storage.isAutoIgnoreSensitive()
        clipboardManager = clipManager
        clipManager.startMonitoring()

        // 2. Observe captured notifications and forward to Mac via Protobuf
        DroidLinkNotificationListener.onNotificationCaptured = { captured ->
            serviceScope.launch {
                try {
                    val notifData = NotificationProto.NotificationData.newBuilder()
                        .setId(captured.id)
                        .setPackageName(captured.packageName)
                        .setAppName(captured.appName)
                        .setTitle(captured.title)
                        .setText(captured.text)
                        .setTimestamp(System.currentTimeMillis())

                    if (captured.iconBytes.isNotEmpty()) {
                        notifData.setIcon(ByteString.copyFrom(captured.iconBytes))
                    }

                    val notifMsg = NotificationProto.NotificationMessage.newBuilder()
                        .setEvent(NotificationProto.NotificationMessage.NotificationEventType.POSTED)
                        .setNotification(notifData)
                        .build()

                    val rootMsg = DroidlinkMessages.DroidLinkMessage.newBuilder()
                        .setId(System.currentTimeMillis())
                        .setTimestamp(System.currentTimeMillis())
                        .setType(DroidlinkMessages.MessageType.NOTIFICATION_MIRROR)
                        .setNotification(notifMsg)
                        .build()

                    val bytes = rootMsg.toByteArray()
                    val tcp = tcpClient
                    val ble = bleClient
                    if (aoaTransport?.isConnected == true) {
                        sendHighSpeedMessage(bytes)
                    } else if (tcp != null && tcp.isConnected) {
                        tcp.send(bytes)
                        Log.d(TAG, "Forwarded notification with icon to Mac over TCP: ${captured.appName} - ${captured.title}")
                    } else if (ble?.isConnected == true) {
                        ble.send(bytes)
                        Log.d(TAG, "Forwarded notification with icon to Mac over BLE: ${captured.appName} - ${captured.title}")
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to send notification to Mac", e)
                }
            }
        }

        // 3. Setup FileWatcher for live change push to Mac
        fileWatcher?.stopWatching()
        val watcher = AndroidFileWatcher(serviceScope) { changeMsg ->
            serviceScope.launch {
                try {
                    val rootMsg = DroidlinkMessages.DroidLinkMessage.newBuilder()
                        .setId(System.currentTimeMillis())
                        .setTimestamp(System.currentTimeMillis())
                        .setType(DroidlinkMessages.MessageType.FILE_TRANSFER)
                        .setFile(changeMsg)
                        .build()
                    val bytes = rootMsg.toByteArray()
                    val tcp = tcpClient
                    val ble = bleClient
                    if (aoaTransport?.isConnected == true) {
                        sendHighSpeedMessage(bytes)
                    } else if (tcp != null && tcp.isConnected) {
                        tcp.send(bytes)
                    } else if (ble?.isConnected == true) {
                        ble.send(bytes)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to send file change event: ${e.message}")
                }
            }
        }
        fileWatcher = watcher
    }

    private suspend fun listenForIncoming(client: BleClient, deviceName: String) {
        while (client.isConnected) {
            val messages = client.receiveMessages()
            if (messages.isEmpty()) {
                Log.d(TAG, "BLE stream ended or disconnected.")
                break
            }
            var goodbyeReceived = false
            for (bytes in messages) {
                try {
                    val rootMsg = DroidlinkMessages.DroidLinkMessage.parseFrom(bytes)
                    if (rootMsg.hasSystem()) {
                        val sys = rootMsg.system
                        if (sys.event == SystemProto.SystemMessage.SystemEventType.HELLO_ACK) {
                            val verifiedName = sys.helloAck.deviceName.ifEmpty { deviceName }
                            Log.i(TAG, "🤝 Received HELLO_ACK from Mac via BLE: $verifiedName")
                            _connectionState.value = ServiceConnectionState.Connected(verifiedName)
                            updateForegroundNotification(verifiedName, isConnected = true)
                        }
                        if (sys.event == SystemProto.SystemMessage.SystemEventType.GOODBYE) {
                            val isManual = sys.hasError() && sys.error.message == "MANUAL_DISCONNECT"
                            Log.i(TAG, "👋 Received GOODBYE from Mac via BLE${if (isManual) " (MANUAL_DISCONNECT)" else ""}. Disconnecting.")
                            if (isManual) {
                                com.droidlink.core.security.PairingStorage(applicationContext).setManuallyDisconnected(true)
                            }
                            goodbyeReceived = true
                            break
                        }
                        if (sys.hasError() && sys.error.message == "DEVICE_STATUS") {
                            val json = sys.error.details
                            val status = com.droidlink.app.model.DeviceStatusInfo.fromJson(json)
                            Log.d(TAG, "📱 Received telemetry from Mac: ${status.deviceName} (${status.deviceModel}) - Battery: ${status.batteryLevel}%")
                            _remoteDeviceStatus.value = status
                            _connectionState.value = ServiceConnectionState.Connected(deviceName)
                            updateForegroundNotification(deviceName, isConnected = true)
                            if (status.localIpAddress.isNotBlank()) {
                                connectHighSpeedTcp(status.localIpAddress, status.tcpPort, deviceName)
                            }
                        }
                    }
                    if (rootMsg.hasClipboard()) {
                        val storage = com.droidlink.core.security.PairingStorage(applicationContext)
                        if (!storage.isClipboardSyncEnabled()) {
                            Log.d(TAG, "Clipboard sync disabled in settings; ignoring incoming remote clip from Mac.")
                        } else {
                            val clip = rootMsg.clipboard
                            val text = clip.data.text
                            Log.d(TAG, "Received clipboard from Mac: ${text.take(30)}...")
                            withContext(Dispatchers.Main) {
                                clipboardManager?.setContent(text)
                            }
                        }
                    }
                    if (rootMsg.hasFile()) {
                        val fileMsg = rootMsg.file
                        Log.d(TAG, "📁 Received file message from Mac: op=${fileMsg.operation}, path=${fileMsg.filePath}, offset=${fileMsg.offset}")
                        handleFileMessage(fileMsg, bleClient = client)
                    }
                    if (rootMsg.hasScreen()) {
                        handleScreenMessage(rootMsg.screen)
                    }
                    if (rootMsg.hasExternalDisplay()) {
                        handleExternalDisplayMessage(rootMsg.externalDisplay)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error parsing incoming Protobuf message", e)
                }
            }
            if (goodbyeReceived) {
                break
            }
        }
        Log.i(TAG, "Exited BLE listen loop.")
        if (tcpClient?.isConnected != true) {
            _connectionState.value = ServiceConnectionState.Disconnected
            updateForegroundNotification(deviceName, isConnected = false)
        }
        teardown()
    }

    suspend fun sendHighSpeedMessage(bytes: ByteArray) {
        if (aoaTransport?.isConnected == true) {
            aoaTransport?.send(bytes)
        } else if (tcpClient?.isConnected == true) {
            tcpClient?.send(bytes)
        }
    }

    private fun checkAndConnectAttachedUsbAccessory() {
        val usbManager = getSystemService(Context.USB_SERVICE) as? android.hardware.usb.UsbManager ?: return
        val accessoryList = usbManager.accessoryList
        val accessory = accessoryList?.firstOrNull { it.manufacturer == "DroidLink" }
        if (accessory != null) {
            Log.i(TAG, "🔌 Found attached DroidLink USB accessory on startup: ${accessory.model}")
            connectAoa(accessory)
        }
    }

    fun connectAoa(accessory: android.hardware.usb.UsbAccessory) {
        val usbManager = getSystemService(Context.USB_SERVICE) as? android.hardware.usb.UsbManager ?: return
        serviceScope.launch(Dispatchers.IO) {
            val transport = com.droidlink.core.network.AoaUsbTransport(usbManager)
            val success = transport.connect(accessory)
            if (success) {
                aoaTransport = transport
                connectionJob?.cancel()
                connectionJob = null
                _isUsbConnected.value = true
                val paired = com.droidlink.core.security.PairingStorage(applicationContext).getPairedDevice()
                val initialName = paired?.deviceName ?: "Mac (Direct USB)"
                _connectionState.value = ServiceConnectionState.Connected(initialName)
                updateForegroundNotification(initialName, isConnected = true)
                Log.i(TAG, "⚡ AOA USB Direct Connection established! Zero-ADB, Zero-WiFi mode active.")
                setupConnectedFeatures()
                sendHelloHandshake(aoa = transport)
                sendLocalTelemetry(force = true)
                startTelemetryTicker()
                listenForIncomingAoa(transport)
            }
        }
    }

    private suspend fun listenForIncomingAoa(transport: com.droidlink.core.network.AoaUsbTransport) {
        while (transport.isConnected) {
            val messages = transport.receiveMessages()
            if (messages.isEmpty()) break
            for (bytes in messages) {
                try {
                    val rootMsg = DroidlinkMessages.DroidLinkMessage.parseFrom(bytes)
                    if (rootMsg.hasSystem()) {
                        val sys = rootMsg.system
                        if (sys.event == SystemProto.SystemMessage.SystemEventType.HELLO_ACK) {
                            val verifiedName = sys.helloAck.deviceName.ifEmpty { "Mac" }
                            Log.i(TAG, "🤝 Received HELLO_ACK from Mac via AOA USB: $verifiedName")
                            _connectionState.value = ServiceConnectionState.Connected(verifiedName)
                            updateForegroundNotification(verifiedName, isConnected = true)
                        }
                        if (sys.event == SystemProto.SystemMessage.SystemEventType.GOODBYE) {
                            Log.i(TAG, "👋 Received GOODBYE from Mac via AOA USB. Disconnecting.")
                            withContext(Dispatchers.Main) {
                                teardown()
                                stopSelf()
                            }
                            break
                        }
                        if (sys.hasError() && sys.error.message == "DEVICE_STATUS") {
                            val json = sys.error.details
                            val status = com.droidlink.app.model.DeviceStatusInfo.fromJson(json)
                            _remoteDeviceStatus.value = status
                            val verifiedName = status.deviceName.ifEmpty { "Mac" }
                            _connectionState.value = ServiceConnectionState.Connected(verifiedName)
                            updateForegroundNotification(verifiedName, isConnected = true)
                            Log.i(TAG, "📱 Received telemetry from Mac via AOA USB: ${status.deviceName} (${status.deviceModel}) - Battery: ${status.batteryLevel}%")
                        }
                    }
                    if (rootMsg.hasClipboard()) {
                        val storage = com.droidlink.core.security.PairingStorage(applicationContext)
                        if (storage.isClipboardSyncEnabled()) {
                            val clip = rootMsg.clipboard
                            val text = clip.data.text
                            Log.d(TAG, "Received clipboard from Mac via AOA USB: ${text.take(30)}...")
                            withContext(Dispatchers.Main) {
                                clipboardManager?.setContent(text)
                            }
                        }
                    }
                    if (rootMsg.hasScreen()) {
                        handleScreenMessage(rootMsg.screen)
                    }
                    if (rootMsg.hasExternalDisplay()) {
                        handleExternalDisplayMessage(rootMsg.externalDisplay)
                    }
                    if (rootMsg.hasFile()) {
                        handleFileMessage(rootMsg.file, aoaTransport = transport)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error handling AOA USB message", e)
                }
            }
        }
        _isUsbConnected.value = false
        Log.i(TAG, "AOA USB transport disconnected.")
    }

    fun disconnectAoa() {
        _isUsbConnected.value = false
        val transport = aoaTransport
        aoaTransport = null
        transport?.close()
        ExternalDisplayActivity.stop()
        dismissExternalDisplayNotification()
    }

    fun checkClipboard() {
        clipboardManager?.checkClipboardNow()
    }

    fun sendClipboardDirect(text: String) {
        if (text.isBlank()) return
        val storage = com.droidlink.core.security.PairingStorage(applicationContext)
        if (!storage.isClipboardSyncEnabled()) {
            Log.d(TAG, "Clipboard sync is disabled; skipping direct send.")
            return
        }
        if (storage.isIncognitoMode()) {
            Log.d(TAG, "Incognito mode is active; skipping direct send.")
            return
        }

        clipboardManager?.updateLastContent(text)

        serviceScope.launch {
            try {
                val clipData = ClipboardProto.ClipboardData.newBuilder()
                    .setType(ClipboardProto.DataType.DATA_TEXT)
                    .setText(text)
                    .setTimestamp(System.currentTimeMillis())
                    .build()

                val clipMsg = ClipboardProto.ClipboardMessage.newBuilder()
                    .setData(clipData)
                    .setIsRemote(false)
                    .build()

                val rootMsg = DroidlinkMessages.DroidLinkMessage.newBuilder()
                    .setId(System.currentTimeMillis())
                    .setTimestamp(System.currentTimeMillis())
                    .setType(DroidlinkMessages.MessageType.CLIPBOARD_SYNC)
                    .setClipboard(clipMsg)
                    .build()

                val bytes = rootMsg.toByteArray()
                val tcp = tcpClient
                val ble = bleClient
                if (aoaTransport?.isConnected == true) {
                    sendHighSpeedMessage(bytes)
                    Log.d(TAG, "Sent clipboard directly to Mac over AOA USB: ${text.take(30)}...")
                } else if (tcp != null && tcp.isConnected) {
                    tcp.send(bytes)
                    Log.d(TAG, "Sent clipboard directly to Mac over TCP: ${text.take(30)}...")
                } else if (ble?.isConnected == true) {
                    ble.send(bytes)
                    Log.d(TAG, "Sent clipboard directly to Mac over BLE: ${text.take(30)}...")
                } else {
                    Log.w(TAG, "Cannot send clipboard: No connected transport")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to send clipboard directly", e)
            }
        }
    }

    private fun connectHighSpeedTcp(host: String, port: Int, deviceName: String = "Mac") {
        val key = sessionKey ?: return
        if (tcpClient?.isConnected == true) return
        serviceScope.launch(Dispatchers.IO) {
            val crypto = com.droidlink.core.security.CryptoChannel(key)
            var connectedClient: com.droidlink.core.network.TcpClient? = null

            // 1. First probe ultra-low latency direct USB loopback (127.0.0.1:port)
            try {
                Log.d(TAG, "🔌 Probing USB tunnel at 127.0.0.1:$port...")
                val usbClient = com.droidlink.core.network.TcpClient("127.0.0.1", port, crypto)
                kotlinx.coroutines.withTimeout(1000) {
                    usbClient.connect()
                }
                if (usbClient.isConnected) {
                    Log.i(TAG, "⚡ High-speed TCP connected via Ultra-Low Latency USB Loopback (127.0.0.1:$port)!")
                    connectedClient = usbClient
                }
            } catch (e: Exception) {
                Log.d(TAG, "USB tunnel probe skipped (${e.message}), connecting via Wi-Fi to $host:$port")
            }

            // 2. If USB loopback not available, connect via Wi-Fi host IP
            if (connectedClient == null && host.isNotBlank()) {
                try {
                    Log.i(TAG, "🚀 Connecting high-speed TCP channel to Wi-Fi $host:$port...")
                    val wifiClient = com.droidlink.core.network.TcpClient(host, port, crypto)
                    wifiClient.connect()
                    connectedClient = wifiClient
                    Log.i(TAG, "⚡ High-speed TCP channel connected to Mac via Wi-Fi!")
                } catch (e: Exception) {
                    Log.w(TAG, "TCP connection to $host:$port failed (falling back to BLE): ${e.message}")
                    return@launch
                }
            }

            if (connectedClient != null) {
                tcpClient = connectedClient
                connectionJob?.cancel()
                connectionJob = null
                _connectionState.value = ServiceConnectionState.Connected(deviceName)
                updateForegroundNotification(deviceName, isConnected = true)
                sendHelloHandshake(tcp = connectedClient)
                sendLocalTelemetry(force = true)
                startTelemetryTicker()
                setupConnectedFeatures()
                listenForIncomingTcp(connectedClient, deviceName)
            }
        }
    }

    private suspend fun listenForIncomingTcp(client: com.droidlink.core.network.TcpClient, deviceName: String) {
        while (client.isConnected) {
            val messages = client.receiveMessages()
            if (messages.isEmpty()) break
            for (bytes in messages) {
                try {
                    val rootMsg = DroidlinkMessages.DroidLinkMessage.parseFrom(bytes)
                    if (rootMsg.hasSystem()) {
                        val sys = rootMsg.system
                        if (sys.event == SystemProto.SystemMessage.SystemEventType.HELLO_ACK) {
                            val verifiedName = sys.helloAck.deviceName.ifEmpty { deviceName }
                            Log.i(TAG, "🤝 Received HELLO_ACK from Mac via TCP: $verifiedName")
                            _connectionState.value = ServiceConnectionState.Connected(verifiedName)
                            updateForegroundNotification(verifiedName, isConnected = true)
                        }
                        if (sys.event == SystemProto.SystemMessage.SystemEventType.GOODBYE) {
                            val isManual = sys.hasError() && sys.error.message == "MANUAL_DISCONNECT"
                            Log.i(TAG, "👋 Received GOODBYE from Mac via TCP${if (isManual) " (MANUAL_DISCONNECT)" else ""}. Disconnecting.")
                            if (isManual) {
                                com.droidlink.core.security.PairingStorage(applicationContext).setManuallyDisconnected(true)
                            }
                            withContext(Dispatchers.Main) {
                                teardown()
                                stopSelf()
                            }
                            break
                        }
                        if (sys.hasError() && sys.error.message == "DEVICE_STATUS") {
                            val json = sys.error.details
                            val status = com.droidlink.app.model.DeviceStatusInfo.fromJson(json)
                            Log.d(TAG, "📱 Received telemetry from Mac via TCP: ${status.deviceName} (${status.deviceModel}) - Battery: ${status.batteryLevel}%")
                            _remoteDeviceStatus.value = status
                            _connectionState.value = ServiceConnectionState.Connected(deviceName)
                            updateForegroundNotification(deviceName, isConnected = true)
                        }
                    }
                    if (rootMsg.hasClipboard()) {
                        val storage = com.droidlink.core.security.PairingStorage(applicationContext)
                        if (storage.isClipboardSyncEnabled()) {
                            val clip = rootMsg.clipboard
                            val text = clip.data.text
                            Log.d(TAG, "Received clipboard from Mac via TCP: ${text.take(30)}...")
                            withContext(Dispatchers.Main) {
                                clipboardManager?.setContent(text)
                            }
                        }
                    }
                    if (rootMsg.hasFile()) {
                        val fileMsg = rootMsg.file
                        Log.d(TAG, "📁 Received file message from Mac via TCP: op=${fileMsg.operation}, path=${fileMsg.filePath}")
                        handleFileMessage(fileMsg, bleClient = null, tcpClient = client)
                    }
                    if (rootMsg.hasScreen()) {
                        handleScreenMessage(rootMsg.screen)
                    }
                    if (rootMsg.hasExternalDisplay()) {
                        handleExternalDisplayMessage(rootMsg.externalDisplay)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error handling TCP file message", e)
                }
            }
        }
        Log.i(TAG, "TCP channel disconnected.")
        tcpClient = null
        if (bleClient?.isConnected != true) {
            _connectionState.value = ServiceConnectionState.Disconnected
            updateForegroundNotification(deviceName, isConnected = false)
        }
    }

    private suspend fun handleFileMessage(
        fileMsg: FileProto.FileMessage,
        bleClient: BleClient? = null,
        tcpClient: com.droidlink.core.network.TcpClient? = null,
        aoaTransport: com.droidlink.core.network.AoaUsbTransport? = null
    ) {
        val storage = com.droidlink.core.security.PairingStorage(applicationContext)
        if (!storage.isFinderStorageEnabled()) {
            Log.w(TAG, "Rejecting FileMessage ${fileMsg.operation}: Finder storage disabled in settings")
            val errResp = FileProto.FileMessage.newBuilder()
                .setOperation(fileMsg.operation)
                .setFilePath(fileMsg.filePath)
                .setFileId(fileMsg.fileId)
                .setErrorMessage("Finder storage access is disabled in Android settings")
                .build()
            sendFileResponse(errResp, bleClient, tcpClient, aoaTransport)
            return
        }

        try {
            when (fileMsg.operation) {
                FileProto.FileMessage.FileOperation.ENUM_DIRECTORY_REQUEST -> {
                    val (files, nextToken) = fileSystemManager.enumerateDirectory(
                        fileMsg.filePath,
                        fileMsg.pageToken.ifEmpty { null }
                    )
                    val respBuilder = FileProto.FileMessage.newBuilder()
                        .setOperation(FileProto.FileMessage.FileOperation.ENUM_DIRECTORY_RESPONSE)
                        .setFilePath(fileMsg.filePath)
                        .setFileId(fileMsg.fileId)
                        .addAllFiles(files)
                    if (nextToken != null) {
                        respBuilder.setNextPageToken(nextToken)
                    }
                    sendFileResponse(respBuilder.build(), bleClient, tcpClient, aoaTransport)
                }
                FileProto.FileMessage.FileOperation.GET_METADATA_REQUEST -> {
                    val info = fileSystemManager.getItemMetadata(fileMsg.filePath)
                    val respBuilder = FileProto.FileMessage.newBuilder()
                        .setOperation(FileProto.FileMessage.FileOperation.GET_METADATA_RESPONSE)
                        .setFilePath(fileMsg.filePath)
                        .setFileId(fileMsg.fileId)
                    if (info != null) {
                        respBuilder.setFileInfo(info)
                    }
                    sendFileResponse(respBuilder.build(), bleClient, tcpClient, aoaTransport)
                }
                FileProto.FileMessage.FileOperation.READ_CHUNK_REQUEST -> {
                    val result = fileSystemManager.readChunk(
                        fileMsg.filePath,
                        fileMsg.offset,
                        fileMsg.chunkSize
                    )
                    val resp = FileProto.FileMessage.newBuilder()
                        .setOperation(FileProto.FileMessage.FileOperation.READ_CHUNK_RESPONSE)
                        .setFilePath(fileMsg.filePath)
                        .setFileId(fileMsg.fileId)
                        .setOffset(fileMsg.offset)
                        .setFileData(com.google.protobuf.ByteString.copyFrom(result.data))
                        .setChunkSize(result.bytesRead)
                        .setFileSize(result.totalSize)
                        .setIsEof(result.isEof)
                        .build()
                    sendFileResponse(resp, bleClient, tcpClient, aoaTransport)
                }
                FileProto.FileMessage.FileOperation.WRITE_CHUNK_REQUEST -> {
                    val totalLength = fileSystemManager.writeChunk(
                        fileMsg.filePath,
                        fileMsg.offset,
                        fileMsg.fileData.toByteArray(),
                        fileMsg.isEof,
                        truncate = (fileMsg.offset == 0L)
                    )
                    val resp = FileProto.FileMessage.newBuilder()
                        .setOperation(FileProto.FileMessage.FileOperation.WRITE_CHUNK_RESPONSE)
                        .setFilePath(fileMsg.filePath)
                        .setFileId(fileMsg.fileId)
                        .setOffset(fileMsg.offset)
                        .setFileSize(totalLength)
                        .setIsEof(fileMsg.isEof)
                        .build()
                    sendFileResponse(resp, bleClient, tcpClient, aoaTransport)

                    if (fileMsg.isEof) {
                        try {
                            val savedFile = fileSystemManager.resolveSafeFile(fileMsg.filePath)
                            android.media.MediaScannerConnection.scanFile(
                                applicationContext,
                                arrayOf(savedFile.absolutePath),
                                null
                            ) { path, uri ->
                                Log.i(TAG, "Indexed received file in MediaStore: $path ($uri)")
                            }
                            showFileReceivedNotification(savedFile)
                        } catch (e: Exception) {
                            Log.w(TAG, "Failed to index/notify received file: ${e.message}")
                        }
                    }
                }
                FileProto.FileMessage.FileOperation.CREATE_ITEM_REQUEST -> {
                    val info = fileSystemManager.createItem(fileMsg.filePath, fileMsg.isDirectory)
                    val resp = FileProto.FileMessage.newBuilder()
                        .setOperation(FileProto.FileMessage.FileOperation.CREATE_ITEM_RESPONSE)
                        .setFilePath(fileMsg.filePath)
                        .setFileId(fileMsg.fileId)
                        .setFileInfo(info)
                        .build()
                    sendFileResponse(resp, bleClient, tcpClient, aoaTransport)
                }
                FileProto.FileMessage.FileOperation.DELETE_ITEM_REQUEST -> {
                    val success = fileSystemManager.deleteItem(fileMsg.filePath, recursive = true)
                    val respBuilder = FileProto.FileMessage.newBuilder()
                        .setOperation(FileProto.FileMessage.FileOperation.DELETE_ITEM_RESPONSE)
                        .setFilePath(fileMsg.filePath)
                        .setFileId(fileMsg.fileId)
                    if (!success) {
                        respBuilder.setErrorMessage("Failed to delete item")
                    }
                    sendFileResponse(respBuilder.build(), bleClient, tcpClient, aoaTransport)
                }
                FileProto.FileMessage.FileOperation.MOVE_ITEM_REQUEST -> {
                    val success = fileSystemManager.moveItem(fileMsg.filePath, fileMsg.targetPath)
                    val respBuilder = FileProto.FileMessage.newBuilder()
                        .setOperation(FileProto.FileMessage.FileOperation.MOVE_ITEM_RESPONSE)
                        .setFilePath(fileMsg.filePath)
                        .setFileId(fileMsg.fileId)
                        .setTargetPath(fileMsg.targetPath)
                    if (!success) {
                        respBuilder.setErrorMessage("Failed to move item")
                    }
                    sendFileResponse(respBuilder.build(), bleClient, tcpClient, aoaTransport)
                }
                FileProto.FileMessage.FileOperation.SUBSCRIBE_CHANGES_REQUEST -> {
                    fileWatcher?.startWatching(fileMsg.filePath)
                }
                else -> {
                    Log.w(TAG, "Unhandled file operation: ${fileMsg.operation}")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error handling file operation: ${fileMsg.operation}", e)
            val errResp = FileProto.FileMessage.newBuilder()
                .setOperation(FileProto.FileMessage.FileOperation.FILE_ERROR)
                .setFilePath(fileMsg.filePath)
                .setFileId(fileMsg.fileId)
                .setErrorMessage(e.message ?: "Filesystem error")
                .build()
            sendFileResponse(errResp, bleClient, tcpClient, aoaTransport)
        }
    }

    private suspend fun sendFileResponse(
        fileResp: FileProto.FileMessage,
        bleClient: BleClient? = null,
        tcpClient: com.droidlink.core.network.TcpClient? = null,
        aoaTransport: com.droidlink.core.network.AoaUsbTransport? = null
    ) {
        val rootMsg = DroidlinkMessages.DroidLinkMessage.newBuilder()
            .setId(System.currentTimeMillis())
            .setTimestamp(System.currentTimeMillis())
            .setType(DroidlinkMessages.MessageType.FILE_TRANSFER)
            .setFile(fileResp)
            .build()
        val bytes = rootMsg.toByteArray()
        if (aoaTransport != null && aoaTransport.isConnected) {
            aoaTransport.send(bytes)
        } else if (tcpClient != null && tcpClient.isConnected) {
            tcpClient.send(bytes)
        } else if (this.tcpClient?.isConnected == true) {
            this.tcpClient?.send(bytes)
        } else if (bleClient != null && bleClient.isConnected) {
            bleClient.send(bytes)
        }
    }

    private fun createNotificationChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return

        val serviceChannel = NotificationChannel(
            CHANNEL_ID,
            "DroidLink Connection Service",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Maintains persistent background bridge with Mac"
        }
        manager.createNotificationChannel(serviceChannel)

        val transferChannel = NotificationChannel(
            CHANNEL_ID_FILE_TRANSFER,
            "DroidLink File Transfers",
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = "Shows progress and completion for file transfers between Android and Mac"
        }
        manager.createNotificationChannel(transferChannel)
    }

    fun isTransportConnected(): Boolean {
        return (aoaTransport?.isConnected == true || tcpClient?.isConnected == true || bleClient?.isConnected == true)
    }

    fun sendSharedFiles(uris: List<Uri>) {
        serviceScope.launch(Dispatchers.IO) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            for (uri in uris) {
                var fileName = "shared_file_${System.currentTimeMillis()}"
                var fileSize = -1L

                try {
                    contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                        val nameIdx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                        val sizeIdx = cursor.getColumnIndex(android.provider.OpenableColumns.SIZE)
                        if (cursor.moveToFirst()) {
                            if (nameIdx != -1) {
                                val resolved = cursor.getString(nameIdx)
                                if (!resolved.isNullOrBlank()) fileName = resolved
                            }
                            if (sizeIdx != -1) {
                                fileSize = cursor.getLong(sizeIdx)
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to resolve metadata for $uri: ${e.message}")
                }

                val notifId = NOTIFICATION_ID_FILE_TRANSFER + (uri.hashCode() % 1000)
                val notifBuilder = NotificationCompat.Builder(this@DroidLinkService, CHANNEL_ID_FILE_TRANSFER)
                    .setContentTitle(getString(R.string.file_transfer_sending, fileName))
                    .setSmallIcon(R.drawable.ic_stat_droidlink)
                    .setOngoing(true)
                    .setOnlyAlertOnce(true)
                    .setProgress(100, 0, fileSize <= 0)

                nm?.notify(notifId, notifBuilder.build())

                try {
                    contentResolver.openInputStream(uri)?.use { inputStream ->
                        val fileId = java.util.UUID.randomUUID().toString()
                        val chunkSize = if (fileSize > 0) AndroidFileSystemManager.getOptimalChunkSize(fileSize) else 512 * 1024
                        val buffer = ByteArray(chunkSize)
                        var offset = 0L

                        var currentLen = inputStream.read(buffer)
                        if (currentLen <= 0) {
                            val fileMsg = FileProto.FileMessage.newBuilder()
                                .setOperation(FileProto.FileMessage.FileOperation.WRITE_CHUNK_REQUEST)
                                .setFilePath(fileName)
                                .setFileId(fileId)
                                .setFileSize(0)
                                .setOffset(0)
                                .setFileData(ByteString.EMPTY)
                                .setChunkSize(0)
                                .setIsEof(true)
                                .build()
                            sendHighSpeedOrBle(fileMsg)
                        } else {
                            val nextBuffer = ByteArray(chunkSize)
                            while (currentLen > 0) {
                                val nextLen = inputStream.read(nextBuffer)
                                val isEof = (nextLen == -1)

                                val fileMsg = FileProto.FileMessage.newBuilder()
                                    .setOperation(FileProto.FileMessage.FileOperation.WRITE_CHUNK_REQUEST)
                                    .setFilePath(fileName)
                                    .setFileId(fileId)
                                    .setFileSize(fileSize)
                                    .setOffset(offset)
                                    .setFileData(ByteString.copyFrom(buffer, 0, currentLen))
                                    .setChunkSize(currentLen)
                                    .setIsEof(isEof)
                                    .build()

                                sendHighSpeedOrBle(fileMsg)

                                offset += currentLen
                                if (fileSize > 0) {
                                    val progress = ((offset.toDouble() / fileSize.toDouble()) * 100).toInt().coerceIn(0, 100)
                                    notifBuilder.setProgress(100, progress, false)
                                        .setContentText("$progress%")
                                    nm?.notify(notifId, notifBuilder.build())
                                }

                                if (isEof) break
                                System.arraycopy(nextBuffer, 0, buffer, 0, nextLen)
                                currentLen = nextLen
                            }
                        }

                        notifBuilder.setContentTitle(getString(R.string.file_transfer_sent, fileName))
                            .setContentText("Completed")
                            .setOngoing(false)
                            .setProgress(0, 0, false)
                        nm?.notify(notifId, notifBuilder.build())

                        delay(4000)
                        nm?.cancel(notifId)
                    } ?: run {
                        throw java.io.IOException("Unable to open input stream for $uri")
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "File transfer error for $fileName: ${e.message}", e)
                    notifBuilder.setContentTitle(getString(R.string.file_transfer_failed, fileName))
                        .setContentText(e.message ?: "Transfer error")
                        .setOngoing(false)
                        .setProgress(0, 0, false)
                    nm?.notify(notifId, notifBuilder.build())
                }
            }
        }
    }

    private suspend fun sendHighSpeedOrBle(fileMsg: FileProto.FileMessage) {
        val rootMsg = DroidlinkMessages.DroidLinkMessage.newBuilder()
            .setId(System.currentTimeMillis())
            .setTimestamp(System.currentTimeMillis())
            .setType(DroidlinkMessages.MessageType.FILE_TRANSFER)
            .setFile(fileMsg)
            .build()
        val bytes = rootMsg.toByteArray()
        if (aoaTransport?.isConnected == true) {
            sendHighSpeedMessage(bytes)
        } else if (tcpClient?.isConnected == true) {
            tcpClient?.send(bytes)
        } else if (bleClient?.isConnected == true) {
            bleClient?.send(bytes)
        } else {
            throw java.io.IOException("No connected transport to Mac")
        }
    }

    private fun showFileReceivedNotification(file: File) {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            val openIntent = Intent(Intent.ACTION_VIEW).apply {
                val uri = androidx.core.content.FileProvider.getUriForFile(
                    applicationContext,
                    "${applicationContext.packageName}.fileprovider",
                    file
                )
                setDataAndType(uri, contentResolver.getType(uri) ?: "*/*")
                flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK
            }
            val pendingIntent = PendingIntent.getActivity(
                this,
                file.hashCode(),
                openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val notif = NotificationCompat.Builder(this, CHANNEL_ID_FILE_TRANSFER)
                .setContentTitle(getString(R.string.file_transfer_received_title))
                .setContentText(getString(R.string.file_transfer_received_desc, file.name))
                .setSmallIcon(R.drawable.ic_stat_droidlink)
                .setAutoCancel(true)
                .setContentIntent(pendingIntent)
                .build()

            nm.notify(file.hashCode(), notif)
        } catch (e: Exception) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            val notif = NotificationCompat.Builder(this, CHANNEL_ID_FILE_TRANSFER)
                .setContentTitle(getString(R.string.file_transfer_received_title))
                .setContentText(getString(R.string.file_transfer_received_desc, file.name))
                .setSmallIcon(R.drawable.ic_stat_droidlink)
                .setAutoCancel(true)
                .build()
            nm.notify(file.hashCode(), notif)
        }
    }

    private fun startTelemetryTicker() {
        telemetryTickerJob?.cancel()
        telemetryTickerJob = serviceScope.launch {
            while (isActive) {
                delay(30_000)
                sendLocalTelemetry(force = false)
            }
        }
    }

    private fun sendLocalTelemetry(force: Boolean = false) {
        val aoa = aoaTransport
        val tcp = tcpClient
        val ble = bleClient
        if ((aoa == null || !aoa.isConnected) && (tcp == null || !tcp.isConnected) && (ble == null || !ble.isConnected)) {
            return
        }
        serviceScope.launch {
            try {
                val collector = com.droidlink.app.telemetry.AndroidTelemetryCollector(applicationContext)
                val status = collector.collectStatus()
                val old = lastSentTelemetry
                if (!force && old != null &&
                    old.batteryLevel == status.batteryLevel &&
                    old.isCharging == status.isCharging &&
                    old.powerSource == status.powerSource &&
                    old.wifiSsid == status.wifiSsid &&
                    old.wifiSignalLevel == status.wifiSignalLevel &&
                    old.isFinderStorageEnabled == status.isFinderStorageEnabled
                ) {
                    return@launch
                }
                lastSentTelemetry = status

                val errorMsg = SystemProto.ErrorMessage.newBuilder()
                    .setCode(SystemProto.ErrorCode.ERROR_UNKNOWN)
                    .setMessage("DEVICE_STATUS")
                    .setDetails(status.toJson())
                    .build()

                val sysMsg = SystemProto.SystemMessage.newBuilder()
                    .setEvent(SystemProto.SystemMessage.SystemEventType.SYS_ERROR)
                    .setError(errorMsg)
                    .build()

                val rootMsg = DroidlinkMessages.DroidLinkMessage.newBuilder()
                    .setId(System.currentTimeMillis())
                    .setTimestamp(System.currentTimeMillis())
                    .setType(DroidlinkMessages.MessageType.SYSTEM)
                    .setSystem(sysMsg)
                    .build()

                val bytes = rootMsg.toByteArray()
                if (aoa != null && aoa.isConnected) {
                    sendHighSpeedMessage(bytes)
                    Log.d(TAG, "📊 Sent local telemetry to Mac via AOA USB: ${status.deviceName} (${status.deviceModel}) - ${status.batteryLevel}%")
                } else if (tcp != null && tcp.isConnected) {
                    tcp.send(bytes)
                    Log.d(TAG, "📊 Sent local telemetry to Mac via TCP: ${status.deviceName} (${status.deviceModel}) - ${status.batteryLevel}%")
                } else if (ble != null && ble.isConnected) {
                    ble.send(bytes)
                    Log.d(TAG, "📊 Sent local telemetry to Mac via BLE: ${status.deviceName} (${status.deviceModel}) - ${status.batteryLevel}%")
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to send local telemetry: ${e.message}")
            }
        }
    }

    private fun teardown(isManual: Boolean = false) {
        telemetryTickerJob?.cancel()
        telemetryTickerJob = null
        lastSentTelemetry = null
        connectionJob?.cancel()
        connectionJob = null
        clipboardManager?.stopMonitoring()
        clipboardManager = null
        fileWatcher?.stopWatching()
        fileWatcher = null
        DroidLinkNotificationListener.onNotificationCaptured = null
        _connectionState.value = ServiceConnectionState.Disconnected
        _remoteDeviceStatus.value = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        disconnectAoa()
        val client = bleClient
        bleClient = null
        val tcp = tcpClient
        tcpClient = null
        if (tcp != null) {
            serviceScope.launch {
                try {
                    if (isManual && tcp.isConnected) {
                        sendGoodbye(tcpClient = tcp, isManual = true)
                    }
                    tcp.close()
                } catch (e: Exception) {
                    Log.d(TAG, "Error closing TCP client: ${e.message}")
                }
            }
        }
        if (client != null && client.isConnected) {
            serviceScope.launch {
                try {
                    sendGoodbye(bleClient = client, isManual = isManual)
                } catch (e: Exception) {
                    Log.d(TAG, "Error sending GOODBYE to Mac: ${e.message}")
                } finally {
                    client.close()
                }
            }
        }
    }

    private suspend fun sendGoodbye(
        bleClient: BleClient? = null,
        tcpClient: com.droidlink.core.network.TcpClient? = null,
        isManual: Boolean = false
    ) {
        try {
            val sysMsgBuilder = SystemProto.SystemMessage.newBuilder()
                .setEvent(SystemProto.SystemMessage.SystemEventType.GOODBYE)
            if (isManual) {
                val err = SystemProto.ErrorMessage.newBuilder()
                    .setCode(SystemProto.ErrorCode.ERROR_UNKNOWN)
                    .setMessage("MANUAL_DISCONNECT")
                    .build()
                sysMsgBuilder.setError(err)
            }
            val rootMsg = DroidlinkMessages.DroidLinkMessage.newBuilder()
                .setId(System.currentTimeMillis())
                .setTimestamp(System.currentTimeMillis())
                .setType(DroidlinkMessages.MessageType.SYSTEM)
                .setSystem(sysMsgBuilder.build())
                .build()
            val bytes = rootMsg.toByteArray()
            if (tcpClient != null && tcpClient.isConnected) {
                tcpClient.send(bytes)
            } else if (bleClient != null && bleClient.isConnected) {
                bleClient.send(bytes)
            }
            delay(50)
        } catch (e: Exception) {
            Log.d(TAG, "Error sending GOODBYE: ${e.message}")
        }
    }

    private fun handleExternalDisplayMessage(extMsg: ExternalDisplayProto.ExternalDisplayMessage) {
        when (extMsg.event) {
            ExternalDisplayProto.ExternalDisplayMessage.DisplayEventType.START_REQUEST,
            ExternalDisplayProto.ExternalDisplayMessage.DisplayEventType.STARTED -> {
                val (detectedWidth, detectedHeight) = ExternalDisplayActivity.getNativeLandscapeResolution(applicationContext)
                val width = if (extMsg.config.width > 0) extMsg.config.width else detectedWidth
                val height = if (extMsg.config.height > 0) extMsg.config.height else detectedHeight
                val scale = if (extMsg.config.scaleFactor > 0f) extMsg.config.scaleFactor else 2.0f
                Log.i(TAG, "🖥️ External display session initiated by Mac (${width}x${height}, scale=${scale}x)")
                ExternalDisplayActivity.start(applicationContext, width, height, scale)
            }
            ExternalDisplayProto.ExternalDisplayMessage.DisplayEventType.CONFIG_UPDATE -> {
                val scale = if (extMsg.config.scaleFactor > 0f) extMsg.config.scaleFactor else 2.0f
                Log.i(TAG, "🖥️ External display scale updated to ${scale}x")
                ExternalDisplayActivity.updateScale(scale)
            }
            ExternalDisplayProto.ExternalDisplayMessage.DisplayEventType.VIDEO_FRAME -> {
                val frame = extMsg.frame
                val frameBytes = frame.frameData.toByteArray()
                ExternalDisplayActivity.dispatchVideoFrame(
                    frameData = frameBytes,
                    isKeyframe = frame.isKeyframe,
                    frameNumber = frame.frameNumber,
                    timestamp = frame.timestamp
                )
            }
            ExternalDisplayProto.ExternalDisplayMessage.DisplayEventType.STOP -> {
                Log.i(TAG, "🖥️ External display session stopped by Mac")
                ExternalDisplayActivity.stop()
            }
            ExternalDisplayProto.ExternalDisplayMessage.DisplayEventType.CALIBRATION_START -> {
                val refNits = if (extMsg.calibration.macReferenceNits > 0f) extMsg.calibration.macReferenceNits else 200.0f
                val force = extMsg.calibration.forceRecalibrate
                Log.i(TAG, "🎯 External display calibration requested by Mac (refNits=$refNits, force=$force)")
                ExternalDisplayActivity.onCalibrationRequested(refNits, force)
            }
            ExternalDisplayProto.ExternalDisplayMessage.DisplayEventType.BRIGHTNESS_UPDATE -> {
                val targetNits = extMsg.brightness.targetNits
                val macLux = extMsg.brightness.macAmbientLux
                ExternalDisplayActivity.onBrightnessUpdate(targetNits, macLux)
            }
            else -> {
                Log.d(TAG, "External display unhandled event: ${extMsg.event}")
            }
        }
    }

    private fun handleScreenMessage(screenMsg: ScreenProto.ScreenMessage) {
        Log.d(TAG, "Screen message received: ${screenMsg.event}")
    }

    override fun onDestroy() {
        if (activeServiceInstance == this) {
            activeServiceInstance = null
        }
        batteryReceiver?.let {
            try { unregisterReceiver(it) } catch (_: Exception) {}
            batteryReceiver = null
        }
        networkCallback?.let {
            try {
                val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                cm?.unregisterNetworkCallback(it)
            } catch (_: Exception) {}
            networkCallback = null
        }
        telemetryTickerJob?.cancel()
        telemetryTickerJob = null
        super.onDestroy()
        teardown()
        serviceScope.cancel()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
