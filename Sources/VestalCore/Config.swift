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
    /// A trackpad gesture that toggles the dashboard ("pinch"), macOS only.
    public var gesture: String?
    public var theme: ThemeConfig = ThemeConfig()
    public var sources: [String: SourceConfig] = [:]
    public var widgets: [String: WidgetConfig] = [:]
    public var views: [String: ViewConfig] = [:]
    /// Named secrets for source definitions (EXTENSIBILITY.md 5.3).
    public var secrets: [String: SecretConfig] = [:]
    /// The config with templates expanded and the legacy adapter applied
    /// (ConfigExpansion), when it came from ConfigLoader: what the render
    /// engine draws, and where template-made sources are read from.
    public var expanded: AnyJSON?

    public init(
        version: Int = 1,
        hotkey: String? = nil,
        gesture: String? = nil,
        theme: ThemeConfig = ThemeConfig(),
        sources: [String: SourceConfig] = [:],
        widgets: [String: WidgetConfig] = [:],
        views: [String: ViewConfig] = [:],
        secrets: [String: SecretConfig] = [:]
    ) {
        self.version = version
        self.hotkey = hotkey
        self.gesture = gesture
        self.theme = theme
        self.sources = sources
        self.widgets = widgets
        self.views = views
        self.secrets = secrets
    }
}

extension Config {
    /// Takes the expansion's sources (named ones with source templates
    /// expanded, template-made inline ones, the adapter's `host:<name>`)
    /// and its tree.
    public mutating func adopt(_ expansion: ExpandedConfig) {
        expanded = expansion.tree
        for (name, source) in expansion.sources { sources[name] = source }
    }
}

extension Config: Codable {
    enum CodingKeys: String, CodingKey {
        case version, hotkey, gesture, theme, sources, widgets, views, secrets
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.lenient(Int.self, .version) ?? 1
        hotkey  = c.lenient(String.self, .hotkey)
        gesture = c.lenient(String.self, .gesture)
        theme   = c.lenient(ThemeConfig.self, .theme) ?? ThemeConfig()
        sources = c.lenientEntries(SourceConfig.self, .sources)
        widgets = c.lenientEntries(WidgetConfig.self, .widgets)
        views   = c.lenientEntries(ViewConfig.self, .views)
        secrets = c.lenientEntries(SecretConfig.self, .secrets)
    }
}

// MARK: - Theme

public struct ThemeConfig: Codable, Equatable, Sendable {
    public static let palettes = ["tokyo-night"]
    public static let backgrounds = ["aurora", "blur", "none"]
    /// `theme.backdrop` (Linux): who blurs the desktop behind the dashboard.
    public static let backdrops = ["self", "compositor", "none"]
    /// `theme.density`: how much room the built-in presets take.
    public static let densities = ["comfortable", "compact"]

    /// `theme.density` of a `theme` object: one of `densities`, else
    /// `comfortable`.
    public static func density(_ theme: AnyJSON?) -> String {
        theme?.objectValue?["density"]?.stringValue.flatMap { densities.contains($0) ? $0 : nil } ?? "comfortable"
    }

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
// One flat struct for every type; `type` says which keys apply (besides the
// common `refresh`, `when`, `transform`, `history`, `maxAge` and `cache`):
//   http      url, parse, method, headers, body, timeout
//   command   argv, timeout, parse, env
//   calendar  days, calendars, ics, timeout   ("eventkit" is an alias)
//   file      path, parse
//   system    disks, interfaces
//   media     player
//   claude    argv (path, fiveHourLimit and weeklyLimit are accepted and ignored)
//   codex     argv
// docs/EXTENSIBILITY.md section 5 is the reference.

public struct SourceConfig: Codable, Equatable, Sendable {
    /// Keys every type accepts (EXTENSIBILITY.md 5.1).
    public static let commonKeys: Set<String> = ["refresh", "when", "transform", "history", "maxAge", "cache"]
    /// Keys each type accepts besides `type` (from SchemaRegistry).
    public static let keysByType = SchemaRegistry.keysByType(SchemaRegistry.sourceTypes)
    public static let aliases = SchemaRegistry.aliases(SchemaRegistry.sourceTypes)
    public static let parseModes = ["json", "raw", "lines", "feed"]
    /// `file` also takes `exists`.
    public static let fileParseModes = parseModes + ["exists"]
    public static let whenValues = ["always", "visible"]
    public static let methods = ["GET", "POST"]

