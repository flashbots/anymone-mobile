package net.flashbots.anymone

import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.flashbots.anymone.ffi.AnymoneClient
import net.flashbots.anymone.ffi.AnymonePipe
import net.flashbots.anymone.ffi.AttestationStatus
import net.flashbots.anymone.ffi.MobileScheme
import net.flashbots.anymone.bench.BenchResult
import net.flashbots.anymone.bench.benchNames
import net.flashbots.anymone.bench.benchReportCsv
import net.flashbots.anymone.bench.benchReps
import net.flashbots.anymone.bench.benchThreads
import net.flashbots.anymone.bench.clientRoleMedianNs
import net.flashbots.anymone.bench.coreSweepReportCsv
import net.flashbots.anymone.bench.coreSweepThreads
import net.flashbots.anymone.bench.runBench
import net.flashbots.anymone.bench.runCoreBench
import net.flashbots.anymone.bench.runSmoke
import net.flashbots.anymone.bench.smokeNames
import net.flashbots.anymone.bench.smokeReportCsv

/** Committee default public_round_ms, kept as the reference to report against. */
private const val ROUND_BUDGET_NS = 4_000_000_000L

/** Flagged only past this: a large cell legitimately runs far over the 4 s
 *  reference, and calling that a failure would hide the measurement. */
private const val ROUND_CEILING_NS = 60_000_000_000L
private const val ROUND_BENCH = "anymone_panetiere_round"

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { AnymoneTheme { App(filesDir.path) } }
    }
}

private enum class Screen {
    BENCH,
    ROOM,
    ATTEST,
}

private enum class BenchMode {
    BENCHMARK,
    CORE_SWEEP,
    SMOKE,
}

@Composable
private fun App(dataDir: String) {
    var screen by remember { mutableStateOf(Screen.BENCH) }
    Column(Modifier.fillMaxSize().background(Ink.night)) {
        Brand()
        Hairline()
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 20.dp)) {
            when (screen) {
                Screen.BENCH -> BenchScreen()
                Screen.ROOM -> RoomScreen(dataDir, attested = false)
                Screen.ATTEST -> RoomScreen(dataDir, attested = true)
            }
            Spacer(Modifier.height(24.dp))
        }
        Hairline()
        TabStrip(screen) { screen = it }
    }
}

@Composable
private fun Brand() {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column {
            Text("ANYMONE", style = mono(12, FontWeight.Bold, 1.8), color = Ink.paper)
            Text(
                "anonymous broadcast · handset client",
                style = mono(8, tracking = 1.2),
                color = Ink.fog,
            )
        }
    }
}

@Composable
private fun TabStrip(current: Screen, onPick: (Screen) -> Unit) {
    Row(Modifier.fillMaxWidth().height(46.dp).background(Ink.night)) {
        Screen.entries.forEachIndexed { i, item ->
            val on = item == current
            Column(
                Modifier.weight(1f).height(46.dp).clickable { onPick(item) },
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Box(Modifier.fillMaxWidth().height(2.dp).background(if (on) Ink.moon else Ink.night))
                Spacer(Modifier.height(9.dp))
                Text(
                    item.name,
                    style = mono(10, FontWeight.Bold, 1.6),
                    color = if (on) Ink.moon else Ink.fog,
                )
            }
            if (i < Screen.entries.lastIndex) {
                Box(Modifier.width(1.dp).height(46.dp).background(Ink.line))
            }
        }
    }
}

