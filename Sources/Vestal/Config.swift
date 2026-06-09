import Foundation

// MARK: - Top-level Config
//
// The whole shape of a Vestal configuration. Loaded once at startup from
// $VESTAL_CONFIG, ~/Library/Application Support/Vestal/config.json, or the
// bundled defaults (in that precedence order).
//
// Schema versioning lives at the top: `version` is set to 1 for now. Future
// breaking changes bump this. The decoder is permissive — unknown fields are
// ignored, and missing optional fields fall back to defaults.

struct Config {
    var version: Int = 1
    var hotkey: String?
    var theme: ThemeConfig = ThemeConfig()
    var sources: [String: SourceConfig] = [:]
    var widgets: [String: WidgetConfig] = [:]
    var views: [String: ViewConfig] = [:]
}

extension Config: Codable {
    enum CodingKeys: String, CodingKey {
        case version, hotkey, theme, sources, widgets, views
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        hotkey  = try c.decodeIfPresent(String.self, forKey: .hotkey)
        theme   = try c.decodeIfPresent(ThemeConfig.self, forKey: .theme) ?? ThemeConfig()
        sources = try c.decodeIfPresent([String: SourceConfig].self, forKey: .sources) ?? [:]
        widgets = try c.decodeIfPresent([String: WidgetConfig].self, forKey: .widgets) ?? [:]
        views   = try c.decodeIfPresent([String: ViewConfig].self, forKey: .views) ?? [:]
    }
    // Memberwise init is auto-synthesized — defining it explicitly conflicts.
}

// MARK: - Theme

struct ThemeConfig: Codable {
    var palette: String = "tokyo-night"
    var background: String = "aurora" // "aurora" | "none"

    enum CodingKeys: String, CodingKey { case palette, background }
    init(palette: String = "tokyo-night", background: String = "aurora") {
        self.palette = palette
        self.background = background
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        palette    = try c.decodeIfPresent(String.self, forKey: .palette) ?? "tokyo-night"
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? "aurora"
    }
}

// MARK: - Source
//
// A data source is something widgets read from. Sources are fetched once on
// their `refresh` interval; multiple widgets referencing the same source
// share the cached result (dedupe is the runtime's job, not the config's).
//
// v0.2 supports only `http` and `eventkit`. `command` is deferred until we
// have a sandboxing story.

struct SourceConfig: Codable {
    var type: String                 // "http" | "eventkit"
    var url: String?                 // http
    var refresh: String = "30m"      // duration: "30s", "5m", "1h", "4h"
    var parse: String = "json"       // "json" | "raw"

    enum CodingKeys: String, CodingKey { case type, url, refresh, parse }
    init(type: String, url: String? = nil, refresh: String = "30m", parse: String = "json") {
        self.type = type; self.url = url; self.refresh = refresh; self.parse = parse
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type    = try c.decode(String.self, forKey: .type)
        url     = try c.decodeIfPresent(String.self, forKey: .url)
        refresh = try c.decodeIfPresent(String.self, forKey: .refresh) ?? "30m"
        parse   = try c.decodeIfPresent(String.self, forKey: .parse) ?? "json"
    }
}

// MARK: - Widget
//
// Heterogeneous widget configs are flattened into a single struct, with the
// `type` field acting as the discriminator. Widget-type-specific fields are
// all Optional; only the appropriate widget reads them. Unknown widget types
// are dropped with a warning at view-render time.

struct WidgetConfig: Codable {
    var type: String                            // "clock" | "weather" | "spotify" | "agenda" | "systemBar" | "systemHealth" | "keyValueList" | "weatherCard"
    var title: String?
    var source: String?                         // reference to sources[<name>]

    // Clock
    var worldClocks: [WorldClock]?

    // SystemBar
    var show: [String]?                         // ["uptime", "disk", "battery", ...]

    // Spotify
    var hideWhenOff: Bool?

    // AgendaList
    var maxEvents: Int?

    // SystemHealth
    var hosts: [HostConfig]?
    var provider: String?                       // "foyer" | "netdata" | "prometheus" | "ssh" | "json"

    // KeyValueList (e.g. exchange rates)
    var items: [PickItem]?

    // WeatherCard / generic field mapping
    var fields: [String: String]?               // field name → dot-path

    // Generic single value
    var pick: String?

    // Weather widget convenience
    var fixedLocation: FixedLocation?
    var units: String?                          // "metric" | "imperial"

    // Keep an "extra" bag for forward-compat — unknown widget options are
    // preserved as raw JSON so v0.2 doesn't choke on a v0.3 widget config.
    var extras: [String: AnyJSON]?

    enum CodingKeys: String, CodingKey {
        case type, title, source, worldClocks, show, hideWhenOff, maxEvents,
             hosts, provider, items, fields, pick, fixedLocation, units, extras
    }
}

struct WorldClock: Codable {
    var label: String
    var tz: String
}

struct HostConfig: Codable {
    var name: String
    var url: String?      // for remote providers (foyer, netdata, prometheus)
    var source: String?   // for "local" — references local system bridge
}

struct PickItem: Codable {
    var label: String
    var source: String?                // optional per-item source override (defaults to widget's source)
    var match: [String: AnyJSON]?      // exact-match selector for array sources
    var pick: String?                  // single-value dot path within matched element
    var picks: [String: String]?       // multi-value: e.g. { buy = "compra"; sell = "venta"; }
    var format: String?                // "int" | "decimal" | nil (raw string)
}

struct FixedLocation: Codable {
    var lat: Double
    var lon: Double
}

// MARK: - View

struct ViewConfig: Codable {
    var order: [String] = []
    var layout: String = "stack"        // "stack" | (future) "grid"

    enum CodingKeys: String, CodingKey { case order, layout }
    init(order: [String] = [], layout: String = "stack") {
        self.order = order; self.layout = layout
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order  = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        layout = try c.decodeIfPresent(String.self, forKey: .layout) ?? "stack"
    }
}

// MARK: - AnyJSON
//
// Type-erased holder for arbitrary JSON primitives. Used for fields like
// `match` where the value type isn't fixed at compile time. Encoding round-
// trips losslessly; comparison via `matches(_:)` handles cross-type numeric
// equivalence (Int vs Double in parsed JSON).

enum AnyJSON: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self)   { self = .bool(v);   return }
        if let v = try? c.decode(Int.self)    { self = .int(v);    return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "AnyJSON: unsupported value type")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v):   try c.encode(v)
        case .null:          try c.encodeNil()
        }
    }

    /// Exact-match comparison against a value pulled from parsed JSON.
    /// Handles Int↔Double cross-type comparison since JSON parsing can land
    /// either way depending on the source.
    func matches(_ other: Any?) -> Bool {
        switch self {
        case .string(let s):
            return (other as? String) == s
        case .int(let i):
            if let o = other as? Int    { return o == i }
            if let o = other as? Double { return Int(o) == i }
            return false
        case .double(let d):
            if let o = other as? Double { return o == d }
            if let o = other as? Int    { return Double(o) == d }
            return false
        case .bool(let b):
            return (other as? Bool) == b
        case .null:
            return other == nil || other is NSNull
        }
    }
}