    public static let defaultRefresh = "30m"
    public static let defaultTimeout = "10s"
    public static let defaultDays = 1
    public static let defaultPlayer = "auto"
    public static let defaultDisks = ["/"]

    /// `refresh` when the source doesn't set it (EXTENSIBILITY.md 5.1).
    public static func defaultRefresh(for type: String) -> String {
        switch canonicalType(type) {
        case "system", "media": return "3s"
        case "file": return "30s"
        case "claude", "codex": return "5m"
        default: return defaultRefresh
        }
    }

    /// `when` when the source doesn't set it: the platform's live data only
    /// while the dashboard is shown, everything else always.
    public static func defaultWhen(for type: String) -> String {
        switch canonicalType(type) {
        case "system", "media", "claude", "codex": return "visible"
        default: return "always"
        }
    }

    /// A visible-only source whose data is older than this when the
    /// dashboard is shown fetches at once, though its `refresh` hasn't
    /// passed: `claude` and `codex`, whose refresh is long, after a minute.
    /// Nil: only `refresh` counts.
    public var showRefreshSeconds: TimeInterval? {
        type == "claude" || type == "codex" ? min(60, refreshSeconds) : nil
    }

    public var type: String                 // a key of `keysByType` (aliases resolved)
    public var url: String?                 // http
    public var refresh: String              // duration: "30s", "5m", "1h", "4h"; per type by default
    public var parse: String = "json"       // http, command, file: see `parseModes`
    public var argv: [String]?              // command; claude, codex (default claude -p ... /usage, codex app-server)
    public var timeout: String = SourceConfig.defaultTimeout // command, http, calendar (ics URLs)
    public var env: [String: String]?       // command: extra environment
    public var days: Int = SourceConfig.defaultDays          // calendar: lookahead in days
    public var calendars: [String]?         // calendar: names to include (nil = all)

    // v0.4 (EXTENSIBILITY.md 5.1, 5.2)
    public var when: String                 // "always" | "visible"; per type by default
    public var transform: String?           // jq, applied on read (phase 3)
    public var history: [String: HistorySpec]?
    public var maxAge: String?              // duration: older cached data isn't shown at startup
    public var cache: Bool = true           // false: never written to disk
    public var method: String = "GET"       // http: "GET" | "POST"
    public var headers: [String: String]?   // http
    public var body: AnyJSON?               // http POST: text, or JSON sent as application/json
    public var path: String?                // file (required)
    public var disks: [String]?             // system: mount points (default ["/"])
    public var interfaces: [String]?        // system: interfaces to sum (nil: all but loopback)
    public var player: [String]?            // media: names in order, or ["auto"] (a string decodes as one)
    public var ics: [String]?               // calendar: .ics files, directories or http(s) URLs

    enum CodingKeys: String, CodingKey {
        case type, url, refresh, parse, argv, timeout, env, days, calendars
        case when, transform, history, maxAge, cache, method, headers, body, path
        case disks, interfaces, player, ics
    }

