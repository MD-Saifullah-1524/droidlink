package com.droidlink.app

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.lifecycle.viewmodel.compose.viewModel
import com.droidlink.app.service.DroidLinkService
import com.droidlink.app.ui.main.MainScreen
import com.droidlink.app.ui.main.MainViewModel
import com.droidlink.app.ui.main.MainViewModelFactory
import com.droidlink.app.ui.settings.AppNotificationFilterScreen
import com.droidlink.app.ui.theme.DroidLinkTheme

enum class AppScreen {
    Main,
    AppNotificationFilters
}

class MainActivity : ComponentActivity() {
    private var mainViewModel: MainViewModel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
        enableEdgeToEdge()
        setContent {
            DroidLinkTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    val vm: MainViewModel = viewModel(
                        factory = MainViewModelFactory(applicationContext)
                    )
                    mainViewModel = vm

                    var currentScreen by remember { mutableStateOf(AppScreen.Main) }

                    // Hardware back button navigation handling
                    BackHandler(enabled = currentScreen != AppScreen.Main) {
                        currentScreen = AppScreen.Main
                    }

                    when (currentScreen) {
                        AppScreen.Main -> {
                            MainScreen(
                                viewModel = vm,
                                onNavigateToAppFilters = { currentScreen = AppScreen.AppNotificationFilters }
                            )
                        }
                        AppScreen.AppNotificationFilters -> {
                            AppNotificationFilterScreen(
                                viewModel = vm,
                                onBack = { currentScreen = AppScreen.Main }
                            )
                        }
                    }
                }
            }
        }
        handleIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        mainViewModel?.refreshPermissionStatus()
        checkAttachedUsbAccessory()
        checkAndSyncClipboardOnFocus()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            checkAndSyncClipboardOnFocus()
        }
    }

    private fun checkAndSyncClipboardOnFocus() {
        try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as? android.content.ClipboardManager ?: return
            val clip = cm.primaryClip ?: return
            if (clip.itemCount > 0) {
                val text = clip.getItemAt(0).coerceToText(this)?.toString() ?: ""
                if (text.isNotBlank()) {
                    DroidLinkService.sendClipboardDirect(text)
                }
            }
        } catch (_: Exception) {}
    }

    private fun checkAttachedUsbAccessory() {
        try {
            val usbManager = getSystemService(Context.USB_SERVICE) as? android.hardware.usb.UsbManager ?: return
            val accessory = usbManager.accessoryList?.firstOrNull { it.manufacturer == "DroidLink" || it.manufacturer == "droidOS" }
            if (accessory != null) {
                DroidLinkService.handleUsbAccessoryAttached(this, accessory)
            }
        } catch (_: Exception) {}
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent?.action == android.hardware.usb.UsbManager.ACTION_USB_ACCESSORY_ATTACHED) {
            val accessory = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(android.hardware.usb.UsbManager.EXTRA_ACCESSORY, android.hardware.usb.UsbAccessory::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(android.hardware.usb.UsbManager.EXTRA_ACCESSORY)
            }
            if (accessory != null) {
                DroidLinkService.handleUsbAccessoryAttached(this, accessory)
            }
        }
    }
}
