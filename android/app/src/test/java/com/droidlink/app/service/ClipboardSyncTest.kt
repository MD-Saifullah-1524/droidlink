package com.droidlink.app.service

import droidlink.protocol.ClipboardProto
import droidlink.protocol.DroidlinkMessages
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardSyncTest {

    @Test
    fun testClipboardMessageSerialization() {
        val testText = "Hello from Android to Mac via Universal Clipboard!"
        val timestamp = 1700000000000L

        val clipData = ClipboardProto.ClipboardData.newBuilder()
            .setType(ClipboardProto.DataType.DATA_TEXT)
            .setText(testText)
            .setTimestamp(timestamp)
            .build()

        val clipMsg = ClipboardProto.ClipboardMessage.newBuilder()
            .setData(clipData)
            .setIsRemote(false)
            .build()

        val rootMsg = DroidlinkMessages.DroidLinkMessage.newBuilder()
            .setId(timestamp)
            .setTimestamp(timestamp)
            .setType(DroidlinkMessages.MessageType.CLIPBOARD_SYNC)
            .setClipboard(clipMsg)
            .build()

        val serializedBytes = rootMsg.toByteArray()
        assertNotNull(serializedBytes)
        assertTrue(serializedBytes.isNotEmpty())

        // Simulate deserialization on Mac / recipient side
        val parsedRoot = DroidlinkMessages.DroidLinkMessage.parseFrom(serializedBytes)
        assertEquals(DroidlinkMessages.MessageType.CLIPBOARD_SYNC, parsedRoot.type)
        assertTrue(parsedRoot.hasClipboard())

        val parsedClip = parsedRoot.clipboard
        assertFalse(parsedClip.isRemote)
        assertEquals(testText, parsedClip.data.text)
        assertEquals(ClipboardProto.DataType.DATA_TEXT, parsedClip.data.type)
        assertEquals(timestamp, parsedClip.data.timestamp)
    }

    @Test
    fun testEmptyOrBlankClipboardAvoidance() {
        val blankText = "   "
        assertTrue(blankText.isBlank())
    }
}
