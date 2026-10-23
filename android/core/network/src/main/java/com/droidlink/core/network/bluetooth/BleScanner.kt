package com.droidlink.core.network.bluetooth

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.ParcelUuid
import android.util.Log
import java.util.UUID

data class DiscoveredBleDevice(
    val name: String,
    val address: String,
    val rssi: Int
)

/**
 * Scans for nearby DroidLink peripherals advertising the DroidLink BLE Service.
 */
class BleScanner(private val context: Context) {

    companion object {
        private const val TAG = "BleScanner"
        val DROIDLINK_SERVICE_UUID: UUID = UUID.fromString("D701D100-38F1-4F24-B1F7-3C7E9D420001")
    }

    private val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? get() = bluetoothManager?.adapter
    private var isScanning = false
    private var scanCallback: ScanCallback? = null

    val isBluetoothEnabled: Boolean
        get() = bluetoothAdapter?.isEnabled == true

    @SuppressLint("MissingPermission")
    fun startScan(
        onDeviceFound: (DiscoveredBleDevice) -> Unit,
        onError: (String) -> Unit = {}
    ) {
        val adapter = bluetoothAdapter
        if (adapter == null || !adapter.isEnabled) {
            onError("Bluetooth is disabled. Please enable Bluetooth.")
            return
        }

        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) {
            onError("Bluetooth LE Scanner unavailable.")
            return
        }

        if (isScanning) {
            stopScan()
        }

        val discoveredMap = mutableMapOf<String, DiscoveredBleDevice>()

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult?) {
                result?.let { handleResult(it, discoveredMap, onDeviceFound) }
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>?) {
                results?.forEach { handleResult(it, discoveredMap, onDeviceFound) }
            }

            override fun onScanFailed(errorCode: Int) {
                Log.e(TAG, "BLE Scan failed with errorCode: $errorCode")
                isScanning = false
                onError("Scan failed (error code $errorCode)")
            }
        }

        val filters = listOf(
            // Filter by DroidLink Service UUID
            ScanFilter.Builder()
                .setServiceUuid(ParcelUuid(DROIDLINK_SERVICE_UUID))
                .build()
        )

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        try {
            this.scanCallback = callback
            this.isScanning = true
            scanner.startScan(filters, settings, callback)
            Log.d(TAG, "Started BLE scan for DroidLink service ($DROIDLINK_SERVICE_UUID)")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start BLE scan", e)
            isScanning = false
            onError("Could not start BLE scan: ${e.message}")
        }
    }

    @SuppressLint("MissingPermission")
    private fun handleResult(
        result: ScanResult,
        discoveredMap: MutableMap<String, DiscoveredBleDevice>,
        onDeviceFound: (DiscoveredBleDevice) -> Unit
    ) {
        val device = result.device ?: return
        val address = device.address ?: return
        val record = result.scanRecord

        var name = record?.deviceName ?: device.name ?: ""
        if (name.isBlank()) {
            name = "DroidLink Mac"
        }

        // Clean up prefix if present, e.g. "DroidLink (MacBook Pro)" -> "MacBook Pro"
        val cleanName = if (name.startsWith("DroidLink (") && name.endsWith(")")) {
            name.substring("DroidLink (".length, name.length - 1)
        } else {
            name
        }

        val discovered = DiscoveredBleDevice(
            name = cleanName,
            address = address,
            rssi = result.rssi
        )

        discoveredMap[address] = discovered
        onDeviceFound(discovered)
    }

    @SuppressLint("MissingPermission")
    fun stopScan() {
        if (!isScanning) return
        val scanner = bluetoothAdapter?.bluetoothLeScanner
        scanCallback?.let {
            try {
                scanner?.stopScan(it)
                Log.d(TAG, "Stopped BLE scan")
            } catch (e: Exception) {
                Log.w(TAG, "Error stopping BLE scan: ${e.message}")
            }
        }
        scanCallback = null
        isScanning = false
    }
}
