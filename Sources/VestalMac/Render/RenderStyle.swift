#if os(macOS)
import AppKit
import SwiftUI
import VestalCore

// MARK: - Render style
//
// Colours and fonts for the render model's nodes (EXTENSIBILITY.md §8.2,
// §8.3, §8.5): palette names resolved through the snapshot's `theme.colors`,
// font roles mapped to the system font's designs (or `theme.fonts`), and the
// icon mode of §16.1. The GTK UI's ThemeState does the same for Pango.

/// An sRGB colour with alpha, parsed from the model's `#rrggbbaa`.
struct RenderRGBA: Equatable {
    var r: Double, g: Double, b: Double, a: Double

    static let white = RenderRGBA(r: 1, g: 1, b: 1, a: 1)

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa`.
    init?(hex: String) {
        guard hex.hasPrefix("#") else { return nil }
        var digits = Array(hex.dropFirst())
        if digits.count == 3 || digits.count == 4 { digits = digits.flatMap { [$0, $0] } }
        guard digits.count == 6 || digits.count == 8,
              let value = UInt64(String(digits), radix: 16) else { return nil }
        let bytes = digits.count == 8 ? value : (value << 8) | 0xff
        r = Double((bytes >> 24) & 0xff) / 255
        g = Double((bytes >> 16) & 0xff) / 255
        b = Double((bytes >> 8) & 0xff) / 255
        a = Double(bytes & 0xff) / 255
    }

    func withAlpha(_ factor: Double) -> RenderRGBA { RenderRGBA(r: r, g: g, b: b, a: a * factor) }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

/// How icons are drawn on macOS (§16.1 `theme.icons`): `native` draws the
/// names the table knows as the SF Symbols v0.3 used, and everything else
/// in the bundled Phosphor font; `phosphor` always uses the font.
enum RenderIconMode: String {
    case native, phosphor
}

/// The resolved look of one snapshot's `theme`. A value: a theme op makes a
/// new one, and every node reads it from the environment.
struct RenderStyle {
    let theme: RenderTheme
    let iconMode: RenderIconMode
    private let palette: [String: RenderRGBA]

    init(_ theme: RenderTheme, iconMode: RenderIconMode? = nil) {
        self.theme = theme
        self.iconMode = iconMode ?? theme.icons.mode.flatMap(RenderIconMode.init(rawValue:)) ?? .native
        // Every palette name, resolved once (a name may name another).
        var palette: [String: RenderRGBA] = [:]
        for name in Set(theme.colors.keys).union(RenderTheme.tokyoNight.keys) {
            if let c = Self.resolve(name, theme: theme, depth: 0) { palette[name] = c }
        }
        self.palette = palette
    }

    static let `default` = RenderStyle(RenderTheme())

    // MARK: Colours

    /// A node colour: a palette name, `#hex`, or either with `@alpha`. An
    /// unknown name draws as `text`, as check-config promises (§8.3).
    func rgba(_ spec: String?, default fallback: String = "text") -> RenderRGBA {
        let spec = spec ?? fallback
        if let hit = palette[spec] { return hit }
        return Self.resolve(spec, theme: theme, depth: 0) ?? palette["text"] ?? .white
    }

    func color(_ spec: String?, default fallback: String = "text") -> Color {
        rgba(spec, default: fallback).color
    }

    private static func resolve(_ spec: String, theme: RenderTheme, depth: Int) -> RenderRGBA? {
        guard depth < 8 else { return nil }
        if let at = spec.lastIndex(of: "@"), let factor = Double(spec[spec.index(after: at)...]) {
            return resolve(String(spec[..<at]), theme: theme, depth: depth + 1)?.withAlpha(factor)
        }
        if spec.hasPrefix("#") { return RenderRGBA(hex: spec) }
        if let value = theme.colors[spec] { return resolve(value, theme: theme, depth: depth + 1) }
        if let value = RenderTheme.tokyoNight[spec] { return RenderRGBA(hex: value) }
        return nil
    }

    // MARK: Fonts

    /// The font for a text node: its role's family (§8.5), absolute size and
    /// numeric weight. The system font by default, as v0.3 draws: SF Pro,
    /// SF Mono for `mono`, SF Pro Rounded for `rounded`.
    func font(role: String, size: Double, weight: Int) -> Font {
        let w = Self.fontWeight(weight)
        let family: String?
        let design: Font.Design
        switch role {
        case "mono": family = theme.fonts.mono; design = .monospaced
        case "rounded": family = theme.fonts.rounded; design = .rounded
        default: family = theme.fonts.sans; design = .default
        }
        if let family, Self.hasFamily(family) {
            return Font.custom(family, fixedSize: CGFloat(size)).weight(w)
        }
        return .system(size: CGFloat(size), weight: w, design: design)
    }

    /// §8.4's names: 100 ultralight … 900 black; other numbers round to the
    /// nearest hundred.
    static func fontWeight(_ weight: Int) -> Font.Weight {
        switch (min(900, max(100, weight)) + 50) / 100 {
        case 1: return .ultraLight
        case 2: return .thin
        case 3: return .light
        case 4: return .regular
        case 5: return .medium
        case 6: return .semibold
        case 7: return .bold
        case 8: return .heavy
        default: return .black
        }
    }

    /// Families checked once each; a missing one falls back to the role's
    /// default and is logged once (§8.5).
    @MainActor private static var families: [String: Bool] = [:]

    private static func hasFamily(_ family: String) -> Bool {
        MainActor.assumeIsolated {
            if let known = families[family] { return known }
            let found = NSFontManager.shared.availableMembers(ofFontFamily: family) != nil
                || NSFont(name: family, size: 12) != nil
            if !found { NSLog("%@", "[vestal] font family \(family) not found; using the default") }
            families[family] = found
            return found
        }
    }
}

// MARK: - Environment

private struct RenderStyleKey: EnvironmentKey {
    static let defaultValue = RenderStyle.default
}

private struct RenderSendKey: EnvironmentKey {
    static let defaultValue: (RenderInput) -> Void = { _ in }
}

extension EnvironmentValues {
    /// The snapshot's theme, for every node under the stage.
    var renderStyle: RenderStyle {
        get { self[RenderStyleKey.self] }
        set { self[RenderStyleKey.self] = newValue }
    }

    /// Where clicks go (`invoke`, and `escape` from the scrim).
    var renderSend: (RenderInput) -> Void {
        get { self[RenderSendKey.self] }
        set { self[RenderSendKey.self] = newValue }
    }
}
#endif
