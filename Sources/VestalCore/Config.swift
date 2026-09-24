import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Top-level Config
//
// The whole shape of a Vestal configuration, as decoded after the layers are
// merged (see ConfigLoader): built-in defaults, the user file, then the user
// file's `platform.<os>` block. docs/CONFIG.md documents every key here; keep
// the two in step.
//
// Decoding is permissive. Unknown keys are ignored, a value of the wrong type
// counts as absent, and an entry that can't be used (a source or widget
// without a `type`, a host without a name) is dropped by itself rather than
// failing the whole file. `vestal check-config` reports all of these (see
// ConfigValidator).

public struct Config: Equatable, Sendable {
    public var version: Int = 1
    public var hotkey: String?
    public var theme: ThemeConfig = ThemeConfig()
    public var sources: [String: SourceConfig] = [:]
    public var widgets: [String: WidgetConfig] = [:]
    public var views: [String: ViewConfig] = [:]

    public init(
        version: Int = 1,
        hotkey: String? = nil,
        theme: ThemeConfig = ThemeConfig(),
        sources: [String: SourceConfig] = [:],
        widgets: [String: WidgetConfig] = [:],
        views: [String: ViewConfig] = [:]
    ) {
        self.version = version
        self.hotkey = hotkey
        self.theme = theme
        self.sources = sources
        self.widgets = widgets
        self.views = views
    }
}

extension Config {
    /// Where a system bar's "claudeUsage" item takes its options: the first
    /// widget of type claudeUsage, by key. Nil means the defaults.
    public var claudeUsageWidget: WidgetConfig? {
        widgets.sorted { $0.key < $1.key }.first { $0.value.type == "claudeUsage" }?.value
    }
}

extension Config: Codable {
    enum CodingKeys: String, CodingKey {
        case version, hotkey, theme, sources, widgets, views
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.lenient(Int.self, .version) ?? 1
        hotkey  = c.lenient(String.self, .hotkey)
        theme   = c.lenient(ThemeConfig.self, .theme) ?? ThemeConfig()
        sources = c.lenientEntries(SourceConfig.self, .sources)
        widgets = c.lenientEntries(WidgetConfig.self, .widgets)
        views   = c.lenientEntries(ViewConfig.self, .views)
    }
}

// MARK: - Theme

public struct ThemeConfig: Codable, Equatable, Sendable {
    public static let palettes = ["tokyo-night"]
    public static let backgrounds = ["aurora", "blur", "none"]

    public var palette: String = "tokyo-night"
    public var background: String = "aurora" // "aurora" | "blur" | "none"

    enum CodingKeys: String, CodingKey { case palette, background }
    public init(palette: String = "tokyo-night", background: String = "aurora") {
        self.palette = palette
        self.background = background
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        palette    = c.lenient(String.self, .palette) ?? "tokyo-night"
        background = c.lenient(String.self, .background) ?? "aurora"
    }
}

// MARK: - Source
//
// A data source is something widgets read from. Sources are fetched on their
// `refresh` interval; widgets referencing the same source share the result
// (dedupe is the runtime's job, not the config's).
//
// One flat struct for every type; `type` says which keys apply:
//   http      url, refresh, parse
//   command   argv, timeout, refresh, parse, env
//   calendar  refresh, days, calendars   ("eventkit" is an alias)

public struct SourceConfig: Codable, Equatable, Sendable {
    /// Keys each type accepts besides `type`.
    public static let keysByType: [String: Set<String>] = [
        "http": ["url", "refresh", "parse"],
        "command": ["argv", "timeout", "refresh", "parse", "env"],
        "calendar": ["refresh", "days", "calendars"],
    ]
    public static let aliases = ["eventkit": "calendar"]
    public static let parseModes = ["json", "raw"]

    public static let defaultRefresh = "30m"
    public static let defaultTimeout = "10s"
    public static let defaultDays = 1

    public var type: String                 // "http" | "command" | "calendar" (aliases resolved)
    public var url: String?                 // http
    public var refresh: String = SourceConfig.defaultRefresh // duration: "30s", "5m", "1h", "4h"
    public var parse: String = "json"       // http, command: "json" | "raw"
    public var argv: [String]?              // command
    public var timeout: String = SourceConfig.defaultTimeout // command
    public var env: [String: String]?       // command: extra environment
    public var days: Int = SourceConfig.defaultDays          // calendar: lookahead in days
    public var calendars: [String]?         // calendar: names to include (nil = all)

    enum CodingKeys: String, CodingKey {
        case type, url, refresh, parse, argv, timeout, env, days, calendars
    }

