package net.flashbots.anymone

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import net.flashbots.anymone.ffi.SecretStore
import net.flashbots.anymone.ffi.SecretStoreException

private const val KEYSTORE = "AndroidKeyStore"
private const val KEY_ALIAS = "anymone-identity-wrap"
private const val IV_BYTES = 12
private const val TAG_BITS = 128

/**
 * Identity storage wrapped by a Keystore key.
 *
 * The wrapping key is generated in secure hardware and cannot be extracted, so
 * the ciphertext on disk is useless off this device — which is what app-private
 * files alone do not give you on a rooted phone or through a backup. The manifest
 * also disables backups, so the ciphertext never leaves at all.
 */
class KeystoreSecretStore(context: Context) : SecretStore {
    private val file = File(context.filesDir, "identity.bin")

    override fun load(): ByteArray? {
        if (!file.exists()) return null
        return try {
            val blob = file.readBytes()
            if (blob.size <= IV_BYTES) throw SecretStoreException.Failed("truncated identity blob")
            val cipher =
                Cipher.getInstance("AES/GCM/NoPadding").apply {
                    init(
                        Cipher.DECRYPT_MODE,
                        wrappingKey(existingOnly = true),
                        GCMParameterSpec(TAG_BITS, blob, 0, IV_BYTES),
                    )
                }
            cipher.doFinal(blob, IV_BYTES, blob.size - IV_BYTES)
        } catch (e: SecretStoreException) {
            throw e
        } catch (e: Exception) {
            // The blob exists but will not open: the wrapping key was cleared
            // (screen lock removed, app data restored elsewhere). Minting a new
            // identity here would silently abandon the enrolled one.
            throw SecretStoreException.Failed("cannot unwrap identity: ${e.message}")
        }
    }

    override fun store(secrets: ByteArray) {
        try {
            val cipher =
                Cipher.getInstance("AES/GCM/NoPadding").apply {
                    init(Cipher.ENCRYPT_MODE, wrappingKey(existingOnly = false))
                }
            val sealed = cipher.iv + cipher.doFinal(secrets)
            file.writeBytes(sealed)
        } catch (e: Exception) {
            throw SecretStoreException.Failed("cannot wrap identity: ${e.message}")
        } finally {
            secrets.fill(0)
        }
    }

    private fun wrappingKey(existingOnly: Boolean): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        if (existingOnly) throw SecretStoreException.Failed("wrapping key is gone")

        val spec =
            KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                // The client runs in the background between rounds, so it cannot
                // wait on a user presenting a credential.
                .setUserAuthenticationRequired(false)
                .build()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
            .apply { init(spec) }
            .generateKey()
    }
}
