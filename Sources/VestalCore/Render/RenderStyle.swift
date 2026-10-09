import Foundation

// MARK: - Styling
//
// The palette a config draws with, the color grammar and the
// text style that widgets inherit. Nodes carry a palette name when a
// color is one, so a palette change is a single `theme` op; anything else
// (hex, `name@alpha`) is sent resolved as `#rrggbbaa`.

public struct RenderPalette: Equatable, Sendable {
    /// Every name the config may use, resolved to `#rrggbbaa`.
    public let colors: [String: String]
    /// Problems with `theme.palette`, `theme.palettes` or `theme.colors`.
    public let problems: [String]

    public static let builtin = ["tokyo-night": RenderTheme.tokyoNight]

    /// From the config's `theme`: the chosen palette (built-in, or a
    /// key of `palettes` extending another), then `colors` over it.
    public init(theme: AnyJSON?) {
        let theme = theme?.objectValue ?? [:]
        let custom = theme["palettes"]?.objectValue ?? [:]
        var problems: [String] = []
        var raw: [String: String] = [:]
        func load(_ name: String, depth: Int) {
            if let builtin = Self.builtin[name] {
                raw.merge(builtin) { _, new in new }
                return
            }
            guard depth < 8, let palette = custom[name]?.objectValue else {
                problems.append("unknown palette \"\(name)\"; using tokyo-night")
                raw.merge(RenderTheme.tokyoNight) { _, new in new }
                return
            }
            load(palette["extends"]?.stringValue ?? "tokyo-night", depth: depth + 1)
            for (key, value) in palette["colors"]?.objectValue ?? [:] {
                if let text = value.stringValue { raw[key] = text }
            }
        }
        load(theme["palette"]?.stringValue ?? "tokyo-night", depth: 0)
        for (key, value) in theme["colors"]?.objectValue ?? [:] {
            if let text = value.stringValue { raw[key] = text }
        }
        // Entries may name other entries ("good": "green").
        var resolved: [String: String] = [:]
        for name in raw.keys.sorted() {
            var seen: Set<String> = []
            var value = raw[name]!
            while !value.hasPrefix("#"), let next = raw[Self.baseName(value)], seen.insert(value).inserted {
                if let alpha = Self.alphaSuffix(value) {
                    value = Self.hex(next).map { Self.withAlpha($0, alpha) } ?? next
                } else {
                    value = next
                }
            }
            if let hex = Self.hex(value) {
                resolved[name] = hex
            } else {
                problems.append("color \"\(name)\": \"\(raw[name]!)\" is not a color")
            }
        }
        colors = resolved
        self.problems = problems
    }

    /// A color value as a node carries it: a palette name as is,
    /// anything else as `#rrggbbaa`. Nil when it isn't a color.
    public func resolve(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if colors[trimmed] != nil { return trimmed }
        if let alpha = Self.alphaSuffix(trimmed) {
            let base = Self.baseName(trimmed)
            guard let hex = colors[base] ?? Self.hex(base) else { return nil }
            return Self.withAlpha(hex, alpha)
        }
        return Self.hex(trimmed)
    }

    /// A color as `#rrggbbaa`, palette names included.
    public func hexValue(_ text: String) -> String? {
        guard let resolved = resolve(text) else { return nil }
        return colors[resolved] ?? resolved
    }

    // MARK: Parsing

    /// `#rgb`, `#rrggbb` or `#rrggbbaa` → lowercase `#rrggbbaa`.
    static func hex(_ text: String) -> String? {
        guard text.hasPrefix("#") else { return nil }
        let digits = text.dropFirst().lowercased()
        guard digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        switch digits.count {
        case 3: return "#" + digits.map { "\($0)\($0)" }.joined() + "ff"
        case 6: return "#" + digits + "ff"
        case 8: return "#" + digits
        default: return nil
        }
    }

    static func baseName(_ text: String) -> String {
        text.split(separator: "@", maxSplits: 1).first.map(String.init) ?? text
    }

    static func alphaSuffix(_ text: String) -> Double? {
        let parts = text.split(separator: "@", maxSplits: 1)
        guard parts.count == 2, let alpha = Double(parts[1]) else { return nil }
        return min(max(alpha, 0), 1)
    }

    /// `hex` (`#rrggbbaa`) with its alpha multiplied by `alpha`.
    static func withAlpha(_ hex: String, _ alpha: Double) -> String {
        let digits = Array(hex.dropFirst())
        guard digits.count == 8, let a = Int(String(digits[6...7]), radix: 16) else { return hex }
        let scaled = Int((Double(a) * alpha).rounded())
        return "#" + String(digits[0..<6]) + String(format: "%02x", min(max(scaled, 0), 255))
    }
}

/// The inherited text style, resolved.
struct TextStyle: Equatable {
    var size: Double = 13
    var weight: Int = 400
    var font: String = "sans"
    var color: String = "text"
    var tracking: Double = 0
    var textCase: String = "none"
    /// `theme.scale` times every `style.scale` above.
    var scale: Double = 1

    static let sizeTokens: [String: Double] = [
        "xs": 10, "sm": 11, "md": 12, "base": 13, "lg": 14, "xl": 18, "2xl": 24, "3xl": 36, "display": 56,
    ]
    static let weightNames: [String: Int] = [
        "ultralight": 100, "thin": 200, "light": 300, "regular": 400, "medium": 500, "semibold": 600,
        "bold": 700, "heavy": 800, "black": 900,
    ]
    static let fonts: Set<String> = Set(Typefaces.roles)

    /// What a node draws with for `style.font`: a role (`display`, `sans`,
    /// `mono`, `rounded`) or a family name, or a comma-separated list of them
    /// of which the first usable one counts. `display` is usable when the
    /// theme sets that role; a face names its own family after it
    /// (`"display, Inter Tight"`). Nothing usable: `sans`. Nil for an empty
    /// value.
    static func font(_ spec: String, display: String?) -> String? {
        var sawDisplay = false
        for part in spec.split(separator: ",") {
            let name = part.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            if name == "display" {
                if display != nil { return "display" }
                sawDisplay = true
                continue
            }
            return name
        }
        return sawDisplay ? "sans" : nil
    }

    static func size(_ value: AnyJSON?) -> Double? {
        switch value {
        case .int(let n)?: return Double(n)
        case .double(let d)?: return d.isFinite ? d : nil
        case .string(let s)?: return sizeTokens[s] ?? Double(s)
        default: return nil
        }
    }

    static func weight(_ value: AnyJSON?) -> Int? {
        switch value {
        case .int(let n)?: return min(max(n, 1), 1000)
        case .double(let d)?: return d.isFinite ? min(max(Int(d.rounded()), 1), 1000) : nil
        case .string(let s)?: return weightNames[s] ?? Int(s)
        default: return nil
        }
    }

    /// `text` in this style's case.
    func cased(_ text: String) -> String {
        switch textCase {
        case "upper": return text.uppercased()
        case "lower": return text.lowercased()
        default: return text
        }
    }
}
