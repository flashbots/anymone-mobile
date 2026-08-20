import SwiftUI

/// The deck's palette and type: night ground, lichen labels, moon values,
/// ember counters, hairline rules, monospace everywhere.
enum Ink {
    static let night = Color(hex: 0x080b09)
    static let canopy = Color(hex: 0x112219)
    static let moss = Color(hex: 0x173d28)
    static let lichen = Color(hex: 0xb7ee75)
    static let moon = Color(hex: 0xe4ff8a)
    static let paper = Color(hex: 0xeef6e8)
    static let fog = Color(hex: 0x9baa9c)
    static let ember = Color(hex: 0xff6f52)
    static let violet = Color(hex: 0xbaa8ff)
    static let line = Color(hex: 0xe4ff8a).opacity(0.22)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255)
    }
}

extension Font {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// `01 · BENCH` with the deck's leading rule.
struct SectionLabel: View {
    let index: String
    let title: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Ink.lichen).frame(width: 22, height: 1)
            Text(index).font(.mono(11, .bold)).foregroundStyle(Ink.ember)
            Text(title.uppercased())
                .font(.mono(11, .bold))
                .tracking(1.6)
                .foregroundStyle(Ink.lichen)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).font(.mono(10)).foregroundStyle(Ink.fog)
            }
        }
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Ink.line).frame(height: 1) }
}

/// Key on the left in fog, value on the right in moon — the deck's annotation
/// rhythm, which reads well for live protocol state.
struct Row: View {
    let key: String
    let value: String
    var accent: Color = Ink.moon

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(.mono(12)).foregroundStyle(Ink.fog)
            Spacer(minLength: 12)
            Text(value)
                .font(.mono(12, .medium))
                .foregroundStyle(accent)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 9)
    }
}

struct HouseButton: ButtonStyle {
    var outline = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mono(11, .heavy))
            .tracking(1.4)
            .textCase(.uppercase)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .foregroundStyle(outline ? Ink.lichen : Ink.night)
            .background(outline ? Color.clear : Ink.moon)
            .overlay(Rectangle().stroke(outline ? Ink.lichen.opacity(0.5) : Ink.moon, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct HouseField: View {
    let placeholder: String
    @Binding var text: String
    var monoSize: CGFloat = 12

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Ink.fog))
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(.mono(monoSize))
            .foregroundStyle(Ink.paper)
            .padding(10)
            .background(Ink.canopy.opacity(0.55))
            .overlay(Rectangle().stroke(Ink.line, lineWidth: 1))
    }
}

/// Night ground plus the deck's two corner glows.
struct Ground<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Ink.night.ignoresSafeArea()
            RadialGradient(
                colors: [Ink.moss.opacity(0.5), .clear], center: .init(x: 0.85, y: 0.02),
                startRadius: 0, endRadius: 420
            )
            .ignoresSafeArea()
            RadialGradient(
                colors: [Ink.violet.opacity(0.10), .clear], center: .init(x: 0.08, y: 0.7),
                startRadius: 0, endRadius: 340
            )
            .ignoresSafeArea()
            content
        }
        .tint(Ink.moon)
    }
}
