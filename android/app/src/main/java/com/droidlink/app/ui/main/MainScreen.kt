package com.droidlink.app.ui.main

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat

// MARK: - 4 Bottom Navigation Tabs

enum class MainTab(val title: String, val icon: ImageVector) {
    Home("Home", Icons.Default.Home),
    Notifications("Notifications", Icons.Default.Notifications),
    Clipboard("Clipboard", Icons.Default.ContentPaste),
    Settings("Settings", Icons.Default.Settings)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(
    viewModel: MainViewModel,
    onNavigateToAppFilters: () -> Unit,
    onRequestMediaProjection: () -> Unit = {}
) {
    var selectedTab by rememberSaveable { mutableStateOf(MainTab.Home) }
    val uiState by viewModel.uiState.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        when (selectedTab) {
                            MainTab.Home -> "DroidLink"
                            MainTab.Notifications -> "Notifications"
                            MainTab.Clipboard -> "Universal Clipboard"
                            MainTab.Settings -> "Settings"
                        }
                    )
                }
            )
        },
        bottomBar = {
            NavigationBar {
                MainTab.entries.forEach { tab ->
                    NavigationBarItem(
                        selected = selectedTab == tab,
                        onClick = { selectedTab = tab },
                        icon = { Icon(tab.icon, contentDescription = tab.title) },
                        label = { Text(tab.title) }
                    )
                }
            }
        }
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
        ) {
            when (selectedTab) {
                MainTab.Home -> HomeTabContent(
                    viewModel = viewModel,
                    onNavigateToNotifications = { selectedTab = MainTab.Notifications },
                    onNavigateToClipboard = { selectedTab = MainTab.Clipboard },
                    onRequestMediaProjection = onRequestMediaProjection
                )
                MainTab.Notifications -> NotificationsTabContent(
                    viewModel = viewModel,
                    onNavigateToAppFilters = onNavigateToAppFilters
                )
                MainTab.Clipboard -> ClipboardTabContent(viewModel = viewModel)
                MainTab.Settings -> SettingsTabContent(
                    viewModel = viewModel,
                    onNavigateToNotifications = { selectedTab = MainTab.Notifications },
                    onNavigateToClipboard = { selectedTab = MainTab.Clipboard }
                )
            }
        }
    }
}

// MARK: - Tab 1: Home Content

