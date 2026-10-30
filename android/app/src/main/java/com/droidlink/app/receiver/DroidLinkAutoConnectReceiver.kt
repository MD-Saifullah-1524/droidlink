package com.droidlink.app.receiver

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.droidlink.app.service.DroidLinkService
import com.droidlink.core.security.PairingStorage

/**
 * BroadcastReceiver triggered by ADB or system broadcasts:
 * com.droidlink.ACTION_RETRY_CONNECT
 *
 * When the macOS app launches or reconnects, it dispatches this intent via ADB
 * to wake up the Android client and automatically initiate the TCP connection.
 */
class DroidLinkAutoConnectReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_RETRY_CONNECT = "com.droidlink.ACTION_RETRY_CONNECT"
        const val EXTRA_HOST = "host"
        const val EXTRA_PORT = "port"
        private const val TAG = "AutoConnectReceiver"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action == ACTION_RETRY_CONNECT) {
            Log.d(TAG, "📡 Received ACTION_RETRY_CONNECT intent")
            val storage = PairingStorage(context)
            val paired = storage.getPairedDevice()
            if (paired != null) {
                val currentServiceState = DroidLinkService.connectionState.value
                if (currentServiceState is com.droidlink.app.service.ServiceConnectionState.Connected) {
                    Log.d(TAG, "Ignoring ACTION_RETRY_CONNECT: service is already connected.")
                    return
                }

                val isManualRequest = intent.getBooleanExtra("isManualRequest", false)
                if (storage.isManuallyDisconnected() && !isManualRequest) {
                    Log.d(TAG, "Ignoring ACTION_RETRY_CONNECT: device was manually disconnected by user.")
                    return
                }

                if (isManualRequest) {
                    storage.setManuallyDisconnected(false)
                }

                val overrideHost = intent.getStringExtra(EXTRA_HOST)?.takeIf { it.isNotBlank() }
                val overridePort = intent.getIntExtra(EXTRA_PORT, 0).takeIf { it > 0 }

                val targetHost = overrideHost ?: paired.host
                val targetPort = overridePort ?: paired.port

                if (overrideHost != null && (overrideHost != paired.host || (overridePort != null && overridePort != paired.port))) {
                    Log.d(TAG, "Updating stored paired device address to $targetHost:$targetPort")
                    storage.savePairedDevice(
                        paired.copy(host = targetHost, port = targetPort)
                    )
                }

                Log.d(TAG, "🚀 Initiating DroidLinkService auto-connection to ${paired.deviceName} at $targetHost:$targetPort")
                DroidLinkService.start(
                    context = context,
                    bluetoothAddress = paired.bluetoothAddress,
                    deviceName = paired.deviceName,
                    sessionKey = paired.sessionKey,
                    host = targetHost,
                    port = targetPort
                )
            } else {
                Log.w(TAG, "No stored paired device found; ignoring RETRY_CONNECT broadcast")
            }
        }
    }
}
