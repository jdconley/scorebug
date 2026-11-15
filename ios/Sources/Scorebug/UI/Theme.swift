import ScorebugCore
import SwiftUI

/// Dark, camera-first. Live red is reserved for LIVE and Go live.
enum Theme {
    static let ground = Color(hex: "#0B0D10")
    static let surface = Color(hex: "#16191E")
    static let raised = Color(hex: "#1B1F25")
    static let line = Color(hex: "#262A30")
    static let text = Color(hex: "#F2F4F7")
    static let secondary = Color(hex: "#9AA3AE") // 7.6:1 on ground, 6.7:1 on surface
    static let muted = Color(hex: "#C9CED6")
    static let live = Color(hex: "#E5372C")
    static let ok = Color(hex: "#22C55E")
    static let warn = Color(hex: "#F5A524")
    static let scrim = Color(hex: "#0B0D10").opacity(0.78)

    /// Condensed numerals and team labels (Barlow Condensed, OFL, bundled).
    static func score(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .custom(weight == .bold ? "BarlowCondensed-Bold" : "BarlowCondensed-SemiBold", size: size, relativeTo: .largeTitle)
    }

    static func teamColor(_ hex: String?) -> Color { Color(hex: hex ?? "#9AA3AE") }
    static func onTeam(_ hex: String?) -> Color {
        TeamPalette.prefersDarkText(on: hex ?? "#000000") ? ground : .white
    }
}

extension Color {
    init(hex: String) {
        let (r, g, b) = TeamPalette.components(hex) ?? (0.6, 0.64, 0.68)
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

/// Section labels: "LAST MATCH", "TEAM 1".
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.footnote.weight(.semibold)).kerning(1)
            .foregroundStyle(Theme.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

enum ButtonKind { case primary, live, surface }

struct BigButtonStyle: ButtonStyle {
    var kind: ButtonKind = .primary
    var height: CGFloat = 60
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: kind == .surface ? 16 : 18, weight: kind == .surface ? .semibold : .bold))
            .frame(maxWidth: .infinity, minHeight: height)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Rectangle())
    }
    private var foreground: Color { kind == .primary ? Theme.ground : Theme.text }
    private var background: Color {
        switch kind {
        case .primary: Theme.text
        case .live: Theme.live
        case .surface: Theme.surface
        }
    }
}

/// Small translucent controls over the camera picture.
struct OverlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14).frame(minHeight: 44)
            .background(Theme.scrim, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A team color bar followed by its short name.
struct TeamChip: View {
    let team: MatchTeam?
    var size: CGFloat = 22
    var trailingBar = false
    var dim = false
    var body: some View {
        HStack(spacing: 8) {
            if !trailingBar { bar }
            Text(team?.shortName ?? "—")
                .font(Theme.score(size))
                .foregroundStyle(dim ? Theme.secondary : Theme.text)
                .lineLimit(1)
            if trailingBar { bar }
        }
    }
    private var bar: some View {
        RoundedRectangle(cornerRadius: 3).fill(Theme.teamColor(team?.color))
            .frame(width: 6, height: size * 1.1)
            .accessibilityHidden(true)
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true) }
}

extension View {
    func screenBackground() -> some View {
        background(Theme.ground.ignoresSafeArea())
    }
}
