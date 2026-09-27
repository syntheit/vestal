#if os(Linux)
import CGtk4
import Foundation
import VestalCore

// MARK: - Theme
//
// Colours and fonts for the nodes: palette names resolved through the
// snapshot's `theme.colors` (§10.2), font roles mapped to families (§8.5),
// and the bundled fonts registered with fontconfig.

struct RGBA: Equatable {
    var r: Double, g: Double, b: Double, a: Double

    static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)

    var gdk: GdkRGBA { GdkRGBA(red: Float(r), green: Float(g), blue: Float(b), alpha: Float(a)) }

    func withAlpha(_ factor: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: a * factor) }

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

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// For CSS: `rgba(r, g, b, a)`.
    var css: String {
        "rgba(\(Int((r * 255).rounded())), \(Int((g * 255).rounded())), \(Int((b * 255).rounded())), \(String(format: "%.3f", a)))"
    }
}

/// The resolved look of one snapshot's `theme`.
final class ThemeState {
    let theme: RenderTheme
    private var cache: [String: RGBA] = [:]

    init(_ theme: RenderTheme) {
        self.theme = theme
    }

    /// A node colour: a palette name, `#hex`, or either with `@alpha`. An
    /// unknown name draws as `text`, as check-config promises (§8.3).
    func color(_ spec: String?, default fallback: String = "text") -> RGBA {
        let spec = spec ?? fallback
        if let hit = cache[spec] { return hit }
        let resolved = resolve(spec, depth: 0) ?? resolve("text", depth: 0) ?? .white
        cache[spec] = resolved
        return resolved
    }

    private func resolve(_ spec: String, depth: Int) -> RGBA? {
        guard depth < 8 else { return nil }
        if let at = spec.lastIndex(of: "@"), let factor = Double(spec[spec.index(after: at)...]) {
            return resolve(String(spec[..<at]), depth: depth + 1)?.withAlpha(factor)
        }
        if spec.hasPrefix("#") { return RGBA(hex: spec) }
        if let value = theme.colors[spec] { return resolve(value, depth: depth + 1) }
        if let value = RenderTheme.tokyoNight[spec] { return RGBA(hex: value) }
        return nil
    }

    // MARK: Fonts

    /// The Pango family list for a font role. Inter and JetBrains Mono ship
    /// with the Linux package (the macOS UI uses SF Pro and SF Mono); the
    /// fontconfig generics follow as fallbacks.
    func family(role: String) -> String {
        switch role {
        case "mono": return (theme.fonts.mono.map { "\($0)," } ?? "") + "JetBrains Mono,monospace"
        case "rounded":
            // No rounded Inter; the rounded role falls back to sans (§8.5).
            let family = theme.fonts.rounded ?? theme.fonts.sans
            return (family.map { "\($0)," } ?? "") + "Inter,sans-serif"
        default: return (theme.fonts.sans.map { "\($0)," } ?? "") + "Inter,sans-serif"
        }
    }

    /// The icon font family for a weight (`regular` or `fill`).
    func iconFamily(weight: String) -> String {
        theme.icons.fonts[weight] ?? (weight == "fill" ? "Phosphor-Fill" : "Phosphor")
    }

    /// The background behind the dashboard: the palette's `bg`, translucent
    /// over the compositor's blur for `aurora` and `blur`, opaque for `none`.
    var windowBackground: RGBA {
        let bg = color("bg")
        return theme.background == "none" ? bg.withAlpha(1) : bg.withAlpha(Self.dimAlpha)
    }

    /// How much of `bg` lies over the (blurred) desktop. With Hyprland's blur
    /// this reads like the macOS HUD material; without blur it is a plain dim.
    static let dimAlpha = 0.62
}

// MARK: - Bundled fonts

enum BundledFonts {
    private static var registered = false

    /// Adds Inter, JetBrains Mono and the Phosphor icon fonts to fontconfig
    /// for this process, before GTK loads any font. Looked up in
    /// `$VESTAL_FONT_DIRS` (colon-separated, for dev builds) and next to the
    /// executable in `share/vestal/{fonts,icons}` (the Nix package).
    static func register() {
        guard !registered else { return }
        registered = true
        var dirs: [String] = []
        if let env = ProcessInfo.processInfo.environment["VESTAL_FONT_DIRS"] {
            dirs += env.split(separator: ":").map(String.init)
        }
        let exe = URL(fileURLWithPath: CommandLine.executablePath).resolvingSymlinksInPath().deletingLastPathComponent()
        for up in ["..", "../.."] {
            let share = exe.appendingPathComponent(up).appendingPathComponent("share/vestal").standardized
            dirs.append(share.appendingPathComponent("fonts").path)
            dirs.append(share.appendingPathComponent("icons").path)
        }
        var added = 0
        for dir in dirs where FileManager.default.fileExists(atPath: dir) {
            if FcConfigAppFontAddDir(nil, dir) != 0 { added += 1 }
        }
        if added == 0 {
            uiLog("linux ui: no bundled font directory found; icons will not draw (set VESTAL_FONT_DIRS)")
        }
    }
}

extension CommandLine {
    /// This executable's path, from /proc (argv[0] may be relative or a
    /// wrapper's).
    static var executablePath: String {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")) ?? arguments[0]
    }
}
#endif
