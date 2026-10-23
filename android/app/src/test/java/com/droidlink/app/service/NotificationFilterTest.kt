package com.droidlink.app.service

import android.app.Notification
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

class NotificationFilterTest {

    @Before
    fun setUp() {
        NotificationFilter.clearCache()
    }

    @After
    fun tearDown() {
        NotificationFilter.clearCache()
    }

    @Test
    fun testAllowedUserAppNotificationPasses() {
        val result = NotificationFilter.shouldFilter(
            packageName = "com.whatsapp",
            isOngoing = false,
            flags = 0,
            category = Notification.CATEGORY_MESSAGE,
            channelId = "messages",
            title = "Alice",
            text = "Hey, are you free to chat?",
            isPackageAllowed = true,
            ownPackageName = "com.droidlink.app"
        )
        assertNull("Standard user notification should not be filtered", result)
    }

    @Test
    fun testOwnAppNotificationFiltered() {
        val result = NotificationFilter.shouldFilter(
            packageName = "com.droidlink.app",
            isOngoing = false,
            flags = 0,
            category = null,
            channelId = "service_channel",
            title = "DroidLink Active",
            text = "Connected to Mac",
            isPackageAllowed = true,
            ownPackageName = "com.droidlink.app"
        )
        assertEquals("own_app", result)
    }

    @Test
    fun testBlockedPackageFiltered() {
        val result = NotificationFilter.shouldFilter(
            packageName = "com.annoying.app",
            isOngoing = false,
            flags = 0,
            category = null,
            channelId = null,
            title = "Spam Alert",
            text = "Click here to win",
            isPackageAllowed = false,
            ownPackageName = "com.droidlink.app"
        )
        assertEquals("package_blocked", result)
    }

    @Test
    fun testEmptyContentFiltered() {
        val result = NotificationFilter.shouldFilter(
            packageName = "com.some.app",
            isOngoing = false,
            flags = 0,
            category = null,
            channelId = null,
            title = "   ",
            text = "",
            isPackageAllowed = true,
            ownPackageName = "com.droidlink.app"
        )
        assertEquals("empty_content", result)
    }

    @Test
    fun testOngoingNotificationFiltered() {
        val result = NotificationFilter.shouldFilter(
            packageName = "com.pedometer.app",
            isOngoing = true,
            flags = Notification.FLAG_ONGOING_EVENT,
            category = Notification.CATEGORY_SERVICE,
            channelId = "steps",
            title = "Step Tracker",
            text = "5,432 steps today",
            isPackageAllowed = true,
            filterOngoingEnabled = true,
            ownPackageName = "com.droidlink.app"
        )
        assertNotNull("Ongoing notification should be filtered", result)
    }

    @Test
    fun testMediaPlaybackNotificationFiltered() {
        val extrasWithMedia = mapOf<String, Any?>(Notification.EXTRA_MEDIA_SESSION to "dummy_token")
        val result = NotificationFilter.shouldFilter(
            packageName = "com.spotify.music",
            isOngoing = false,
            flags = 0,
            category = Notification.CATEGORY_TRANSPORT,
            channelId = "playback",
            title = "Song Title",
            text = "Artist Name",
            extras = extrasWithMedia,
            isPackageAllowed = true,
            filterMediaEnabled = true,
            ownPackageName = "com.droidlink.app"
        )
        assertEquals("media_playback", result)
    }

    @Test
    fun testActiveCallChronometerFiltered() {
        val extrasWithChronometer = mapOf<String, Any?>(Notification.EXTRA_SHOW_CHRONOMETER to true)
        val result = NotificationFilter.shouldFilter(
            packageName = "com.google.android.dialer",
            isOngoing = true,
            flags = Notification.FLAG_ONGOING_EVENT,
            category = Notification.CATEGORY_CALL,
            channelId = "ongoing_call",
            title = "Ongoing Call",
            text = "01:23 • Alice",
            extras = extrasWithChronometer,
            isPackageAllowed = true,
            filterOngoingEnabled = true,
            ownPackageName = "com.droidlink.app"
        )
        assertEquals("ongoing_call_timer", result)
    }

