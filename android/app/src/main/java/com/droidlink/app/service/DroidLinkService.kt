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
import android.media.projection.MediaProjection
import com.droidlink.app.screen.AndroidAppManager
import com.droidlink.app.screen.ScreenCaptureManager
import com.droidlink.app.screen.AudioCaptureManager
import com.droidlink.app.screen.MacMicReceiver
import com.droidlink.app.screen.OrientationManager
import com.droidlink.app.screen.AodPrivacyOverlayManager
import droidlink.protocol.ClipboardProto
import droidlink.protocol.DroidlinkMessages
import droidlink.protocol.FileProto
import droidlink.protocol.NotificationProto
import droidlink.protocol.ScreenProto
import droidlink.protocol.SystemProto
import droidlink.protocol.ExternalDisplayProto
import com.droidlink.app.display.ExternalDisplayActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
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
    private var appManager: AndroidAppManager? = null
    private var screenCaptureManager: ScreenCaptureManager? = null
    private var videoFrameChannel: Channel<ByteArray>? = null
    private var videoSenderJob: Job? = null
    private var audioCaptureManager: AudioCaptureManager? = null
    private val macMicReceiver = MacMicReceiver()
    private var orientationManager: OrientationManager? = null
    private var aodPrivacyOverlayManager: AodPrivacyOverlayManager? = null
    private var batteryReceiver: BroadcastReceiver? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var telemetryTickerJob: Job? = null
    private var lastSentTelemetry: com.droidlink.app.model.DeviceStatusInfo? = null

    companion object {
        var mediaProjection: MediaProjection? = null
        private var isScreenMirroringPending = false
        private var pendingLaunchAppPackage: String? = null
        private var activeServiceInstance: DroidLinkService? = null

        fun setMediaProjectionInstance(mp: MediaProjection?) {
            mediaProjection = mp
        }

        fun updateForegroundServiceTypes(context: Context? = null, hasMediaProjection: Boolean) {
            val instance = activeServiceInstance
            if (instance != null) {
                instance.updateFgsTypes(hasMediaProjection)
            } else if (context != null) {
                val intent = Intent(context, DroidLinkService::class.java).apply {
                    action = ACTION_PREPARE_CAPTURE
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            }
        }

        fun startScreenMirroringIfPending() {
            if (isScreenMirroringPending && mediaProjection != null) {
                isScreenMirroringPending = false
                val pendingPkg = pendingLaunchAppPackage
                if (!pendingPkg.isNullOrEmpty()) {
                    pendingLaunchAppPackage = null
                    activeServiceInstance?.appManager?.launchApp(pendingPkg)
                }
                activeServiceInstance?.startScreenMirroring()
            }
        }

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
        private const val CHANNEL_ID = "droidlink_channel"

        const val ACTION_CONNECT = "com.droidlink.ACTION_CONNECT"
        const val ACTION_DISCONNECT = "com.droidlink.ACTION_DISCONNECT"
        const val ACTION_STOP_EXTERNAL_DISPLAY = "com.droidlink.ACTION_STOP_EXTERNAL_DISPLAY"
        const val ACTION_UPDATE_PRIVACY = "com.droidlink.ACTION_UPDATE_PRIVACY"
        const val ACTION_BROADCAST_TELEMETRY = "com.droidlink.ACTION_BROADCAST_TELEMETRY"
        const val ACTION_PREPARE_CAPTURE = "com.droidlink.ACTION_PREPARE_CAPTURE"
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
        appManager = AndroidAppManager(applicationContext)
        orientationManager = OrientationManager(applicationContext)
        aodPrivacyOverlayManager = AodPrivacyOverlayManager(applicationContext)
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
            ACTION_PREPARE_CAPTURE -> {
                startAsForeground(lastDeviceName)
                updateFgsTypes(hasMediaProjection = true)
            }
        }
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        Log.d(TAG, "Task removed from Recents; maintaining persistent foreground connection.")
    }

    private var lastDeviceName: String = "Mac"

    private fun buildServiceNotification(deviceName: String): android.app.Notification {
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

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("DroidLink Active")
            .setContentText("Connected to $deviceName")
            .setSmallIcon(R.drawable.ic_stat_droidlink)
            .setLargeIcon(BitmapFactory.decodeResource(resources, R.mipmap.ic_launcher))
            .setOngoing(true)
            .setContentIntent(contentPendingIntent)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Disconnect", disconnectPendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun startAsForeground(deviceName: String) {
        this.lastDeviceName = deviceName
        val notification = buildServiceNotification(deviceName)

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

    fun updateFgsTypes(hasMediaProjection: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val notification = buildServiceNotification(lastDeviceName)
            var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            if (hasMediaProjection) {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            }
            startForeground(NOTIFICATION_ID, notification, types)
            Log.i(TAG, "🔄 Updated foreground service types (hasMediaProjection=$hasMediaProjection, types=0x${Integer.toHexString(types)})")
        }
    }

    private var connectionJob: kotlinx.coroutines.Job? = null

    private fun initiateConnection(
        bluetoothAddress: String,
        host: String,
        port: Int,
        deviceName: String,
        sessionKey: ByteArray
    ) {
        this.sessionKey = sessionKey
        val base64Key = android.util.Base64.encodeToString(sessionKey, android.util.Base64.NO_WRAP)
        Log.d(TAG, "🔑 Current Android session key: $base64Key, target BLE: $bluetoothAddress")
        connectionJob?.cancel()
        _connectionState.value = ServiceConnectionState.Connecting(deviceName)
        connectionJob = serviceScope.launch {
            var retryCount = 0
            val maxRetries = 10
            var connected = false

            while (retryCount < maxRetries && !connected) {
                try {
                    // Clean up previous client if any
                    bleClient?.close()

                    val crypto = CryptoChannel(sessionKey)
                    val client = BleClient(applicationContext, bluetoothAddress, crypto)
                    client.connect()
                    bleClient = client
                    connected = true
                    _connectionState.value = ServiceConnectionState.Connected(deviceName)

                    // Send local Android telemetry to Mac & start periodic telemetry updates
                    sendLocalTelemetry(force = true)
                    startTelemetryTicker()

                    // 1. Observe local clipboard changes and forward to Mac via Protobuf
                    clipboardManager?.stopMonitoring()
                    val clipManager = ClipboardManager(applicationContext) { newContent ->
                        val storage = com.droidlink.core.security.PairingStorage(applicationContext)
                        if (!storage.isClipboardSyncEnabled()) {
                            Log.d(TAG, "Clipboard sync is disabled; skipping sync.")
                            return@ClipboardManager
                        }
                        serviceScope.launch {
                            try {
                                val clipData = ClipboardProto.ClipboardData.newBuilder()
                                    .setType(ClipboardProto.DataType.DATA_TEXT)
                                    .setText(newContent)
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

                                client.send(rootMsg.toByteArray())
                                Log.d(TAG, "Sent local clipboard to Mac over BLE: ${newContent.take(30)}...")
                            } catch (e: Exception) {
                                Log.e(TAG, "Failed to send clipboard", e)
                            }
                        }
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

                                client.send(rootMsg.toByteArray())
                                Log.d(TAG, "Forwarded notification with icon to Mac over BLE: ${captured.appName} - ${captured.title}")
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
                                client.send(rootMsg.toByteArray())
                            } catch (e: Exception) {
                                Log.e(TAG, "Failed to send file change event: ${e.message}")
                            }
                        }
                    }
                    fileWatcher = watcher

                    // 7. Receive incoming Protobuf messages from Mac
                    listenForIncoming(client)
                } catch (e: Exception) {
                    retryCount++
                    Log.w(TAG, "BLE Connection attempt $retryCount failed: ${e.message}")
                    if (retryCount < maxRetries) {
                        _connectionState.value = ServiceConnectionState.Connecting("$deviceName (retrying $retryCount/$maxRetries)...")
                        kotlinx.coroutines.delay(2000)
                    } else {
                        Log.e(TAG, "All BLE connection attempts failed", e)
                        _connectionState.value = ServiceConnectionState.Error("Could not reach $deviceName over Bluetooth. Check that Mac app is open.")
                        teardown()
                        stopSelf()
                    }
                }
            }
        }
    }

    private suspend fun listenForIncoming(client: BleClient) {
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
                            if (status.localIpAddress.isNotBlank()) {
                                connectHighSpeedTcp(status.localIpAddress, status.tcpPort)
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
                        val screenMsg = rootMsg.screen
                        handleScreenMessage(screenMsg)
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
        Log.i(TAG, "Exited listen loop. Tearing down service and stopping foreground.")
        withContext(Dispatchers.Main) {
            teardown()
            stopSelf()
        }
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
                _isUsbConnected.value = true
                _connectionState.value = ServiceConnectionState.Connected("Mac (Direct USB)")
                Log.i(TAG, "⚡ AOA USB Direct Connection established! Zero-ADB, Zero-WiFi mode active.")
                sendLocalTelemetry(force = true)
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
                        }
                    }
                    if (rootMsg.hasScreen()) {
                        handleScreenMessage(rootMsg.screen)
                    }
                    if (rootMsg.hasExternalDisplay()) {
                        handleExternalDisplayMessage(rootMsg.externalDisplay)
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

    private fun connectHighSpeedTcp(host: String, port: Int) {
        val key = sessionKey ?: return
        if (tcpClient?.isConnected == true) return
        serviceScope.launch(Dispatchers.IO) {
            val crypto = com.droidlink.core.security.CryptoChannel(key)
            var connectedClient: com.droidlink.core.network.TcpClient? = null

            // 1. First probe ultra-low latency direct USB loopback (127.0.0.1:port)
            try {
                Log.d(TAG, "🔌 Probing USB tunnel at 127.0.0.1:$port...")
                val usbClient = com.droidlink.core.network.TcpClient("127.0.0.1", port, crypto)
                kotlinx.coroutines.withTimeout(800) {
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
            if (connectedClient == null) {
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

            tcpClient = connectedClient
            listenForIncomingTcp(connectedClient)
        }
    }

    private suspend fun listenForIncomingTcp(client: com.droidlink.core.network.TcpClient) {
        while (client.isConnected) {
            val messages = client.receiveMessages()
            if (messages.isEmpty()) break
            for (bytes in messages) {
                try {
                    val rootMsg = DroidlinkMessages.DroidLinkMessage.parseFrom(bytes)
                    if (rootMsg.hasSystem()) {
                        val sys = rootMsg.system
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
                        }
                    }
                    if (rootMsg.hasFile()) {
                        val fileMsg = rootMsg.file
                        Log.d(TAG, "📁 Received file message from Mac via TCP: op=${fileMsg.operation}, path=${fileMsg.filePath}")
                        handleFileMessage(fileMsg, bleClient = null, tcpClient = client)
                    }
                    if (rootMsg.hasScreen()) {
                        val screenMsg = rootMsg.screen
                        handleScreenMessage(screenMsg)
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
    }

    private suspend fun handleFileMessage(
        fileMsg: FileProto.FileMessage,
        bleClient: BleClient? = null,
        tcpClient: com.droidlink.core.network.TcpClient? = null
    ) {
        val storage = com.droidlink.core.security.PairingStorage(applicationContext)
        if (!storage.isFinderStorageEnabled()) {
            Log.w(TAG, "Rejecting FileMessage ${fileMsg.operation}: Finder storage disabled in settings")
            val errResp = FileProto.FileMessage.newBuilder()
                .setOperation(fileMsg.operation)
                .setFilePath(fileMsg.filePath)
                .setErrorMessage("Finder storage access is disabled in Android settings")
                .build()
            sendFileResponse(errResp, bleClient, tcpClient)
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
                        .addAllFiles(files)
                    if (nextToken != null) {
                        respBuilder.setNextPageToken(nextToken)
                    }
                    sendFileResponse(respBuilder.build(), bleClient, tcpClient)
                }
                FileProto.FileMessage.FileOperation.GET_METADATA_REQUEST -> {
                    val info = fileSystemManager.getItemMetadata(fileMsg.filePath)
                    val respBuilder = FileProto.FileMessage.newBuilder()
                        .setOperation(FileProto.FileMessage.FileOperation.GET_METADATA_RESPONSE)
                        .setFilePath(fileMsg.filePath)
                    if (info != null) {
                        respBuilder.setFileInfo(info)
                    }
                    sendFileResponse(respBuilder.build(), bleClient, tcpClient)
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
                        .setOffset(fileMsg.offset)
                        .setFileData(com.google.protobuf.ByteString.copyFrom(result.data))
                        .setChunkSize(result.bytesRead)
                        .setFileSize(result.totalSize)
                        .setIsEof(result.isEof)
                        .build()
                    sendFileResponse(resp, bleClient, tcpClient)
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
                        .setOffset(fileMsg.offset)
                        .setFileSize(totalLength)
                        .setIsEof(fileMsg.isEof)
                        .build()
                    sendFileResponse(resp, bleClient, tcpClient)
                }
                FileProto.FileMessage.FileOperation.CREATE_ITEM_REQUEST -> {
                    val info = fileSystemManager.createItem(fileMsg.filePath, fileMsg.isDirectory)
                    val resp = FileProto.FileMessage.newBuilder()
                        .setOperation(FileProto.FileMessage.FileOperation.CREATE_ITEM_RESPONSE)
                        .setFilePath(fileMsg.filePath)
                        .setFileInfo(info)
                        .build()
                    sendFileResponse(resp, bleClient, tcpClient)
                }
                FileProto.FileMessage.FileOperation.DELETE_ITEM_REQUEST -> {
                    val success = fileSystemManager.deleteItem(fileMsg.filePath, recursive = true)
                    val respBuilder = FileProto.FileMessage.newBuilder()
                        .setOperation(FileProto.FileMessage.FileOperation.DELETE_ITEM_RESPONSE)
                        .setFilePath(fileMsg.filePath)
                    if (!success) {
                        respBuilder.setErrorMessage("Failed to delete item")
                    }
                    sendFileResponse(respBuilder.build(), bleClient, tcpClient)
                }
                FileProto.FileMessage.FileOperation.MOVE_ITEM_REQUEST -> {
                    val success = fileSystemManager.moveItem(fileMsg.filePath, fileMsg.targetPath)
                    val respBuilder = FileProto.FileMessage.newBuilder()
                        .setOperation(FileProto.FileMessage.FileOperation.MOVE_ITEM_RESPONSE)
                        .setFilePath(fileMsg.filePath)
                        .setTargetPath(fileMsg.targetPath)
                    if (!success) {
                        respBuilder.setErrorMessage("Failed to move item")
                    }
                    sendFileResponse(respBuilder.build(), bleClient, tcpClient)
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
                .setErrorMessage(e.message ?: "Filesystem error")
                .build()
            sendFileResponse(errResp, bleClient, tcpClient)
        }
    }

    private suspend fun sendFileResponse(
        fileResp: FileProto.FileMessage,
        bleClient: BleClient? = null,
        tcpClient: com.droidlink.core.network.TcpClient? = null
    ) {
        val rootMsg = DroidlinkMessages.DroidLinkMessage.newBuilder()
            .setId(System.currentTimeMillis())
            .setTimestamp(System.currentTimeMillis())
            .setType(DroidlinkMessages.MessageType.FILE_TRANSFER)
            .setFile(fileResp)
            .build()
        val bytes = rootMsg.toByteArray()
        if (tcpClient != null && tcpClient.isConnected) {
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
        val tcp = tcpClient
        val ble = bleClient
        if ((tcp == null || !tcp.isConnected) && (ble == null || !ble.isConnected)) {
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
                if (tcp != null && tcp.isConnected) {
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
        stopScreenMirroring()
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

    private fun handleScreenMessage(screenMsg: ScreenProto.ScreenMessage) {
        when (screenMsg.event) {
            ScreenProto.ScreenMessage.StreamEventType.LIST_APPS_REQUEST -> {
                Log.d(TAG, "📱 Received LIST_APPS_REQUEST from Mac")
                serviceScope.launch(Dispatchers.IO) {
                    val appMgr = appManager ?: AndroidAppManager(applicationContext)
                    val appsResponse = appMgr.getInstalledApps()
                    val respMsg = ScreenProto.ScreenMessage.newBuilder()
                        .setEvent(ScreenProto.ScreenMessage.StreamEventType.LIST_APPS_RESPONSE)
                        .setListAppsResponse(appsResponse)
                        .build()
                    val rootMsg = DroidlinkMessages.DroidLinkMessage.newBuilder()
                        .setId(System.currentTimeMillis())
                        .setTimestamp(System.currentTimeMillis())
                        .setType(DroidlinkMessages.MessageType.SCREEN_STREAM)
                        .setScreen(respMsg)
                        .build()
                    sendToActiveClient(rootMsg.toByteArray())
                    Log.d(TAG, "Sent LIST_APPS_RESPONSE with ${appsResponse.appsCount} apps to Mac")
                }
            }
            ScreenProto.ScreenMessage.StreamEventType.LAUNCH_APP_REQUEST -> {
                val pkgName = screenMsg.launchAppRequest.packageName
                Log.d(TAG, "🚀 Received LAUNCH_APP_REQUEST for $pkgName")
                pendingLaunchAppPackage = pkgName
                val appMgr = appManager ?: AndroidAppManager(applicationContext)

                if (mediaProjection == null) {
                    // Prompt user on phone first before switching foreground apps
                    startScreenMirroring()
                } else {
                    val success = appMgr.launchApp(pkgName)
                    val resp = ScreenProto.LaunchAppResponse.newBuilder()
                        .setSuccess(success)
                        .apply {
                            if (!success) setErrorMessage("Failed to launch $pkgName")
                        }
                        .build()
                    val respMsg = ScreenProto.ScreenMessage.newBuilder()
                        .setEvent(ScreenProto.ScreenMessage.StreamEventType.LAUNCH_APP_RESPONSE)
                        .setLaunchAppResponse(resp)
                        .build()
                    val rootMsg = DroidlinkMessages.DroidLinkMessage.newBuilder()
                        .setId(System.currentTimeMillis())
                        .setTimestamp(System.currentTimeMillis())
                        .setType(DroidlinkMessages.MessageType.SCREEN_STREAM)
                        .setScreen(respMsg)
                        .build()
                    serviceScope.launch(Dispatchers.IO) {
                        sendToActiveClient(rootMsg.toByteArray())
                    }
                    if (success && screenCaptureManager == null) {
                        startScreenMirroring()
                    }
                }
            }
            ScreenProto.ScreenMessage.StreamEventType.START_REQUEST -> {
                Log.i(TAG, "▶️ Received START_REQUEST for screen stream from Mac (fps=${screenMsg.config.fps}, bitrate=${screenMsg.config.bitrate}k)")
                val targetFps = if (screenMsg.config.fps > 0) screenMsg.config.fps else 60
                val targetBitrate = if (screenMsg.config.bitrate > 0) screenMsg.config.bitrate * 1000 else 16_000_000
                if (screenCaptureManager == null) {
                    startScreenMirroring(targetFps, targetBitrate)
                } else {
                    Log.i(TAG, "Screen mirroring pipeline is already active; ignoring duplicate START_REQUEST")
                }
            }
            ScreenProto.ScreenMessage.StreamEventType.STOP -> {
                Log.i(TAG, "⏹️ Received STOP for screen stream from Mac")
                stopScreenMirroring()
            }
            ScreenProto.ScreenMessage.StreamEventType.ROTATE_REQUEST -> {
                val rotateReq = screenMsg.rotateRequest
                Log.i(TAG, "🔄 Received ROTATE_REQUEST: mode=${rotateReq.mode}")
                orientationManager?.setRotationMode(rotateReq.mode)
            }
            ScreenProto.ScreenMessage.StreamEventType.TOUCH_EVENT -> {
                val touch = screenMsg.touchEvent
                DroidLinkAccessibilityService.instance?.dispatchTouch(
                    normX = touch.x,
                    normY = touch.y,
                    action = touch.action,
                    scrollDx = touch.scrollDx,
                    scrollDy = touch.scrollDy
                )
            }
            ScreenProto.ScreenMessage.StreamEventType.KEY_EVENT -> {
                val key = screenMsg.keyEvent
                DroidLinkAccessibilityService.instance?.inputKey(
                    text = key.text,
                    keyCode = key.keyCode
                )
            }
            ScreenProto.ScreenMessage.StreamEventType.NAV_EVENT -> {
                val nav = screenMsg.navEvent
                if (nav.action == ScreenProto.NavigationEvent.NavAction.POWER) {
                    Log.i(TAG, "🌙 Toggling AOD Privacy Overlay via Mac Power button")
                    aodPrivacyOverlayManager?.toggle()
                } else {
                    DroidLinkAccessibilityService.instance?.performNavAction(nav.action)
                }
            }
            ScreenProto.ScreenMessage.StreamEventType.MIC_DATA -> {
                val mic = screenMsg.micFrame
                macMicReceiver.onMicDataReceived(
                    pcmData = mic.audioData.toByteArray(),
                    sampleRate = mic.sampleRate,
                    channels = mic.channels
                )
            }
            ScreenProto.ScreenMessage.StreamEventType.MIC_CONTROL -> {
                val ctrl = screenMsg.micControl
                if (ctrl.isMuted) {
                    macMicReceiver.stop()
                }
            }
            else -> {
                Log.d(TAG, "Screen message unhandled event: ${screenMsg.event}")
            }
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
            else -> {
                Log.d(TAG, "External display unhandled event: ${extMsg.event}")
            }
        }
    }

    private fun startScreenMirroring(targetFps: Int = 60, targetBitrate: Int = 16_000_000) {
        val mp = mediaProjection
        if (mp == null) {
            Log.w(TAG, "⚠️ MediaProjection not granted. Launching screen capture prompt on phone...")
            isScreenMirroringPending = true

            // 1. Wake device screen if asleep
            try {
                val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                @Suppress("DEPRECATION")
                val wakeLock = powerManager.newWakeLock(
                    PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                    "droidlink:screen_mirror_prompt"
                )
                wakeLock.acquire(3000)
            } catch (e: Exception) {
                Log.w(TAG, "Could not acquire wake lock: ${e.message}")
            }

            // 2. Prepare intent to open MainActivity with capture request
            val promptIntent = Intent(applicationContext, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra(MainActivity.EXTRA_REQUEST_SCREEN_CAPTURE, true)
            }

            val pendingIntent = PendingIntent.getActivity(
                this,
                2001,
                promptIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            // 3. Try direct startActivity (succeeds if app has overlay permission or is top)
            try {
                startActivity(promptIntent)
            } catch (e: Exception) {
                Log.w(TAG, "Direct startActivity blocked by BAL: ${e.message}")
            }

            // 4. Concurrently post high-priority Heads-up Notification with FullScreenIntent
            try {
                val notifManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                val notif = NotificationCompat.Builder(this, CHANNEL_ID)
                    .setContentTitle("Screen Mirroring Requested")
                    .setContentText("Mac requested to mirror screen. Tap to start.")
                    .setSmallIcon(R.drawable.ic_stat_droidlink)
                    .setPriority(NotificationCompat.PRIORITY_MAX)
                    .setCategory(NotificationCompat.CATEGORY_CALL)
                    .setFullScreenIntent(pendingIntent, true)
                    .setContentIntent(pendingIntent)
                    .setAutoCancel(true)
                    .addAction(R.drawable.ic_stat_droidlink, "Start Now", pendingIntent)
                    .build()
                notifManager.notify(2002, notif)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to post screen capture request notification: ${e.message}")
            }
            return
        }
        isScreenMirroringPending = false

        screenCaptureManager?.stop()

        videoSenderJob?.cancel()
        val frameChannel = Channel<ByteArray>(
            capacity = 2,
            onBufferOverflow = BufferOverflow.DROP_OLDEST
        )
        videoFrameChannel = frameChannel

        videoSenderJob = serviceScope.launch(Dispatchers.IO) {
            for (frameBytes in frameChannel) {
                sendToActiveClient(frameBytes)
            }
        }

        val captureMgr = ScreenCaptureManager(
            context = applicationContext,
            mediaProjection = mp,
            scope = serviceScope,
            onFrameEncoded = { frameData, isKeyframe, frameNum, timestamp ->
                val frameMsg = ScreenProto.ScreenMessage.newBuilder()
                    .setEvent(ScreenProto.ScreenMessage.StreamEventType.FRAME)
                    .setFrameData(ByteString.copyFrom(frameData))
                    .setIsKeyframe(isKeyframe)
                    .setFrameNumber(frameNum)
                    .setTimestamp(timestamp)
                    .build()
                val rootMsg = DroidlinkMessages.DroidLinkMessage.newBuilder()
                    .setId(System.currentTimeMillis())
                    .setTimestamp(System.currentTimeMillis())
                    .setType(DroidlinkMessages.MessageType.SCREEN_STREAM)
                    .setScreen(frameMsg)
                    .build()
                videoFrameChannel?.trySend(rootMsg.toByteArray())
            },
            onScreenMetricsChanged = { width, height, rotation, dpi ->
                val info = ScreenProto.ScreenInfo.newBuilder()
                    .setWidth(width)
                    .setHeight(height)
                    .setRotation(rotation)
                    .setDpi(dpi)
                    .build()
                val infoMsg = ScreenProto.ScreenMessage.newBuilder()
                    .setEvent(ScreenProto.ScreenMessage.StreamEventType.SCREEN_INFO)
                    .setScreenInfo(info)
                    .build()
                val rootMsg = DroidlinkMessages.DroidLinkMessage.newBuilder()
                    .setId(System.currentTimeMillis())
                    .setTimestamp(System.currentTimeMillis())
                    .setType(DroidlinkMessages.MessageType.SCREEN_STREAM)
                    .setScreen(infoMsg)
                    .build()
                serviceScope.launch(Dispatchers.IO) {
                    sendToActiveClient(rootMsg.toByteArray())
                }
            }
        )
        screenCaptureManager = captureMgr
        captureMgr.start(targetFps, targetBitrate)

        // Start internal audio capture
        audioCaptureManager?.stop()
        val audioMgr = AudioCaptureManager(
            context = applicationContext,
            mediaProjection = mp,
            scope = serviceScope,
            onAudioCaptured = { audioData, sampleRate, channels, timestamp ->
                val audioFrame = ScreenProto.ScreenAudioFrame.newBuilder()
                    .setAudioData(ByteString.copyFrom(audioData))
                    .setSampleRate(sampleRate)
                    .setChannels(channels)
                    .setTimestamp(timestamp)
                    .build()
                val audioMsg = ScreenProto.ScreenMessage.newBuilder()
                    .setEvent(ScreenProto.ScreenMessage.StreamEventType.AUDIO_FRAME)
                    .setAudioFrame(audioFrame)
                    .build()
                val rootMsg = DroidlinkMessages.DroidLinkMessage.newBuilder()
                    .setId(System.currentTimeMillis())
                    .setTimestamp(System.currentTimeMillis())
                    .setType(DroidlinkMessages.MessageType.SCREEN_STREAM)
                    .setScreen(audioMsg)
                    .build()
                serviceScope.launch(Dispatchers.IO) {
                    sendToActiveClient(rootMsg.toByteArray())
                }
            }
        )
        audioCaptureManager = audioMgr
        audioMgr.start()
        Log.i(TAG, "Screen and internal audio mirroring pipelines fully initialized")
    }

    private fun stopScreenMirroring() {
        videoSenderJob?.cancel()
        videoSenderJob = null
        videoFrameChannel?.close()
        videoFrameChannel = null
        screenCaptureManager?.stop()
        screenCaptureManager = null
        audioCaptureManager?.stop()
        audioCaptureManager = null
        macMicReceiver.stop()
        orientationManager?.reset()
        aodPrivacyOverlayManager?.hide()
        mediaProjection = null
        Log.i(TAG, "Screen and audio mirroring pipelines stopped")
    }

    private suspend fun sendToActiveClient(bytes: ByteArray) {
        try {
            if (tcpClient?.isConnected == true) {
                tcpClient?.send(bytes)
            } else {
                bleClient?.send(bytes)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send message to active client: ${e.message}")
        }
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
