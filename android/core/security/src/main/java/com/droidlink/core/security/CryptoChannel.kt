package com.droidlink.core.security

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Hardware-accelerated AES-256-GCM authenticated encryption channel for Android 15+
 * Wire format matches Apple CryptoKit: [12 bytes nonce] + [ciphertext] + [16 bytes tag]
 */
class CryptoChannel(private val keyBytes: ByteArray) {

    init {
        require(keyBytes.size == KEY_SIZE_BYTES) {
            "Invalid key length: expected $KEY_SIZE_BYTES bytes, got ${keyBytes.size}"
        }
    }

    private val secretKey = SecretKeySpec(keyBytes, "AES")

    companion object {
        const val KEY_SIZE_BYTES = 32
        const val NONCE_SIZE_BYTES = 12
        const val TAG_SIZE_BITS = 128
        const val TAG_SIZE_BYTES = TAG_SIZE_BITS / 8
        private const val TRANSFORMATION = "AES/GCM/NoPadding"

        fun generateSessionKey(): ByteArray {
            val bytes = ByteArray(KEY_SIZE_BYTES)
            SecureRandom().nextBytes(bytes)
            return bytes
        }
    }

    /**
     * Encrypts plaintext using AES-256-GCM.
     * Returns: [12 bytes nonce] + [ciphertext + 16 bytes tag]
     */
    fun encrypt(plaintext: ByteArray): ByteArray {
        val nonce = ByteArray(NONCE_SIZE_BYTES)
        SecureRandom().nextBytes(nonce)

        val cipher = Cipher.getInstance(TRANSFORMATION)
        val spec = GCMParameterSpec(TAG_SIZE_BITS, nonce)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey, spec)

        val ciphertextWithTag = cipher.doFinal(plaintext)
        val combined = ByteArray(NONCE_SIZE_BYTES + ciphertextWithTag.size)
        System.arraycopy(nonce, 0, combined, 0, NONCE_SIZE_BYTES)
        System.arraycopy(ciphertextWithTag, 0, combined, NONCE_SIZE_BYTES, ciphertextWithTag.size)

        return combined
    }

    /**
     * Decrypts ciphertext using AES-256-GCM.
     * Expects: [12 bytes nonce] + [ciphertext + 16 bytes tag]
     */
    fun decrypt(combinedCiphertext: ByteArray): ByteArray {
        require(combinedCiphertext.size >= NONCE_SIZE_BYTES + TAG_SIZE_BYTES) {
            "Ciphertext too short (minimum ${NONCE_SIZE_BYTES + TAG_SIZE_BYTES} bytes required)"
        }

        val nonce = ByteArray(NONCE_SIZE_BYTES)
        System.arraycopy(combinedCiphertext, 0, nonce, 0, NONCE_SIZE_BYTES)

        val ciphertextLength = combinedCiphertext.size - NONCE_SIZE_BYTES
        val ciphertextWithTag = ByteArray(ciphertextLength)
        System.arraycopy(combinedCiphertext, NONCE_SIZE_BYTES, ciphertextWithTag, 0, ciphertextLength)

        val cipher = Cipher.getInstance(TRANSFORMATION)
        val spec = GCMParameterSpec(TAG_SIZE_BITS, nonce)
        cipher.init(Cipher.DECRYPT_MODE, secretKey, spec)

        return cipher.doFinal(ciphertextWithTag)
    }
}
