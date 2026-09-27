import Foundation

// MARK: - Schema registry
//
// One declarative table of every config key: its type, default, kind
// (docs/EXTENSIBILITY.md §4.1), description, examples, allowed values and the
// version that introduced it. `vestal schema` (JSONSchema.swift), the key
// tables of `check-config` (ConfigValidator) and `Config.keysByType` all read
// from here, so they cannot drift. `vestal docs` reference pages will too.
//
// The decoder in Config.swift is still hand-written; a test checks that every
// key it reads is declared here and the other way round.

/// How a field's value is read (§4.1).
public enum SchemaKind: String, Sendable {
    /// A jq expression.
    case expr
    /// Literal text with `{{ expr }}` holes.
    case text
    /// A JSON value.
    case literal
}

/// The JSON a key takes.
public indirect enum SchemaType: Equatable, Sendable {
    case string
    /// A whole number, at least `minimum` and at most `maximum` when set.
    case integer(minimum: Int?, maximum: Int? = nil)
    case boolean
    /// A duration string: "30s", "5m", "4h", "1d".
    case duration
    /// One of these strings.
    case oneOf([String])
    case list(SchemaType)
    /// An object with free keys, every value of this type.
    case map(SchemaType)
    /// A shape declared in `SchemaRegistry.shapes`, by name.
    case shape(String)
    /// A source or a widget: a `type` and the keys that type takes.
    case source, widget
    /// A `platform` block: any top-level key except `platform`.
    case layer
    /// Any JSON value.
    case any
}

/// One key of an object.
public struct SchemaKey: Sendable {
    public var name: String
    public var type: SchemaType
    public var kind: SchemaKind
    /// Nil when the key has no default (it is required, or absent means off).
    public var defaultValue: AnyJSON?
    /// The entry is dropped or does nothing without it. Informational: a user
    /// file may leave it to a lower layer, so the JSON Schema doesn't require it.
    public var required: Bool
    /// `null` is a meaningful value, not only a deletion (`hotkey`).
    public var nullable: Bool
    public var description: String
    public var examples: [AnyJSON]
    public var since: String

    public init(_ name: String, _ type: SchemaType, kind: SchemaKind = .literal, default defaultValue: AnyJSON? = nil,
                required: Bool = false, nullable: Bool = false, since: String = "0.3",
                examples: [AnyJSON] = [], _ description: String) {
        self.name = name; self.type = type; self.kind = kind; self.defaultValue = defaultValue
        self.required = required; self.nullable = nullable; self.description = description
        self.examples = examples; self.since = since
    }
}

/// An object with fixed keys.
public struct SchemaShape: Sendable {
    public var name: String
    public var description: String
    public var keys: [SchemaKey]

    public init(_ name: String, _ description: String, keys: [SchemaKey]) {
        self.name = name; self.description = description; self.keys = keys
    }

    public var keyNames: [String] { keys.map(\.name) }

    public func key(_ name: String) -> SchemaKey? { keys.first { $0.name == name } }
}

/// A source type or a widget type: the keys it takes besides `type`.
public struct SchemaEntityType: Sendable {
    public var name: String
    public var aliases: [String]
    public var description: String
    public var keys: [SchemaKey]
    public var since: String

    public init(_ name: String, aliases: [String] = [], since: String = "0.3", _ description: String, keys: [SchemaKey]) {
        self.name = name; self.aliases = aliases; self.description = description; self.keys = keys; self.since = since
    }

    public var keyNames: [String] { keys.map(\.name) }
}

public enum SchemaRegistry {
    // MARK: Lookups

    /// `type` → the keys it takes besides `type` (Config's `keysByType`).
    public static func keysByType(_ types: [SchemaEntityType]) -> [String: Set<String>] {
        Dictionary(uniqueKeysWithValues: types.map { ($0.name, Set($0.keyNames)) })
    }

    /// Alias → canonical type name.
    public static func aliases(_ types: [SchemaEntityType]) -> [String: String] {
        var result: [String: String] = [:]
        for type in types { for alias in type.aliases { result[alias] = type.name } }
        return result
    }

    public static func sourceType(_ name: String) -> SchemaEntityType? {
        sourceTypes.first { $0.name == name || $0.aliases.contains(name) }
    }

    public static func widgetType(_ name: String) -> SchemaEntityType? {
        widgetTypes.first { $0.name == name || $0.aliases.contains(name) }
    }