@Composable
private fun HomeTabContent(
    viewModel: MainViewModel,
    onNavigateToNotifications: () -> Unit,
    onNavigateToClipboard: () -> Unit,
    onRequestMediaProjection: () -> Unit = {}
) {
    val context = LocalContext.current
    val uiState by viewModel.uiState.collectAsState()
    val isClipboardSyncEnabled by viewModel.isClipboardSyncEnabled.collectAsState()
    val isNotificationSyncEnabled by viewModel.isNotificationSyncEnabled.collectAsState()
    val remoteStatus by viewModel.remoteDeviceStatus.collectAsState()
    val isMediaProjectionGranted by viewModel.isMediaProjectionGranted.collectAsState()
    val isAccessibilityEnabled by viewModel.isAccessibilityEnabled.collectAsState()
    val shizukuState by viewModel.shizukuState.collectAsState()
    val isUsbConnected by viewModel.isUsbConnected.collectAsState()
    val isScreenMirroringActive by viewModel.isScreenMirroringActive.collectAsState()

    val bluetoothPermissions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        arrayOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT
        )
    } else {
        arrayOf(
            Manifest.permission.ACCESS_FINE_LOCATION
        )
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        viewModel.refreshPermissionStatus()
        val allGranted = permissions.values.all { it }
        if (allGranted) {
            viewModel.startBluetoothScan()
        }
    }

    val postNotificationLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) {
        viewModel.refreshPermissionStatus()
    }

    val requestScan = {
        val allGranted = bluetoothPermissions.all { perm ->
            ContextCompat.checkSelfPermission(context, perm) == PackageManager.PERMISSION_GRANTED
        }
        if (allGranted) {
            viewModel.startBluetoothScan()
        } else {
            permissionLauncher.launch(bluetoothPermissions)
        }
    }

    LaunchedEffect(Unit) {
        viewModel.refreshPermissionStatus()
    }

    val isPaired = when (uiState) {
        is MainUiState.Connected, is MainUiState.Connecting, is MainUiState.Paired -> true
        else -> false
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(20.dp),
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 20.dp)
    ) {
        if (isPaired) {
            val (pairedName, pairedModel) = when (val state = uiState) {
                is MainUiState.Connected -> state.deviceName to (remoteStatus?.deviceModel?.ifEmpty { state.deviceModel } ?: state.deviceModel)
                is MainUiState.Connecting -> state.deviceName to (remoteStatus?.deviceModel?.ifEmpty { state.deviceModel } ?: state.deviceModel)
                is MainUiState.Paired -> state.deviceName to (remoteStatus?.deviceModel?.ifEmpty { state.deviceModel } ?: state.deviceModel)
                else -> "Mac" to "Mac"
            }

            // 1. Primary Action Buttons when Disconnected (Placed directly before Mac widget)
            if (uiState !is MainUiState.Connected) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    if (uiState is MainUiState.Connecting) {
                        OutlinedButton(
                            onClick = { viewModel.disconnect() },
                            modifier = Modifier.weight(1f)
                        ) {
                            Text("Cancel Connection")
                        }
                    } else {
                        Button(
                            onClick = { viewModel.reconnect() },
                            modifier = Modifier.weight(1f)
                        ) {
                            Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(6.dp))
                            Text("Connect")
                        }
                    }
                    Button(
                        onClick = { viewModel.forgetDevice() },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.error
                        ),
                        modifier = Modifier.weight(1f)
                    ) {
                        Text("Forget Device")
                    }
                }
            }

            // 2. Paired Device Header Card (Name & Model Beneath)
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
                )
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(18.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(16.dp)
                    ) {
                        Surface(
                            shape = CircleShape,
                            color = MaterialTheme.colorScheme.primary.copy(alpha = 0.12f),
                            modifier = Modifier.size(52.dp)
                        ) {
                            Box(contentAlignment = Alignment.Center) {
                                Icon(
                                    imageVector = Icons.Default.Laptop,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.primary,
                                    modifier = Modifier.size(28.dp)
                                )
                            }
                        }

                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween
                            ) {
                                Text(
                                    text = pairedName,
                                    style = MaterialTheme.typography.titleMedium,
                                    fontWeight = FontWeight.Bold,
                                    maxLines = 1,
                                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                                    modifier = Modifier.weight(1f, fill = false).padding(end = 8.dp)
                                )
                                when (uiState) {
                                    is MainUiState.Connected -> {
                                        Surface(
                                            shape = CircleShape,
                                            color = Color(0xFF4CAF50).copy(alpha = 0.15f)
                                        ) {
                                            Text(
                                                text = "ACTIVE",
                                                style = MaterialTheme.typography.labelSmall,
                                                fontWeight = FontWeight.Bold,
                                                color = Color(0xFF2E7D32),
                                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                                                maxLines = 1
                                            )
                                        }
                                    }
                                    is MainUiState.Connecting -> {
                                        Surface(
                                            shape = CircleShape,
                                            color = MaterialTheme.colorScheme.tertiary.copy(alpha = 0.15f)
                                        ) {
                                            Text(
                                                text = "CONNECTING",
                                                style = MaterialTheme.typography.labelSmall,
                                                fontWeight = FontWeight.Bold,
                                                color = MaterialTheme.colorScheme.tertiary,
                                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                                                maxLines = 1
                                            )
                                        }
                                    }
                                    else -> {
                                        Surface(
                                            shape = CircleShape,
                                            color = Color(0xFFFF9800).copy(alpha = 0.15f)
                                        ) {
                                            Text(
                                                text = "DISCONNECTED",
                                                style = MaterialTheme.typography.labelSmall,
                                                fontWeight = FontWeight.Bold,
                                                color = Color(0xFFE65100),
                                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                                                maxLines = 1
                                            )
                                        }
                                    }
                                }
                            }

                            Text(
                                text = pairedModel,
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.primary,
                                fontWeight = FontWeight.Medium,
                                maxLines = 1,
                                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
                            )

                            Text(
                                text = when (uiState) {
                                    is MainUiState.Connected -> "Connected via Encrypted BLE • 0 Cloud"
                                    is MainUiState.Connecting -> "Connecting to $pairedName..."
                                    else -> "Disconnected • Tap Connect above to resume session"
                                },
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }

                // Active Multi-Transport Channels Card
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
                    )
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Text(
                            text = "Active Transport Channels",
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = FontWeight.Bold
                        )
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            // 1. Bluetooth Status
                            Surface(
                                shape = MaterialTheme.shapes.small,
                                color = if (uiState is MainUiState.Connected) Color(0xFF2E7D32).copy(alpha = 0.12f) else MaterialTheme.colorScheme.surfaceVariant,
                                modifier = Modifier.weight(1f)
                            ) {
                                Column(modifier = Modifier.padding(8.dp)) {
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                        Icon(Icons.Default.Bluetooth, contentDescription = null, modifier = Modifier.size(14.dp), tint = if (uiState is MainUiState.Connected) Color(0xFF2E7D32) else MaterialTheme.colorScheme.onSurfaceVariant)
                                        Text("Bluetooth", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold)
                                    }
                                    Text(if (uiState is MainUiState.Connected) "Connected (BLE)" else "Idle", style = MaterialTheme.typography.labelSmall, color = if (uiState is MainUiState.Connected) Color(0xFF2E7D32) else MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }

                            // 2. Wi-Fi LAN Status
                            Surface(
                                shape = MaterialTheme.shapes.small,
                                color = if (uiState is MainUiState.Connected) Color(0xFF1976D2).copy(alpha = 0.12f) else MaterialTheme.colorScheme.surfaceVariant,
                                modifier = Modifier.weight(1f)
                            ) {
                                Column(modifier = Modifier.padding(8.dp)) {
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                        Icon(Icons.Default.Wifi, contentDescription = null, modifier = Modifier.size(14.dp), tint = if (uiState is MainUiState.Connected) Color(0xFF1976D2) else MaterialTheme.colorScheme.onSurfaceVariant)
                                        Text("Wi-Fi LAN", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold)
                                    }
                                    Text(if (uiState is MainUiState.Connected) "Active" else "Offline", style = MaterialTheme.typography.labelSmall, color = if (uiState is MainUiState.Connected) Color(0xFF1976D2) else MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }

                            // 3. USB AOA Status
                            Surface(
                                shape = MaterialTheme.shapes.small,
                                color = if (isUsbConnected) Color(0xFF2E7D32).copy(alpha = 0.15f) else Color(0xFFE65100).copy(alpha = 0.12f),
                                modifier = Modifier.weight(1f)
                            ) {
                                Column(modifier = Modifier.padding(8.dp)) {
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                        Icon(Icons.Default.Usb, contentDescription = null, modifier = Modifier.size(14.dp), tint = if (isUsbConnected) Color(0xFF2E7D32) else Color(0xFFE65100))
                                        Text("USB Link", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold)
                                    }
                                    Text(if (isUsbConnected) "⚡ Wire Speed" else "Independent", style = MaterialTheme.typography.labelSmall, color = if (isUsbConnected) Color(0xFF2E7D32) else Color(0xFFE65100))
                                }
                            }
                        }
                    }
                }
            }

            // 2. Battery, Network, Cellular & SIM Info
            val localStatus by viewModel.localDeviceStatus.collectAsState()

            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Text(
                    text = "Device & Network Status",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold
                )

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    // Battery Card
                    Card(
                        modifier = Modifier.weight(1f),
                        colors = CardDefaults.cardColors(
                            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
                        )
                    ) {
                        Column(
                            modifier = Modifier.padding(14.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                val isCharging = remoteStatus?.isCharging ?: localStatus.isCharging
                                Icon(
                                    imageVector = if (isCharging) Icons.Default.BatteryChargingFull else Icons.Default.BatteryStd,
                                    contentDescription = null,
                                    tint = if (isCharging) Color(0xFF4CAF50) else MaterialTheme.colorScheme.primary,
                                    modifier = Modifier.size(20.dp)
                                )
                                Text(
                                    "Battery",
                                    style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            val batteryPct = remoteStatus?.batteryLevel?.takeIf { it >= 0 } ?: localStatus.batteryLevel
                            Text(
                                text = if (batteryPct >= 0) "$batteryPct%" else "AC Power",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold
                            )
                            val source = remoteStatus?.powerSource ?: localStatus.powerSource
                            Text(
                                text = source,
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }

                    // Network (Wi-Fi) Card
                    Card(
                        modifier = Modifier.weight(1f),
                        colors = CardDefaults.cardColors(
                            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
                        )
                    ) {
                        Column(
                            modifier = Modifier.padding(14.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                Icon(
                                    imageVector = Icons.Default.Wifi,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.primary,
                                    modifier = Modifier.size(20.dp)
                                )
                                Text(
                                    "Wi-Fi",
                                    style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            val wifiSsid = (remoteStatus?.wifiSsid?.ifEmpty { null } ?: localStatus.wifiSsid).ifEmpty { "Connected" }
                            Text(
                                text = wifiSsid,
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                                maxLines = 1
                            )
                            val signalLevel = remoteStatus?.wifiSignalLevel ?: localStatus.wifiSignalLevel
                            Text(
                                text = "Signal: $signalLevel/4 bars",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }

                // Connection & Host Info Card (Replacing Cellular & SIM)
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
                    )
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(14.dp)
                    ) {
                        Surface(
                            shape = CircleShape,
                            color = MaterialTheme.colorScheme.primary.copy(alpha = 0.1f),
                            modifier = Modifier.size(40.dp)
                        ) {
                            Box(contentAlignment = Alignment.Center) {
                                Icon(
                                    imageVector = Icons.Default.Dns,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.primary,
                                    modifier = Modifier.size(20.dp)
                                )
                            }
                        }

                        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                val pairedDevice = remember(uiState) { com.droidlink.core.security.PairingStorage(context).getPairedDevice() }
                                val host = remoteStatus?.localIpAddress?.ifEmpty { null }
                                    ?: pairedDevice?.host?.ifEmpty { null }
                                    ?: "Local Network Peer"
                                Text(
                                    text = host,
                                    style = MaterialTheme.typography.bodyLarge,
                                    fontWeight = FontWeight.SemiBold
                                )
                                Surface(
                                    shape = MaterialTheme.shapes.extraSmall,
                                    color = MaterialTheme.colorScheme.primaryContainer
                                ) {
                                    val port = remoteStatus?.tcpPort?.takeIf { it > 0 }
                                        ?: pairedDevice?.port?.takeIf { it > 0 }
                                        ?: 29170
                                    Text(
                                        text = ":$port",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onPrimaryContainer,
                                        modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp)
                                    )
                                }
                            }
                            Text(
                                text = "AES-256-GCM Encrypted • Direct Wi-Fi / USB",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }
            }

            // 3. Modules List with Direct Toggle Switches
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Text(
                    text = "Modules",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold
                )

                // Universal Clipboard Module Row
                Card(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(onClick = onNavigateToClipboard),
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
                    )
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(14.dp),
                                modifier = Modifier.weight(1f).padding(end = 8.dp)
                            ) {
                                Surface(
                                    shape = CircleShape,
                                    color = MaterialTheme.colorScheme.primary.copy(alpha = 0.12f),
                                    modifier = Modifier.size(42.dp)
                                ) {
                                    Box(contentAlignment = Alignment.Center) {
                                        Icon(
                                            imageVector = Icons.Default.ContentPaste,
                                            contentDescription = null,
                                            tint = MaterialTheme.colorScheme.primary,
                                            modifier = Modifier.size(20.dp)
                                        )
                                    }
                                }
                                Column {
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                        Text(
                                            "Universal Clipboard",
                                            style = MaterialTheme.typography.bodyLarge,
                                            fontWeight = FontWeight.SemiBold
                                        )
                                        Surface(
                                            shape = CircleShape,
                                            color = Color(0xFF2E7D32).copy(alpha = 0.12f)
                                        ) {
                                            Text(
                                                "BLE Sync Active",
                                                style = MaterialTheme.typography.labelSmall,
                                                color = Color(0xFF2E7D32),
                                                fontWeight = FontWeight.Bold,
                                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                                            )
                                        }
                                    }
                                    Text(
                                        if (isClipboardSyncEnabled) "Instant bidirectional sync (Android ⟷ Mac over BLE)" else "Module disabled",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            }
                            Switch(
                                checked = isClipboardSyncEnabled,
                                onCheckedChange = { viewModel.setClipboardSyncEnabled(it) }
                            )
                        }

                        // Test Button to immediately demonstrate Android -> Mac sync
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.End
                        ) {
                            OutlinedButton(
                                onClick = {
                                    val synced = viewModel.triggerTestClipboardSync()
                                    android.widget.Toast.makeText(context, "Copied & Synced to Mac: $synced", android.widget.Toast.LENGTH_SHORT).show()
                                },
                                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)
                            ) {
                                Icon(Icons.Default.Send, contentDescription = null, modifier = Modifier.size(14.dp))
                                Spacer(Modifier.width(6.dp))
                                Text("Test Android ➔ Mac Sync", style = MaterialTheme.typography.labelMedium)
                            }
                        }
                    }
                }

                // Notification Sync Module Row
                Card(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(onClick = onNavigateToNotifications),
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
                    )
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(14.dp),
                            modifier = Modifier.weight(1f).padding(end = 8.dp)
                        ) {
                            Surface(
                                shape = CircleShape,
                                color = MaterialTheme.colorScheme.tertiary.copy(alpha = 0.12f),
                                modifier = Modifier.size(42.dp)
                            ) {
                                Box(contentAlignment = Alignment.Center) {
                                    Icon(
                                        imageVector = Icons.Default.Notifications,
                                        contentDescription = null,
                                        tint = MaterialTheme.colorScheme.tertiary,
                                        modifier = Modifier.size(20.dp)
                                    )
                                }
                            }
                            Column {
                                Text(
                                    "Notification Sync",
                                    style = MaterialTheme.typography.bodyLarge,
                                    fontWeight = FontWeight.SemiBold
                                )
                                Text(
                                    if (isNotificationSyncEnabled) "Mirror phone alerts natively to Mac" else "Module disabled",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                        Switch(
                            checked = isNotificationSyncEnabled,
                            onCheckedChange = { viewModel.setNotificationSyncEnabled(it) }
                        )
                    }
                }

                // Android Storage in Finder (NSFileProvider)
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
                    )
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(14.dp)
                        ) {
                            Surface(
                                shape = CircleShape,
                                color = MaterialTheme.colorScheme.secondary.copy(alpha = 0.12f),
                                modifier = Modifier.size(42.dp)
                            ) {
                                Box(contentAlignment = Alignment.Center) {
                                    Icon(
                                        imageVector = Icons.Default.Folder,
                                        contentDescription = null,
                                        tint = MaterialTheme.colorScheme.secondary,
                                        modifier = Modifier.size(20.dp)
                                    )
                                }
                            }
                            Column(modifier = Modifier.weight(1f)) {
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                    Text(
                                        "Android Storage in Finder",
                                        style = MaterialTheme.typography.bodyLarge,
                                        fontWeight = FontWeight.SemiBold
                                    )
                                    if (isUsbConnected) {
                                        Surface(
                                            shape = CircleShape,
                                            color = Color(0xFF1976D2).copy(alpha = 0.15f)
                                        ) {
                                            Text(
                                                "⚡ Supercharged USB",
                                                style = MaterialTheme.typography.labelSmall,
                                                color = Color(0xFF1976D2),
                                                fontWeight = FontWeight.Bold,
                                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                                            )
                                        }
                                    }
                                }
                                Text(
                                    if (isUsbConnected) {
                                        "Wire Speed (35-45 MB/s) direct AOA Bulk transfer active • Finder browsing ready"
                                    } else {
                                        "Local Wi-Fi Mode active • Browse files directly in macOS Finder sidebar"
                                    },
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }
                }

                // Screen Mirroring & Remote Control Card
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
                    )
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(14.dp)
                        ) {
                            Surface(
                                shape = CircleShape,
                                color = MaterialTheme.colorScheme.primary.copy(alpha = 0.12f),
                                modifier = Modifier.size(42.dp)
                            ) {
                                Box(contentAlignment = Alignment.Center) {
                                    Icon(
                                        imageVector = Icons.Default.ScreenShare,
                                        contentDescription = null,
                                        tint = MaterialTheme.colorScheme.primary,
                                        modifier = Modifier.size(20.dp)
                                    )
                                }
                            }
                            Column(modifier = Modifier.weight(1f)) {
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                    Text(
                                        "Screen Mirroring & Control",
                                        style = MaterialTheme.typography.bodyLarge,
                                        fontWeight = FontWeight.SemiBold
                                    )
                                    if (isScreenMirroringActive) {
                                        Surface(
                                            shape = CircleShape,
                                            color = Color(0xFF4CAF50).copy(alpha = 0.15f)
                                        ) {
                                            Text(
                                                "STREAMING",
                                                style = MaterialTheme.typography.labelSmall,
                                                fontWeight = FontWeight.Bold,
                                                color = Color(0xFF2E7D32),
                                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                                            )
                                        }
                                    } else if (isUsbConnected) {
                                        Surface(
                                            shape = CircleShape,
                                            color = Color(0xFF1976D2).copy(alpha = 0.12f)
                                        ) {
                                            Text(
                                                "⚡ USB HID Ready",
                                                style = MaterialTheme.typography.labelSmall,
                                                fontWeight = FontWeight.Bold,
                                                color = Color(0xFF1976D2),
                                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                                            )
                                        }
                                    }
                                }
                                Text(
                                    "Low-latency H.264 display, audio & hardware AOA 2.0 USB HID control",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }

                        // Hardware USB HID Indicator when USB connected
                        if (isUsbConnected) {
                            Surface(
                                shape = MaterialTheme.shapes.small,
                                color = Color(0xFF2E7D32).copy(alpha = 0.10f),
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Row(
                                    modifier = Modifier.padding(10.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    Icon(Icons.Default.Bolt, contentDescription = null, tint = Color(0xFF2E7D32), modifier = Modifier.size(16.dp))
                                    Text(
                                        "Native Hardware USB HID Mode: Mac acts as direct hardware USB mouse (1000Hz) & keyboard to Android kernel.",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = Color(0xFF1B5E20)
                                    )
                                }
                            }
                        }

                        HorizontalDivider(color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.15f))

                        // 1. MediaProjection Screen Capture Status
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Column(modifier = Modifier.weight(1f).padding(end = 8.dp)) {
                                Text(
                                    "Display & Audio Capture",
                                    style = MaterialTheme.typography.bodyMedium,
                                    fontWeight = FontWeight.Medium
                                )
                                Text(
                                    if (isMediaProjectionGranted) "Ready to stream to Mac" else "Requires one-time capture permission",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            if (isMediaProjectionGranted) {
                                Surface(
                                    shape = CircleShape,
                                    color = Color(0xFF4CAF50).copy(alpha = 0.15f)
                                ) {
                                    Text(
                                        "READY",
                                        style = MaterialTheme.typography.labelSmall,
                                        fontWeight = FontWeight.Bold,
                                        color = Color(0xFF2E7D32),
                                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
                                    )
                                }
                            } else {
                                Button(
                                    onClick = onRequestMediaProjection,
                                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)
                                ) {
                                    Text("Grant", style = MaterialTheme.typography.labelMedium)
                                }
                            }
                        }

                        // 2. Accessibility Remote Control Status (Zero-ADB)
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Column(modifier = Modifier.weight(1f).padding(end = 8.dp)) {
                                Text(
                                    "Mouse, Touch & Keyboard",
                                    style = MaterialTheme.typography.bodyMedium,
                                    fontWeight = FontWeight.Medium
                                )
                                Text(
                                    if (isUsbConnected) "Hardware USB HID (0ms lag)" else (if (isAccessibilityEnabled) "Zero-ADB control active" else "Requires Accessibility Service"),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            if (isUsbConnected || isAccessibilityEnabled) {
                                Surface(
                                    shape = CircleShape,
                                    color = Color(0xFF4CAF50).copy(alpha = 0.15f)
                                ) {
                                    Text(
                                        if (isUsbConnected) "USB HID" else "ACTIVE",
                                        style = MaterialTheme.typography.labelSmall,
                                        fontWeight = FontWeight.Bold,
                                        color = Color(0xFF2E7D32),
                                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
                                    )
                                }
                            } else {
                                OutlinedButton(
                                    onClick = { viewModel.openAccessibilitySettings() },
                                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)
                                ) {
                                    Text("Enable", style = MaterialTheme.typography.labelMedium)
                                }
                            }
                        }

                        HorizontalDivider(color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.15f))

                        // Direct Launch Button
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.End
                        ) {
                            if (isScreenMirroringActive) {
                                Button(
                                    onClick = { viewModel.stopScreenMirroring() },
                                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
                                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp)
                                ) {
                                    Icon(Icons.Default.Stop, contentDescription = null, modifier = Modifier.size(16.dp))
                                    Spacer(Modifier.width(6.dp))
                                    Text("Stop Mirroring", style = MaterialTheme.typography.labelMedium)
                                }
                            } else {
                                Button(
                                    onClick = {
                                        if (isMediaProjectionGranted) {
                                            viewModel.startScreenMirroring()
                                        } else {
                                            onRequestMediaProjection()
                                        }
                                    },
                                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp)
                                ) {
                                    Icon(Icons.Default.PlayArrow, contentDescription = null, modifier = Modifier.size(16.dp))
                                    Spacer(Modifier.width(6.dp))
                                    Text("Start Mirroring to Mac", style = MaterialTheme.typography.labelMedium)
                                }
                            }
                        }
                    }
                }

                // External Display (Mac Secondary Monitor) & Zero-ADB Shizuku Card
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
                    )
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(14.dp)
                        ) {
                            Surface(
                                shape = CircleShape,
                                color = MaterialTheme.colorScheme.tertiary.copy(alpha = 0.12f),
                                modifier = Modifier.size(42.dp)
                            ) {
                                Box(contentAlignment = Alignment.Center) {
                                    Icon(
                                        imageVector = Icons.Default.Tv,
                                        contentDescription = null,
                                        tint = MaterialTheme.colorScheme.tertiary,
                                        modifier = Modifier.size(20.dp)
                                    )
                                }
                            }
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    "External Display for Mac",
                                    style = MaterialTheme.typography.bodyLarge,
                                    fontWeight = FontWeight.SemiBold
                                )
                                Text(
                                    "Zero-latency USB secondary monitor with multi-touch & keyboard",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }

                        HorizontalDivider(color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.15f))

                        // USB Connection Requirement Indicator (AOA 2.0 Direct)
                        val nativeRes = remember(context) { com.droidlink.app.display.ExternalDisplayActivity.getNativeLandscapeResolution(context) }
                        Surface(
                            shape = MaterialTheme.shapes.small,
                            color = if (isUsbConnected) Color(0xFF2E7D32).copy(alpha = 0.12f) else Color(0xFFE65100).copy(alpha = 0.12f),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(12.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp)
                            ) {
                                Icon(
                                    imageVector = if (isUsbConnected) Icons.Default.CheckCircle else Icons.Default.Warning,
                                    contentDescription = null,
                                    tint = if (isUsbConnected) Color(0xFF2E7D32) else Color(0xFFE65100),
                                    modifier = Modifier.size(20.dp)
                                )
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = if (isUsbConnected) "USB Cable Connected (AOA 2.0 Direct)" else "USB Connection Required",
                                        style = MaterialTheme.typography.labelMedium,
                                        fontWeight = FontWeight.Bold,
                                        color = if (isUsbConnected) Color(0xFF2E7D32) else Color(0xFFE65100)
                                    )
                                    Text(
                                        text = if (isUsbConnected) {
                                            "Direct hardware link active. Extended display stream ready."
                                        } else {
                                            "Connect to your Mac via USB-C cable. Wireless display is disabled for 100% reliability."
                                        },
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            }
                        }

                        // Display Specs (Auto-Detected Resolution & Default Scaling)
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Column {
                                Text(
                                    "Detected Native Resolution",
                                    style = MaterialTheme.typography.bodyMedium,
                                    fontWeight = FontWeight.Medium
                                )
                                Text(
                                    "${nativeRes.first} × ${nativeRes.second} (Hardware Native • 200% Default Scale)",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }

                        // Shizuku Zero-ADB Status
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Column(modifier = Modifier.weight(1f).padding(end = 8.dp)) {
                                Text(
                                    "Zero-ADB Optimization (Shizuku)",
                                    style = MaterialTheme.typography.bodyMedium,
                                    fontWeight = FontWeight.Medium
                                )
                                Text(
                                    when (shizukuState) {
                                        is com.droidlink.app.shizuku.ShizukuState.Authorized -> "120Hz refresh rate & wake lock enabled"
                                        is com.droidlink.app.shizuku.ShizukuState.PermissionRequired -> "Permission required to unlock 120Hz"
                                        else -> "Running in standard mode (60Hz)"
                                    },
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }

                            when (shizukuState) {
                                is com.droidlink.app.shizuku.ShizukuState.Authorized -> {
                                    Surface(
                                        color = Color(0xFF2E7D32).copy(alpha = 0.15f),
                                        shape = CircleShape
                                    ) {
                                        Text(
                                            "Active (120Hz)",
                                            color = Color(0xFF2E7D32),
                                            style = MaterialTheme.typography.labelSmall,
                                            fontWeight = FontWeight.Bold,
                                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
                                        )
                                    }
                                }
                                is com.droidlink.app.shizuku.ShizukuState.PermissionRequired -> {
                                    Button(
                                        onClick = { viewModel.requestShizukuPermission() },
                                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)
                                    ) {
                                        Text("Grant", style = MaterialTheme.typography.labelMedium)
                                    }
                                }
                                else -> {
                                    Surface(
                                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.12f),
                                        shape = CircleShape
                                    ) {
                                        Text(
                                            "Standard",
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            style = MaterialTheme.typography.labelSmall,
                                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
                                        )
                                    }
                                }
                            }
                        }

                        // Launch External Display Button
                        Button(
                            onClick = { viewModel.launchExternalDisplay() },
                            enabled = isUsbConnected,
                            modifier = Modifier.fillMaxWidth(),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = MaterialTheme.colorScheme.tertiary
                            )
                        ) {
                            Icon(Icons.Default.PlayArrow, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text(if (isUsbConnected) "Launch External Display Mode" else "USB Connection Required to Launch")
                        }
                    }
                }
            }

            // 4. Action Buttons when Connected (Disconnect & Forget Device)
            if (uiState is MainUiState.Connected) {
                HorizontalDivider(modifier = Modifier.padding(vertical = 4.dp))

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    OutlinedButton(
                        onClick = { viewModel.disconnect() },
                        modifier = Modifier.weight(1f)
                    ) {
                        Text("Disconnect")
                    }
                    Button(
                        onClick = { viewModel.forgetDevice() },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.error
                        ),
                        modifier = Modifier.weight(1f)
                    ) {
                        Text("Forget Device")
                    }
                }
            }
        } else {
            // UNPAIRED STATE: Only show options to pair, and below that: Necessary permissions checklist!
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
                )
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(16.dp)
                ) {
                    when (val state = uiState) {
                        is MainUiState.BleScanning -> {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(12.dp)
                            ) {
                                CircularProgressIndicator(modifier = Modifier.size(24.dp), strokeWidth = 2.5.dp)
                                Text(
                                    "Searching for nearby Macs...",
                                    style = MaterialTheme.typography.titleSmall
                                )
                            }

                            if (state.discoveredDevices.isEmpty()) {
                                Text(
                                    "Looking for DroidLink broadcast...\nMake sure DroidLink is open on your Mac.",
                                    style = MaterialTheme.typography.bodySmall,
                                    textAlign = TextAlign.Center,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(vertical = 12.dp)
                                )
                            } else {
                                Column(
                                    modifier = Modifier.fillMaxWidth(),
                                    verticalArrangement = Arrangement.spacedBy(10.dp)
                                ) {
                                    state.discoveredDevices.forEach { device ->
                                        Card(
                                            modifier = Modifier.fillMaxWidth(),
                                            colors = CardDefaults.cardColors(
                                                containerColor = MaterialTheme.colorScheme.surface
                                            )
                                        ) {
                                            Row(
                                                modifier = Modifier
                                                    .fillMaxWidth()
                                                    .padding(12.dp),
                                                verticalAlignment = Alignment.CenterVertically,
                                                horizontalArrangement = Arrangement.SpaceBetween
                                            ) {
                                                Row(
                                                    verticalAlignment = Alignment.CenterVertically,
                                                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                                                    modifier = Modifier.weight(1f)
                                                ) {
                                                    Icon(
                                                        Icons.Default.Laptop,
                                                        contentDescription = null,
                                                        tint = MaterialTheme.colorScheme.primary,
                                                        modifier = Modifier.size(28.dp)
                                                    )
                                                    Column {
                                                        Text(
                                                            device.name,
                                                            style = MaterialTheme.typography.bodyMedium,
                                                            fontWeight = FontWeight.SemiBold
                                                        )
                                                        Text(
                                                            "Signal: ${device.rssi} dBm",
                                                            style = MaterialTheme.typography.labelSmall,
                                                            color = MaterialTheme.colorScheme.onSurfaceVariant
                                                        )
                                                    }
                                                }
                                                Button(
                                                    onClick = { viewModel.pairWithDevice(device) },
                                                    contentPadding = PaddingValues(horizontal = 14.dp, vertical = 6.dp)
                                                ) {
                                                    Text("Pair")
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            OutlinedButton(
                                onClick = { viewModel.cancelPairing() },
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Text("Cancel Scan")
                            }
                        }

                        is MainUiState.Error -> {
                            Text(
                                state.message,
                                color = MaterialTheme.colorScheme.error,
                                textAlign = TextAlign.Center,
                                style = MaterialTheme.typography.bodyMedium
                            )
                            Button(
                                onClick = requestScan,
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Text("Try Scan Again")
                            }
                        }

                        else -> {
                            // Disconnected
                            Icon(
                                imageVector = Icons.AutoMirrored.Filled.BluetoothSearching,
                                contentDescription = null,
                                modifier = Modifier.size(56.dp),
                                tint = MaterialTheme.colorScheme.primary
                            )
                            Text(
                                "No Mac Paired Yet",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold
                            )
                            Text(
                                "Open DroidLink on your Mac and ensure Bluetooth is turned on. Tap below to discover and pair your Mac.",
                                style = MaterialTheme.typography.bodySmall,
                                textAlign = TextAlign.Center,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Button(
                                onClick = requestScan,
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Icon(Icons.Default.Bluetooth, contentDescription = null, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(8.dp))
                                Text("Scan for Mac")
                            }
                        }
                    }
                }
            }

            // Below that: INSTEAD OF MODULES: Necessary Permissions Section
            val hasNotificationPermission by viewModel.hasNotificationListenerPermission.collectAsState()
            val hasBluetoothPermission by viewModel.hasBluetoothPermission.collectAsState()
            val hasPostNotificationPermission by viewModel.hasPostNotificationPermission.collectAsState()

            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Text(
                    text = "Necessary Permissions",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold
                )
                Text(
                    text = "Grant these permissions to ensure smooth connection and notification mirroring.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )

                // 1. Notification Listener Access
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(
                        containerColor = if (hasNotificationPermission)
                            MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
                        else
                            MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.35f)
                    )
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                            modifier = Modifier.weight(1f).padding(end = 8.dp)
                        ) {
                            Icon(
                                imageVector = if (hasNotificationPermission) Icons.Default.CheckCircle else Icons.Default.Warning,
                                contentDescription = null,
                                tint = if (hasNotificationPermission) Color(0xFF4CAF50) else MaterialTheme.colorScheme.error,
                                modifier = Modifier.size(24.dp)
                            )
                            Column {
                                Text(
                                    "Notification Listener Access",
                                    style = MaterialTheme.typography.bodyMedium,
                                    fontWeight = FontWeight.SemiBold
                                )
                                Text(
                                    if (hasNotificationPermission) "Granted • Ready to mirror notifications" else "Required to forward app notifications to Mac",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                        if (!hasNotificationPermission) {
                            Button(
                                onClick = {
                                    context.startActivity(viewModel.getNotificationListenerSettingsIntent())
                                },
                                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)
                            ) {
                                Text("Grant")
                            }
                        }
                    }
                }

                // 2. Bluetooth Permissions
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(
                        containerColor = if (hasBluetoothPermission)
                            MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
                        else
                            MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.35f)
                    )
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                            modifier = Modifier.weight(1f).padding(end = 8.dp)
                        ) {
                            Icon(
                                imageVector = if (hasBluetoothPermission) Icons.Default.CheckCircle else Icons.Default.Warning,
                                contentDescription = null,
                                tint = if (hasBluetoothPermission) Color(0xFF4CAF50) else MaterialTheme.colorScheme.error,
                                modifier = Modifier.size(24.dp)
                            )
                            Column {
                                Text(
                                    "Bluetooth Permissions",
                                    style = MaterialTheme.typography.bodyMedium,
                                    fontWeight = FontWeight.SemiBold
                                )
                                Text(
                                    if (hasBluetoothPermission) "Granted • Ready to discover Mac" else "Required for direct Bluetooth LE connection",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                        if (!hasBluetoothPermission) {
                            Button(
                                onClick = { permissionLauncher.launch(bluetoothPermissions) },
                                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)
                            ) {
                                Text("Grant")
                            }
                        }
                    }
                }

                // 3. Notification Posting (Android 13+)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    Card(
                        modifier = Modifier.fillMaxWidth(),
                        colors = CardDefaults.cardColors(
                            containerColor = if (hasPostNotificationPermission)
                                MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
                            else
                                MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.35f)
                        )
                    ) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(14.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(12.dp),
                                modifier = Modifier.weight(1f).padding(end = 8.dp)
                            ) {
                                Icon(
                                    imageVector = if (hasPostNotificationPermission) Icons.Default.CheckCircle else Icons.Default.Warning,
                                    contentDescription = null,
                                    tint = if (hasPostNotificationPermission) Color(0xFF4CAF50) else MaterialTheme.colorScheme.error,
                                    modifier = Modifier.size(24.dp)
                                )
                                Column {
                                    Text(
                                        "Notification Alerts",
                                        style = MaterialTheme.typography.bodyMedium,
                                        fontWeight = FontWeight.SemiBold
                                    )
                                    Text(
                                        if (hasPostNotificationPermission) "Granted • Ready to post incoming Mac alerts" else "Required to display mirrored alerts on phone",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            }
                            if (!hasPostNotificationPermission) {
                                Button(
                                    onClick = { postNotificationLauncher.launch(Manifest.permission.POST_NOTIFICATIONS) },
                                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)
                                ) {
                                    Text("Grant")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Tab 2: Notifications Content

@Composable
private fun NotificationsTabContent(
    viewModel: MainViewModel,
    onNavigateToAppFilters: () -> Unit
) {
    val context = LocalContext.current
    val scrollState = rememberScrollState()

    val isNotificationSyncEnabled by viewModel.isNotificationSyncEnabled.collectAsState()
    val isFilterOngoing by viewModel.isFilterOngoing.collectAsState()
    val isFilterCharging by viewModel.isFilterCharging.collectAsState()
    val isFilterMedia by viewModel.isFilterMedia.collectAsState()
    val hasNotificationPermission by viewModel.hasNotificationListenerPermission.collectAsState()
    val apps by viewModel.installedApps.collectAsState()
    var testSentFeedback by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        viewModel.refreshPermissionStatus()
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(scrollState)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        // Master Notification Mirroring Toggle Card
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
            )
        ) {
            Column(
                modifier = Modifier.padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f).padding(end = 8.dp)) {
                        Text("Mirror Notifications to Mac", style = MaterialTheme.typography.titleMedium)
                        Text(
                            "Forward Android app notifications to your Mac natively",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Switch(
                        checked = isNotificationSyncEnabled,
                        onCheckedChange = { viewModel.setNotificationSyncEnabled(it) }
                    )
                }

                // Permission Warning if missing
                if (!hasNotificationPermission) {
                    Surface(
                        shape = MaterialTheme.shapes.small,
                        color = MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.8f),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Row(
                            modifier = Modifier.padding(12.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Icon(
                                imageVector = Icons.Default.Warning,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.error,
                                modifier = Modifier.size(24.dp)
                            )
                            Spacer(Modifier.width(10.dp))
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    "Notification Access Needed",
                                    style = MaterialTheme.typography.labelLarge,
                                    color = MaterialTheme.colorScheme.onErrorContainer
                                )
                                Text(
                                    "Grant access so DroidLink can mirror notifications",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onErrorContainer
                                )
                            }
                            Button(
                                onClick = {
                                    context.startActivity(viewModel.getNotificationListenerSettingsIntent())
                                },
                                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 4.dp)
                            ) {
                                Text("Grant", style = MaterialTheme.typography.labelSmall)
                            }
                        }
                    }
                }

                HorizontalDivider()

                // Configure Synced Apps Row
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(onClick = onNavigateToAppFilters)
                        .padding(vertical = 4.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Configure Synced Apps", style = MaterialTheme.typography.bodyLarge)
                        val allowedCount = apps.count { it.isSyncEnabled }
                        val totalCount = apps.size
                        Text(
                            if (totalCount > 0) "Syncing $allowedCount of $totalCount apps" else "Choose which apps mirror notifications",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.ArrowForwardIos,
                        contentDescription = null,
                        modifier = Modifier.size(16.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }

                HorizontalDivider()

                // Notification Filters Section
                Text(
                    text = "Notification Filters",
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.primary
                )

                // 1. Filter Ongoing Notifications
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f).padding(end = 8.dp)) {
                        Text("Filter Ongoing Notifications", style = MaterialTheme.typography.bodyLarge)
                        Text(
                            "Ignore foreground services, active calls, and persistent status bars",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Switch(
                        checked = isFilterOngoing,
                        onCheckedChange = { viewModel.setFilterOngoing(it) }
                    )
                }

                // 2. Filter Media Controls
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f).padding(end = 8.dp)) {
                        Text("Filter Media Controls", style = MaterialTheme.typography.bodyLarge)
                        Text(
                            "Ignore playback controllers from Spotify, YouTube, and media players",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Switch(
                        checked = isFilterMedia,
                        onCheckedChange = { viewModel.setFilterMedia(it) }
                    )
                }

                // 3. Filter Battery & Charging
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f).padding(end = 8.dp)) {
                        Text("Filter Battery & Charging", style = MaterialTheme.typography.bodyLarge)
                        Text(
                            "Ignore recurring charging alerts and battery level fluctuations",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Switch(
                        checked = isFilterCharging,
                        onCheckedChange = { viewModel.setFilterCharging(it) }
                    )
                }

                HorizontalDivider()

                // Send Test Notification Button
                OutlinedButton(
                    onClick = {
                        viewModel.sendTestNotificationToMac()
                        testSentFeedback = true
                    },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Icon(imageVector = Icons.AutoMirrored.Filled.Send, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(if (testSentFeedback) "Test Notification Sent to Mac!" else "Send Test Notification to Mac")
                }
            }
        }
    }
}

