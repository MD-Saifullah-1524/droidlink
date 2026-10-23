package com.droidlink.app.model

import org.json.JSONObject

data class DeviceStatusInfo(
    val deviceName: String = "",
    val deviceModel: String = "",
    val batteryLevel: Int = -1,
    val isCharging: Boolean = false,
    val powerSource: String = "Battery",
    val wifiSsid: String = "",
    val wifiSignalLevel: Int = 0, // 0 - 4
    val wifiRssi: Int = 0,
    val hasCellular: Boolean = false,
    val carrierName: String = "",
    val cellularNetworkType: String = "",
    val cellularSignalLevel: Int = 0, // 0 - 4
    val simState: String = "",
    val simDisplayName: String = "",
    val localIpAddress: String = "",
    val tcpPort: Int = 9999,
    val isFinderStorageEnabled: Boolean = true,
    val screenWidth: Int = 0,
    val screenHeight: Int = 0
) {
    fun toJson(): String {
        val obj = JSONObject()
        obj.put("deviceName", deviceName)
        obj.put("deviceModel", deviceModel)
        obj.put("batteryLevel", batteryLevel)
        obj.put("isCharging", isCharging)
        obj.put("powerSource", powerSource)
        obj.put("wifiSsid", wifiSsid)
        obj.put("wifiSignalLevel", wifiSignalLevel)
        obj.put("wifiRssi", wifiRssi)
        obj.put("hasCellular", hasCellular)
        obj.put("carrierName", carrierName)
        obj.put("cellularNetworkType", cellularNetworkType)
        obj.put("cellularSignalLevel", cellularSignalLevel)
        obj.put("simState", simState)
        obj.put("simDisplayName", simDisplayName)
        obj.put("localIpAddress", localIpAddress)
        obj.put("tcpPort", tcpPort)
        obj.put("isFinderStorageEnabled", isFinderStorageEnabled)
        obj.put("screenWidth", screenWidth)
        obj.put("screenHeight", screenHeight)
        return obj.toString()
    }

    companion object {
        fun fromJson(json: String): DeviceStatusInfo {
            return try {
                val obj = JSONObject(json)
                DeviceStatusInfo(
                    deviceName = obj.optString("deviceName", ""),
                    deviceModel = obj.optString("deviceModel", ""),
                    batteryLevel = obj.optInt("batteryLevel", -1),
                    isCharging = obj.optBoolean("isCharging", false),
                    powerSource = obj.optString("powerSource", "Battery"),
                    wifiSsid = obj.optString("wifiSsid", ""),
                    wifiSignalLevel = obj.optInt("wifiSignalLevel", 0),
                    wifiRssi = obj.optInt("wifiRssi", 0),
                    hasCellular = obj.optBoolean("hasCellular", false),
                    carrierName = obj.optString("carrierName", ""),
                    cellularNetworkType = obj.optString("cellularNetworkType", ""),
                    cellularSignalLevel = obj.optInt("cellularSignalLevel", 0),
                    simState = obj.optString("simState", ""),
                    simDisplayName = obj.optString("simDisplayName", ""),
                    localIpAddress = obj.optString("localIpAddress", ""),
                    tcpPort = obj.optInt("tcpPort", 9999),
                    isFinderStorageEnabled = obj.optBoolean("isFinderStorageEnabled", true),
                    screenWidth = obj.optInt("screenWidth", 0),
                    screenHeight = obj.optInt("screenHeight", 0)
                )
            } catch (e: Exception) {
                DeviceStatusInfo()
            }
        }
    }
}
