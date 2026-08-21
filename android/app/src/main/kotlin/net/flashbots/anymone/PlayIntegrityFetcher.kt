package net.flashbots.anymone

import android.content.Context
import android.util.Base64
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.StandardIntegrityManager
import com.google.android.play.core.integrity.StandardIntegrityManager.PrepareIntegrityTokenRequest
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenRequest
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine
import net.flashbots.anymone.ffi.AttestationTokenFetcher
import net.flashbots.anymone.ffi.FetchException

/**
 * Rust hands over the 32-byte challenge; this turns it into a Play Integrity
 * verdict token. Verification is local at the relay, against the Play Console
 * keys in the signed network policy.
 *
 * `PLAY_RECOGNIZED` only comes back for builds installed through Play, so a
 * sideloaded debug APK will not satisfy an attested subnet — use the internal
 * testing track. `prepare` is warmed once because standard requests are
 * quota'd per app per day; re-attestation happens once per validity window,
 * not per round.
 */
class PlayIntegrityFetcher(
    context: Context,
    private val cloudProjectNumber: Long,
) : AttestationTokenFetcher {
    private val manager = IntegrityManagerFactory.createStandard(context)
    private var provider: StandardIntegrityManager.StandardIntegrityTokenProvider? = null

    private suspend fun provider(): StandardIntegrityManager.StandardIntegrityTokenProvider {
        provider?.let { return it }
        return suspendCoroutine { cont ->
            manager
                .prepareIntegrityToken(
                    PrepareIntegrityTokenRequest.builder()
                        .setCloudProjectNumber(cloudProjectNumber)
                        .build()
                )
                .addOnSuccessListener {
                    provider = it
                    cont.resume(it)
                }
                .addOnFailureListener {
                    cont.resumeWithException(
                        FetchException.Unavailable("prepareIntegrityToken: ${it.message}")
                    )
                }
        }
    }

    override suspend fun fetch(challenge: ByteArray): ByteArray {
        val requestHash = Base64.encodeToString(challenge, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
        val provider = provider()
        return suspendCoroutine { cont ->
            provider
                .request(StandardIntegrityTokenRequest.builder().setRequestHash(requestHash).build())
                .addOnSuccessListener { cont.resume(it.token().toByteArray()) }
                .addOnFailureListener {
                    cont.resumeWithException(FetchException.Failed("integrity request: ${it.message}"))
                }
        }
    }
}
