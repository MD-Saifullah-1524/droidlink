package com.droidlink.app.shizuku

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import rikka.shizuku.Shizuku
import rikka.shizuku.ShizukuProvider

sealed class ShizukuState {
    data object NotInstalled : ShizukuState()
    data object ServiceDead : ShizukuState()
    data object PermissionRequired : ShizukuState()
    data object Authorized : ShizukuState()
}

data class ShellResult(
    val exitCode: Int,
    val output: String,
    val error: String
) {
    val isSuccess: Boolean get() = exitCode == 0
}

/**
 * Manages Shizuku connection state, permission lifecycle, and privileged Zero-ADB execution.
 * Allows DroidLink to execute system optimizations (120Hz refresh rate, persistent wake lock,
 * and system-wide immersive edge-to-edge mode) completely on-device without a Mac ADB connection.
 */
object ShizukuManager {
    private const val TAG = "ShizukuManager"
    const val SHIZUKU_PERMISSION_REQUEST_CODE = 4201

    private val _state = MutableStateFlow<ShizukuState>(ShizukuState.ServiceDead)
    val state: StateFlow<ShizukuState> = _state.asStateFlow()

    private var isInitialized = false

    private val binderReceivedListener = Shizuku.OnBinderReceivedListener {
        Log.i(TAG, "⚡ Shizuku binder received")
        refreshState()
    }

    private val binderDeadListener = Shizuku.OnBinderDeadListener {
        Log.w(TAG, "⚠️ Shizuku binder died")
        _state.value = ShizukuState.ServiceDead
    }

    private val requestPermissionResultListener = Shizuku.OnRequestPermissionResultListener { requestCode, grantResult ->
        if (requestCode == SHIZUKU_PERMISSION_REQUEST_CODE) {
            val granted = grantResult == PackageManager.PERMISSION_GRANTED
            Log.i(TAG, "🔑 Shizuku permission request result: granted=$granted")
            refreshState()
        }
    }

    /**
     * Initializes listeners for Shizuku binder lifecycle
     */
    fun init() {
        if (isInitialized) return
        isInitialized = true

        try {
            Shizuku.addBinderReceivedListenerSticky(binderReceivedListener)
            Shizuku.addBinderDeadListener(binderDeadListener)
            Shizuku.addRequestPermissionResultListener(requestPermissionResultListener)
            refreshState()
            Log.d(TAG, "Initialized ShizukuManager")
        } catch (e: Throwable) {
            Log.w(TAG, "Shizuku not present or failed to attach listener", e)
            _state.value = ShizukuState.NotInstalled
        }
    }

    /**
     * Queries current Shizuku status
     */
    fun refreshState(): ShizukuState {
        val newState = try {
            if (!Shizuku.pingBinder()) {
                ShizukuState.ServiceDead
            } else {
                val hasPermission = if (Shizuku.isPreV11()) {
                    false
                } else {
                    Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
                }

                if (hasPermission) {
                    ShizukuState.Authorized
                } else {
                    ShizukuState.PermissionRequired
                }
            }
        } catch (e: Throwable) {
            ShizukuState.NotInstalled
        }

        _state.value = newState
        return newState
    }

    /**
     * Requests permission from Shizuku Manager
     */
    fun requestPermission() {
        try {
            if (Shizuku.pingBinder()) {
                if (Shizuku.isPreV11()) {
                    Log.w(TAG, "Shizuku pre-v11 not supported")
                } else {
                    Shizuku.requestPermission(SHIZUKU_PERMISSION_REQUEST_CODE)
                }
            } else {
                Log.w(TAG, "Cannot request permission: Shizuku service is not running")
            }
        } catch (e: Throwable) {
            Log.e(TAG, "Error requesting Shizuku permission", e)
        }
    }

    /**
     * Executes a privileged shell command directly via Shizuku with UID 2000 (Shell) permissions.
     * Does not require connecting ADB to Mac.
     */
    suspend fun executePrivileged(command: String): ShellResult = withContext(Dispatchers.IO) {
        if (_state.value != ShizukuState.Authorized) {
            return@withContext ShellResult(-1, "", "Shizuku not authorized")
        }

        try {
            val newProcessMethod = Shizuku::class.java.getDeclaredMethod(
                "newProcess",
                Array<String>::class.java,
                Array<String>::class.java,
                String::class.java
            ).apply { isAccessible = true }

            val process = newProcessMethod.invoke(null, arrayOf("sh", "-c", command), null, null) as Process
            val output = process.inputStream.bufferedReader().use { it.readText() }
            val error = process.errorStream.bufferedReader().use { it.readText() }
            val exitCode = process.waitFor()
            Log.d(TAG, "Privileged command '$command' -> exitCode: $exitCode")
            ShellResult(exitCode, output.trim(), error.trim())
        } catch (e: Throwable) {
            Log.e(TAG, "Privileged command failed: $command", e)
            ShellResult(-1, "", e.message ?: "Unknown error")
        }
    }

    /**
     * Applies display and performance optimizations during external display sessions
     */
    suspend fun applyExternalDisplayOptimizations() {
        if (_state.value != ShizukuState.Authorized) return
        Log.i(TAG, "🚀 Applying Zero-ADB display optimizations via Shizuku...")

        // 1. Force peak refresh rate to 120Hz/90Hz for ultra-low latency monitor display
        executePrivileged("settings put system peak_refresh_rate 120.0 && settings put system min_refresh_rate 120.0")

        // 2. Prevent screen timeout / sleep while acting as an external display
        executePrivileged("svc power stayon true")

        // 3. Enforce true edge-to-edge immersive mode (hide navigation bar / status bar)
        executePrivileged("settings put global policy_control immersive.full=*")

        // 4. Disable battery throttling / doze for DroidLink during monitor session
        executePrivileged("dumpsys deviceidle whitelist +com.droidlink.app")

        // 5. Ensure system user rotation is oriented to landscape
        executePrivileged("settings put system user_rotation 1")
    }

    /**
     * Restores normal device display settings when external display session finishes
     */
    suspend fun restoreDisplaySettings() {
        if (_state.value != ShizukuState.Authorized) return
        Log.i(TAG, "🔄 Restoring original display settings via Shizuku...")

        // Restore normal power stayon setting
        executePrivileged("svc power stayon false")

        // Clear immersive policy restriction
        executePrivileged("settings put global policy_control null*")

        // Restore system accelerometer auto-rotation
        executePrivileged("settings put system accelerometer_rotation 1")
    }
}
