#if os(Linux)
import CGtk4
import Foundation
import VestalCore

// MARK: - Theme
//
// Colours and fonts for the nodes: palette names resolved through the
// snapshot's `theme.colors`, font roles mapped to families,
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
}

/// The resolved look of one snapshot's `theme`.
final class ThemeState {
    let theme: RenderTheme
    private var cache: [String: RGBA] = [:]

    init(_ theme: RenderTheme) {
        self.theme = theme
    }

    /// A node colour: a palette name, `#hex`, or either with `@alpha`. An
    /// unknown name draws as `text`, as check-config promises.
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

    /// The Pango family list for a font role. Geist and Geist Mono ship with
    /// the Linux package (the macOS UI uses SF Pro and SF Mono, which they
    /// resemble); the fontconfig generics follow as fallbacks.
    func family(role: String) -> String {
        switch role {
        case "mono": return (theme.fonts.mono.map { "\($0)," } ?? "") + "Geist Mono,monospace"
        case "rounded":
            // No rounded Geist; the rounded role falls back to sans.
            let family = theme.fonts.rounded ?? theme.fonts.sans
            return (family.map { "\($0)," } ?? "") + "Geist,sans-serif"
        case "display":
            let family = theme.fonts.display ?? theme.fonts.sans
            return (family.map { "\($0)," } ?? "") + "Geist,sans-serif"
        case "sans": return (theme.fonts.sans.map { "\($0)," } ?? "") + "Geist,sans-serif"
        // A family name (`style.font`): Pango tries the list in order, so one
        // that is not installed draws as sans.
        default: return "\(role)," + family(role: "sans")
        }
    }

    /// The weight a text node draws with: one step heavier below bold
    /// (`FontRendering.weightOffset`), within Pango's 100...1000.
    func weight(_ weight: Int) -> Int {
        let heavier = weight < 700 ? min(700, weight + FontRendering.weightOffset) : weight
        return min(1000, max(100, heavier))
    }

    /// The icon font family for a weight (`regular` or `fill`).
    func iconFamily(weight: String) -> String {
        theme.icons.fonts[weight] ?? (weight == "fill" ? "Phosphor-Fill" : "Phosphor")
    }

    /// The background behind the dashboard: the palette's `bg`, at
    /// `theme.dim` (default `RenderTheme.linuxDim`) over the compositor's
    /// blur for `aurora` and `blur`, opaque for `none`. `dim` must stay above
    /// the `ignore_alpha` layer rule (0.3 by default), or Hyprland blurs only
    /// the aurora's ribbons; check-config warns. Without blur it is a plain
    /// dim. The window's CSS is `RenderTheme.linuxWindowCSS`, the same colour.
    var windowBackground: RGBA {
        color("bg").withAlpha(theme.windowAlpha(defaultDim: RenderTheme.linuxDim))
    }

    /// The same colour over a self-blurred backdrop, which the aurora's GL
    /// area lays itself (the window is clear then).
    var backdropTint: RGBA { windowBackground }
}

// MARK: - Font rendering

/// How this process draws text, closer to macOS's heavier glyphs (compared
/// in docs/screenshots/linux/fonts): FreeType's stem darkening, which
/// thickens stems at text sizes (for CFF fonts, and for TrueType ones
/// through the autofitter GTK's slight hinting uses), and one weight step
/// up for text below bold (`ThemeState.weight`). GTK's own automatic
/// options stay: grayscale antialiasing, slight hinting, subpixel
/// positioning, unhinted metrics (none or full hinting and hinted metrics
/// looked no better).
///
/// GTK's glyphs go through cairo's FreeType library, which reads
/// `FREETYPE_PROPERTIES` once, when it is created. The variable is set
/// for that moment only (a value the user set wins and stays), so the
/// programs vestal starts (actions, terminals) don't inherit it.
enum FontRendering {
    static let freetypeProperties = "cff:no-stem-darkening=0 autofitter:no-stem-darkening=0"
    private static var setByUs = false

    /// Before GTK starts.
    static func prepare() {
        guard getenv("FREETYPE_PROPERTIES") == nil else { return }
        setenv("FREETYPE_PROPERTIES", freetypeProperties, 1)
        setByUs = true
    }

    /// After GTK started: draws one glyph through cairo, which creates its
    /// FreeType library with the properties, then unsets the variable.
    static func apply() {
        guard setByUs else { return }
        setByUs = false
        if let surface = cairo_image_surface_create(CAIRO_FORMAT_A8, 8, 8) {
            let cr = cairo_create(surface)
            let layout = pango_cairo_create_layout(cr)
            pango_layout_set_text(layout, "x", -1)
            pango_cairo_show_layout(cr, layout)
            g_object_unref(UnsafeMutableRawPointer(layout))
            cairo_destroy(cr)
            cairo_surface_destroy(surface)
        }
        unsetenv("FREETYPE_PROPERTIES")
    }

    /// Added to every text weight below bold (700): 400 draws as 500, 600
    /// as 700. `VESTAL_FONT_WEIGHT_OFFSET` (0 to 300) changes it; 0 draws
    /// the weights as given.
    static let weightOffset: Int = {
        guard let value = ProcessInfo.processInfo.environment["VESTAL_FONT_WEIGHT_OFFSET"], let offset = Int(value) else { return 100 }
        return min(300, max(0, offset))
    }()
}

// MARK: - Bundled fonts

enum BundledFonts {
    private static var registered = false

    /// Adds the typefaces (Geist, Inter, Plex, ... one directory per family, see
    /// Resources/fonts) and the Phosphor icon fonts to fontconfig
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
