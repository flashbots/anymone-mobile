package net.flashbots.anymone

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Same palette and type as the iOS shell and the decks. */
object Ink {
    val night = Color(0xFF080B09)
    val canopy = Color(0xFF112219)
    val lichen = Color(0xFFB7EE75)
    val moon = Color(0xFFE4FF8A)
    val paper = Color(0xFFEEF6E8)
    val fog = Color(0xFF9BAA9C)
    val ember = Color(0xFFFF6F52)
    val line = Color(0x38E4FF8A)
}

fun mono(size: Int, weight: FontWeight = FontWeight.Normal, tracking: Double = 0.0) =
    TextStyle(
        fontFamily = FontFamily.Monospace,
        fontSize = size.sp,
        fontWeight = weight,
        letterSpacing = tracking.sp,
    )

@Composable
fun AnymoneTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme =
            darkColorScheme(
                primary = Ink.moon,
                background = Ink.night,
                surface = Ink.night,
                onPrimary = Ink.night,
                onBackground = Ink.paper,
                onSurface = Ink.paper,
            ),
        content = content,
    )
}

@Composable
fun SectionLabel(index: String, title: String, trailing: String? = null) {
    Row(
        Modifier.fillMaxWidth().padding(top = 20.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.width(22.dp).height(1.dp).background(Ink.lichen))
        Spacer(Modifier.width(10.dp))
        Text(index, style = mono(11, FontWeight.Bold), color = Ink.ember)
        Spacer(Modifier.width(8.dp))
        Text(title.uppercase(), style = mono(11, FontWeight.Bold, 1.6), color = Ink.lichen)
        Spacer(Modifier.weight(1f))
        trailing?.let { Text(it, style = mono(10), color = Ink.fog) }
    }
}

@Composable
fun Hairline() {
    Box(Modifier.fillMaxWidth().height(1.dp).background(Ink.line))
}

@Composable
fun Row(key: String, value: String, accent: Color = Ink.moon) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 9.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(key, style = mono(12), color = Ink.fog)
        Text(value, style = mono(12, FontWeight.Medium), color = accent)
    }
}

@Composable
fun HouseButton(
    label: String,
    modifier: Modifier = Modifier,
    outline: Boolean = false,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Button(
        onClick = onClick,
        enabled = enabled,
        shape = RectangleShape,
        modifier = modifier.fillMaxWidth().height(44.dp),
        colors =
            ButtonDefaults.buttonColors(
                containerColor = if (outline) Color.Transparent else Ink.moon,
                contentColor = if (outline) Ink.lichen else Ink.night,
            ),
    ) {
        Text(label.uppercase(), style = mono(11, FontWeight.Black, 1.4))
    }
}

@Composable
fun HouseField(placeholder: String, value: String, onChange: (String) -> Unit, lines: Int = 1) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        placeholder = { Text(placeholder, style = mono(12), color = Ink.fog) },
        textStyle = mono(if (lines > 1) 10 else 12),
        singleLine = lines == 1,
        minLines = lines,
        shape = RectangleShape,
        modifier = Modifier.fillMaxWidth().background(Ink.canopy).border(1.dp, Ink.line),
        colors =
            TextFieldDefaults.colors(
                focusedTextColor = Ink.paper,
                unfocusedTextColor = Ink.paper,
                focusedContainerColor = Color.Transparent,
                unfocusedContainerColor = Color.Transparent,
                cursorColor = Ink.moon,
            ),
    )
}
