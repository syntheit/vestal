import Foundation

// MARK: - The background library
//
// `theme.background` names one of these. `aurora`, `blur` and `none` are
// older than the library; the others are fragment shaders (Resources/shaders)
// that both renderers draw at a reduced resolution and scale up, paused while
// the dashboard is hidden. This file is what the renderers share: the names,
// the per-background defaults, the clock-driven sky, the weather code tables
// and the uniform values (`p`, `c0..c3`) each background gets, so the macOS
// and GTK renderers cannot disagree.

public enum Backgrounds {
    /// Before the library: not shaders from the library.
    public static let base = ["aurora", "blur", "none"]
    /// The shader library.
    public static let library = ["mesh", "topo", "stars", "flow", "rain", "plasma", "grain", "sky", "weather", "load", "artmesh"]
    /// Every value `theme.background` takes as a name (or as `type`).
    public static let names = base + library

    public static func isLibrary(_ name: String) -> Bool { library.contains(name) }

    /// Frames a second, `theme.backgroundFPS`.
    public static let defaultFPS = 30
    public static let fpsRange = 1...60
    /// `theme.backgroundResolution`: the share of the screen's pixels.
    public static let resolutionRange = 0.1...1.0

    /// The render scale each background looks right at.
    public static let resolutions: [String: Double] = [
        "mesh": 0.25, "artmesh": 0.25, "plasma": 0.25, "load": 0.35, "sky": 0.5, "rain": 0.45, "topo": 0.6,
        "flow": 0.6, "weather": 0.7, "stars": 0.8, "grain": 0.9,
    ]

    public static func defaultResolution(_ name: String) -> Double { resolutions[name] ?? 0.5 }

    /// The shader file a background draws with (`artmesh` is the mesh).
    public static func shaderName(_ name: String) -> String { name == "artmesh" ? "mesh" : name }

    /// `theme.backgroundFPS` clamped, else the default.
    public static func fps(_ value: AnyJSON?) -> Int? {
        switch value {
        case .int(let n)?: return min(max(n, fpsRange.lowerBound), fpsRange.upperBound)
        case .double(let d)?: return d.isFinite ? min(max(Int(d.rounded()), fpsRange.lowerBound), fpsRange.upperBound) : nil
        default: return nil
        }
    }

    /// `theme.backgroundResolution` clamped.
    public static func resolution(_ value: AnyJSON?) -> Double? {
        switch value {
        case .int(let n)?: return min(max(Double(n), resolutionRange.lowerBound), resolutionRange.upperBound)
        case .double(let d)?: return d.isFinite ? min(max(d, resolutionRange.lowerBound), resolutionRange.upperBound) : nil
        default: return nil
        }
    }

    // MARK: Defaults of the data-driven backgrounds

    /// The source and expression a background reads when the config names
    /// none.
    public static func defaultSource(_ type: String) -> String? {
        switch type {
        case "load": return "system"
        case "weather": return "weather"
        case "artmesh": return "media"
        default: return nil
        }
    }

    public static let defaultLoadValue = ".cpu.percent"
    public static let defaultWeatherCondition = ".current_condition[0].weatherCode"
    public static let defaultArtwork = ".artwork"

    // MARK: Weather

    /// What `weather` draws; a `condition` is turned into one of these.
    public static let conditions = ["clear", "rain", "snow", "storm"]

    /// The condition `weather` draws for `value`: one of `conditions`, a
    /// description in words ("Light rain shower", "Thundery outbreaks"), or
    /// a code: 0 to 99 is WMO (Open-Meteo), 100 and up is World Weather
    /// Online's (wttr.in's `weatherCode`). Nil when it is none of those.
    public static func condition(_ value: AnyJSON) -> String? {
        switch value {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let code = Double(trimmed) { return condition(code: code) }
            return condition(words: trimmed)
        case .int(let n): return condition(code: Double(n))
        case .double(let d): return condition(code: d)
        default: return nil
        }
    }

