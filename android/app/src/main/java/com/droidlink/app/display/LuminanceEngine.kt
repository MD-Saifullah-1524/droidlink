package com.droidlink.app.display

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Mathematical engine for physical luminance (nits / cd/m²) matching.
 * Combines Way 2 (Mandatory 1-step visual calibration) with
 * Way 4 (Ambient Light Sensor / ALS-assisted dynamic adjustments).
 */
object LuminanceEngine {
    private const val TAG = "LuminanceEngine"
    private const val PREFS_NAME = "droidlink_luminance_calibration"

    private const val KEY_IS_CALIBRATED = "is_calibrated"
    private const val KEY_K_PANEL = "k_panel"
    private const val KEY_CALIBRATED_BACKLIGHT = "calibrated_backlight"
    private const val KEY_AMBIENT_LUX_REF = "ambient_lux_ref"
    private const val KEY_REFERENCE_NITS = "reference_nits"
    private const val KEY_ALS_ENABLED = "als_enabled"
    private const val KEY_TRIM_NITS = "trim_nits"

    // Standard display perceptual power law gamma
    const val GAMMA = 2.2f

    // Ambient contrast adaptation exponent (Stevens' power law)
    const val ALS_ALPHA = 0.33f

    // Default reference luminance (200 nits is standard SDR office white level)
    const val DEFAULT_REFERENCE_NITS = 200.0f
    const val DEFAULT_AMBIENT_LUX = 150.0f

    private fun getPrefs(context: Context): SharedPreferences {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    /**
     * Checks if this device has completed the mandatory visual calibration (Way 2).
     */
    fun isCalibrated(context: Context): Boolean {
        return getPrefs(context).getBoolean(KEY_IS_CALIBRATED, false)
    }

    /**
     * Retrieves the calibrated panel constant K_panel.
     * Default is based on a standard 500-nit panel.
     */
    fun getKPanel(context: Context): Float {
        return getPrefs(context).getFloat(KEY_K_PANEL, 500.0f)
    }

    /**
     * Retrieves the calibrated backlight slider value.
     */
    fun getCalibratedBacklight(context: Context): Float {
        return getPrefs(context).getFloat(KEY_CALIBRATED_BACKLIGHT, 0.40f)
    }

    /**
     * Retrieves the reference ambient lux captured during calibration.
     */
    fun getAmbientLuxRef(context: Context): Float {
        return getPrefs(context).getFloat(KEY_AMBIENT_LUX_REF, DEFAULT_AMBIENT_LUX)
    }

    /**
     * Whether dynamic ALS adaptation is enabled.
     */
    fun isAlsEnabled(context: Context): Boolean {
        return getPrefs(context).getBoolean(KEY_ALS_ENABLED, true)
    }

    fun setAlsEnabled(context: Context, enabled: Boolean) {
        getPrefs(context).edit().putBoolean(KEY_ALS_ENABLED, enabled).apply()
    }

    /**
     * User-configurable manual offset in nits (e.g. -50 to +50 nits).
     */
    fun getTrimNits(context: Context): Float {
        return getPrefs(context).getFloat(KEY_TRIM_NITS, 0.0f)
    }

    fun setTrimNits(context: Context, trimNits: Float) {
        getPrefs(context).edit().putFloat(KEY_TRIM_NITS, trimNits).apply()
    }

    /**
     * Saves the mandatory visual calibration result (Way 2).
     * Calculates the panel transfer constant: K_panel = L_ref / (b_slider)^GAMMA
     */
    fun saveCalibration(
        context: Context,
        sliderValue: Float,
        referenceNits: Float = DEFAULT_REFERENCE_NITS,
        ambientLux: Float = DEFAULT_AMBIENT_LUX
    ) {
        val safeSlider = max(0.01f, min(1.0f, sliderValue))
        val safeRefNits = max(50.0f, min(1000.0f, referenceNits))
        val safeLux = max(5.0f, ambientLux)

        // K_panel: physical peak capacity extrapolated from the user's matched point
        val kPanel = safeRefNits / safeSlider.pow(GAMMA)

        getPrefs(context).edit().apply {
            putBoolean(KEY_IS_CALIBRATED, true)
            putFloat(KEY_K_PANEL, kPanel)
            putFloat(KEY_CALIBRATED_BACKLIGHT, safeSlider)
            putFloat(KEY_AMBIENT_LUX_REF, safeLux)
            putFloat(KEY_REFERENCE_NITS, safeRefNits)
            apply()
        }

        Log.i(
            TAG,
            "🎯 Calibration saved: slider=$safeSlider, refNits=$safeRefNits, lux=$safeLux -> K_panel=$kPanel"
        )
    }

    /**
     * Resets calibration to force re-running the mandatory wizard.
     */
    fun resetCalibration(context: Context) {
        getPrefs(context).edit().remove(KEY_IS_CALIBRATED).apply()
        Log.i(TAG, "Calibration reset to uncalibrated state.")
    }

    /**
     * Computes the target Android window backlight float (0.01f to 1.0f)
     * from Mac target physical nits and current Android ambient lux (Way 4).
     */
    fun calculateBacklight(
        context: Context,
        targetNits: Float,
        currentLux: Float = DEFAULT_AMBIENT_LUX
    ): Float {
        val kPanel = getKPanel(context)
        val trimNits = getTrimNits(context)
        val alsEnabled = isAlsEnabled(context)
        val luxRef = getAmbientLuxRef(context)

        // 1. Base requested physical luminance
        var effectiveNits = max(2.0f, targetNits + trimNits)

        // 2. Way 4: Ambient contrast adaptation
        if (alsEnabled && luxRef > 1.0f && currentLux > 1.0f) {
            // Clamp lux ratio between 0.25x and 4.0x to avoid extreme swings in sunlight/pitch dark
            val luxRatio = max(0.25f, min(4.0f, currentLux / luxRef))
            val ambientMultiplier = luxRatio.pow(ALS_ALPHA)
            effectiveNits *= ambientMultiplier
        }

        // 3. Invert power law: b = (L_adapted / K_panel)^(1 / GAMMA)
        val normalizedLuminance = max(0.001f, effectiveNits / max(10.0f, kPanel))
        val backlight = normalizedLuminance.pow(1.0f / GAMMA)

        return max(0.01f, min(1.0f, backlight))
    }
}
