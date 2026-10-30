package com.droidlink.core.network.bluetooth

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Build
import android.util.Log
import com.droidlink.core.network.protocol.MessageFramer
import com.droidlink.core.security.CryptoChannel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.io.ByteArrayOutputStream
import java.util.UUID

/**
 * Robust, encrypted Bluetooth Low Energy (GATT) client for Android 15+.
 * Manages connection, MTU negotiation, chunking, and encrypted stream exchange with Mac BleServer.
 */
class BleClient(
    private val context: Context,
    private val bluetoothAddress: String,
    private val cryptoChannel: CryptoChannel? = null
) {
    companion object {
        private const val TAG = "BleClient"
        val SERVICE_UUID: UUID = UUID.fromString("D701D100-38F1-4F24-B1F7-3C7E9D420001")
        val PAIRING_CHAR_UUID: UUID = UUID.fromString("D701D101-38F1-4F24-B1F7-3C7E9D420001")
        val TX_CHAR_UUID: UUID = UUID.fromString("D701D102-38F1-4F24-B1F7-3C7E9D420001") // Mac -> Android (Notify)
        val RX_CHAR_UUID: UUID = UUID.fromString("D701D103-38F1-4F24-B1F7-3C7E9D420001") // Android -> Mac (Write)
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? get() = bluetoothManager?.adapter

    private var gatt: BluetoothGatt? = null
    private var txCharacteristic: BluetoothGattCharacteristic? = null
    private var rxCharacteristic: BluetoothGattCharacteristic? = null
    private var pairingCharacteristic: BluetoothGattCharacteristic? = null

    private var negotiatedMtu = 23 // Default BLE MTU until negotiated
    private val rxChunker = BleChunker()
    private val framer = MessageFramer()
    private val incomingDeframingBuffer = ByteArrayOutputStream()

    private val incomingMessageChannel = Channel<ByteArray>(Channel.UNLIMITED)
    private val writeMutex = Mutex()
    private var writeCompletionDeferred: CompletableDeferred<Boolean>? = null

    private var connectDeferred: CompletableDeferred<Boolean>? = null
    private var mtuDeferred: CompletableDeferred<Int>? = null
    private var servicesDeferred: CompletableDeferred<Boolean>? = null
    private var cccdDeferred: CompletableDeferred<Boolean>? = null

    @Volatile
    private var _isConnected = false
    val isConnected: Boolean get() = _isConnected

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(gatt: BluetoothGatt?, status: Int, newState: Int) {
            Log.d(TAG, "onConnectionStateChange: status=$status, newState=$newState")
            if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED) {
                Log.d(TAG, "GATT connected to $bluetoothAddress")
                connectDeferred?.complete(true)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) {
                Log.w(TAG, "GATT disconnected from $bluetoothAddress (status=$status)")
                _isConnected = false
                connectDeferred?.complete(false)
                servicesDeferred?.complete(false)
                incomingMessageChannel.close()
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt?, mtu: Int, status: Int) {
            Log.d(TAG, "onMtuChanged: mtu=$mtu, status=$status")
            if (status == BluetoothGatt.GATT_SUCCESS) {
                negotiatedMtu = mtu
            }
            mtuDeferred?.complete(negotiatedMtu)
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt?, status: Int) {
            Log.d(TAG, "onServicesDiscovered: status=$status")
            if (status == BluetoothGatt.GATT_SUCCESS && gatt != null) {
                for (s in gatt.services) {
                    Log.d(TAG, "Found GATT service: ${s.uuid}")
                }
                val service = gatt.services.firstOrNull { 
                    it.uuid.toString().equals(SERVICE_UUID.toString(), ignoreCase = true) 
                } ?: gatt.getService(SERVICE_UUID)
                
                if (service != null) {
                    txCharacteristic = service.characteristics.firstOrNull { 
                        it.uuid.toString().equals(TX_CHAR_UUID.toString(), ignoreCase = true) 
                    } ?: service.getCharacteristic(TX_CHAR_UUID)
                    
                    rxCharacteristic = service.characteristics.firstOrNull { 
                        it.uuid.toString().equals(RX_CHAR_UUID.toString(), ignoreCase = true) 
                    } ?: service.getCharacteristic(RX_CHAR_UUID)
                    
                    pairingCharacteristic = service.characteristics.firstOrNull { 
                        it.uuid.toString().equals(PAIRING_CHAR_UUID.toString(), ignoreCase = true) 
                    } ?: service.getCharacteristic(PAIRING_CHAR_UUID)
                    
                    Log.d(TAG, "Bound DroidLink characteristics: tx=$txCharacteristic, rx=$rxCharacteristic, pairing=$pairingCharacteristic")
                    servicesDeferred?.complete(true)
                    return
                }
            }
            servicesDeferred?.complete(false)
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt?, descriptor: BluetoothGattDescriptor?, status: Int) {
            if (descriptor?.uuid == CCCD_UUID) {
                Log.d(TAG, "CCCD notification subscription status=$status")
                cccdDeferred?.complete(status == BluetoothGatt.GATT_SUCCESS)
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
        ) {
            if (characteristic.uuid == TX_CHAR_UUID) {
                handleIncomingChunk(value)
            }
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(gatt: BluetoothGatt?, characteristic: BluetoothGattCharacteristic?) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU && characteristic != null) {
                @Suppress("DEPRECATION")
                val value = characteristic.value ?: return
                if (characteristic.uuid == TX_CHAR_UUID) {
                    handleIncomingChunk(value)
                }
            }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt?, characteristic: BluetoothGattCharacteristic?, status: Int) {
            writeCompletionDeferred?.complete(status == BluetoothGatt.GATT_SUCCESS)
        }
    }

    private fun handleIncomingChunk(chunk: ByteArray) {
        val completeFrame = rxChunker.feed(chunk) ?: return
        try {
            incomingDeframingBuffer.write(completeFrame)
            val deframed = framer.deframe(incomingDeframingBuffer)
            for (payload in deframed) {
                val decrypted = cryptoChannel?.decrypt(payload) ?: payload
                incomingMessageChannel.trySend(decrypted)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Deframing/decryption error on BLE chunk", e)
            incomingDeframingBuffer.reset()
        }
    }

    /**
     * Connects to the remote Mac BLE server, requests MTU 517, discovers DroidLink service,
     * and enables notifications on TX_CHAR.
     */
    @SuppressLint("MissingPermission")
    suspend fun connect() = withContext(Dispatchers.IO) {
        val adapter = bluetoothAdapter ?: throw IllegalStateException("Bluetooth adapter unavailable")
        val device = try {
            adapter.getRemoteDevice(bluetoothAddress)
        } catch (e: Exception) {
            throw IllegalArgumentException("Invalid Bluetooth address: $bluetoothAddress", e)
        }

        Log.d(TAG, "Connecting GATT to ${device.name ?: bluetoothAddress}...")
        connectDeferred = CompletableDeferred()

        val newGatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } else {
            device.connectGatt(context, false, gattCallback)
        } ?: throw IllegalStateException("Failed to initiate connectGatt")

        this@BleClient.gatt = newGatt

        withTimeout(10000) {
            val connected = connectDeferred?.await() == true
            if (!connected) throw IllegalStateException("Failed to connect to GATT server")
        }

        // 1. Request MTU 517 for high throughput
        mtuDeferred = CompletableDeferred()
        newGatt.requestMtu(517)
        try {
            withTimeout(3000) {
                mtuDeferred?.await()
            }
        } catch (e: Exception) {
            Log.w(TAG, "MTU request timed out, continuing with MTU=$negotiatedMtu")
        }

        // 2. Discover Services (Refresh GATT cache first to ensure newly published services are discovered)
        refreshGatt(newGatt)
        kotlinx.coroutines.delay(250)
        servicesDeferred = CompletableDeferred()
        newGatt.discoverServices()
        withTimeout(5000) {
            val discovered = servicesDeferred?.await() == true
            if (!discovered) throw IllegalStateException("DroidLink service not found on device")
        }

        val tx = txCharacteristic ?: throw IllegalStateException("TX characteristic not found")

        // 3. Enable notifications on TX Characteristic
        newGatt.setCharacteristicNotification(tx, true)
        val cccd = tx.getDescriptor(CCCD_UUID)
        if (cccd != null) {
            cccdDeferred = CompletableDeferred()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                newGatt.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
            } else {
                @Suppress("DEPRECATION")
                cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                @Suppress("DEPRECATION")
                newGatt.writeDescriptor(cccd)
            }
            try {
                withTimeout(4000) {
                    val ok = cccdDeferred?.await() == true
                    if (ok) {
                        Log.d(TAG, "CCCD notification subscription confirmed")
                    } else {
                        Log.w(TAG, "CCCD notification subscription returned status failure")
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "CCCD descriptor write timed out, continuing: ${e.message}")
            }
        }

        _isConnected = true
        Log.i(TAG, "✅ BleClient fully connected and configured to $bluetoothAddress")
    }

    /**
     * Executes pairing handshake with Mac over PAIRING_CHAR.
     */
    @SuppressLint("MissingPermission")
    suspend fun performPairingHandshake(
        myDeviceId: String,
        myDeviceName: String,
        sessionKey: ByteArray
    ): Boolean = withContext(Dispatchers.IO) {
        val g = gatt ?: return@withContext false
        val pairingChar = pairingCharacteristic ?: return@withContext false

        val base64Key = android.util.Base64.encodeToString(sessionKey, android.util.Base64.NO_WRAP)
        val payloadJson = """
            {
                "version": "3.0.0",
                "deviceId": "$myDeviceId",
                "deviceName": "$myDeviceName",
                "sessionKey": "$base64Key"
            }
        """.trimIndent()

        val payloadBytes = payloadJson.toByteArray(Charsets.UTF_8)
        writeMutex.withLock {
            writeCompletionDeferred = CompletableDeferred()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                g.writeCharacteristic(pairingChar, payloadBytes, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
            } else {
                @Suppress("DEPRECATION")
                pairingChar.value = payloadBytes
                @Suppress("DEPRECATION")
                pairingChar.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                @Suppress("DEPRECATION")
                g.writeCharacteristic(pairingChar)
            }

            try {
                withTimeout(5000) {
                    writeCompletionDeferred?.await() == true
                }
            } catch (e: Exception) {
                Log.e(TAG, "Pairing write timed out", e)
                false
            }
        }
    }

    /**
     * Encrypts, frames, chunks, and sends raw payload bytes to Mac over RX_CHAR.
     */
    @SuppressLint("MissingPermission")
    suspend fun send(payload: ByteArray) = withContext(Dispatchers.IO) {
        val g = gatt ?: throw IllegalStateException("Not connected")
        val rx = rxCharacteristic ?: throw IllegalStateException("RX characteristic unavailable")

        val encrypted = cryptoChannel?.encrypt(payload) ?: payload
        val frame = framer.frame(encrypted)
        // Cap chunk size at 500 to strictly conform to Android GATT attribute value length <= 512
        val maxChunk = maxOf(20, minOf(500, negotiatedMtu - 3))
        val chunks = BleChunker.chunk(frame, maxChunk)

        writeMutex.withLock {
            for (chunk in chunks) {
                writeCompletionDeferred = CompletableDeferred()
                val writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    val status = g.writeCharacteristic(rx, chunk, writeType)
                    if (status != android.bluetooth.BluetoothStatusCodes.SUCCESS) {
                        Log.e(TAG, "writeCharacteristic failed with status: $status")
                        break
                    }
                } else {
                    @Suppress("DEPRECATION")
                    rx.value = chunk
                    @Suppress("DEPRECATION")
                    rx.writeType = writeType
                    @Suppress("DEPRECATION")
                    val started = g.writeCharacteristic(rx)
                    if (!started) {
                        Log.e(TAG, "Legacy writeCharacteristic returned false")
                        break
                    }
                }

                try {
                    val ack = withTimeout(5000) {
                        writeCompletionDeferred?.await() == true
                    }
                    if (!ack) {
                        Log.e(TAG, "Chunk write was rejected by GATT server")
                        break
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Chunk write timed out waiting for ACK", e)
                    break
                }
            }
        }
    }

    /**
     * Reads incoming messages from Mac.
     * Suspends until at least one complete message is available, or returns empty list if disconnected.
     */
    suspend fun receiveMessages(): List<ByteArray> = withContext(Dispatchers.IO) {
        if (!_isConnected) return@withContext emptyList()
        val first = incomingMessageChannel.receiveCatching().getOrNull() ?: return@withContext emptyList()
        val messages = mutableListOf(first)
        while (true) {
            val next = incomingMessageChannel.tryReceive().getOrNull() ?: break
            messages.add(next)
        }
        messages
    }

    private fun refreshGatt(gatt: BluetoothGatt): Boolean {
        return try {
            val refreshMethod = gatt.javaClass.getMethod("refresh")
            val res = (refreshMethod.invoke(gatt) as? Boolean) == true
            Log.d(TAG, "GATT cache refresh result: $res")
            res
        } catch (e: Exception) {
            Log.w(TAG, "GATT cache refresh reflection failed: ${e.message}")
            false
        }
    }

    @SuppressLint("MissingPermission")
    fun close() {
        _isConnected = false
        try {
            gatt?.disconnect()
            gatt?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Error closing GATT: ${e.message}")
        } finally {
            gatt = null
            txCharacteristic = null
            rxCharacteristic = null
            pairingCharacteristic = null
            incomingDeframingBuffer.reset()
            rxChunker.reset()
            incomingMessageChannel.close()
        }
    }
}