    /// WMO weather interpretation codes, and World Weather Online's.
    public static func condition(code: Double) -> String? {
        guard code.isFinite, code >= 0, code == code.rounded() else { return nil }
        let n = Int(code)
        if n < 100 {
            switch n {
            case 0...48: return "clear"            // clear, cloud, fog and rime fog
            case 51...67: return "rain"            // drizzle, rain, freezing rain
            case 71...77: return "snow"            // snow fall, grains
            case 80...82: return "rain"            // rain showers
            case 85, 86: return "snow"             // snow showers
            case 95...99: return "storm"           // thunderstorm
            default: return nil
            }
        }
        switch n {
        case 113...122, 143, 248, 260: return "clear"                         // sunny, cloudy, mist, fog
        case 200, 386, 389, 392, 395: return "storm"                          // thunder
        case 179, 227, 230, 317, 320, 323...338, 350, 362...377: return "snow" // snow, sleet, ice pellets
        case 176, 182, 185, 263...314, 353...359: return "rain"              // drizzle, rain, freezing rain
        default: return nil
        }
    }

    /// A description in words: thunder or storm, then snow (sleet, ice,
    /// blizzard), then rain (drizzle, shower), else clear.
    static func condition(words: String) -> String? {
        let text = words.lowercased()
        if text.isEmpty { return nil }
        if conditions.contains(text) { return text }
        for (needles, result) in [(["thunder", "storm"], "storm"), (["snow", "sleet", "blizzard", "ice", "hail", "flurr"], "snow"),
                                  (["rain", "drizzle", "shower"], "rain")] where needles.contains(where: { text.contains($0) }) {
            return result
        }
        return "clear"
    }

    // MARK: Sky

    /// The keyframes of `sky`: hour, the color overhead, at the horizon and
    /// of the sun or moon (darkened for white text).
    static let skyKeys: [(hour: Double, top: String, horizon: String, sun: String)] = [
        (0, "#04060d", "#0d1428", "#cfd6ff"), (5, "#05070f", "#141b33", "#cfd6ff"), (6.5, "#1a2350", "#b0674f", "#ffcf8a"),
        (8.5, "#1d3f78", "#6b8fb8", "#fff2c8"), (13, "#1b4a8a", "#6a98c8", "#ffffff"), (17, "#1f3c74", "#a07a5e", "#ffe0a0"),
        (19, "#231c48", "#c0603e", "#ffb070"), (20.5, "#0a0d1e", "#22203f", "#cfd6ff"), (24, "#04060d", "#0d1428", "#cfd6ff"),
    ]

    public struct Sky: Equatable, Sendable {
        public var top: [Float], horizon: [Float], sun: [Float]
        /// The sun or moon's place across and up the screen, 0 to 1.
        public var x: Float, y: Float
        /// 0 by day to 1 at night.
        public var stars: Float
    }

    /// The sky at `hour` (0 to 24, local time).
    public static func sky(hour rawHour: Double) -> Sky {
        let hour = min(max(rawHour, 0), 24)
        var i = 0
        while i < skyKeys.count - 2 && skyKeys[i + 1].hour <= hour { i += 1 }
        let a = skyKeys[i], b = skyKeys[i + 1]
        let f = Float(min(max((hour - a.hour) / (b.hour - a.hour), 0), 1))
        func mix(_ x: String, _ y: String) -> [Float] {
            let u = rgb(x) ?? [0, 0, 0], v = rgb(y) ?? [0, 0, 0]
            return (0..<3).map { u[$0] + (v[$0] - u[$0]) * f }
        }
        let elevation = sin((hour - 6.25) / 12.75 * Double.pi)
        return Sky(top: mix(a.top, b.top), horizon: mix(a.horizon, b.horizon), sun: mix(a.sun, b.sun),
                   x: Float(min(max((hour - 6.25) / 12.75, 0), 1) * 0.8 + 0.1), y: Float(0.06 + 0.88 * elevation),
                   stars: Float(min(max(-elevation * 3, 0), 1)))
    }