    /// A shape by name. Traps on a name that isn't declared (a programming
    /// error, caught by the tests).
    public static func shape(_ name: String) -> SchemaShape {
        guard let shape = shapes.first(where: { $0.name == name }) else {
            preconditionFailure("no schema shape named \(name)")
        }
        return shape
    }

    /// The top-level keys, `platform` last.
    public static var topLevel: SchemaShape { shape("config") }

    // MARK: Shapes

    public static let shapes: [SchemaShape] = [
        SchemaShape("config", "A vestal config file. Every key is optional: the file is merged over the built-in defaults.", keys: [
            SchemaKey("version", .integer(minimum: 1, maximum: 1), default: .int(1), examples: [.int(1)],
                      "Schema version. Only 1 exists."),
            SchemaKey("hotkey", .string, default: .null, nullable: true, examples: [.string("f3"), .string("cmd+shift+space"), .null],
                      "Built-in toggle hotkey: f1-f20, letters, digits, space, escape, home or end, with cmd (super), ctrl, "
                      + "alt (opt) and shift, joined with +. Letters, digits, space and escape need cmd, ctrl or alt. null "
                      + "registers nothing; bind `vestal toggle` in the window manager instead."),
            SchemaKey("theme", .shape("theme"), default: defaults("theme"), examples: [.object(["background": .string("blur")])],
                      "Palette and background."),
            SchemaKey("sources", .map(.source), default: defaults("sources"),
                      examples: [.object(["rates": .object(["type": .string("http"), "url": .string("https://api.example.com/rates.json"),
                                                            "refresh": .string("4h")])])],
                      "Named data sources. Widgets refer to them by name; every widget reading one shares its fetch. "
                      + "null deletes a built-in one."),
            SchemaKey("widgets", .map(.widget), default: defaults("widgets"),
                      examples: [.object(["agenda": .object(["maxEvents": .int(3)])])],
                      "Named widgets. A widget shows when a view's order lists its key. null deletes a built-in one."),
            SchemaKey("views", .map(.shape("view")), default: defaults("views"),
                      examples: [.object(["main": .object(["order": .array([.string("clock"), .string("agenda")])])])],
                      "Named views. The dashboard shows main."),
            SchemaKey("secrets", .map(.shape("secret")), since: "0.4",
                      examples: [.object(["gh": .object(["command": .array([.string("gh"), .string("auth"), .string("token")])])])],
                      "Named secrets, usable in source definitions as {{ $secrets.name }}. Never write a secret's value into the config."),
            SchemaKey("platform", .shape("platform"),
                      examples: [.object(["linux": .object(["hotkey": .string("home")])])],
                      "Per-OS overrides: a macos and a linux block, each merged over the rest of the file on that OS only."),
        ]),
        SchemaShape("platform", "Per-OS blocks. Each takes any top-level key except platform.", keys: [
            SchemaKey("macos", .layer, examples: [.object(["hotkey": .string("f3")])],
                      "Merged over the rest of the file on macOS."),
            SchemaKey("linux", .layer, examples: [.object(["hotkey": .string("home")])],
                      "Merged over the rest of the file on Linux."),
        ]),
        SchemaShape("theme", "Palette and background.", keys: [
            SchemaKey("palette", .oneOf(ThemeConfig.palettes), default: .string("tokyo-night"), examples: [.string("tokyo-night")],
                      "The colour palette. An unknown name falls back to tokyo-night."),
            SchemaKey("background", .oneOf(ThemeConfig.backgrounds), default: .string("aurora"), examples: [.string("blur")],
                      "aurora: the animated aurora over the blurred desktop. blur: the blurred desktop only. none: the palette's solid background."),
        ]),
        SchemaShape("view", "A view: the widgets it shows, top to bottom.", keys: [
            SchemaKey("order", .list(.string), default: .array([]),
                      examples: [.array([.string("clock"), .string("systemBar"), .string("agenda")])],
                      "Widget keys, top to bottom. Each key may appear once."),
            SchemaKey("layout", .oneOf(ViewConfig.layouts), default: .string("stack"), examples: [.string("stack")],
                      "How the widgets are arranged. stack is the only layout so far."),
        ]),
        SchemaShape("worldClock", "An extra clock under the date.", keys: [
            SchemaKey("label", .string, kind: .text, required: true, examples: [.string("NYC")], "Shown next to the time."),
            SchemaKey("tz", .string, required: true, examples: [.string("America/New_York")], "An IANA time zone."),
        ]),
        SchemaShape("privacy", "The system bar's privacy toggle. It shows, and its p key works, only when both keys are set.", keys: [
            SchemaKey("command", .list(.string), kind: .text, examples: [.array([.string("~/bin/toggle-privacy")])],
                      "Run to toggle privacy mode, with the rules of a command source's argv."),
            SchemaKey("stateFile", .string, examples: [.string("~/.cache/privacy-mode")],
                      "The file that exists while privacy mode is on. A leading ~/ expands."),
        ]),
        SchemaShape("host", "A host of a systemHealth widget. It needs url or source.", keys: [
            SchemaKey("name", .string, kind: .text, examples: [.string("web")],
                      "Display name. Required, except for a local host, which is named after this machine."),
            SchemaKey("url", .string, kind: .text, examples: [.string("https://web.example.com")],
                      "The host's foyer base URL."),
            SchemaKey("source", .string, examples: [.string("local"), .string("health")],
                      "local: this machine, read in-process. Any other value names a source whose JSON is a foyer /api/health payload."),
            SchemaKey("key", .string, examples: [.string("w")],
                      "Shortcut letter, a to z; p and i are reserved. Default: the first free letter of the name."),
            SchemaKey("interval", .duration, default: .string(HostConfig.defaultInterval), examples: [.string("10s")],
                      "How often a url host is polled while the dashboard is shown."),
        ]),
        SchemaShape("item", "A labelled value of a keyValueList. It needs pick or picks.", keys: [
            SchemaKey("label", .string, kind: .text, required: true, examples: [.string("EUR")], "Shown above the value."),
            SchemaKey("source", .string, examples: [.string("rates")], "Where to pick from. Default: the widget's source."),
            SchemaKey("match", .map(.any), examples: [.object(["casa": .string("blue")])],
                      "When the source's JSON is a list, use the first element whose fields equal all of these values."),
            SchemaKey("pick", .string, examples: [.string("rates.EUR")],
                      "Path of the one value to show: field names separated by dots (the leading dot is optional) and [N] indexes. "
                      + "A legacy path, never jq."),
            SchemaKey("picks", .shape("picks"), examples: [.object(["buy": .string("compra"), "sell": .string("venta")])],
                      "Paths of two values, shown as buy / sell."),
            SchemaKey("format", .oneOf(PickItem.formats), examples: [.string("int"), .string("decimal")],
                      "int (alias integer): a whole number. decimal (alias %.2f): two decimals. Absent: as is."),
        ]),
        SchemaShape("history", "A number history of a source: one sample per successful fetch, at most every `every`.", keys: [
            SchemaKey("value", .string, kind: .expr, required: true, since: "0.4", examples: [.string(".bitcoin.usd")],
                      "A jq expression giving the number to record; a non-number is skipped."),
            SchemaKey("size", .integer(minimum: 1, maximum: HistorySpec.maxSize), default: .int(HistorySpec.defaultSize),
                      since: "0.4", examples: [.int(288)], "How many samples to keep."),
            SchemaKey("every", .duration, since: "0.4", examples: [.string("5m")],
                      "The least time between samples. Default: the source's refresh."),
        ]),
        SchemaShape("secret", "A secret, read when the config loads. Give exactly one key.", keys: [
            SchemaKey("file", .string, since: "0.4", examples: [.string("~/.config/vestal/secrets/token")],
                      "A file whose contents (trimmed) are the secret. A leading ~/ expands."),
            SchemaKey("env", .string, since: "0.4", examples: [.string("OPENWEATHER_KEY")], "An environment variable."),
            SchemaKey("command", .list(.string), since: "0.4", examples: [.array([.string("gh"), .string("auth"), .string("token")])],
                      "A program whose output (trimmed) is the secret, run with a 10 second timeout."),
        ]),
        SchemaShape("picks", "Paths of a buy and a sell value (legacy paths, never jq).", keys: [
            SchemaKey("buy", .string, examples: [.string("compra")], "Path of the buy value."),
            SchemaKey("sell", .string, examples: [.string("venta")], "Path of the sell value."),
        ]),
        SchemaShape("weatherFields", "Paths into the weather source (legacy paths, never jq).", keys: WidgetConfig.weatherFields.map { field in
            SchemaKey(field, .string, examples: [.string(weatherExamples[field] ?? ".x")], weatherDescriptions[field] ?? field)
        }),
    ]

