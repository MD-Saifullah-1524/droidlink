package com.droidlink.app.display

import com.google.protobuf.ByteString
import droidlink.protocol.DroidlinkMessages
import droidlink.protocol.ExternalDisplayProto
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ExternalDisplayTest {

    @Test
    fun testExternalDisplayConfigSerialization() {
        val config = ExternalDisplayProto.ExternalDisplayConfig.newBuilder()
            .setWidth(2560)
            .setHeight(1600)
            .setFps(120)
            .setDpi(320)
            .setHiDpi(true)
            .setBitrateKbps(15000)
            .setCodec(ExternalDisplayProto.DisplayCodec.DISPLAY_H264)
            .setEnableInput(true)
            .build()

        val bytes = config.toByteArray()
        val parsed = ExternalDisplayProto.ExternalDisplayConfig.parseFrom(bytes)

        assertEquals(2560, parsed.width)
        assertEquals(1600, parsed.height)
        assertEquals(120, parsed.fps)
        assertEquals(320, parsed.dpi)
        assertTrue(parsed.hiDpi)
        assertEquals(15000, parsed.bitrateKbps)
        assertEquals(ExternalDisplayProto.DisplayCodec.DISPLAY_H264, parsed.codec)
        assertTrue(parsed.enableInput)
    }

    @Test
    fun testExternalDisplayFrameSerialization() {
        val rawNalu = byteArrayOf(0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x1F)
        val frame = ExternalDisplayProto.ExternalDisplayFrame.newBuilder()
            .setFrameData(ByteString.copyFrom(rawNalu))
            .setFrameNumber(99)
            .setTimestamp(1700000000000L)
            .setIsKeyframe(true)
            .setWidth(1920)
            .setHeight(1080)
            .build()

        val msg = ExternalDisplayProto.ExternalDisplayMessage.newBuilder()
            .setEvent(ExternalDisplayProto.ExternalDisplayMessage.DisplayEventType.VIDEO_FRAME)
            .setFrame(frame)
            .setTimestamp(1700000000000L)
            .build()

        val rootMsg = DroidlinkMessages.DroidLinkMessage.newBuilder()
            .setId(12345L)
            .setTimestamp(1700000000000L)
            .setType(DroidlinkMessages.MessageType.EXTERNAL_DISPLAY)
            .setExternalDisplay(msg)
            .build()

        val rootBytes = rootMsg.toByteArray()
        val parsedRoot = DroidlinkMessages.DroidLinkMessage.parseFrom(rootBytes)

        assertEquals(DroidlinkMessages.MessageType.EXTERNAL_DISPLAY, parsedRoot.type)
        assertTrue(parsedRoot.hasExternalDisplay())
        assertEquals(ExternalDisplayProto.ExternalDisplayMessage.DisplayEventType.VIDEO_FRAME, parsedRoot.externalDisplay.event)
        assertEquals(99, parsedRoot.externalDisplay.frame.frameNumber)
        assertTrue(parsedRoot.externalDisplay.frame.isKeyframe)
        assertEquals(1920, parsedRoot.externalDisplay.frame.width)
        assertEquals(1080, parsedRoot.externalDisplay.frame.height)
        assertEquals(rawNalu.size, parsedRoot.externalDisplay.frame.frameData.size())
    }

    @Test
    fun testExternalDisplayInputSerialization() {
        val input = ExternalDisplayProto.ExternalDisplayInput.newBuilder()
            .setAction(ExternalDisplayProto.ExternalDisplayInput.ActionType.DOWN)
            .setToolType(ExternalDisplayProto.ExternalDisplayInput.ToolType.STYLUS)
            .setPointerId(1)
            .setNormalizedX(0.45f)
            .setNormalizedY(0.85f)
            .setPressure(0.92f)
            .setTiltX(12.5f)
            .setTiltY(-3.0f)
            .setButtonState(1)
            .build()

        val bytes = input.toByteArray()
        val parsed = ExternalDisplayProto.ExternalDisplayInput.parseFrom(bytes)

        assertEquals(ExternalDisplayProto.ExternalDisplayInput.ActionType.DOWN, parsed.action)
        assertEquals(ExternalDisplayProto.ExternalDisplayInput.ToolType.STYLUS, parsed.toolType)
        assertEquals(1, parsed.pointerId)
        assertEquals(0.45f, parsed.normalizedX, 0.001f)
        assertEquals(0.85f, parsed.normalizedY, 0.001f)
        assertEquals(0.92f, parsed.pressure, 0.001f)
        assertEquals(12.5f, parsed.tiltX, 0.001f)
        assertEquals(-3.0f, parsed.tiltY, 0.001f)
        assertEquals(1, parsed.buttonState)
    }

    @Test
    fun testExternalDisplayKeyboardEventSerialization() {
        val keyInput = ExternalDisplayProto.ExternalDisplayInput.newBuilder()
            .setAction(ExternalDisplayProto.ExternalDisplayInput.ActionType.KEY_DOWN)
            .setKeyCode(29) // KEYCODE_A
            .setModifiers(1) // Shift
            .setCharacters("A")
            .build()

        val bytes = keyInput.toByteArray()
        val parsed = ExternalDisplayProto.ExternalDisplayInput.parseFrom(bytes)

        assertEquals(ExternalDisplayProto.ExternalDisplayInput.ActionType.KEY_DOWN, parsed.action)
        assertEquals(29, parsed.keyCode)
        assertEquals(1, parsed.modifiers)
        assertEquals("A", parsed.characters)
    }

    @Test
    fun testExternalDisplayCalibrationSerialization() {
        val calib = ExternalDisplayProto.ExternalDisplayCalibration.newBuilder()
            .setIsCalibrating(true)
            .setMacReferenceNits(200.0f)
            .setMacAmbientLux(150.0f)
            .setForceRecalibrate(false)
            .setCalibratedBacklight(0.42f)
            .build()

        val msg = ExternalDisplayProto.ExternalDisplayMessage.newBuilder()
            .setEvent(ExternalDisplayProto.ExternalDisplayMessage.DisplayEventType.CALIBRATION_START)
            .setCalibration(calib)
            .setTimestamp(1700000000000L)
            .build()

        val bytes = msg.toByteArray()
        val parsed = ExternalDisplayProto.ExternalDisplayMessage.parseFrom(bytes)

        assertEquals(ExternalDisplayProto.ExternalDisplayMessage.DisplayEventType.CALIBRATION_START, parsed.event)
        assertTrue(parsed.calibration.isCalibrating)
        assertEquals(200.0f, parsed.calibration.macReferenceNits, 0.001f)
        assertEquals(150.0f, parsed.calibration.macAmbientLux, 0.001f)
        assertFalse(parsed.calibration.forceRecalibrate)
        assertEquals(0.42f, parsed.calibration.calibratedBacklight, 0.001f)
    }

    @Test
    fun testExternalDisplayBrightnessSerialization() {
        val brightness = ExternalDisplayProto.ExternalDisplayBrightness.newBuilder()
            .setTargetNits(195.5f)
            .setMacAmbientLux(120.0f)
            .setMacLinearBrightness(0.38f)
            .setTimestamp(1700000000000L)
            .build()

        val msg = ExternalDisplayProto.ExternalDisplayMessage.newBuilder()
            .setEvent(ExternalDisplayProto.ExternalDisplayMessage.DisplayEventType.BRIGHTNESS_UPDATE)
            .setBrightness(brightness)
            .setTimestamp(1700000000000L)
            .build()

        val bytes = msg.toByteArray()
        val parsed = ExternalDisplayProto.ExternalDisplayMessage.parseFrom(bytes)

        assertEquals(ExternalDisplayProto.ExternalDisplayMessage.DisplayEventType.BRIGHTNESS_UPDATE, parsed.event)
        assertEquals(195.5f, parsed.brightness.targetNits, 0.001f)
        assertEquals(120.0f, parsed.brightness.macAmbientLux, 0.001f)
        assertEquals(0.38f, parsed.brightness.macLinearBrightness, 0.001f)
        assertEquals(1700000000000L, parsed.brightness.timestamp)
    }
}