    public init(
        type: String,
        url: String? = nil,
        refresh: String = SourceConfig.defaultRefresh,
        parse: String = "json",
        argv: [String]? = nil,
        timeout: String = SourceConfig.defaultTimeout,
        env: [String: String]? = nil,
        days: Int = SourceConfig.defaultDays,
        calendars: [String]? = nil
    ) {
        self.type = Self.canonicalType(type)
        self.url = url; self.refresh = refresh; self.parse = parse
        self.argv = argv; self.timeout = timeout; self.env = env
        self.days = days; self.calendars = calendars
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let type = c.lenient(String.self, .type) else {
            throw DecodingError.keyNotFound(CodingKeys.type, DecodingError.Context(
                codingPath: c.codingPath, debugDescription: "a source needs a type"))
        }
        self.type = Self.canonicalType(type)
        url       = c.lenient(String.self, .url)
        refresh   = c.lenient(String.self, .refresh) ?? Self.defaultRefresh
        parse     = c.lenient(String.self, .parse) ?? "json"
        argv      = c.lenient([String].self, .argv)
        timeout   = c.lenient(String.self, .timeout) ?? Self.defaultTimeout
        env       = c.lenient([String: String].self, .env)
        days      = c.lenientPositive(.days) ?? Self.defaultDays
        calendars = c.lenient([String].self, .calendars)
    }

    /// `type` with aliases resolved ("eventkit" → "calendar").
    public static func canonicalType(_ type: String) -> String {
        aliases[type] ?? type
    }
}

// MARK: - Widget
//
// Heterogeneous widget configs are flattened into a single struct, with the
// `type` field acting as the discriminator. Widget-type-specific fields are
// all Optional; only the appropriate widget reads them. The defaults for
// absent keys are in `WidgetConfig.Defaults`.

public struct WidgetConfig: Codable, Equatable, Sendable {
    /// Keys each type accepts besides `type`.
    public static let keysByType: [String: Set<String>] = [
        "clock": ["worldClocks"],
        "systemBar": ["show", "privacy"],
        "media": ["player", "hideWhenOff"],
        "agendaList": ["source", "maxEvents", "title"],
        "systemHealth": ["hosts", "provider", "title"],
        "keyValueList": ["source", "items", "title"],
        "weatherCard": ["source", "fields", "units", "title"],
        "claudeUsage": ["path", "fiveHourLimit", "weeklyLimit"],
    ]
    public static let aliases = ["spotify": "media"]

    public static let systemBarItems = ["uptime", "disk", "battery", "claudeUsage", "network", "privacy"]
    public static let weatherFields = ["location", "region", "condition", "temp", "sunrise", "sunset"]
    public static let unitSystems = ["metric", "imperial"]
    public static let providers = ["foyer"]

    public enum Defaults {
        public static let maxEvents = 5
        public static let player = "Spotify"
        public static let hideWhenOff = true
        public static let provider = "foyer"
        public static let units = "metric"
        public static let claudePath = "~/.claude/projects"
        public static let fiveHourLimit = ClaudeUsage.blockLimitTokens
        public static let weeklyLimit = ClaudeUsage.weeklyLimitTokens
        /// Section titles of the widget types that have one; a keyValueList
        /// is titled after its key (see `title(forKey:)`).
        public static let titles = ["agendaList": "Today", "systemHealth": "Systems", "weatherCard": "Weather"]
    }

    public var type: String                            // a key of `keysByType` (aliases resolved)
    public var title: String?
    public var source: String?                         // reference to sources[<name>]

    // Clock
    public var worldClocks: [WorldClock]?

    // SystemBar
    public var show: [String]?                         // ["uptime", "disk", "battery", ...], in display order
    public var privacy: PrivacyConfig?

    // Media
    public var player: String?
    public var hideWhenOff: Bool?

    // AgendaList
    public var maxEvents: Int?

    // SystemHealth
    public var hosts: [HostConfig]?
    public var provider: String?                       // "foyer"

    // KeyValueList (e.g. exchange rates)
    public var items: [PickItem]?

    // WeatherCard: field name → JSON path into the source
    public var fields: [String: String]?
    public var units: String?                          // "metric" | "imperial"

    // ClaudeUsage
    public var path: String?
    public var fiveHourLimit: Int?
    public var weeklyLimit: Int?

    enum CodingKeys: String, CodingKey {
        case type, title, source, worldClocks, show, privacy, player, hideWhenOff, maxEvents,
             hosts, provider, items, fields, units, path, fiveHourLimit, weeklyLimit
    }

