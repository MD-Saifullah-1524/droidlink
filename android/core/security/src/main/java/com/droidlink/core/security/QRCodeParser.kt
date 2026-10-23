package com.droidlink.core.security

import android.util.Base64
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Pairing token data decoded from QR code
 */
@Serializable
data class PairingToken(
    val version: String,
    val deviceId: String,
    val deviceName: String,
    val host: String,
    val port: Int,
    val sessionKey: String,
    val timestamp: Long
)

/**
 * Parser and validator for DroidLink QR code data
 */
class QRCodeParser {
    private val json = Json { ignoreUnknownKeys = true }

    /**
     * Parse pairing token from JSON string
     */
    fun parse(qrCodeData: String): PairingToken {
        return try {
            json.decodeFromString<PairingToken>(qrCodeData)
        } catch (e: Exception) {
            throw QRCodeParseException("Invalid QR code format: ${e.message}", e)
        }
    }

    /**
     * Validate pairing token
     */
    fun validate(token: PairingToken): ValidationResult {
        if (!token.version.startsWith("2.") && !token.version.startsWith("1.")) {
            return ValidationResult.InvalidVersion("Unsupported protocol version: ${token.version}")
        }

        if (token.host.isBlank() || token.port !in 1024..65535) {
            return ValidationResult.InvalidNetworkInfo("Invalid network endpoint: ${token.host}:${token.port}")
        }

        val currentTime = System.currentTimeMillis() / 1000
        val tokenAge = currentTime - token.timestamp

        // Allow up to 10 minutes QR validity
        if (tokenAge > 600) {
            return ValidationResult.ExpiredQR("QR code expired (age: $tokenAge seconds)")
        }

        if (tokenAge < -120) {
            return ValidationResult.FutureQR("Device clock skew detected (future: ${-tokenAge} seconds)")
        }

        return ValidationResult.Valid
    }

    /**
     * Extract validated device information and decode session key
     */
    fun extractDeviceInfo(token: PairingToken): DeviceInfo {
        val keyBytes = try {
            Base64.decode(token.sessionKey, Base64.DEFAULT)
        } catch (e: Exception) {
            throw QRCodeParseException("Invalid base64 session key", e)
        }

        return DeviceInfo(
            deviceId = token.deviceId,
            deviceName = token.deviceName,
            host = token.host,
            port = token.port,
            sessionKey = keyBytes
        )
    }
}

sealed class ValidationResult {
    data object Valid : ValidationResult()
    data class InvalidVersion(val message: String) : ValidationResult()
    data class InvalidNetworkInfo(val message: String) : ValidationResult()
    data class ExpiredQR(val message: String) : ValidationResult()
    data class FutureQR(val message: String) : ValidationResult()
}

data class DeviceInfo(
    val deviceId: String,
    val deviceName: String,
    val host: String,
    val port: Int,
    val sessionKey: ByteArray
)

class QRCodeParseException(message: String, cause: Throwable? = null) : Exception(message, cause)