    /// Hours into the day in `timeZone`, with minutes as the fraction.
    public static func hour(of date: Date, in timeZone: TimeZone = .current) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60 + Double(parts.second ?? 0) / 3600
    }

    // MARK: Colors

    /// `#rrggbb` or `#rrggbbaa` as red, green, blue in 0 to 1.
    public static func rgb(_ hex: String) -> [Float]? {
        guard hex.hasPrefix("#"), hex.count == 7 || hex.count == 9, let value = UInt32(hex.dropFirst().prefix(6), radix: 16) else { return nil }
        return [Float((value >> 16) & 255) / 255, Float((value >> 8) & 255) / 255, Float(value & 255) / 255]
    }

    /// The mesh's colors, and the album-art mesh's when no artwork is set.
    public static let meshColors = ["#1e2a62", "#4a2a72", "#164f5c", "#5a2448"]
    public static let artMeshColors = ["#2a1e4f", "#6a2f63", "#a0504a", "#b07a4a"]

    /// The four colors of a picture for `artmesh`, one per quadrant (top
    /// left, top right, bottom right, bottom left), from `rgba` pixels of an
    /// opaque picture, row 0 at the top. Each is the quadrant's average with
    /// its saturation lifted and its brightness held between 0.22 and 0.60,
    /// so that white text stays readable and a pale cover still has color.
    public static func artworkColors(rgba: [UInt8], width: Int, height: Int) -> [[Float]] {
        guard width >= 2, height >= 2, rgba.count >= width * height * 4 else { return [] }
        var sums = [[Double]](repeating: [0, 0, 0, 0], count: 4)
        for y in 0..<height {
            for x in 0..<width {
                let quadrant = y < height / 2 ? (x < width / 2 ? 0 : 1) : (x < width / 2 ? 3 : 2)
                let i = (y * width + x) * 4
                let alpha = Double(rgba[i + 3]) / 255
                for c in 0..<3 { sums[quadrant][c] += Double(rgba[i + c]) / 255 * alpha }
                sums[quadrant][3] += alpha
            }
        }
        return sums.map { sum in
            guard sum[3] > 0 else { return [0.16, 0.12, 0.31] }
            let r = sum[0] / sum[3], g = sum[1] / sum[3], b = sum[2] / sum[3]
            let high = max(r, g, b), low = min(r, g, b), spread = high - low
            var hue = 0.0
            if spread > 0 {
                if high == r { hue = (g - b) / spread / 6 }
                else if high == g { hue = (2 + (b - r) / spread) / 6 }
                else { hue = (4 + (r - g) / spread) / 6 }
            }
            let saturation = high > 0 ? min(spread / high * 1.15 + 0.04, 1) : 0
            let value = min(max(high, 0.22), 0.60)
            return (0..<3).map { c in
                let k = (hue + [1.0, 2.0 / 3, 1.0 / 3][c]).truncatingRemainder(dividingBy: 1)
                let q = min(max(abs((k < 0 ? k + 1 : k) * 6 - 3) - 1, 0), 1)
                return Float(value * (1 - saturation + saturation * q))
            }
        }
    }

    // MARK: Uniforms

    /// What a background's shader gets besides `resolution` and `time`.
    public struct Uniforms: Equatable, Sendable {
        /// `p`.
        public var p: [Float] = [0, 0, 0, 0]
        /// `c0` to `c3`, each red, green, blue.
        public var colors: [[Float]] = Array(repeating: [0, 0, 0], count: 4)
        /// How fast `time` runs next to the clock (`load` speeds up when busy).
        public var timeScale: Double = 1
        /// The time of a still frame (reduced motion, and screenshots).
        public static let stillTime = 14.0
    }

    /// The uniforms of background `name`. `hour` is the local time for `sky`;
    /// `artworkColors` (up to four, each red, green, blue) are the playing
    /// track's, for `artmesh`.
    public static func uniforms(_ name: String, params: RenderBackground?, hour: Double, artworkColors: [[Float]]? = nil) -> Uniforms {
        var u = Uniforms()
        switch name {
        case "mesh":
            u.p = [0.74, 0, 0, 0]
            u.colors = cycle(params?.colors?.compactMap(rgb), fallback: meshColors)
        case "artmesh":
            u.p = [0.78, 0, 0, 0]
            let own = artworkColors.flatMap { $0.isEmpty ? nil : $0 }
            u.colors = cycle(own ?? params?.colors?.compactMap(rgb), fallback: artMeshColors)
        case "load":
            let load = Float(min(max(params?.load ?? 0, 0), 1))
            u.p = [load, 0, 0, 0]
            u.timeScale = 0.5 + 3.2 * Double(load)
        case "sky":
            let sky = sky(hour: hour)
            u.p = [sky.x, sky.y, sky.stars, 0.78]
            u.colors = [sky.top, sky.horizon, sky.sun, [0, 0, 0]]
        case "weather":
            let mode = ["clear": 0, "rain": 1, "snow": 2, "storm": 3][params?.condition ?? "clear"] ?? 0
            u.p = [Float(mode), 0, 0, 0]
        default:
            break
        }
        return u
    }

    /// Four colors from `colors` (repeated to fill), else from `fallback`.
    static func cycle(_ colors: [[Float]]?, fallback: [String]) -> [[Float]] {
        let source = colors.flatMap { $0.isEmpty ? nil : $0 } ?? fallback.compactMap(rgb)
        return (0..<4).map { source[$0 % source.count] }
    }
}