    public init(
        type: String,
        url: String? = nil,
        refresh: String? = nil,
        parse: String = "json",
        argv: [String]? = nil,
        timeout: String = SourceConfig.defaultTimeout,
        env: [String: String]? = nil,
        days: Int = SourceConfig.defaultDays,
        calendars: [String]? = nil,
        when: String? = nil,
        transform: String? = nil,
        history: [String: HistorySpec]? = nil,
        maxAge: String? = nil,
        cache: Bool = true,
        method: String = "GET",
        headers: [String: String]? = nil,
        body: AnyJSON? = nil,
        path: String? = nil,
        disks: [String]? = nil,
        interfaces: [String]? = nil,
        player: [String]? = nil,
        ics: [String]? = nil
    ) {
        let type = Self.canonicalType(type)
        self.type = type
        self.url = url; self.refresh = refresh ?? Self.defaultRefresh(for: type); self.parse = parse
        self.argv = argv; self.timeout = timeout; self.env = env
        self.days = days; self.calendars = calendars
        self.when = when ?? Self.defaultWhen(for: type)
        self.transform = transform; self.history = history; self.maxAge = maxAge; self.cache = cache
        self.method = method; self.headers = headers; self.body = body; self.path = path
        self.disks = disks; self.interfaces = interfaces; self.player = player
        self.ics = ics
        fillDefaults()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let type = c.lenient(String.self, .type) else {
            throw DecodingError.keyNotFound(CodingKeys.type, DecodingError.Context(
                codingPath: c.codingPath, debugDescription: "a source needs a type"))
        }
        let canonical = Self.canonicalType(type)
        self.type = canonical
        url       = c.lenient(String.self, .url)
        refresh   = c.lenient(String.self, .refresh) ?? Self.defaultRefresh(for: canonical)
        parse     = c.lenient(String.self, .parse) ?? "json"
        argv      = c.lenient([String].self, .argv)
        timeout   = c.lenient(String.self, .timeout) ?? Self.defaultTimeout
        env       = c.lenient([String: String].self, .env)
        days      = c.lenientPositive(.days) ?? Self.defaultDays
        calendars = c.lenient([String].self, .calendars)
        when      = c.lenient(String.self, .when).flatMap { Self.whenValues.contains($0) ? $0 : nil }
            ?? Self.defaultWhen(for: canonical)
        transform = c.lenient(String.self, .transform)
        history   = c.lenientEntries(HistorySpec.self, .history)
        if history?.isEmpty == true { history = nil }
        maxAge    = c.lenient(String.self, .maxAge)
        cache     = c.lenient(Bool.self, .cache) ?? true
        method    = c.lenient(String.self, .method).map { $0.uppercased() } ?? "GET"
        headers   = c.lenient([String: String].self, .headers)
        body      = c.lenient(AnyJSON.self, .body)
        path      = c.lenient(String.self, .path)
        disks     = c.lenient([String].self, .disks)
        interfaces = c.lenient([String].self, .interfaces)
        player    = c.lenient([String].self, .player) ?? c.lenient(String.self, .player).map { [$0] }
        ics       = c.lenient([String].self, .ics) ?? c.lenient(String.self, .ics).map { [$0] }
        fillDefaults()
    }

    /// The per-type defaults that are values rather than "absent", so two
    /// definitions that mean the same have the same canonical JSON.
    private mutating func fillDefaults() {
        switch type {
        case "media":
            if player?.isEmpty ?? true { player = [Self.defaultPlayer] }
        case "system":
            if disks?.isEmpty ?? true { disks = Self.defaultDisks }
        case "claude":
            // `path` is ignored (it was the v0.3 log directory).
            path = nil
        default:
            break
        }
    }

    /// `type` with aliases resolved ("eventkit" → "calendar").
    public static func canonicalType(_ type: String) -> String {
        aliases[type] ?? type
    }

    /// Fetched only while the dashboard is shown.
    public var isVisibleOnly: Bool { when == "visible" }

    /// `refresh` in seconds; the type's default if it doesn't parse.
    public var refreshSeconds: TimeInterval {
        ConfigDuration.seconds(refresh)
            ?? ConfigDuration.seconds(Self.defaultRefresh(for: type)) ?? 1800
    }

    /// `timeout` in seconds; 10 if it doesn't parse.
    public var timeoutSeconds: TimeInterval {
        ConfigDuration.seconds(timeout) ?? ConfigDuration.seconds(Self.defaultTimeout) ?? 10
    }

    /// The definition as canonical JSON (CanonicalJSON.swift): every key,
    /// defaults filled in, text fields as written (a `{{ $secrets.x }}` is
    /// the name `x`, never its value).
    public var canonicalJSON: String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self), let tree = AnyJSON.decode(data) else { return "" }
        return tree.canonicalText()
    }

    /// SHA-256 of `canonicalJSON`, in hex: what the snapshot cache records,
    /// and where inline sources get their names.
    public var definitionHash: String { SHA256.hex(canonicalJSON) }

    /// An inline source's name: `inline:` and the first 8 hex digits of its
    /// definition hash (EXTENSIBILITY.md 5.1).
    public var inlineName: String { "inline:" + definitionHash.prefix(8) }
}

