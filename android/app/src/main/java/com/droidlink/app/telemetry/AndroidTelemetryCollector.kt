package com.droidlink.app.telemetry

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import com.droidlink.app.model.DeviceStatusInfo

class AndroidTelemetryCollector(private val context: Context) {

    fun collectStatus(): DeviceStatusInfo {
        val deviceName = try {
            android.provider.Settings.Global.getString(context.contentResolver, "device_name")
                ?: Build.MODEL ?: "Android Phone"
        } catch (e: Exception) {
            Build.MODEL ?: "Android Phone"
        }
        val manufacturer = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
        val deviceModel = if (Build.MODEL.startsWith(manufacturer, ignoreCase = true)) {
            Build.MODEL
        } else {
            "$manufacturer ${Build.MODEL}"
        }

        val (batteryLevel, isCharging, powerSource) = getBatteryInfo()
        val (wifiSsid, wifiSignalLevel, wifiRssi) = getWifiInfo()
        val (hasCellular, carrierName, netType, cellSignalLevel, simState, simDisplay) = getCellularInfo()
        val (resWidth, resHeight) = com.droidlink.app.display.ExternalDisplayActivity.getNativeLandscapeResolution(context)

        return DeviceStatusInfo(
            deviceName = deviceName,
            deviceModel = deviceModel,
            batteryLevel = batteryLevel,
            isCharging = isCharging,
            powerSource = powerSource,
            wifiSsid = wifiSsid,
            wifiSignalLevel = wifiSignalLevel,
            wifiRssi = wifiRssi,
            hasCellular = hasCellular,
            carrierName = carrierName,
            cellularNetworkType = netType,
            cellularSignalLevel = cellSignalLevel,
            simState = simState,
            simDisplayName = simDisplay,
            isFinderStorageEnabled = com.droidlink.core.security.PairingStorage(context).isFinderStorageEnabled(),
            screenWidth = resWidth,
            screenHeight = resHeight
        )
    }

    private fun getBatteryInfo(): Triple<Int, Boolean, String> {
        return try {
            val filter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
            val batteryStatus: Intent? = context.registerReceiver(null, filter)
            if (batteryStatus != null) {
                val level = batteryStatus.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                val scale = batteryStatus.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
                val pct = if (level >= 0 && scale > 0) (level * 100 / scale) else -1

                val status = batteryStatus.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
                val isCharging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                        status == BatteryManager.BATTERY_STATUS_FULL

                val chargePlug = batteryStatus.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1)
                val source = when (chargePlug) {
                    BatteryManager.BATTERY_PLUGGED_AC -> "AC Power"
                    BatteryManager.BATTERY_PLUGGED_USB -> "USB"
                    BatteryManager.BATTERY_PLUGGED_WIRELESS -> "Wireless"
                    else -> if (isCharging) "Charging" else "Battery"
                }
                Triple(pct, isCharging, source)
            } else {
                Triple(-1, false, "Battery")
            }
        } catch (e: Exception) {
            Triple(-1, false, "Battery")
        }
    }

    private fun getWifiInfo(): Triple<String, Int, Int> {
        return try {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            val activeNetwork = cm?.activeNetwork
            val capabilities = cm?.getNetworkCapabilities(activeNetwork)
            val isWifi = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true

            if (isWifi) {
                val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                val info = wm?.connectionInfo
                val rawSsid = info?.ssid?.replace("\"", "") ?: ""
                val ssid = if (rawSsid.isEmpty() || rawSsid == "<unknown ssid>") "Wi-Fi Connected" else rawSsid
                val rssi = info?.rssi ?: 0
                val level = WifiManager.calculateSignalLevel(rssi, 5) // 0 - 4
                Triple(ssid, level, rssi)
            } else {
                Triple("", 0, 0)
            }
        } catch (e: Exception) {
            Triple("", 0, 0)
        }
    }

    private fun getCellularInfo(): CellularResult {
        return try {
            val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
            if (tm == null) {
                return CellularResult(false, "", "", 0, "Absent", "")
            }

            val simStateCode = tm.simState
            val simState = when (simStateCode) {
                TelephonyManager.SIM_STATE_READY -> "Ready"
                TelephonyManager.SIM_STATE_ABSENT -> "Absent"
                TelephonyManager.SIM_STATE_PIN_REQUIRED -> "PIN Locked"
                TelephonyManager.SIM_STATE_PUK_REQUIRED -> "PUK Locked"
                else -> "Unknown"
            }

            val hasSim = simStateCode == TelephonyManager.SIM_STATE_READY
            val carrier = tm.networkOperatorName.ifEmpty { tm.simOperatorName }.ifEmpty { if (hasSim) "Cellular" else "" }

            val signalStrength = tm.signalStrength
            val cellLevel = signalStrength?.level ?: 3 // 0 - 4

            // Network generation detection
            val netType = if (hasSim) {
                when {
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.N -> {
                        when (tm.dataNetworkType) {
                            TelephonyManager.NETWORK_TYPE_NR -> "5G"
                            TelephonyManager.NETWORK_TYPE_LTE -> "4G LTE"
                            TelephonyManager.NETWORK_TYPE_HSPAP,
                            TelephonyManager.NETWORK_TYPE_HSPA,
                            TelephonyManager.NETWORK_TYPE_UMTS -> "3G"
                            TelephonyManager.NETWORK_TYPE_EDGE,
                            TelephonyManager.NETWORK_TYPE_GPRS -> "2G"
                            else -> "Cellular"
                        }
                    }
                    else -> "Cellular"
                }
            } else ""

            val simDisplay = if (hasSim) {
                val subMgr = context.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE) as? SubscriptionManager
                val subs = try {
                    if (context.checkSelfPermission(android.Manifest.permission.READ_PHONE_STATE) == android.content.pm.PackageManager.PERMISSION_GRANTED) {
                        subMgr?.activeSubscriptionInfoList
                    } else null
                } catch (e: Exception) {
                    null
                }
                val firstSub = subs?.firstOrNull()
                firstSub?.displayName?.toString() ?: "SIM 1"
            } else ""

            CellularResult(hasSim, carrier, netType, cellLevel, simState, simDisplay)
        } catch (e: Exception) {
            CellularResult(false, "", "", 0, "Absent", "")
        }
    }

    private data class CellularResult(
        val hasCellular: Boolean,
        val carrierName: String,
        val networkType: String,
        val signalLevel: Int,
        val simState: String,
        val simDisplayName: String
    )
}