@Composable
private fun BenchScreen() {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var results by remember { mutableStateOf(listOf<BenchResult>()) }
    var running by remember { mutableStateOf<String?>(null) }
    var benchMode by remember { mutableStateOf(BenchMode.BENCHMARK) }

    SectionLabel("01", "bench", "client hot paths")
    Text(
        "panetiere_* mirror the host sweep's Prony direct and RS phases, plus "
            + "MSE encoding: 8 servers, 50 messages a round, 1 KB payloads. anymone_* time "
            + "a whole round as the client runs it, framing and signatures included.",
        style = mono(11),
        color = Ink.fog,
    )
    Spacer(Modifier.height(14.dp))
    HouseButton("smoke 4×10", outline = true, enabled = running == null) {
        scope.launch {
            benchMode = BenchMode.SMOKE
            results = emptyList()
            for (name in smokeNames()) {
                running = name
                results = results + withContext(Dispatchers.Default) { runSmoke(name) }
            }
            running = null
        }
    }
    Spacer(Modifier.height(8.dp))
    HouseButton("core sweep 1·2·4·8", outline = true, enabled = running == null) {
        scope.launch {
            benchMode = BenchMode.CORE_SWEEP
            results = emptyList()
            for (threads in coreSweepThreads()) {
                running = "$threads cores"
                results = results + withContext(Dispatchers.Default) { runCoreBench(threads) }
            }
            running = null
        }
    }
    Spacer(Modifier.height(8.dp))
    HouseButton(running?.let { "running $it" } ?: "run all · ${benchThreads()} cores", enabled = running == null) {
        scope.launch {
            benchMode = BenchMode.BENCHMARK
            results = emptyList()
            for (name in benchNames()) {
                running = name
                results = results + withContext(Dispatchers.Default) {
                    runBench(name, benchReps(name), benchThreads())
                }
            }
            running = null
        }
    }

    if (results.isNotEmpty()) {
        SectionLabel("02", "results", "median ns per op")
        Hairline()
        results.forEach { r ->
            val slow = r.name == ROUND_BENCH && r.medianNs.toLong() >= ROUND_CEILING_NS
            Row(r.name, format(r.medianNs.toLong()), if (slow) Ink.ember else Ink.moon)
            Row(
                "  ${r.reps} reps",
                "${format(r.minNs.toLong())} – ${format(r.maxNs.toLong())}",
                Ink.fog,
            )
            Hairline()
        }
        // The host sweep's client-role total, for comparison against it.
        clientRoleMedianNs(results).toLong().takeIf { it > 0 }?.let {
            Row("panetiere prony client", format(it), Ink.lichen)
            Hairline()
        }
        results.firstOrNull { it.name == ROUND_BENCH }?.let { r ->
            val share = r.medianNs.toLong() * 100.0 / ROUND_BUDGET_NS
            Spacer(Modifier.height(10.dp))
            Text(
                "a client round costs %.1f%% of the 4 s round budget on this device".format(share),
                style = mono(11),
                color = if (r.medianNs.toLong() < ROUND_CEILING_NS) Ink.lichen else Ink.ember,
            )
        }
        Spacer(Modifier.height(10.dp))
        HouseButton("export csv", outline = true) {
            val report = when (benchMode) {
                BenchMode.SMOKE -> smokeReportCsv(
                    results,
                    "android",
                    "${Build.MANUFACTURER} ${Build.MODEL}",
                    "Android ${Build.VERSION.RELEASE} SDK ${Build.VERSION.SDK_INT}",
                    "${Build.FINGERPRINT}; app ${BuildConfig.VERSION_NAME}",
                )
                BenchMode.CORE_SWEEP -> coreSweepReportCsv(
                    results,
                    "android",
                    "${Build.MANUFACTURER} ${Build.MODEL}",
                    "Android ${Build.VERSION.RELEASE} SDK ${Build.VERSION.SDK_INT}",
                    "${Build.FINGERPRINT}; app ${BuildConfig.VERSION_NAME}",
                )
                BenchMode.BENCHMARK -> benchReportCsv(
                    results,
                    "android",
                    "${Build.MANUFACTURER} ${Build.MODEL}",
                    "Android ${Build.VERSION.RELEASE} SDK ${Build.VERSION.SDK_INT}",
                    "${Build.FINGERPRINT}; app ${BuildConfig.VERSION_NAME}",
                )
            }
            context.startActivity(
                Intent.createChooser(
                    Intent(Intent.ACTION_SEND).apply {
                        type = "text/csv"
                        putExtra(Intent.EXTRA_SUBJECT, "Panetiere Android benchmark")
                        putExtra(Intent.EXTRA_TEXT, report)
                    },
                    "Export benchmark",
                ),
            )
        }
    }
}

