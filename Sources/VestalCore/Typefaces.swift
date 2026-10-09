import Foundation

// MARK: - Typefaces
//
// A typeface is a named set of font families that fills the four roles at
// once (`theme.typeface`): `display` for clocks and big numbers, `sans`,
// `mono` and `rounded`. `theme.fonts` entries override the set's roles. The
// families listed here ship with vestal (Resources/fonts) and are
// registered with the platform's font system when the UI starts; a family
// that is neither bundled nor installed falls back to the role's default.

public struct Typeface: Equatable, Sendable {
    public let name: String
    /// One line for the docs and `vestal schema`.
    public let summary: String
    /// A family per role; nil is the platform default.
    public let display: String?
    public let sans: String?
    public let mono: String?
    public let rounded: String?

    public var fonts: RenderTheme.Fonts {
        RenderTheme.Fonts(sans: sans, mono: mono, rounded: rounded, display: display)
    }
}

public enum Typefaces {
    public static let defaultName = "system"

    public static let all: [Typeface] = [
        Typeface(name: "system", summary: "The platform's own fonts: SF Pro and SF Mono on macOS, Geist and Geist Mono on Linux.",
                 display: nil, sans: nil, mono: nil, rounded: nil),
        Typeface(name: "geist", summary: "Geist and Geist Mono: neutral and a little technical.",
                 display: "Geist Mono", sans: "Geist", mono: "Geist Mono", rounded: "Geist"),
        Typeface(name: "inter", summary: "Inter, with Inter Tight for the clock and JetBrains Mono for values.",
                 display: "Inter Tight", sans: "Inter", mono: "JetBrains Mono", rounded: "Inter"),
        Typeface(name: "plex", summary: "IBM Plex Sans and IBM Plex Mono: squarer and warmer than Inter.",
                 display: "IBM Plex Sans", sans: "IBM Plex Sans", mono: "IBM Plex Mono", rounded: "IBM Plex Sans"),
        Typeface(name: "instrument", summary: "Instrument Serif for the clock, Instrument Sans for the rest, JetBrains Mono for values.",
                 display: "Instrument Serif", sans: "Instrument Sans", mono: "JetBrains Mono", rounded: "Instrument Sans"),
        Typeface(name: "fira", summary: "Fira Code in every role. The palette is unchanged.",
                 display: "Fira Code", sans: "Fira Code", mono: "Fira Code", rounded: "Fira Code"),
    ]

    public static var names: [String] { all.map(\.name) }

    public static func named(_ name: String?) -> Typeface? {
        guard let name else { return nil }
        return all.first { $0.name == name }
    }

    /// The four roles `theme.fonts` and `style.font` take.
    public static let roles = ["display", "sans", "mono", "rounded"]

    /// The families that ship in `Resources/fonts`: the typefaces' and the
    /// clock faces' own.
    public static let bundled: [String] = [
        "Big Shoulders Display", "Fira Code", "Geist", "Geist Mono", "IBM Plex Mono", "IBM Plex Sans",
        "Instrument Sans", "Instrument Serif", "Inter", "Inter Tight", "JetBrains Mono", "Manrope", "Nunito",
        "Space Grotesk",
    ]

    public static func isBundled(_ family: String) -> Bool {
        bundled.contains { $0.caseInsensitiveCompare(family) == .orderedSame }
    }

    /// The fonts of a config's `theme`: the typeface's roles, then
    /// `theme.fonts` over them (and the older `theme.font` for sans).
    public static func fonts(theme: [String: AnyJSON]) -> RenderTheme.Fonts {
        var fonts = named(theme["typeface"]?.stringValue)?.fonts ?? RenderTheme.Fonts()
        let own = theme["fonts"]?.objectValue ?? [:]
        if let sans = own["sans"]?.stringValue ?? theme["font"]?.stringValue { fonts.sans = sans }
        if let mono = own["mono"]?.stringValue { fonts.mono = mono }
        if let rounded = own["rounded"]?.stringValue { fonts.rounded = rounded }
        if let display = own["display"]?.stringValue { fonts.display = display }
        return fonts
    }

    // MARK: Finding families

    /// Whether a family can be drawn: bundled with vestal, or a font file
    /// whose name starts with it in a system font directory. A heuristic
    /// for `check-config`; the UIs ask the font system themselves.
    public static func isAvailable(_ family: String, home: String = NSHomeDirectory()) -> Bool {
        if isBundled(family) { return true }
        let squashed = family.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !squashed.isEmpty else { return false }
        let directories = [
            "/System/Library/Fonts", "/System/Library/Fonts/Supplemental", "/Library/Fonts", home + "/Library/Fonts",
            "/usr/share/fonts", "/usr/local/share/fonts", home + "/.local/share/fonts", home + "/.fonts",
            "/run/current-system/sw/share/X11/fonts", "/etc/profiles/per-user/\(NSUserName())/share/fonts",
        ]
        for directory in directories where scan(directory, matching: squashed, depth: 3) { return true }
        return false
    }

    private static func scan(_ directory: String, matching squashed: String, depth: Int) -> Bool {
        guard depth >= 0,
              let items = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return false }
        for item in items {
            let path = directory + "/" + item
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if scan(path, matching: squashed, depth: depth - 1) { return true }
            } else {
                let base = (item as NSString).deletingPathExtension.lowercased().filter { $0.isLetter || $0.isNumber }
                if base.hasPrefix(squashed) { return true }
            }
        }
        return false
    }
}