    public init(
        type: String,
        title: String? = nil,
        source: String? = nil,
        worldClocks: [WorldClock]? = nil,
        show: [String]? = nil,
        privacy: PrivacyConfig? = nil,
        player: String? = nil,
        hideWhenOff: Bool? = nil,
        maxEvents: Int? = nil,
        hosts: [HostConfig]? = nil,
        provider: String? = nil,
        items: [PickItem]? = nil,
        fields: [String: String]? = nil,
        units: String? = nil,
        path: String? = nil,
        fiveHourLimit: Int? = nil,
        weeklyLimit: Int? = nil
    ) {
        self.type = Self.canonicalType(type)
        self.title = title
        self.source = source
        self.worldClocks = worldClocks
        self.show = show
        self.privacy = privacy
        self.player = player
        self.hideWhenOff = hideWhenOff
        self.maxEvents = maxEvents
        self.hosts = hosts
        self.provider = provider
        self.items = items
        self.fields = fields
        self.units = units
        self.path = path
        self.fiveHourLimit = fiveHourLimit
        self.weeklyLimit = weeklyLimit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let type = c.lenient(String.self, .type) else {
            throw DecodingError.keyNotFound(CodingKeys.type, DecodingError.Context(
                codingPath: c.codingPath, debugDescription: "a widget needs a type"))
        }
        self.type     = Self.canonicalType(type)
        title         = c.lenient(String.self, .title)
        source        = c.lenient(String.self, .source)
        worldClocks   = c.lenientList(WorldClock.self, .worldClocks)
        show          = c.lenient([String].self, .show)
        privacy       = c.lenient(PrivacyConfig.self, .privacy)
        player        = c.lenient(String.self, .player)
        hideWhenOff   = c.lenient(Bool.self, .hideWhenOff)
        maxEvents     = c.lenientPositive(.maxEvents)
        hosts         = c.lenientList(HostConfig.self, .hosts)
        provider      = c.lenient(String.self, .provider)
        items         = c.lenientList(PickItem.self, .items)
        fields        = c.lenient([String: String].self, .fields)
        units         = c.lenient(String.self, .units)
        path          = c.lenient(String.self, .path)
        fiveHourLimit = c.lenientPositive(.fiveHourLimit)
        weeklyLimit   = c.lenientPositive(.weeklyLimit)
    }

    /// `type` with aliases resolved ("spotify" → "media").
    public static func canonicalType(_ type: String) -> String {
        aliases[type] ?? type
    }

    /// The section title: `title` if set, else the type's default (a
    /// keyValueList uses its key with the first letter capitalized). Nil for
    /// types without a title.
    public func title(forKey key: String) -> String? {
        if let title { return title }
        if type == "keyValueList" { return key.prefix(1).uppercased() + key.dropFirst() }
        return Defaults.titles[type]
    }
}

public struct WorldClock: Codable, Equatable, Sendable {
    public var label: String
    public var tz: String

    public init(label: String, tz: String) {
        self.label = label; self.tz = tz
    }
}

/// The system bar's privacy toggle. The item shows, and its key works, only
/// when both are set.
public struct PrivacyConfig: Codable, Equatable, Sendable {
    public var command: [String]?   // argv run to toggle
    public var stateFile: String?   // exists while privacy mode is on

    enum CodingKeys: String, CodingKey { case command, stateFile }
    public init(command: [String]? = nil, stateFile: String? = nil) {
        self.command = command; self.stateFile = stateFile
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command   = c.lenient([String].self, .command)
        stateFile = c.lenient(String.self, .stateFile)
    }

    public var isConfigured: Bool {
        !(command ?? []).isEmpty && !(stateFile ?? "").isEmpty
    }
}

public struct HostConfig: Codable, Equatable, Sendable {
    /// `source` value that means this machine, read in-process.
    public static let local = "local"
    public static let defaultInterval = "5s"

    /// Display name. A local host without a `name` gets this machine's short
    /// hostname when the config is decoded, so one config serves every host.
    public var name: String
    public var url: String?      // for remote providers (foyer)
    public var source: String?   // "local", or a source whose JSON is a health payload
    public var key: String?      // shortcut letter; auto-assigned when nil
    public var interval: String = HostConfig.defaultInterval // health poll interval

    enum CodingKeys: String, CodingKey { case name, url, source, key, interval }

    public init(name: String, url: String? = nil, source: String? = nil,
                key: String? = nil, interval: String = HostConfig.defaultInterval) {
        self.name = name; self.url = url; self.source = source
        self.key = key; self.interval = interval
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url      = c.lenient(String.self, .url)
        source   = c.lenient(String.self, .source)
        key      = c.lenient(String.self, .key)
        interval = c.lenient(String.self, .interval) ?? Self.defaultInterval
        if let name = c.lenient(String.self, .name) {
            self.name = name
        } else if source == Self.local {
            self.name = LocalHost.shortName
        } else {
            throw DecodingError.keyNotFound(CodingKeys.name, DecodingError.Context(
                codingPath: c.codingPath, debugDescription: "only a local host may omit its name"))
        }
    }

