package net.flashbots.anymone

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp

@Composable
fun RemoteSessionScreen() {
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val remote = RemoteClientSessionService
    var automation by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { if (remote.address.isEmpty()) remote.refreshAddress() }
    SectionLabel("01", "remote", "developer keys")
    Text("Your computer controls the protocol client on this phone. The session continues while the screen is locked.",
        style = mono(11), color = Ink.fog)
    Spacer(Modifier.height(12.dp))
    if (!remote.running && !remote.starting) {
        OutlinedTextField(remote.address, { remote.address = it },
            label = { Text("LAN IPv4 address") }, modifier = Modifier.fillMaxWidth())
        HouseButton("refresh address", outline = true) { remote.refreshAddress() }
        HouseButton("start developer host", enabled = remote.address.isNotBlank()) {
            remote.start(context, remote.address)
        }
    } else {
        HouseButton("stop", outline = true) { remote.stop(context) }
    }
    Spacer(Modifier.height(12.dp))
    Text("STATE  ${remote.status}", style = mono(11), color = Ink.paper)
    Text("ACTIVITY  ${remote.activity}", style = mono(11), color = Ink.moon)
    remote.issue?.let { Text("ISSUE  $it", style = mono(11), color = Ink.ember) }
    if (remote.endpoint.isNotEmpty()) Text(remote.endpoint, style = mono(10), color = Ink.fog)
    if (remote.protocol.isNotEmpty()) {
        Text(
            "${remote.protocol} · round ${remote.currentRound} · ${remote.requestsProcessed} requests · ${remote.pendingMessages} pending",
            style = mono(10),
            color = Ink.fog,
        )
    }
    if (remote.participant.isNotEmpty()) Text(remote.participant, style = mono(10), color = Ink.fog)
    Text(remote.discovery, style = mono(10), color = Ink.fog)
    if (remote.pairingCode.isNotEmpty()) {
        Text("PAIRING CODE", style = mono(10), color = Ink.lichen)
        Text(remote.pairingCode.chunked(4).joinToString(" "), style = mono(24), color = Ink.moon)
        Text("Select this phone on your computer and enter this code.", style = mono(11), color = Ink.fog)
    }
    if (remote.pairing.isNotEmpty()) {
        TextButton(onClick = { automation = !automation }) { Text("Automation", style = mono(11)) }
        if (automation) {
            HouseButton("copy pairing data", outline = true) { clipboard.setText(AnnotatedString(remote.pairing)) }
            Text("For automated test drivers. Pairing data grants control of this host.",
                style = mono(10), color = Ink.fog)
        }
    }
    Text("Developer mode uses software keys. Platform attestation is disabled.",
        style = mono(10), color = Ink.lichen)
}
