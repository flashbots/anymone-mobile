package net.flashbots.anymone

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.util.Log
import org.json.JSONObject

object DebugRemoteHost {
    private var ownsHost = false

    fun start(context: Context, intent: Intent): Boolean {
        if (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0 ||
            intent.action != "net.flashbots.anymone.START_REMOTE_DEVELOPER"
        ) return false
        val app = context.applicationContext
        val remote = RemoteHostController
        if (remote.running) {
            if (ownsHost) report(app, "ready", pairing = remote.pairing)
            else report(app, "error", error = "stop the manually started host first")
            return true
        }
        if (remote.starting) {
            if (!ownsHost) report(app, "error", error = "a manual host start is in progress")
            return true
        }
        report(app, "starting")
        try {
            val file = app.getFileStreamPath("remote-host-config.json")
            require(file.length() <= 1024 * 1024) { "host configuration exceeds 1 MiB" }
            remote.config = file.readText()
            remote.address = "127.0.0.1"
            ownsHost = true
            remote.start(
                app,
                onResult = { result ->
                    result.fold(
                        onSuccess = { report(app, "ready", pairing = it) },
                        onFailure = { report(app, "error", error = it.message ?: it.toString()) },
                    )
                },
                onStopped = { ownsHost = false; report(app, "stopped") },
            )
        } catch (error: Exception) {
            ownsHost = false
            report(app, "error", error = error.message ?: error.toString())
        }
        return true
    }

    private fun report(context: Context, state: String, pairing: String? = null, error: String? = null) {
        val result = JSONObject().put("state", state)
        if (pairing != null) result.put("pairing", JSONObject(pairing))
        if (error != null) result.put("error", error)
        try {
            context.openFileOutput("remote-host-result.json", Context.MODE_PRIVATE).bufferedWriter().use {
                it.write(result.toString())
            }
        } catch (failure: Exception) {
            Log.e("RemoteHost", "Could not write debug host result", failure)
        }
    }
}