    public var isLocal: Bool { source == Self.local }
}

public struct PickItem: Codable, Equatable, Sendable {
    public static let formats = ["int", "integer", "decimal", "%.2f"]

    public var label: String
    public var source: String? = nil             // optional per-item source override (defaults to widget's source)
    public var match: [String: AnyJSON]? = nil   // exact-match selector for array sources
    public var pick: String? = nil               // single-value dot path within matched element
    public var picks: [String: String]? = nil    // multi-value: e.g. { buy = "compra"; sell = "venta"; }
    public var format: String? = nil             // "int" | "decimal" | nil (raw string)

    enum CodingKeys: String, CodingKey { case label, source, match, pick, picks, format }

    public init(
        label: String,
        source: String? = nil,
        match: [String: AnyJSON]? = nil,
        pick: String? = nil,
        picks: [String: String]? = nil,
        format: String? = nil
    ) {
        self.label = label; self.source = source; self.match = match
        self.pick = pick; self.picks = picks; self.format = format
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let label = c.lenient(String.self, .label) else {
            throw DecodingError.keyNotFound(CodingKeys.label, DecodingError.Context(
                codingPath: c.codingPath, debugDescription: "an item needs a label"))
        }
        self.label = label
        source = c.lenient(String.self, .source)
        match  = c.lenient([String: AnyJSON].self, .match)
        pick   = c.lenient(String.self, .pick)
        picks  = c.lenient([String: String].self, .picks)
        format = c.lenient(String.self, .format)
    }
}

// MARK: - View

public struct ViewConfig: Codable, Equatable, Sendable {
    public static let layouts = ["stack"]

    public var order: [String] = []
    public var layout: String = "stack"        // "stack" | (future) "grid"

    enum CodingKeys: String, CodingKey { case order, layout }
    public init(order: [String] = [], layout: String = "stack") {
        self.order = order; self.layout = layout
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order  = c.lenient([String].self, .order) ?? []
        layout = c.lenient(String.self, .layout) ?? "stack"
    }
}

// MARK: - Durations

public enum ConfigDuration {
    /// Parse "30s" / "5m" / "1h" / "4h" / "2d": a whole number above zero and
    /// a unit. Nil for anything else, including a number of seconds too large
    /// for an Int; callers fall back to their default.
    public static func parse(_ s: String) -> Duration? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let unit = trimmed.last else { return nil }
        let valueStr = String(trimmed.dropLast())
        guard let value = Int(valueStr), value > 0 else { return nil }
        let unitSeconds: Int
        switch unit {
        case "s": unitSeconds = 1
        case "m": unitSeconds = 60
        case "h": unitSeconds = 3600
        case "d": unitSeconds = 86400
        default:  return nil
        }
        let (seconds, overflow) = value.multipliedReportingOverflow(by: unitSeconds)
        return overflow ? nil : .seconds(seconds)
    }
}

// MARK: - Local host

public enum LocalHost {
    /// This machine's hostname up to the first dot ("swift" for
    /// "swift.local"). gethostname, not ProcessInfo.hostName, which can wait
    /// on DNS.
    public static let shortName: String = {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "localhost" }
        let full = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let short = full.split(separator: ".").first.map(String.init) ?? ""
        return short.isEmpty ? "localhost" : short
    }()
}

// MARK: - Permissive decoding

/// Decodes to nil instead of throwing, so a bad entry in a list or map drops
/// only itself.
struct Lossy<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension KeyedDecodingContainer {
    /// The value for `key`, or nil when it is absent, null or not a `T`.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }

    /// A whole number of at least 1, or nil: a count or limit below 1 counts
    /// as absent, so the default applies (`prefix(-1)` would trap).
    func lenientPositive(_ key: Key) -> Int? {
        lenient(Int.self, key).flatMap { $0 >= 1 ? $0 : nil }
    }

    /// A map of entries (sources, widgets, views); entries that fail to
    /// decode are dropped.
    func lenientEntries<T: Decodable>(_ type: T.Type, _ key: Key) -> [String: T] {
        (lenient([String: Lossy<T>].self, key) ?? [:]).compactMapValues(\.value)
    }

    /// A list whose elements that fail to decode are dropped. Nil when the
    /// key is absent or not a list.
    func lenientList<T: Decodable>(_ type: T.Type, _ key: Key) -> [T]? {
        lenient([Lossy<T>].self, key).map { $0.compactMap(\.value) }
    }
}