    // MARK: Sources

    public static let sourceTypes: [SchemaEntityType] = [
        SchemaEntityType("http", "Fetches a URL.", keys: [
            SchemaKey("url", .string, kind: .text, required: true, examples: [.string("https://wttr.in/?m&format=j1")],
                      "An http:// or https:// URL. The answer must have a 2xx status. May use {{ $secrets.name }} and {{ $env.NAME }}."),
            SchemaKey("method", .oneOf(SourceConfig.methods), default: .string("GET"), since: "0.4", examples: [.string("POST")],
                      "GET or POST."),
            SchemaKey("headers", .map(.string), kind: .text, since: "0.4",
                      examples: [.object(["Authorization": .string("Bearer {{ $secrets.token }}")])],
                      "Request headers."),
            SchemaKey("body", .any, since: "0.4", examples: [.object(["query": .string("x")]), .string("a=1&b=2")],
                      "The POST body: text, or a JSON value sent as application/json."),
            timeout("The request fails after this long."),
        ] + common("30m", "always") + [parse("the body")]),
        SchemaEntityType("command", "Runs a program, never through a shell.", keys: [
            SchemaKey("argv", .list(.string), kind: .text, required: true,
                      examples: [.array([.string("~/bin/health-json"), .string("--host"), .string("nas")])],
                      "The program and its arguments. argv[0] is looked up on PATH and the usual Nix and Homebrew directories. "
                      + "A leading ~ or ~/ in any element expands to the home directory."),
            timeout("The command is killed after this long."),
            SchemaKey("env", .map(.string), kind: .text, examples: [.object(["TOKEN_FILE": .string("/run/secrets/token")])],
                      "Added to the command's environment."),
        ] + common("30m", "always") + [parse("stdout")]),
        SchemaEntityType("calendar", aliases: ["eventkit"],
                         "Events: EventKit on macOS, or .ics files, directories and URLs (ics) on both OSes.", keys: [
            SchemaKey("days", .integer(minimum: 1), default: .int(SourceConfig.defaultDays), examples: [.int(2)],
                      "How many days to read, today being the first."),
            SchemaKey("calendars", .list(.string), examples: [.array([.string("Work"), .string("Home")])],
                      "Only calendars with these names. Default: all."),
            SchemaKey("ics", .any, kind: .text, since: "0.4",
                      examples: [.array([.string("~/.calendars/work"), .string("https://example.com/cal.ics")])],
                      "A list (or one) of .ics files, directories of them, or http(s) URLs. Without it macOS reads EventKit and "
                      + "Linux yields no events. Recurrences with unsupported rules (BYSETPOS, BYWEEKNO, ...) are left out."),
            timeout("For ics URLs."),
        ] + common("30m", "always")),
        SchemaEntityType("file", since: "0.4", "Reads a file.", keys: [
            SchemaKey("path", .string, kind: .text, required: true, examples: [.string("~/.local/state/notes.json")],
                      "The file. A leading ~/ expands."),
            SchemaKey("parse", .oneOf(SourceConfig.fileParseModes), default: .string("json"), examples: [.string("exists")],
                      "As for http, plus exists: {exists, modified}, which never fails."),
        ] + common("30s", "always")),
        SchemaEntityType("system", since: "0.4", "This machine's CPU, memory, temperature, battery, disks, network and volume.", keys: [
            SchemaKey("disks", .list(.string), default: .array(SourceConfig.defaultDisks.map(AnyJSON.string)),
                      examples: [.array([.string("/"), .string("/home")])], "Mount points to report."),
            SchemaKey("interfaces", .list(.string), examples: [.array([.string("en0")])],
                      "Network interfaces to report and sum. Default: all but loopback (on Linux, the physical ones)."),
        ] + common("3s", "visible")),
        SchemaEntityType("media", since: "0.4", "One music player: state, track, album, position, duration and the players seen.", keys: [
            SchemaKey("player", .any, default: .array([.string(SourceConfig.defaultPlayer)]), examples: [.string("Spotify"), .array([.string("Spotify"), .string("spotifyd")])],
                      "A player name, or a list (the first running one wins), or auto: an AppleScript application on macOS "
                      + "(auto: Spotify, then Music), an MPRIS player through playerctl on Linux (auto: the first playing one)."),
        ] + common("3s", "visible")),
        SchemaEntityType("claude", since: "0.4", "Claude Code token usage over 5 hours and 7 days.", keys: [
            SchemaKey("path", .string, default: .string(SourceConfig.defaultClaudePath), examples: [.string("~/.claude/projects")],
                      "Claude Code's projects directory. A leading ~/ expands."),
            SchemaKey("fiveHourLimit", .integer(minimum: 1), default: .int(ClaudeUsage.blockLimitTokens), examples: [.int(8_000_000)],
                      "Tokens that count as 100% over 5 hours."),
            SchemaKey("weeklyLimit", .integer(minimum: 1), default: .int(ClaudeUsage.weeklyLimitTokens), examples: [.int(95_000_000)],
                      "Tokens that count as 100% over 7 days."),
        ] + common("30s", "visible")),
    ]

