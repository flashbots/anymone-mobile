package net.flashbots.anymone

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.spec.ECGenParameterSpec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import net.flashbots.anymone.ffi.AttestationTokenFetcher
import net.flashbots.anymone.ffi.FetchException

private const val KEYSTORE = "AndroidKeyStore"

/**
 * Hardware key attestation. Needs no Play Console, no Cloud project and no
 * install through Play, so a sideloaded build can enrol on an attested subnet.
 *
 * The relay checks the chain against Google's published root, so what it proves
 * is the device and its boot state — not that the APK came from a store. The
 * signing digest in the policy is what identifies the app.
 */
class AndroidKeyFetcher(private val requireStrongBox: Boolean = false) : AttestationTokenFetcher {

    override suspend fun fetch(challenge: ByteArray): ByteArray =
        withContext(Dispatchers.Default) {
            // A fresh alias per attestation: the challenge is baked into the
            // certificate at generation, so a key cannot be reattested.
            val alias = "anymone-attest-${System.nanoTime()}"
            try {
                generate(alias, challenge)
                val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
                val chain =
                    store.getCertificateChain(alias)
                        ?: throw FetchException.Failed("keystore returned no chain")
                chain.fold(ByteArray(0)) { acc, cert -> acc + cert.encoded }
            } catch (e: FetchException) {
                throw e
            } catch (e: Exception) {
                throw FetchException.Unavailable("key attestation: ${e.message}")
            } finally {
                runCatching { KeyStore.getInstance(KEYSTORE).apply { load(null) }.deleteEntry(alias) }
            }
        }

    private fun generate(alias: String, challenge: ByteArray) {
        val spec =
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setAttestationChallenge(challenge)
                .apply { if (requireStrongBox) setIsStrongBoxBacked(true) }
                .build()
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE)
            .apply { initialize(spec) }
            .generateKeyPair()
    }
}
