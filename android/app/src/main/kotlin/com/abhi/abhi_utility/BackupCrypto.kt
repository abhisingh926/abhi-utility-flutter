package com.abhi.abhi_utility

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * Encryption for cloud backups of the diary (BackupService on the Dart side).
 *
 *  - Key: PBKDF2-HMAC-SHA256 of the diary password (slow on purpose).
 *  - Data: AES-256-GCM. Output = 12-byte nonce || ciphertext+tag.
 *  - Nonce: random, or (deterministic = true) the first 12 bytes of
 *    HMAC-SHA256(key, data). Deterministic is used for photos so the same
 *    photo encrypts to the same bytes and is uploaded only once; it only
 *    reveals that two photos are identical.
 *
 * Work runs off the main thread (key derivation takes about a second).
 */
object BackupCrypto {
    private const val NONCE = 12
    private const val TAG_BITS = 128
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "abhi_utility/crypto").setMethodCallHandler { call, result ->
            worker.execute {
                try {
                    val value: Any = when (call.method) {
                        "deriveKey" -> deriveKey(
                            call.argument<String>("password")!!,
                            call.argument<ByteArray>("salt")!!,
                            call.argument<Int>("iterations")!!,
                        )
                        "encrypt" -> encrypt(
                            call.argument<ByteArray>("key")!!,
                            call.argument<ByteArray>("data")!!,
                            call.argument<Boolean>("deterministic") ?: false,
                        )
                        "decrypt" -> decrypt(call.argument<ByteArray>("key")!!, call.argument<ByteArray>("data")!!)
                        else -> {
                            main.post { result.notImplemented() }
                            return@execute
                        }
                    }
                    main.post { result.success(value) }
                } catch (e: AEADBadTagException) {
                    main.post { result.error("WRONG_KEY", "Wrong password or damaged backup", null) }
                } catch (e: Exception) {
                    main.post { result.error("CRYPTO", e.message ?: e.toString(), null) }
                }
            }
        }
    }

    fun deriveKey(password: String, salt: ByteArray, iterations: Int): ByteArray {
        val spec = PBEKeySpec(password.toCharArray(), salt, iterations, 256)
        try {
            return SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        } finally {
            spec.clearPassword()
        }
    }

    fun encrypt(key: ByteArray, data: ByteArray, deterministic: Boolean): ByteArray {
        val nonce = if (deterministic) {
            Mac.getInstance("HmacSHA256").run {
                init(SecretKeySpec(key, "HmacSHA256"))
                doFinal(data).copyOf(NONCE)
            }
        } else {
            ByteArray(NONCE).also { java.security.SecureRandom().nextBytes(it) }
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
        return nonce + cipher.doFinal(data)
    }

    fun decrypt(key: ByteArray, blob: ByteArray): ByteArray {
        require(blob.size > NONCE) { "Encrypted data is too short" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(key, "AES"),
            GCMParameterSpec(TAG_BITS, blob, 0, NONCE),
        )
        return cipher.doFinal(blob, NONCE, blob.size - NONCE)
    }
}
