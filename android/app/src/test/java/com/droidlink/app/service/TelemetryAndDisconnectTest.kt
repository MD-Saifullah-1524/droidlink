package com.droidlink.app.service

import com.droidlink.app.model.DeviceStatusInfo
import droidlink.protocol.DroidlinkMessages
import droidlink.protocol.SystemProto
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TelemetryAndDisconnectTest {

    @Test
    fun testDeviceStatusInfoJsonSerialization() {
        val original = DeviceStatusInfo(
            deviceName = "Pixel 8 Pro",
            deviceModel = "Google Pixel 8 Pro",
            batteryLevel = 92,
            isCharging = true,
            powerSource = "AC Power",
            wifiSsid = "Home_5G",
            wifiSignalLevel = 4,
            wifiRssi = -48,
            hasCellular = true,
            carrierName = "Google Fi",
            cellularNetworkType = "5G",
            cellularSignalLevel = 4,
            simState = "Ready",
            simDisplayName = "eSIM 1",
            isFinderStorageEnabled = true
        )

        val json = original.toJson()
        assertNotNull(json)

        val parsed = DeviceStatusInfo.fromJson(json)
        assertEquals("Pixel 8 Pro", parsed.deviceName)
        assertEquals("Google Pixel 8 Pro", parsed.deviceModel)
        assertEquals(92, parsed.batteryLevel)
        assertTrue(parsed.isCharging)
        assertEquals("AC Power", parsed.powerSource)
        assertEquals("Home_5G", parsed.wifiSsid)
        assertEquals(4, parsed.wifiSignalLevel)
        assertEquals(-48, parsed.wifiRssi)
        assertTrue(parsed.hasCellular)
        assertEquals("Google Fi", parsed.carrierName)
        assertEquals("5G", parsed.cellularNetworkType)
        assertTrue(parsed.isFinderStorageEnabled)
    }

    @Test
    fun testManualDisconnectProtobufMessageFormat() {
        val err = SystemProto.ErrorMessage.newBuilder()
            .setCode(SystemProto.ErrorCode.ERROR_UNKNOWN)
            .setMessage("MANUAL_DISCONNECT")
            .build()

        val sysMsg = SystemProto.SystemMessage.newBuilder()
            .setEvent(SystemProto.SystemMessage.SystemEventType.GOODBYE)
            .setError(err)
            .build()

        val rootMsg = DroidlinkMessages.DroidLinkMessage.newBuilder()
            .setId(12345L)
            .setTimestamp(System.currentTimeMillis())
            .setType(DroidlinkMessages.MessageType.SYSTEM)
            .setSystem(sysMsg)
            .build()

        val serialized = rootMsg.toByteArray()
        val parsed = DroidlinkMessages.DroidLinkMessage.parseFrom(serialized)

        assertTrue(parsed.hasSystem())
        val parsedSys = parsed.system
        assertEquals(SystemProto.SystemMessage.SystemEventType.GOODBYE, parsedSys.event)
        assertTrue(parsedSys.hasError())
        assertEquals("MANUAL_DISCONNECT", parsedSys.error.message)
    }

    @Test
    fun testDeviceStatusProtobufMessageFormat() {
        val status = DeviceStatusInfo(
            deviceName = "Galaxy S24",
            deviceModel = "Samsung Galaxy S24",
            batteryLevel = 75,
            isCharging = false,
            powerSource = "Battery"
        )

        val err = SystemProto.ErrorMessage.newBuilder()
            .setCode(SystemProto.ErrorCode.ERROR_UNKNOWN)
            .setMessage("DEVICE_STATUS")
            .setDetails(status.toJson())
            .build()

        val sysMsg = SystemProto.SystemMessage.newBuilder()
            .setEvent(SystemProto.SystemMessage.SystemEventType.SYS_ERROR)
            .setError(err)
            .build()

        val rootMsg = DroidlinkMessages.DroidLinkMessage.newBuilder()
            .setId(67890L)
            .setTimestamp(System.currentTimeMillis())
            .setType(DroidlinkMessages.MessageType.SYSTEM)
            .setSystem(sysMsg)
            .build()

        val parsed = DroidlinkMessages.DroidLinkMessage.parseFrom(rootMsg.toByteArray())
        assertTrue(parsed.hasSystem())
        val parsedSys = parsed.system
        assertEquals(SystemProto.SystemMessage.SystemEventType.SYS_ERROR, parsedSys.event)
        assertTrue(parsedSys.hasError())
        assertEquals("DEVICE_STATUS", parsedSys.error.message)

        val decodedStatus = DeviceStatusInfo.fromJson(parsedSys.error.details)
        assertEquals("Galaxy S24", decodedStatus.deviceName)
        assertEquals("Samsung Galaxy S24", decodedStatus.deviceModel)
        assertEquals(75, decodedStatus.batteryLevel)
        assertFalse(decodedStatus.isCharging)
        assertEquals("Battery", decodedStatus.powerSource)
    }
}
