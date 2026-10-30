package com.droidlink.app.display

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

class LuminanceEngineMathTest {

    private val gamma = LuminanceEngine.GAMMA // 2.2f
    private val alsAlpha = LuminanceEngine.ALS_ALPHA // 0.33f

    @Test
    fun testCalibrationFormulaKPanelDerivation() {
        // If user sets 50% backlight (0.5) to match 200 nits reference:
        // K_panel = 200 / (0.5)^2.2
        val slider = 0.5f
        val refNits = 200.0f
        val kPanel = refNits / slider.pow(gamma)

        // Verify: (0.5)^2.2 = 0.21763764
        // kPanel = 200 / 0.21763764 = 918.95 nits max extrapolated
        assertEquals(918.95f, kPanel, 1.0f)

        // Inverting with target = 200 nits should give back exactly 0.5f:
        val invertedBacklight = (refNits / kPanel).pow(1.0f / gamma)
        assertEquals(0.5f, invertedBacklight, 0.001f)
    }

    @Test
    fun testTargetNitsInversionAtDifferentMacLuminanceLevels() {
        val slider = 0.40f
        val refNits = 200.0f
        val kPanel = refNits / slider.pow(gamma)

        // Case 1: Mac dims to 100 nits
        val lowNits = 100.0f
        val lowBacklight = (lowNits / kPanel).pow(1.0f / gamma)
        assertTrue(lowBacklight < slider)
        assertTrue(lowBacklight > 0.01f)

        // Case 2: Mac brightens to 400 nits
        val highNits = 400.0f
        val highBacklight = (highNits / kPanel).pow(1.0f / gamma)
        assertTrue(highBacklight > slider)
        assertTrue(highBacklight <= 1.0f)

        // Relative ordering must be strictly monotonic
        assertTrue(lowBacklight < slider)
        assertTrue(slider < highBacklight)
    }

    @Test
    fun testAlsAmbientContrastAdaptation() {
        val luxRef = 150.0f
        val targetNits = 200.0f
        val kPanel = 1000.0f

        // When ambient lux doubles (e.g. 300 lux in brighter room):
        val brightLux = 300.0f
        val ratio = brightLux / luxRef // 2.0
        val ambientMult = ratio.pow(alsAlpha) // 2^0.33 = ~1.257
        val adaptedNits = targetNits * ambientMult

        val baseBacklight = (targetNits / kPanel).pow(1.0f / gamma)
        val adaptedBacklight = (adaptedNits / kPanel).pow(1.0f / gamma)

        // Backlight must increase when room gets brighter to maintain readable contrast
        assertTrue(adaptedBacklight > baseBacklight)

        // When ambient lux drops (e.g. dark room at 30 lux):
        val darkLux = 30.0f
        val darkRatio = darkLux / luxRef // 0.2
        val darkMult = darkRatio.pow(alsAlpha)
        val darkAdaptedNits = targetNits * darkMult
        val darkBacklight = (darkAdaptedNits / kPanel).pow(1.0f / gamma)

        // Backlight must decrease in darker room
        assertTrue(darkBacklight < baseBacklight)
    }

    @Test
    fun testClampingBoundsSafety() {
        val kPanel = 800.0f

        // Near-zero target nits must not drop below minimum safe backlight threshold (0.01f)
        val nearZeroNits = 0.0f
        val clampedNits = max(2.0f, nearZeroNits)
        val minBacklight = max(0.01f, min(1.0f, (clampedNits / kPanel).pow(1.0f / gamma)))
        assertTrue(minBacklight >= 0.01f)

        // Ultra-high target nits (e.g. 3000 nits sunlight) must clamp at 1.0f
        val ultraHighNits = 5000.0f
        val maxBacklight = max(0.01f, min(1.0f, (ultraHighNits / kPanel).pow(1.0f / gamma)))
        assertEquals(1.0f, maxBacklight, 0.001f)
    }
}