// MARK: - The data-driven part of a background

/// The values a background reads from the render engine, resolved at each
/// render: `theme.background`'s `colors` (once), and what `source`,
/// `value`, `condition` and `artwork` evaluate to. Sent in the snapshot's
/// `theme`; a change goes out as a `theme` patch.
public struct RenderBackground: Equatable, Sendable, Codable {
    /// `#rrggbbaa`, up to four (`mesh`, and `artmesh` without artwork).
    public var colors: [String]?
    /// 0 to 1 (`load`).
    public var load: Double?
    /// One of `Backgrounds.conditions` (`weather`).
    public var condition: String?
    /// The picture's local file (`artmesh`), whose colors the UI takes.
    public var artwork: String?

    public init(colors: [String]? = nil, load: Double? = nil, condition: String? = nil, artwork: String? = nil) {
        self.colors = colors
        self.load = load
        self.condition = condition
        self.artwork = artwork
    }
}

/// `theme.background` as written: a name, or an object with `type` and the
/// parameters of that background.
struct BackgroundSpec: Equatable {
    var type: String
    var colors: [String] = []
    var source: String?
    var value: AnyJSON?
    var condition: AnyJSON?
    var artwork: AnyJSON?

    /// The keys a `theme.background` object takes.
    static let keys = ["type", "colors", "source", "value", "condition", "artwork"]

    /// Nil for `aurora`, `blur`, `none` and an unknown name.
    init?(_ json: AnyJSON?, palette: RenderPalette) {
        let type: String
        var object: [String: AnyJSON] = [:]
        switch json {
        case .string(let name)?:
            type = name
        case .object(let members)?:
            guard let name = members["type"]?.stringValue else { return nil }
            type = name
            object = members
        default:
            return nil
        }
        guard Backgrounds.isLibrary(type) else { return nil }
        self.type = type
        if case .array(let items)? = object["colors"] {
            colors = items.prefix(4).compactMap { $0.stringValue.flatMap(palette.hexValue) }
        }
        source = object["source"]?.stringValue ?? Backgrounds.defaultSource(type)
        value = object["value"] ?? (type == "load" ? .string(Backgrounds.defaultLoadValue) : nil)
        condition = object["condition"] ?? (type == "weather" ? .string(Backgrounds.defaultWeatherCondition) : nil)
        artwork = object["artwork"] ?? (type == "artmesh" ? .string(Backgrounds.defaultArtwork) : nil)
    }

    /// Whether anything is read from a source at render time.
    var isDynamic: Bool {
        switch type {
        case "load": return value != nil
        case "weather": return condition != nil
        case "artmesh": return artwork != nil
        default: return false
        }
    }
}

extension ThemeConfig {
    /// `theme.background`'s name, from a name or an object's `type`.
    public static func backgroundName(_ value: AnyJSON?) -> String? {
        switch value {
        case .string(let name)?: return Backgrounds.names.contains(name) ? name : nil
        case .object(let members)?: return members["type"]?.stringValue.flatMap { Backgrounds.names.contains($0) ? $0 : nil }
        default: return nil
        }
    }
}
