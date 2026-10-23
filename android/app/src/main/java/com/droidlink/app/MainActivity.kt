package com.droidlink.app

import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
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

    companion object {
        const val EXTRA_REQUEST_SCREEN_CAPTURE = "extra_request_screen_capture"
    }

    private val mediaProjectionLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
            nm.cancel(2002)
        } catch (_: Exception) {}

        if (result.resultCode == RESULT_OK && result.data != null) {
            try {
                // Android 14+ requirement: FGS must be updated to type mediaProjection before calling getMediaProjection
                DroidLinkService.updateForegroundServiceTypes(applicationContext, hasMediaProjection = true)

                val mpManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                val mp = mpManager.getMediaProjection(result.resultCode, result.data!!)
                DroidLinkService.setMediaProjectionInstance(mp)
                mainViewModel?.updateMediaProjectionGranted(true)
                DroidLinkService.startScreenMirroringIfPending()
            } catch (e: Exception) {
                android.util.Log.e("MainActivity", "Failed to obtain MediaProjection: ${e.message}")
            }
        }
    }

    private fun requestMediaProjection() {
        val mpManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val captureIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            mpManager.createScreenCaptureIntent(
                MediaProjectionConfig.createConfigForDefaultDisplay()
            )
        } else {
            mpManager.createScreenCaptureIntent()
        }
        mediaProjectionLauncher.launch(captureIntent)
    }

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
                                onNavigateToAppFilters = { currentScreen = AppScreen.AppNotificationFilters },
                                onRequestMediaProjection = { requestMediaProjection() }
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
    }

    private fun checkAttachedUsbAccessory() {
        try {
            val usbManager = getSystemService(Context.USB_SERVICE) as? android.hardware.usb.UsbManager ?: return
            val accessory = usbManager.accessoryList?.firstOrNull { it.manufacturer == "DroidLink" }
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
        if (intent?.getBooleanExtra(EXTRA_REQUEST_SCREEN_CAPTURE, false) == true) {
            requestMediaProjection()
        }
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
