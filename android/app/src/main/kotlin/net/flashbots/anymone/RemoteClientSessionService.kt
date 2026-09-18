package net.flashbots.anymone

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.IBinder
import android.os.PowerManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import net.flashbots.anymone.ffi.RemoteProtocolHost
import org.json.JSONObject
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.UUID

class RemoteClientSessionService : Service() {
    companion object {
        private const val LISTEN_ADDRESS = "listenAddress"
        private const val NOTIFICATION_CHANNEL = "remote_client_session"
        private const val NOTIFICATION_ID = 1

        var address by mutableStateOf("")
        var endpoint by mutableStateOf("")
            private set
        var status by mutableStateOf("Stopped")
            private set
        var activity by mutableStateOf("Session is not running")
            private set
        var issue by mutableStateOf<String?>(null)
            private set
        var running by mutableStateOf(false)
            private set
        var starting by mutableStateOf(false)
            private set
        var connected by mutableStateOf(false)
            private set
        var participant by mutableStateOf("")
            private set
        var protocol by mutableStateOf("")
            private set
        var currentRound by mutableStateOf<Long?>(null)
            private set
        var requestsProcessed by mutableStateOf(0L)
            private set
        var pendingMessages by mutableStateOf<Long?>(null)
            private set
        var pairing by mutableStateOf("")
            private set
        var pairingCode by mutableStateOf("")
            private set
        var discovery by mutableStateOf("Not advertised")
            private set

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

        fun start(context: Context, listenAddress: String) {
            if (running || starting) return
            address = listenAddress
            status = "Starting"
            activity = "Starting developer host"
            issue = null
            starting = true
            try {
                context.startForegroundService(
                    Intent(context, RemoteClientSessionService::class.java)
                        .putExtra(LISTEN_ADDRESS, listenAddress),
                )
            } catch (error: Exception) {
                starting = false
                status = "Failed"
                activity = "Developer host did not start"
                issue = error.message ?: error.toString()
                DebugRemoteHost.stopped(context, issue)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, RemoteClientSessionService::class.java))
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var host: RemoteProtocolHost? = null
    private var poll: Job? = null
    private var manager: NsdManager? = null
    private var registration: NsdManager.RegistrationListener? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var generation = 0
    private var finalStatus = "Stopped"
    private var finalActivity = "Session stopped"
    private var finalIssue: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val listenAddress = intent?.getStringExtra(LISTEN_ADDRESS) ?: return START_NOT_STICKY
        generation += 1
        val attempt = generation
        startForeground(NOTIFICATION_ID, notification())
        acquireWakeLock()
        scope.launch {
            try {
                val created = RemoteProtocolHost.startDeveloper("$listenAddress:0")
                if (attempt != generation) {
                    created.stop()
                    return@launch
                }
                host = created
                pairing = created.pairingJson()
                pairingCode = created.pairingCode()
                endpoint = JSONObject(pairing).getString("address")
                advertise(attempt)
                running = true
                starting = false
                status = "Waiting"
                activity = "Waiting for desktop"
                notifyStatus()
                DebugRemoteHost.ready(this@RemoteClientSessionService, pairing)
                poll = scope.launch { poll(created, attempt) }
            } catch (error: Exception) {
                if (attempt == generation) {
                    finish("Failed", "Developer host did not start", error.message ?: error.toString())
                }
            }
        }
        return START_NOT_STICKY
    }

    private suspend fun poll(created: RemoteProtocolHost, attempt: Int) {
        while (attempt == generation) {
            try {
                val remote = JSONObject(created.statusJson())
                val paired = remote.getBoolean("paired")
                val attempts = remote.getInt("pairing_attempts_remaining")
                connected = remote.getBoolean("connected")
                activity = remote.getString("last_activity")
                if (!remote.isNull("last_error")) issue = remote.getString("last_error")
                val client = remote.optJSONObject("client")
                participant = client?.optString("participant").orEmpty()
                protocol = client?.optString("protocol").orEmpty()
                currentRound = client?.optLong("current_round")
                requestsProcessed = remote.getLong("next_request")
                pendingMessages = client?.optLong("pending_messages")
                if (paired || attempts == 0) pairingCode = ""
                status = when {
                    remote.getBoolean("closed") -> "Closed"
                    !paired && attempts == 0 -> "Pairing locked"
                    connected -> "Connected"
                    paired -> "Disconnected"
                    else -> "Waiting"
                }
                notifyStatus()
                if (remote.getBoolean("closed")) {
                    finish("Closed", activity, issue)
                    return
                }
                delay(1000)
            } catch (error: Exception) {
                if (attempt == generation) {
                    finish("Failed", "Could not read host status", error.message ?: error.toString())
                }
                return
            }
        }
    }

    private fun advertise(attempt: Int) {
        val nsd = applicationContext.getSystemService(NsdManager::class.java)
        val service = NsdServiceInfo().apply {
            serviceName = "Anymone-" + UUID.randomUUID().toString().take(8)
            serviceType = "_anymone-remote._tcp."
            port = endpoint.substringAfterLast(":").toInt()
            setAttribute("pairing", "code")
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(service: NsdServiceInfo) {
                scope.launch {
                    if (attempt == generation) {
                        discovery = service.serviceName
                        notifyStatus()
                    }
                }
            }

            override fun onRegistrationFailed(service: NsdServiceInfo, error: Int) {
                scope.launch {
                    if (attempt == generation) {
                        discovery = "Discovery failed $error; use $endpoint"
                        issue = discovery
                        notifyStatus()
                    }
                }
            }

            override fun onServiceUnregistered(service: NsdServiceInfo) {}

            override fun onUnregistrationFailed(service: NsdServiceInfo, error: Int) {
                scope.launch {
                    if (attempt == generation) {
                        issue = "Discovery shutdown failed $error"
                        notifyStatus()
                    }
                }
            }
        }
        manager = nsd
        registration = listener
        discovery = "Advertising"
        try {
            nsd.registerService(service, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (error: Exception) {
            registration = null
            manager = null
            discovery = "Discovery failed; use $endpoint"
            issue = error.message ?: error.toString()
        }
    }

    private fun finish(status: String, activity: String, issue: String?) {
        finalStatus = status
        finalActivity = activity
        finalIssue = issue
        stopSelf()
    }

    private fun notification(): Notification {
        val notifications = getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL,
                "Remote client session",
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, NOTIFICATION_CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("Anymone remote client · $status")
            .setContentText(issue?.let { "Issue: $it" } ?: activity)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    private fun notifyStatus() {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification())
    }

    @SuppressLint("WakelockTimeout")
    private fun acquireWakeLock() {
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Anymone:RemoteClientSession")
            .apply {
                setReferenceCounted(false)
                acquire()
            }
    }

    override fun onDestroy() {
        generation += 1
        poll?.cancel()
        registration?.let { listener -> runCatching { manager?.unregisterService(listener) } }
        wakeLock?.let { if (it.isHeld) it.release() }
        val previous = host
        host = null
        pairing = ""
        pairingCode = ""
        endpoint = ""
        participant = ""
        protocol = ""
        currentRound = null
        pendingMessages = null
        requestsProcessed = 0
        connected = false
        starting = false
        running = false
        discovery = "Not advertised"
        status = finalStatus
        activity = finalActivity
        issue = finalIssue
        DebugRemoteHost.stopped(this, finalIssue)
        stopForeground(STOP_FOREGROUND_REMOVE)
        if (previous == null) {
            scope.cancel()
        } else {
            scope.launch {
                previous.stop()
                scope.cancel()
            }
        }
        super.onDestroy()
    }
}
