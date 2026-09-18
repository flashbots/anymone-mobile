package net.flashbots.anymone

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.util.Log
import org.json.JSONObject

object DebugRemoteHost {
    private var ownsSession = false

    fun start(context: Context, intent: Intent): Boolean {
        if (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0 ||
            intent.action != "net.flashbots.anymone.START_REMOTE_DEVELOPER"
        ) return false
        val app = context.applicationContext
        val remote = RemoteClientSessionService
        if (remote.running) {
            if (ownsSession) report(app, "ready", pairing = remote.pairing)
            else report(app, "error", error = "stop the manually started host first")
            return true
        }
        if (remote.starting) {
            if (!ownsSession) report(app, "error", error = "a manual session start is in progress")
            return true
        }
        report(app, "starting")
        ownsSession = true
        remote.start(app, "127.0.0.1")
        return true
    }

    internal fun ready(context: Context, pairing: String) {
        if (ownsSession) report(context, "ready", pairing)
    }

    internal fun stopped(context: Context, error: String?) {
        if (!ownsSession) return
        ownsSession = false
        report(context, if (error == null) "stopped" else "error", error = error)
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
            Log.e("RemoteClientSession", "Could not write debug session result", failure)
        }
    }
}
