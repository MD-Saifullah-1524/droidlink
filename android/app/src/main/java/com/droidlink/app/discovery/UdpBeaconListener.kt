package com.droidlink.app.discovery

import android.content.Context
import android.util.Log
import com.droidlink.app.service.DroidLinkService
import com.droidlink.app.service.ServiceConnectionState
import com.droidlink.core.security.PairingStorage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress

/**
 * Listens for local Wi-Fi UDP broadcast beacons on port 9998 emitted by the macOS DroidLink app.
 * When the Mac app starts or wakes up, this triggers automatic connection on Android without requiring ADB.
 */
class UdpBeaconListener(private val context: Context) {

    companion object {
        private const val TAG = "UdpBeaconListener"
        private const val UDP_BEACON_PORT = 9998
        private var instance: UdpBeaconListener? = null

        fun start(context: Context) {
            if (instance == null) {
                instance = UdpBeaconListener(context.applicationContext).also { it.startListening() }
            }
        }
    }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var isRunning = false

    fun startListening() {
        if (isRunning) return
        isRunning = true

        scope.launch {
            Log.d(TAG, "Starting UDP Beacon listener on port $UDP_BEACON_PORT")
            var socket: DatagramSocket? = null
            val buffer = ByteArray(4096)

            while (isActive) {
                try {
                    socket = DatagramSocket(null).apply {
                        reuseAddress = true
                        bind(InetSocketAddress(UDP_BEACON_PORT))
                    }

                    while (isActive) {
                        val packet = DatagramPacket(buffer, buffer.size)
                        socket.receive(packet)

                        val jsonStr = String(packet.data, 0, packet.length, Charsets.UTF_8)
                        handleBeaconMessage(jsonStr)
                    }
                } catch (e: Exception) {
                    if (isActive) {
                        Log.w(TAG, "UDP Beacon socket error: ${e.message}. Retrying in 3s...")
                        kotlinx.coroutines.delay(3000)
                    }
                } finally {
                    try {
                        socket?.close()
                    } catch (_: Exception) {}
                    socket = null
                }
            }
        }
    }

    private fun handleBeaconMessage(rawJson: String) {
        try {
            val json = JSONObject(rawJson)
            val event = json.optString("event")
            if (event != "MAC_ONLINE") return

            val macHost = json.optString("host")
            val macPort = json.optInt("port", 9999)
            val macDeviceId = json.optString("deviceId")

            val storage = PairingStorage(context)
            val paired = storage.getPairedDevice() ?: return

            val matchesDevice = (macDeviceId.isNotEmpty() && paired.deviceId.isNotEmpty() && macDeviceId == paired.deviceId)
            val matchesHost = (macHost.isNotBlank() && paired.host.isNotBlank() && macHost == paired.host)

            if (!matchesDevice && !matchesHost) {
                Log.d(TAG, "Ignoring beacon from different device: $macDeviceId (paired with ${paired.deviceId})")
                return
            }

            val isManualRequest = json.optBoolean("isManualRequest", false)
            if (storage.isManuallyDisconnected() && !isManualRequest) {
                Log.d(TAG, "Ignoring MAC_ONLINE beacon from ${paired.deviceName}: device was manually disconnected by user.")
                return
            }

            if (isManualRequest) {
                storage.setManuallyDisconnected(false)
            }

            val currentState = DroidLinkService.connectionState.value
            if (currentState is ServiceConnectionState.Connected || currentState is ServiceConnectionState.Connecting) {
                return
            }

            Log.i(TAG, "🔔 Detected MAC_ONLINE beacon from ${paired.deviceName} at $macHost:$macPort. Auto-connecting...")

            val targetHost = if (macHost.isNotBlank()) macHost else paired.host
            val targetPort = if (macPort > 0) macPort else paired.port

            if (targetHost != paired.host || targetPort != paired.port) {
                storage.savePairedDevice(paired.copy(host = targetHost, port = targetPort))
            }

            DroidLinkService.start(
                context = context,
                bluetoothAddress = paired.bluetoothAddress,
                deviceName = paired.deviceName,
                sessionKey = paired.sessionKey,
                host = targetHost,
                port = targetPort
            )
        } catch (e: Exception) {
            Log.e(TAG, "Error handling UDP beacon payload", e)
        }
    }
}
