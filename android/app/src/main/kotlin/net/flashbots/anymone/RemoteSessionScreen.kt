package net.flashbots.anymone

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import net.flashbots.anymone.ffi.RemoteProtocolHost
import org.json.JSONObject
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.UUID

object RemoteHostController {
    var address by mutableStateOf("")
    var config by mutableStateOf("")
    var status by mutableStateOf("stopped")
        private set
    var participant by mutableStateOf("")
        private set
    var pairing by mutableStateOf("")
        private set
    var running by mutableStateOf(false)
        private set
    var starting by mutableStateOf(false)
        private set
    var discovery by mutableStateOf("not advertised")
        private set
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var host: RemoteProtocolHost? = null
    private var poll: Job? = null
    private var manager: NsdManager? = null
    private var registration: NsdManager.RegistrationListener? = null
    private var generation = 0
    private var stoppedCallback: (() -> Unit)? = null

    fun refreshAddress() {
        if (running || starting) return
        address = runCatching {
            NetworkInterface.getNetworkInterfaces().toList()
                .filter { it.isUp && !it.isLoopback }
                .sortedBy { if (it.name.startsWith("wlan")) 0 else 1 }
                .flatMap { it.inetAddresses.toList() }
                .filterIsInstance<Inet4Address>()
                .firstOrNull()?.hostAddress.orEmpty()
        }.getOrDefault("")
    }

    fun start(
        context: Context,
        onResult: (Result<String>) -> Unit = {},
        onStopped: () -> Unit = {},
    ) {
        if (running || starting) {
            onResult(Result.failure(IllegalStateException("host already active")))
            return
        }
        stoppedCallback = onStopped
        generation += 1
        val attempt = generation
        starting = true
        status = "starting developer host"
        val configuration = config
        val endpoint = "$address:0"
        scope.launch {
            try {
                val created = RemoteProtocolHost.startDeveloper(configuration, endpoint)
                if (attempt != generation) {
                    created.stop()
                    return@launch
                }
                host = created
                pairing = created.pairingJson()
                val info = JSONObject(pairing)
                val boundAddress = info.getString("address")
                val nsd = context.applicationContext.getSystemService(NsdManager::class.java)
                val service = NsdServiceInfo().apply {
                    serviceName = "Anymone-" + UUID.randomUUID().toString().take(8)
                    serviceType = "_anymone-remote._tcp."
                    port = boundAddress.substringAfterLast(":").toInt()
                    setAttribute("version", info.getInt("interface_version").toString())
                }
                val listener = object : NsdManager.RegistrationListener {
                    override fun onServiceRegistered(service: NsdServiceInfo) {
                        scope.launch { if (attempt == generation) discovery = service.serviceName }
                    }
                    override fun onRegistrationFailed(service: NsdServiceInfo, error: Int) {
                        scope.launch {
                            if (attempt == generation) discovery = "discovery failed $error; use the IP address"
                        }
                    }
                    override fun onServiceUnregistered(service: NsdServiceInfo) {}
                    override fun onUnregistrationFailed(service: NsdServiceInfo, error: Int) {
                        scope.launch {
                            if (attempt == generation) discovery = "discovery shutdown failed $error"
                        }
                    }
                }
                manager = nsd
                registration = listener
                discovery = "advertising"
                try {
                    nsd.registerService(service, NsdManager.PROTOCOL_DNS_SD, listener)
                } catch (error: Exception) {
                    registration = null
                    manager = null
                    discovery = "discovery failed: ${error.message}; use the IP address"
                }
                running = true
                starting = false
                status = boundAddress
                onResult(Result.success(pairing))
                poll = scope.launch {
                    while (attempt == generation) {
                        try {
                            val state = JSONObject(created.statusJson())
                            if (attempt != generation) break
                            if (state.getBoolean("closed")) { stop(); break }
                            participant = state.getString("participant")
                            status = "$boundAddress · round ${state.getLong("current_round")} · requests ${state.getLong("next_request")}"
                            delay(1000)
                        } catch (error: Exception) {
                            if (attempt == generation) status = "status failed: ${error.message}"
                            break
                        }
                    }
                }
            } catch (error: Exception) {
                if (attempt == generation) {
                    stop()
                    status = "failed: ${error.message}"
                    onResult(Result.failure(error))
                }
            }
        }
    }

    fun stop() {
        generation += 1
        poll?.cancel()
        poll = null
        registration?.let { listener ->
            runCatching { manager?.unregisterService(listener) }
        }
        registration = null
        manager = null
        val previous = host
        host = null
        pairing = ""
        participant = ""
        running = false
        starting = false
        discovery = "not advertised"
        status = "stopped"
        val notifyStopped = stoppedCallback
        stoppedCallback = null
        notifyStopped?.invoke()
        if (previous != null) scope.launch { previous.stop() }
    }
}

@Composable
fun RemoteSessionScreen() {
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val remote = RemoteHostController
    LaunchedEffect(Unit) { if (remote.address.isEmpty()) remote.refreshAddress() }
    SectionLabel("01", "remote", "developer keys")
    Text("Your computer controls the protocol client on this phone. Keep the app open while connected.",
        style = mono(11), color = Ink.fog)
    Spacer(Modifier.height(12.dp))
    if (!remote.running && !remote.starting) {
        OutlinedTextField(remote.address, { remote.address = it },
            label = { Text("LAN IPv4 address") }, modifier = Modifier.fillMaxWidth())
        HouseButton("refresh address", outline = true) { remote.refreshAddress() }
        OutlinedTextField(remote.config, { remote.config = it },
            label = { Text("Host configuration JSON") },
            modifier = Modifier.fillMaxWidth().height(190.dp))
        HouseButton("start developer host", enabled = remote.config.isNotBlank() && remote.address.isNotBlank()) {
            remote.start(context)
        }
    } else {
        HouseButton("stop", outline = true) { remote.stop() }
    }
    Spacer(Modifier.height(12.dp))
    Text(remote.status, style = mono(11), color = Ink.paper)
    if (remote.participant.isNotEmpty()) Text(remote.participant, style = mono(10), color = Ink.fog)
    Text(remote.discovery, style = mono(10), color = Ink.fog)
    if (remote.pairing.isNotEmpty()) {
        HouseButton("copy pairing data") { clipboard.setText(AnnotatedString(remote.pairing)) }
        Text("Pairing data grants control of this host. Share it with your computer.",
            style = mono(10), color = Ink.fog)
    }
    Text("Developer mode uses software keys. Platform attestation is disabled.",
        style = mono(10), color = Ink.lichen)
}