    /// The keys every source takes (EXTENSIBILITY.md 5.1), with the type's
    /// `refresh` and `when` defaults.
    private static func common(_ refresh: String, _ when: String) -> [SchemaKey] {
        [
            SchemaKey("refresh", .duration, default: .string(refresh), examples: [.string("5m"), .string("4h")],
                      "How often to fetch."),
            SchemaKey("when", .oneOf(SourceConfig.whenValues), default: .string(when), since: "0.4", examples: [.string("visible")],
                      "always: fetched whether or not the dashboard is shown. visible: only while it is shown and a widget reads it."),
            SchemaKey("transform", .string, kind: .expr, since: "0.4", examples: [.string(".items")],
                      "A jq expression applied to the data before widgets see it; the cache keeps the data untransformed."),
            SchemaKey("history", .map(.shape("history")), since: "0.4",
                      examples: [.object(["price": .object(["value": .string(".usd"), "size": .int(288), "every": .string("5m")])])],
                      "Named number histories for sparklines, kept across restarts."),
            SchemaKey("maxAge", .duration, since: "0.4", examples: [.string("1h")],
                      "Cached data older than this is not shown at startup."),
            SchemaKey("cache", .boolean, default: .bool(true), since: "0.4", examples: [.bool(false)],
                      "false: never written to disk."),
        ]
    }