    @Test
    fun testChargingAndBatteryAlertsFiltered() {
        // Test system UI charging channel
        val resultChannel = NotificationFilter.shouldFilter(
            packageName = "com.android.systemui",
            isOngoing = false,
            flags = 0,
            category = Notification.CATEGORY_STATUS,
            channelId = "battery_status",
            title = "Charging",
            text = "Fast charging • 82%",
            isPackageAllowed = true,
            filterChargingEnabled = true,
            ownPackageName = "com.droidlink.app"
        )
        assertEquals("charging_battery", resultChannel)

        // Test charging keyword in title/text
        val resultText = NotificationFilter.shouldFilter(
            packageName = "com.power.battery",
            isOngoing = false,
            flags = 0,
            category = null,
            channelId = "default",
            title = "Cable Connected",
            text = "Device is charging rapidly",
            isPackageAllowed = true,
            filterChargingEnabled = true,
            ownPackageName = "com.droidlink.app"
        )
        assertEquals("charging_battery", resultText)
    }

    @Test
    fun testGroupSummaryFiltered() {
        val result = NotificationFilter.shouldFilter(
            packageName = "com.whatsapp",
            isOngoing = false,
            flags = Notification.FLAG_GROUP_SUMMARY,
            category = Notification.CATEGORY_MESSAGE,
            channelId = "chats",
            title = "WhatsApp",
            text = "4 new messages from 2 chats",
            isPackageAllowed = true,
            ownPackageName = "com.droidlink.app"
        )
        assertEquals("group_summary", result)
    }

    @Test
    fun testDuplicateWithinWindowFiltered() {
        val key = "msg_key_101"
        val t0 = 100_000L

        // First delivery passes
        val first = NotificationFilter.shouldFilter(
            packageName = "com.slack",
            isOngoing = false,
            flags = 0,
            category = Notification.CATEGORY_MESSAGE,
            channelId = "messages",
            title = "Team Lead",
            text = "Review ready for testing",
            isPackageAllowed = true,
            ownPackageName = "com.droidlink.app",
            nowMs = t0,
            notificationKey = key
        )
        assertNull("First post must pass", first)

        // Exact repeat after 2 seconds should be dropped as duplicate
        val second = NotificationFilter.shouldFilter(
            packageName = "com.slack",
            isOngoing = false,
            flags = 0,
            category = Notification.CATEGORY_MESSAGE,
            channelId = "messages",
            title = "Team Lead",
            text = "Review ready for testing",
            isPackageAllowed = true,
            ownPackageName = "com.droidlink.app",
            nowMs = t0 + 2000L,
            notificationKey = key
        )
        assertEquals("duplicate_within_window", second)
    }

    @Test
    fun testRapidBurstThrottled() {
        val key = "rapid_key_202"
        val t0 = 200_000L

        // Initial post
        val first = NotificationFilter.shouldFilter(
            packageName = "com.fast.app",
            isOngoing = false,
            flags = 0,
            category = null,
            channelId = "feed",
            title = "Update #1",
            text = "Data point 1",
            isPackageAllowed = true,
            ownPackageName = "com.droidlink.app",
            nowMs = t0,
            notificationKey = key
        )
        assertNull("Initial post should pass", first)

        // Immediate subsequent post with different text (burst < 1.5s)
        val rapid = NotificationFilter.shouldFilter(
            packageName = "com.fast.app",
            isOngoing = false,
            flags = 0,
            category = null,
            channelId = "feed",
            title = "Update #2",
            text = "Data point 2",
            isPackageAllowed = true,
            ownPackageName = "com.droidlink.app",
            nowMs = t0 + 500L, // only 500ms later
            notificationKey = key
        )
        assertEquals("rapid_burst_throttled", rapid)

        // Post after throttle window (> 1.5s) passes
        val later = NotificationFilter.shouldFilter(
            packageName = "com.fast.app",
            isOngoing = false,
            flags = 0,
            category = null,
            channelId = "feed",
            title = "Update #3",
            text = "Data point 3",
            isPackageAllowed = true,
            ownPackageName = "com.droidlink.app",
            nowMs = t0 + 1600L, // 1600ms later
            notificationKey = key
        )
        assertNull("Post after throttle window should pass", later)
    }
}