// MARK: - Tab 3: Clipboard Content

@Composable
private fun ClipboardTabContent(viewModel: MainViewModel) {
    val scrollState = rememberScrollState()
    val isClipboardSyncEnabled by viewModel.isClipboardSyncEnabled.collectAsState()
    val isIncognito by viewModel.isIncognitoMode.collectAsState()
    val autoIgnoreSensitive by viewModel.autoIgnoreSensitive.collectAsState()
    var manualText by remember { mutableStateOf("") }
    var sentFeedback by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(scrollState)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        // Master Toggle Card for Universal Clipboard Module
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
            )
        ) {
            Column(
                modifier = Modifier.padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f).padding(end = 8.dp)) {
                        Text("Enable Universal Clipboard", style = MaterialTheme.typography.titleMedium)
                        Text(
                            "Instantly synchronize copied text and URLs between this Android phone and your Mac",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Switch(
                        checked = isClipboardSyncEnabled,
                        onCheckedChange = { viewModel.setClipboardSyncEnabled(it) }
                    )
                }
            }
        }

        if (!isClipboardSyncEnabled) {
            Surface(
                shape = MaterialTheme.shapes.medium,
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(
                    modifier = Modifier.padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.Info,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(
                        "Universal Clipboard is currently disabled. Toggle the switch above to resume cross-device clipboard sync.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }

        // Status Card
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = if (isIncognito) MaterialTheme.colorScheme.tertiaryContainer else MaterialTheme.colorScheme.primaryContainer
            )
        ) {
            Column(
                modifier = Modifier.padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Icon(
                        imageVector = if (isIncognito) Icons.Default.VisibilityOff else Icons.Default.ContentPaste,
                        contentDescription = null,
                        modifier = Modifier.size(20.dp)
                    )
                    Text(
                        if (isIncognito) "Clipboard Sync: Paused" else "Clipboard Sync: Active",
                        style = MaterialTheme.typography.titleMedium
                    )
                }
                Text(
                    if (isIncognito)
                        "Incognito mode is active. Clips copied on this phone are not shared with your Mac."
                    else
                        "Text and URLs copied on this phone or Mac are synchronized instantly over local Wi-Fi.",
                    style = MaterialTheme.typography.bodySmall
                )
            }
        }

        // Privacy Controls Card
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
            )
        ) {
            Column(
                modifier = Modifier.padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f).padding(end = 8.dp)) {
                        Text("Incognito Mode", style = MaterialTheme.typography.bodyLarge)
                        Text(
                            "Temporarily pause clipboard sync to protect sensitive data",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Switch(
                        checked = isIncognito,
                        onCheckedChange = { viewModel.setIncognitoMode(it) }
                    )
                }

                HorizontalDivider()

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f).padding(end = 8.dp)) {
                        Text("Auto-Ignore Sensitive Data", style = MaterialTheme.typography.bodyLarge)
                        Text(
                            "Skip passwords, OTPs, and concealed clips automatically",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Switch(
                        checked = autoIgnoreSensitive,
                        onCheckedChange = { viewModel.setAutoIgnoreSensitive(it) }
                    )
                }
            }
        }

        // Quick Push Text to Mac
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
            )
        ) {
            Column(
                modifier = Modifier.padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Text("Push Text to Mac Clipboard", style = MaterialTheme.typography.titleMedium)
                OutlinedTextField(
                    value = manualText,
                    onValueChange = { manualText = it },
                    placeholder = { Text("Type or paste text to send to Mac...") },
                    modifier = Modifier.fillMaxWidth(),
                    maxLines = 4
                )
                Button(
                    onClick = {
                        val text = manualText.trim()
                        if (text.isNotEmpty()) {
                            viewModel.copyToClipboard(text)
                            manualText = ""
                            sentFeedback = true
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = manualText.trim().isNotEmpty()
                ) {
                    Icon(imageVector = Icons.AutoMirrored.Filled.Send, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(if (sentFeedback) "Pushed to Clipboard!" else "Send to Mac Clipboard")
                }
            }
        }
    }
}

// MARK: - Tab 4: Settings Content

@Composable
private fun SettingsTabContent(
    viewModel: MainViewModel,
    onNavigateToNotifications: () -> Unit,
    onNavigateToClipboard: () -> Unit
) {
    val context = LocalContext.current
    val scrollState = rememberScrollState()
    val uiState by viewModel.uiState.collectAsState()
    val hasNotificationPermission by viewModel.hasNotificationListenerPermission.collectAsState()

    LaunchedEffect(Unit) {
        viewModel.refreshPermissionStatus()
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(scrollState)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        // Feature Preferences Navigation
        Text("Feature Preferences", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)

        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
            )
        ) {
            Column(modifier = Modifier.padding(8.dp)) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(onClick = onNavigateToNotifications)
                        .padding(12.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(Icons.Default.Notifications, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                        Column {
                            Text("Notifications", style = MaterialTheme.typography.bodyLarge)
                            Text("Mirroring, incoming alerts, and app filters", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    Icon(Icons.AutoMirrored.Filled.ArrowForwardIos, contentDescription = null, modifier = Modifier.size(16.dp))
                }

                HorizontalDivider()

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(onClick = onNavigateToClipboard)
                        .padding(12.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(Icons.Default.ContentPaste, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                        Column {
                            Text("Universal Clipboard", style = MaterialTheme.typography.bodyLarge)
                            Text("Incognito privacy pause, sensitive filter, and push", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    Icon(Icons.AutoMirrored.Filled.ArrowForwardIos, contentDescription = null, modifier = Modifier.size(16.dp))
                }
            }
        }

        // macOS Finder Storage Access
        Text("macOS Finder Storage", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)

        val hasStorageAccess = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            android.os.Environment.isExternalStorageManager()
        } else {
            true
        }
        val isFinderStorageEnabled by viewModel.isFinderStorageEnabled.collectAsState()
        val isUsbConnected by viewModel.isUsbConnected.collectAsState()

        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
            )
        ) {
            Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                // Direct Toggle Switch for Finder Storage Access
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        modifier = Modifier.weight(1f).padding(end = 8.dp)
                    ) {
                        Icon(Icons.Default.FolderShared, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                        Column {
                            Text("Allow macOS Finder Access", style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold)
                            Text(
                                if (isFinderStorageEnabled) "Mac can browse & manage files in Finder" else "Finder storage sharing disabled",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                    Switch(
                        checked = isFinderStorageEnabled,
                        onCheckedChange = { viewModel.setFinderStorageEnabled(it) }
                    )
                }

                if (isUsbConnected && isFinderStorageEnabled && hasStorageAccess) {
                    Surface(
                        shape = androidx.compose.foundation.shape.RoundedCornerShape(8.dp),
                        color = Color(0xFF1E88E5).copy(alpha = 0.12f),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp)
                        ) {
                            Icon(Icons.Default.Bolt, contentDescription = null, tint = Color(0xFF1E88E5), modifier = Modifier.size(16.dp))
                            Text(
                                "⚡ Supercharged USB Mode Active (Wire Speed)",
                                style = MaterialTheme.typography.bodySmall,
                                fontWeight = FontWeight.SemiBold,
                                color = Color(0xFF1E88E5)
                            )
                        }
                    }
                }

                HorizontalDivider()

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(Icons.Default.Folder, contentDescription = null, tint = MaterialTheme.colorScheme.secondary)
                        Column {
                            Text("All Files Access (Permission)", style = MaterialTheme.typography.bodyMedium)
                            Text(
                                if (hasStorageAccess) "Granted (/storage/emulated/0)" else "Required for macOS Finder integration",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                    if (hasStorageAccess) {
                        Icon(Icons.Default.CheckCircle, contentDescription = "Granted", tint = MaterialTheme.colorScheme.primary)
                    } else {
                        Button(onClick = {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                                try {
                                    val intent = android.content.Intent(android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                                        data = android.net.Uri.parse("package:" + context.packageName)
                                    }
                                    context.startActivity(intent)
                                } catch (e: Exception) {
                                    val fallback = android.content.Intent(android.provider.Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                                    context.startActivity(fallback)
                                }
                            }
                        }) {
                            Text("Grant")
                        }
                    }
                }
            }
        }

        // Device & Connection Management
        Text("Device & Connection", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)

        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
            )
        ) {
            Column(
                modifier = Modifier.padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                when (val state = uiState) {
                    is MainUiState.Connected -> {
                        Text("Connected to: ${state.deviceName}", style = MaterialTheme.typography.titleSmall, color = Color(0xFF4CAF50))
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Button(onClick = { viewModel.disconnect() }) {
                                Text("Disconnect")
                            }
                            OutlinedButton(onClick = { viewModel.forgetDevice() }) {
                                Text("Forget Device")
                            }
                        }
                    }
                    is MainUiState.Paired -> {
                        Text("Paired with: ${state.deviceName}", style = MaterialTheme.typography.titleSmall)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Button(onClick = { viewModel.reconnect() }) {
                                Text("Connect")
                            }
                            OutlinedButton(onClick = { viewModel.forgetDevice() }) {
                                Text("Forget Device")
                            }
                        }
                    }
                    else -> {
                        Text("No paired device active", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }

        // Connection Diagnostics & Security
        Text("Security & Encryption", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)

        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
            )
        ) {
            Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Transport", style = MaterialTheme.typography.bodyMedium)
                    Text("Local Wi-Fi P2P Socket", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                HorizontalDivider()
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Encryption", style = MaterialTheme.typography.bodyMedium)
                    Text("AES-256-GCM End-to-End", style = MaterialTheme.typography.bodyMedium, color = Color(0xFF4CAF50))
                }
                HorizontalDivider()
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Privacy", style = MaterialTheme.typography.bodyMedium)
                    Text("100% Local (0 Cloud Servers)", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }

        // Permissions Diagnostic
        Text("System Permissions", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)

        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
            )
        ) {
            Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Notification Listener Access", style = MaterialTheme.typography.bodyMedium)
                        Text(
                            if (hasNotificationPermission) "Granted • Mirroring enabled" else "Not Granted • Android blocks capture",
                            style = MaterialTheme.typography.bodySmall,
                            color = if (hasNotificationPermission) Color(0xFF4CAF50) else MaterialTheme.colorScheme.error
                        )
                    }
                    if (!hasNotificationPermission) {
                        Button(
                            onClick = { context.startActivity(viewModel.getNotificationListenerSettingsIntent()) },
                            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp)
                        ) {
                            Text("Grant", style = MaterialTheme.typography.labelSmall)
                        }
                    }
                }
            }
        }

        // Roadmap
        Text("Planned Features (Roadmap)", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)

        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
            )
        ) {
            Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("File Transfer", style = MaterialTheme.typography.bodyMedium)
                    Text("Phase 1 (In Progress)", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
                }
                HorizontalDivider()
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Screen Mirroring", style = MaterialTheme.typography.bodyMedium)
                    Text("Phase 1 (In Progress)", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
                }
                HorizontalDivider()
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Virtual Camera & Mic", style = MaterialTheme.typography.bodyMedium)
                    Text("Phase 2 (Planned)", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.secondary)
                }
            }
        }

        // About
        Text("About", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)

        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
            )
        ) {
            Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("DroidLink for Android", style = MaterialTheme.typography.titleMedium)
                Text("Version 1.0.0 • Open Source Apache 2.0", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(
                    "A free, local-first alternative to LinkMyMac. Bridging Android and Apple devices securely over your local network.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}