    private static func timeout(_ description: String) -> SchemaKey {
        SchemaKey("timeout", .duration, default: .string(SourceConfig.defaultTimeout), examples: [.string("5s")], description)
    }

    private static func parse(_ what: String) -> SchemaKey {
        SchemaKey("parse", .oneOf(SourceConfig.parseModes), default: .string("json"), examples: [.string("raw")],
                  "json: \(what) must be valid JSON. raw: \(what) as it is. lines: a list of its lines. "
                  + "feed: an RSS, Atom or JSON Feed document as {title, url, items}.")
    }


    // MARK: Widgets

    public static let widgetTypes: [SchemaEntityType] = [
        SchemaEntityType("clock", "The local time and date.", keys: [
            SchemaKey("worldClocks", .list(.shape("worldClock")),
                      examples: [.array([.object(["label": .string("NYC"), "tz": .string("America/New_York")])])],
                      "Extra clocks under the date. A clock in the local time zone is skipped."),
        ]),
        SchemaEntityType("systemBar", "A row of system stats.", keys: [
            SchemaKey("show", .list(.oneOf(WidgetConfig.systemBarItems)), default: .array(WidgetConfig.systemBarItems.map(AnyJSON.string)),
                      examples: [.array([.string("uptime"), .string("battery"), .string("network")])],
                      "Items, left to right. privacy is always drawn at the right end. Absent or empty shows every item."),
            SchemaKey("privacy", .shape("privacy"),
                      examples: [.object(["command": .array([.string("~/bin/toggle-privacy")]), "stateFile": .string("~/.cache/privacy-mode")])],
                      "The privacy toggle: a command to run and the file that exists while privacy mode is on."),
        ]),
        SchemaEntityType("media", aliases: ["spotify"], "What a music player is playing, with play/pause and the output volume.", keys: [
            SchemaKey("player", .string, default: .string(WidgetConfig.Defaults.player), examples: [.string("Music")],
                      "The player application: over AppleScript on macOS, the MPRIS player (playerctl, lowercased) on Linux."),
            SchemaKey("hideWhenOff", .boolean, default: .bool(WidgetConfig.Defaults.hideWhenOff), examples: [.bool(false)],
                      "Hide the row while the player is not running or has nothing loaded."),
        ]),
        SchemaEntityType("agendaList", "The next events from a calendar source.", keys: [
            SchemaKey("source", .string, required: true, examples: [.string("calendar")],
                      "A calendar source, or a command or http source whose JSON is the same list of events."),
            SchemaKey("maxEvents", .integer(minimum: 1), default: .int(WidgetConfig.Defaults.maxEvents), examples: [.int(3)],
                      "At most this many events."),
            title("Today"),
        ]),
        SchemaEntityType("systemHealth", "CPU, memory, temperature and uptime of hosts.", keys: [
            SchemaKey("hosts", .list(.shape("host")), required: true,
                      examples: [.array([.object(["source": .string("local")]),
                                         .object(["name": .string("web"), "url": .string("https://web.example.com")])])],
                      "The hosts, in display order."),
            SchemaKey("provider", .oneOf(WidgetConfig.providers), default: .string(WidgetConfig.Defaults.provider), examples: [.string("foyer")],
                      "Where remote health comes from: foyer runs `foyer-api --host <url> /api/health`."),
            title("Systems"),
        ]),
        SchemaEntityType("keyValueList", "Labelled values picked out of JSON sources, such as exchange rates.", keys: [
            SchemaKey("source", .string, examples: [.string("rates")], "The source items read, unless they name their own."),
            SchemaKey("items", .list(.shape("item")), required: true,
                      examples: [.array([.object(["label": .string("EUR"), "pick": .string("rates.EUR"), "format": .string("decimal")])])],
                      "The values, in display order."),
            title(nil),
        ]),
        SchemaEntityType("weatherCard", "Current weather from a JSON source; the fields are paths, so any weather API works.", keys: [
            SchemaKey("source", .string, required: true, examples: [.string("weather")], "A JSON source (http or command)."),
            SchemaKey("fields", .shape("weatherFields"), required: true,
                      examples: [.object(["temp": .string(".current_condition[0].temp_C")])],
                      "Paths of the values to show."),
            SchemaKey("units", .oneOf(WidgetConfig.unitSystems), default: .string(WidgetConfig.Defaults.units), examples: [.string("imperial")],
                      "Only picks the °C or °F suffix: point fields.temp at the matching value yourself."),
            title("Weather"),
        ]),
        SchemaEntityType("claudeUsage", "Claude Code token usage over 5 hours and 7 days, as percentages of two limits.", keys: [
            SchemaKey("path", .string, default: .string(WidgetConfig.Defaults.claudePath), examples: [.string("~/.claude/projects")],
                      "Claude Code's projects directory. A leading ~/ expands."),
            SchemaKey("fiveHourLimit", .integer(minimum: 1), default: .int(WidgetConfig.Defaults.fiveHourLimit), examples: [.int(8_000_000)],
                      "Tokens that count as 100% over 5 hours."),
            SchemaKey("weeklyLimit", .integer(minimum: 1), default: .int(WidgetConfig.Defaults.weeklyLimit), examples: [.int(95_000_000)],
                      "Tokens that count as 100% over 7 days."),
        ]),
    ]

    private static func title(_ fallback: String?) -> SchemaKey {
        SchemaKey("title", .string, kind: .text, default: fallback.map(AnyJSON.string),
                  examples: [.string(fallback ?? "Rates")],
                  "Section title." + (fallback == nil ? " Default: the widget key, first letter capitalized." : ""))
    }

    // MARK: Helpers

    private static func defaults(_ key: String) -> AnyJSON? {
        DefaultConfig.tree.objectValue?[key]
    }

    private static let weatherExamples = [
        "location": ".nearest_area[0].areaName[0].value",
        "region": ".nearest_area[0].region[0].value",
        "condition": ".current_condition[0].weatherDesc[0].value",
        "temp": ".current_condition[0].temp_C",
        "sunrise": ".weather[0].astronomy[0].sunrise",
        "sunset": ".weather[0].astronomy[0].sunset",
    ]

    private static let weatherDescriptions = [
        "location": "The place name, shown as location, region.",
        "region": "The region, shown after the location.",
        "condition": "The current condition, such as Partly cloudy.",
        "temp": "The temperature, in the units named by units.",
        "sunrise": "Sunrise, as 06:15 AM or 06:15.",
        "sunset": "Sunset, as 06:15 PM or 18:15.",
    ]
}