@Composable
private fun RoomScreen(dataDir: String, attested: Boolean) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var configToml by remember { mutableStateOf(DEFAULT_CONFIG) }
    var tag by remember { mutableStateOf("anymone.chat") }
    var status by remember { mutableStateOf("idle") }
    var attestation by remember { mutableStateOf("unattested") }
    var draft by remember { mutableStateOf("") }
    var messages by remember { mutableStateOf(listOf<Triple<String, ULong, Boolean>>()) }
    var client by remember { mutableStateOf<AnymoneClient?>(null) }
    var pipe by remember { mutableStateOf<AnymonePipe?>(null) }

    // Leaving the tab drops this composition; without the explicit stop the
    // native runtime, its transport and its storage lock outlive it.
    DisposableEffect(Unit) { onDispose { client?.stop() } }

    LaunchedEffect(client) {
        val c = client ?: return@LaunchedEffect
        while (true) {
            attestation = describe(c.attestationStatus())
            delay(1_000)
        }
    }

    SectionLabel("01", if (attested) "attested room" else "room", if (client == null) "not started" else "joined")

    if (client == null) {
        Text("SERVICE TAG", style = mono(10, FontWeight.Bold, 1.4), color = Ink.lichen)
        HouseField("anymone.chat", tag, { tag = it })
        Spacer(Modifier.height(12.dp))
        Text("CLIENT CONFIG", style = mono(10, FontWeight.Bold, 1.4), color = Ink.lichen)
        HouseField("client.toml", configToml, { configToml = it }, lines = 8)
        Spacer(Modifier.height(14.dp))
        HouseButton(if (attested) "start attested" else "start") {
            scope.launch {
                status = "awaiting signed config"
                // Owns the client until the composition does; a failed or
                // cancelled subscribe would otherwise leave it running.
                var pending: AnymoneClient? = null
                try {
                    val store = KeystoreSecretStore(context)
                    val c =
                        if (attested) {
                            AnymoneClient.startAttested(
                                configToml,
                                dataDir,
                                store,
                                MobileScheme.ANDROID_KEY_ATTESTATION,
                                AndroidKeyFetcher(),
                            )
                        } else {
                            AnymoneClient.start(configToml, dataDir, store)
                        }
                    pending = c
                    val p = c.subscribe(tag, 30_000u)
                    client = c
                    pipe = p
                    pending = null
                    status = "joined $tag"
                    scope.launch {
                        while (true) {
                            val m = p.recv() ?: break
                            messages = messages + Triple(String(m.payload), m.round, m.ownEcho)
                        }
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    status = "failed: ${e.message}"
                } finally {
                    pending?.stop()
                }
            }
        }
    } else {
        Hairline()
        if (messages.isEmpty()) {
            Row("no rounds decoded yet", "—", Ink.fog)
            Hairline()
        }
        messages.forEach { (text, round, own) ->
            Row(
                if (own) "SENT ✓  $text" else "r$round  $text",
                "",
                if (own) Ink.lichen else Ink.paper,
            )
            Hairline()
        }
        Spacer(Modifier.height(12.dp))
        HouseField("message", draft, { draft = it })
        Spacer(Modifier.height(10.dp))
        HouseButton("send", enabled = draft.isNotEmpty()) {
            val text = draft
            draft = ""
            scope.launch {
                runCatching { pipe?.send(text.toByteArray()) }
                    .onFailure { status = "send failed: ${it.message}" }
            }
        }
        Spacer(Modifier.height(8.dp))
        HouseButton("stop", outline = true) {
            client?.stop()
            client = null
            pipe = null
            status = "stopped"
        }
    }

    SectionLabel("02", "state")
    Hairline()
    Row("status", status, Ink.paper)
    Hairline()
    Row("round", client?.let { "${it.roundDurationMs()} ms" } ?: "—")
    Hairline()
    Row("queued", client?.let { "${it.queuedOutbound()} rounds" } ?: "—")
    Hairline()
    Row("attestation", attestation, Ink.paper)
    Hairline()
}

private fun describe(s: AttestationStatus): String =
    when (s) {
        is AttestationStatus.Unattested -> "unattested · open subnets only"
        is AttestationStatus.Cold -> "no token yet"
        is AttestationStatus.Pending -> "fetching for round ${s.round}"
        // Held locally; whether a relay accepted it is not visible from here.
        is AttestationStatus.Ready -> "token held · round ${s.round} · ${s.evidenceBytes} B"
        is AttestationStatus.Failed -> "failed: ${s.detail}"
    }

private fun format(ns: Long): String =
    if (ns > 1_000_000) "%.1f ms".format(ns / 1_000_000.0) else "%.0f µs".format(ns / 1_000.0)

private val DEFAULT_CONFIG =
    """
    # Copy from anymone's deploy/local/configs/client.toml, with the relay
    # addresses rewritten to the dev machine's LAN IP.
    [network]
    stream_bootstrappers = ["ed25519:<hex>@192.168.1.10:7620"]

    [governance]
    threshold = 2
    """
        .trimIndent()