/// One named history of a source (EXTENSIBILITY.md 5.6).
public struct HistorySpec: Codable, Equatable, Sendable {
    public static let defaultSize = 120
    public static let maxSize = 10_000

    /// jq giving the number to record, evaluated against the (transformed)
    /// data after each successful fetch.
    public var value: String
    /// How many samples to keep, 1...10000.
    public var size: Int = HistorySpec.defaultSize
    /// The least time between samples (a duration); the source's `refresh`
    /// when absent.
    public var every: String?

    enum CodingKeys: String, CodingKey { case value, size, every }

    public init(value: String, size: Int = HistorySpec.defaultSize, every: String? = nil) {
        self.value = value
        self.size = min(max(size, 1), Self.maxSize)
        self.every = every
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = c.lenient(String.self, .value) else {
            throw DecodingError.keyNotFound(CodingKeys.value, DecodingError.Context(
                codingPath: c.codingPath, debugDescription: "a history needs a value"))
        }
        self.value = value
        size = min(c.lenientPositive(.size) ?? Self.defaultSize, Self.maxSize)
        every = c.lenient(String.self, .every)
    }
}

// MARK: - Secrets

/// One named secret (EXTENSIBILITY.md 5.3): read from a file, an environment
/// variable or a command's output, once per load, and usable only in source
/// definitions as `{{ $secrets.<name> }}`.
public struct SecretConfig: Codable, Equatable, Sendable {
    public var file: String?
    public var env: String?
    public var command: [String]?

    enum CodingKeys: String, CodingKey { case file, env, command }

    public init(file: String? = nil, env: String? = nil, command: [String]? = nil) {
        self.file = file; self.env = env; self.command = command
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file    = c.lenient(String.self, .file)
        env     = c.lenient(String.self, .env)
        command = c.lenient([String].self, .command)
    }
}

// MARK: - Widget
//
// Heterogeneous widget configs are flattened into a single struct, with the
// `type` field acting as the discriminator. Widget-type-specific fields are
// all Optional; only the appropriate widget reads them. The defaults for
// absent keys are in `WidgetConfig.Defaults`.

public struct WidgetConfig: Codable, Equatable, Sendable {
    /// Keys each type accepts besides `type` (from SchemaRegistry).
    public static let keysByType = SchemaRegistry.keysByType(SchemaRegistry.widgetTypes)
    public static let aliases = SchemaRegistry.aliases(SchemaRegistry.widgetTypes)

    public static let systemBarItems = ["uptime", "disk", "battery", "claudeUsage", "codexUsage", "network", "privacy"]
    /// What an absent or empty `show` shows: every item but codexUsage,
    /// which runs a program (`codex app-server`) and is opt-in.
    public static let systemBarDefaultItems = systemBarItems.filter { $0 != "codexUsage" }
    public static let weatherFields = ["location", "region", "condition", "temp", "sunrise", "sunset"]
    public static let unitSystems = ["metric", "imperial"]
    public static let providers = ["foyer"]

    public enum Defaults {
        public static let maxEvents = 5
        public static let player = "Spotify"
        public static let hideWhenOff = true
        public static let provider = "foyer"
        public static let units = "metric"
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

    // ClaudeUsage: `path`, `fiveHourLimit` and `weeklyLimit` are accepted and
    // ignored (the claude source reads `claude -p /usage`).

    enum CodingKeys: String, CodingKey {
        case type, title, source, worldClocks, show, privacy, player, hideWhenOff, maxEvents,
             hosts, provider, items, fields, units
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
        units: String? = nil
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

    /// Every source this widget reads: its own `source`, its items' and its
    /// hosts' (`local` is not a source).
    public var sourceNames: Set<String> {
        var names = Set([source].compactMap { $0 })
        names.formUnion((items ?? []).compactMap(\.source))
        names.formUnion((hosts ?? []).compactMap(\.source).filter { $0 != HostConfig.local })
        return names
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
    public static let layouts = ["stack", "row", "grid"]

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

    /// `parse`, in seconds.
    public static func seconds(_ s: String) -> TimeInterval? {
        parse(s).map { TimeInterval($0.components.seconds) }
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
