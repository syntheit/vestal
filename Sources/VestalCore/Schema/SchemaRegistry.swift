import Foundation

// MARK: - Schema registry
//
// One declarative table of every config key: its type, default, kind,
// description, examples, allowed values and the
// version that introduced it. `vestal schema` (JSONSchema.swift), the key
// tables of `check-config` (ConfigValidator) and `Config.keysByType` all read
// from here, so they cannot drift. `vestal docs` reference pages will too.
//
// The decoder in Config.swift is still hand-written; a test checks that every
// key it reads is declared here and the other way round.

/// How a field's value is read.
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
    /// Any number.
    case number
    /// A duration string: "30s", "5m", "4h", "1d".
    case duration
    /// One of these strings.
    case oneOf([String])
    /// One of these strings, or an object of the named shape.
    case nameOrShape([String], String)
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
    /// A literal field that may also be `{"expr": "<jq>"}`, computed at
    /// render.
    public var computed: Bool

    public init(_ name: String, _ type: SchemaType, kind: SchemaKind = .literal, default defaultValue: AnyJSON? = nil,
                required: Bool = false, nullable: Bool = false, since: String = "0.3",
                examples: [AnyJSON] = [], computed: Bool = false, _ description: String) {
        self.name = name; self.type = type; self.kind = kind; self.defaultValue = defaultValue
        self.required = required; self.nullable = nullable; self.description = description
        self.examples = examples; self.since = since; self.computed = computed
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
            SchemaKey("gesture", .oneOf(["pinch"]), default: .null, nullable: true, since: "0.4", examples: [.string("pinch"), .null],
                      "Trackpad gesture for the dashboard: pinch (thumb and three fingers, the old Launchpad gesture). "
                      + "Pinching in opens it, spreading closes it, and the fade follows the fingers. macOS only; "
                      + "ignored on Linux. null registers nothing."),
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
            SchemaKey("defaultView", .string, default: .string("main"), since: "0.4", examples: [.string("main")],
                      "The view show and toggle open."),
            SchemaKey("pages", .shape("pages"), since: "0.4",
                      examples: [.object(["order": .array([.string("main"), .string("focus")]), "transition": .string("fade")])],
                      "Paging between views, like home screens: their order, the transition, the dots and the swipe. "
                      + "left and right (and tab) page when the keys are unbound."),
            SchemaKey("keys", .map(.any), default: .object([:]), since: "0.4",
                      examples: [.object(["r": .object(["refresh": .string("*")])])],
                      "Global key bindings: a key (h, 2, tab, shift+tab, cmd+r, ...) → an action or a list of actions. "
                      + "escape and alt+i are reserved."),
            SchemaKey("templates", .map(.shape("template")), default: .object([:]), since: "0.4",
                      examples: [.object(["metric": .object(["params": .object(["label": .object(["type": .string("text")])]),
                                                             "widget": .object(["type": .string("text"), "text": .object(["param": .string("label")])])])])],
                      "Parameterised widgets and sources, used like a type. Built-in templates (the presets) are "
                      + "separate; a user template with a built-in's name needs \"override\": true."),
            SchemaKey("functions", .map(.string), kind: .expr, default: .object([:]), since: "0.4",
                      examples: [.object(["gib": .string(". / 1073741824 | fmt_fixed(1)")])],
                      "jq functions with no arguments, name → body, callable from every expression. Names match "
                      + "^[a-z_][a-z0-9_]*$ and may not shadow a builtin."),
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
            SchemaKey("palette", .string, default: .string("tokyo-night"), examples: [.string("tokyo-night")],
                      "The colour palette: tokyo-night, or a key of palettes. An unknown name falls back to tokyo-night."),
            SchemaKey("background", .nameOrShape(Backgrounds.names, "background"), default: .string("aurora"),
                      examples: [.string("blur"), .object(["type": .string("sky")])],
                      "aurora: the animated aurora over the blurred desktop. blur: the blurred desktop only. none: the palette's "
                      + "solid background. Or a background of the library: mesh, topo, stars, flow, rain, plasma, grain, sky, "
                      + "weather, load, artmesh (`vestal docs styling`), written as a name or as an object with `type` and its parameters."),
            SchemaKey("dim", .number, since: "0.4", examples: [.double(0.8)],
                      "0 to 1: the opacity of the palette's bg over the blurred desktop, for aurora and blur. Default: 0.5 on "
                      + "Linux; on macOS none (the material's own tint). About 0.75 to 0.85 hides busy windows behind."),
            SchemaKey("backdrop", .oneOf(ThemeConfig.backdrops), since: "0.4", examples: [.string("compositor")],
                      "Linux: self (vestal captures the screen before it shows and blurs it), compositor (a translucent "
                      + "window over the compositor's blur) or none (translucent, no blur). Default: self where the "
                      + "compositor can capture the screen, else compositor. macOS ignores it."),
            SchemaKey("blur", .number, since: "0.4", examples: [.int(64)],
                      "Linux, backdrop self: the blur's radius in points, 0 to 200. Default 48."),
            SchemaKey("backgroundFPS", .integer(minimum: 1, maximum: 60), default: .int(Backgrounds.defaultFPS), since: "0.4",
                      examples: [.int(20)],
                      "Frames a second of a library background (not the aurora, which draws at the display's rate). Lower is cheaper."),
            SchemaKey("backgroundResolution", .number, since: "0.4", examples: [.double(0.5)],
                      "The share of the screen's pixels a library background renders at, 0.1 to 1; it is scaled up to fit. "
                      + "Default: per background, from 0.25 (mesh, plasma) to 0.9 (grain)."),
            SchemaKey("palettes", .map(.shape("palette")), since: "0.4",
                      examples: [.object(["ember": .object(["extends": .string("tokyo-night"), "colors": .object(["accent": .string("#ff9e64")])])])],
                      "User palettes: name → extends and colors."),
            SchemaKey("colors", .map(.string), since: "0.4", examples: [.object(["brand": .string("#e01e5a")])],
                      "Colours added to or overriding the chosen palette: name → colour (hex, a palette name, or name@alpha)."),
            SchemaKey("typeface", .oneOf(Typefaces.names), default: .string(Typefaces.defaultName), since: "0.4",
                      examples: [.string("inter")],
                      "A named set of fonts filling the roles at once (display, sans, mono, rounded). "
                      + Typefaces.all.map { "\($0.name): \($0.summary)" }.joined(separator: " ")
                      + " The families ship with vestal. theme.fonts entries override the set's roles."),
            SchemaKey("fonts", .shape("fonts"), since: "0.4", examples: [.object(["sans": .string("Inter")])],
                      "A font family per role (display, sans, mono, rounded); null means the typeface's family, else the "
                      + "platform default. A family that is not bundled or installed draws as the role's default."),
            SchemaKey("font", .string, since: "0.4", examples: [.string("Inter")],
                      "Shorthand for fonts.sans."),
            SchemaKey("scale", .number, default: .int(1), since: "0.4", examples: [.double(1.25)],
                      "Multiplies every text, icon and fixed size (not gaps or padding)."),
            SchemaKey("density", .oneOf(ThemeConfig.densities), default: .string("comfortable"), since: "0.4",
                      examples: [.string("compact")],
                      "How much room the built-in presets take. comfortable: the v0.3 look. compact: a smaller clock with the "
                      + "date and world clocks on one line, no section titles or rules, tighter rows and gaps, one-line "
                      + "currencies and weather. Views' default gap follows it."),
            SchemaKey("icons", .oneOf(["native", "phosphor"]), since: "0.4", examples: [.string("phosphor")],
                      "native: the macOS UI draws the presets' icons as SF Symbols (the default on macOS). phosphor: the bundled "
                      + "Phosphor font everywhere."),
        ]),
        SchemaShape("background", "A library background with parameters; theme.background takes this or just a name.", keys: [
            SchemaKey("type", .oneOf(Backgrounds.names), required: true, since: "0.4", examples: [.string("mesh")],
                      "Which background."),
            SchemaKey("colors", .list(.string), since: "0.4", examples: [.array([.string("#1e2a62"), .string("purple")])],
                      "mesh (and artmesh without artwork): up to four colours (hex or palette names); fewer repeat."),
            SchemaKey("source", .string, since: "0.4", examples: [.string("system")],
                      "load, weather, artmesh: the source value, condition and artwork read. Default: system, weather, media."),
            SchemaKey("value", .string, kind: .expr, since: "0.4", examples: [.string(".cpu.percent")],
                      "load: an expression over the source giving 0 to 100 (shown as 0 to 1). Default .cpu.percent."),
            SchemaKey("condition", .string, kind: .expr, since: "0.4", examples: [.string(".current_condition[0].weatherCode")],
                      "weather: clear, rain, snow or storm written as is, or an expression over the source giving one of those, "
                      + "a description in words, or a WMO or wttr.in weather code. Default .current_condition[0].weatherCode."),
            SchemaKey("artwork", .string, kind: .expr, since: "0.4", examples: [.string(".artwork")],
                      "artmesh: an expression over the source giving a picture's path or URL, whose colours the mesh takes. "
                      + "Default .artwork. Without a picture the mesh keeps its default colours."),
        ]),
        SchemaShape("pages", "Paging between views. A page is an enabled view; the dots show when there are two or more.", keys: [
            SchemaKey("order", .list(.string), since: "0.4", examples: [.array([.string("main"), .string("focus")])],
                      "The views to page through, in order. Default: the views in key order, then by name. A view not "
                      + "listed stays reachable by its key and vestal show, but is not paged to."),
            SchemaKey("transition", .oneOf(PagesConfig.transitions), default: .string("slide"), since: "0.4",
                      examples: [.string("fade")],
                      "How a change of page is drawn. With reduced motion on, slide is a short fade."),
            SchemaKey("indicator", .oneOf(PagesConfig.indicators), default: .string("dots"), since: "0.4",
                      examples: [.string("none")], "dots: one per page near the bottom, drawn only with two or more pages."),
            SchemaKey("swipe", .boolean, default: .bool(true), since: "0.4", examples: [.bool(false)],
                      "Two-finger horizontal trackpad swipe between pages."),
            SchemaKey("wrap", .boolean, default: .bool(false), since: "0.4", examples: [.bool(true)],
                      "Whether next on the last page goes to the first (and previous on the first to the last)."),
        ]),
        SchemaShape("view", "A view: the widgets it shows, top to bottom.", keys: [
            SchemaKey("order", .list(.string), default: .array([]),
                      examples: [.array([.string("clock"), .string("systemBar"), .string("agenda")])],
                      "Widget keys, top to bottom. Each key may appear once. v0.3's name for children: only the first "
                      + "listed entry gets no space before it."),
            SchemaKey("layout", .oneOf(ViewConfig.layouts), default: .string("stack"), examples: [.string("stack")],
                      "The root container: stack (top to bottom), row or grid."),
            SchemaKey("children", .list(.any), default: .array([]), since: "0.4",
                      examples: [.array([.string("clock"), .object(["type": .string("text"), "text": .string("Hi")])])],
                      "Widget keys or inline widgets. Wins over order when both are set."),
            SchemaKey("title", .string, kind: .text, since: "0.4", examples: [.string("Work")],
                      "Shown by UIs that list views. Default: the name, capitalized."),
            SchemaKey("key", .string, since: "0.4", examples: [.string("2")],
                      "A key that switches to this view (a global binding)."),
            SchemaKey("enabled", .boolean, default: .bool(true), since: "0.4", examples: [.bool(false)],
                      "false: the view does not exist as far as the dashboard goes. No key, no paging, vestal show "
                      + "refuses it, nothing in it is evaluated."),
            SchemaKey("columns", .integer(minimum: 1), default: .int(2), since: "0.4", examples: [.int(3)],
                      "Columns, for layout grid."),
            SchemaKey("gap", .number, default: .int(24), since: "0.4", examples: [.int(32)],
                      "Space between root children (presets set their own spaceBefore)."),
            SchemaKey("align", .oneOf(["start", "center", "end", "stretch"]), default: .string("center"), since: "0.4",
                      examples: [.string("stretch")], "Cross-axis alignment of root children."),
            SchemaKey("padding", .any, default: .int(48), since: "0.4", examples: [.int(32), .array([.int(24), .int(48), .int(24), .int(48)])],
                      "Inside maxWidth: a number, or [top, right, bottom, left]."),
            SchemaKey("maxWidth", .number, default: .int(680), since: "0.4", examples: [.int(1100)],
                      "The root is at most this wide, centred on screen."),
            SchemaKey("keys", .map(.any), default: .object([:]), since: "0.4",
                      examples: [.object(["n": .object(["open": .string("https://news.ycombinator.com")])])],
                      "Key bindings of this view: key → action."),
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
    ] + v04Shapes

    // MARK: Sources

    public static let sourceTypes: [SchemaEntityType] = [
        SchemaEntityType("http", "Fetches a URL.", keys: [
            SchemaKey("url", .string, kind: .text, required: true, examples: [.string("https://wttr.in/?m&format=j1")],
                      "An http:// or https:// URL. The answer must have a 2xx status. May use {{ $secrets.name }} and {{ $env.NAME }}."),
            SchemaKey("also", .any, kind: .text, since: "0.4",
                      examples: [.array([.string("https://status.example.com/api/status-page/heartbeat/main")])],
                      "More http(s) URLs fetched together with url, with the same method, headers and body. The data is then a list "
                      + "of the answers, url's first, in order; if any fails, the fetch fails. For APIs that spread what one widget "
                      + "needs over two endpoints (join them with transform)."),
            SchemaKey("method", .oneOf(SourceConfig.methods), default: .string("GET"), since: "0.4", examples: [.string("POST")],
                      "GET or POST."),
            SchemaKey("headers", .map(.string), kind: .text, since: "0.4",
                      examples: [.object(["Authorization": .string("Bearer {{ $secrets.token }}")])],
                      "Request headers."),
            SchemaKey("body", .any, since: "0.4", examples: [.object(["query": .string("x")]), .string("a=1&b=2")],
                      "The POST body: text, or a JSON value sent as application/json. Text, and every string inside a JSON value, may use {{ $secrets.name }} and {{ $env.NAME }}."),
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
                         "Events: EventKit on macOS, or .ics files, directories and URLs (ics), CalDAV servers (caldav) or Thunderbird's calendars (thunderbird) on both OSes.", keys: [
            SchemaKey("days", .integer(minimum: 1), default: .int(SourceConfig.defaultDays), examples: [.int(2)],
                      "How many days to read, today being the first."),
            SchemaKey("includePast", .boolean, since: "0.4", examples: [.bool(true)],
                      "true: read from the start of today instead of from now, so events that already ended are in the data too "
                      + "(the dayTimeline preset dims them). Widgets that list what is coming filter on the end time. Default: false."),
            SchemaKey("calendars", .list(.string), examples: [.array([.string("Work"), .string("Home")])],
                      "Only calendars with these names. Default: all."),
            SchemaKey("ics", .any, kind: .text, since: "0.4",
                      examples: [.array([.string("~/.calendars/work"), .string("https://example.com/cal.ics")])],
                      "A list (or one) of .ics files, directories of them, or http(s) URLs. Without it macOS reads EventKit and "
                      + "Linux yields no events. Recurrences with unsupported rules (BYSETPOS, BYWEEKNO, ...) are left out."),
            SchemaKey("caldav", .any, kind: .text, since: "0.4",
                      examples: [.array([.string("https://me:{{ $secrets.dav }}@dav.example.com/")])],
                      "A list (or one) of CalDAV URLs: a calendar collection, or a server or principal URL whose calendars are "
                      + "discovered (RFC 4791, /.well-known/caldav). user:password@ in the URL is sent as Basic authentication. "
                      + "Like ics, it replaces the platform's calendar, and the two combine. `calendars` filters by display name."),
            SchemaKey("thunderbird", .any, kind: .text, since: "0.4",
                      examples: [.bool(true)],
                      "true for Thunderbird's default profile, or a profile directory such as ~/.thunderbird/abcd1234.default: its "
                      + "calendars with Offline support enabled, read from the profile's local databases. Replaces EventKit like ics, "
                      + "and adds to ics and caldav when set."),
            timeout("For ics and caldav URLs."),
        ] + common("30m", "always")),
        SchemaEntityType("file", since: "0.4", "Reads a file.", keys: [
            SchemaKey("path", .string, kind: .text, required: true, examples: [.string("~/.local/state/notes.json")],
                      "The file, or a directory of .json files (the data is then a list of their contents, each object with _file and _modified added). A leading ~/ expands."),
            SchemaKey("parse", .oneOf(SourceConfig.fileParseModes), default: .string("json"), examples: [.string("exists")],
                      "As for http, plus exists: {exists, modified}, which never fails; and checklist: a markdown file's task list "
                      + "as {path, size, hash, items: [{line, text, done, section}]} (vestal docs source/file)."),
        ] + common("30s", "always")),
        SchemaEntityType("timer", since: "0.4",
                         "A pomodoro timer that keeps its state in the running vestal: focus and break lengths, rounds, a task label.", keys: [
            SchemaKey("focus", .duration, since: "0.4", examples: [.string("50m")],
                      "The length of a focus phase. Default: \(TimerSettings.defaultFocus)."),
            SchemaKey("shortBreak", .duration, since: "0.4", examples: [.string("10m")],
                      "The break after a focus phase. Default: \(TimerSettings.defaultShortBreak)."),
            SchemaKey("longBreak", .duration, since: "0.4", examples: [.string("20m")],
                      "The break after the last focus round. Default: \(TimerSettings.defaultLongBreak)."),
            SchemaKey("rounds", .integer(minimum: 1), since: "0.4", examples: [.int(3)],
                      "Focus rounds before the long break. Default: \(TimerSettings.defaultRounds)."),
            SchemaKey("task", .string, since: "0.4", examples: [.string("Writing: onboarding copy")],
                      "The task label the focusTimer preset shows."),
            SchemaKey("autoStart", .boolean, since: "0.4", examples: [.bool(true)],
                      "true: start the next phase by itself when one ends. Default: false, the timer waits, ready, for the start key."),
        ] + common("1s", "visible", cache: false)),
        SchemaEntityType("system", since: "0.4", "This machine's CPU, memory, temperature, battery, disks, network and volume.", keys: [
            SchemaKey("disks", .list(.string), default: .array(SourceConfig.defaultDisks.map(AnyJSON.string)),
                      examples: [.array([.string("/"), .string("/home")])], "Mount points to report."),
            SchemaKey("interfaces", .list(.string), examples: [.array([.string("en0")])],
                      "Network interfaces to report and sum. Default: all but loopback (on Linux, the physical ones)."),
            SchemaKey("processes", .integer(minimum: 1), examples: [.int(5)],
                      "Report the busiest processes by CPU as processes[] ({pid, name, cpu, memory}), at most 20. "
                      + "Absent: processes is an empty list and no process is read."),
        ] + common("3s", "visible")),
        SchemaEntityType("media", since: "0.4", "One music player: state, track, album, position, duration and the players seen.", keys: [
            SchemaKey("player", .any, default: .array([.string(SourceConfig.defaultPlayer)]), examples: [.string("Spotify"), .array([.string("Spotify"), .string("spotifyd")])],
                      "A player name, or a list (the first running one wins), or auto: an AppleScript application on macOS "
                      + "(auto: Spotify, then Music), an MPRIS player through playerctl on Linux (auto: the first playing one)."),
        ] + common("3s", "visible")),
        SchemaEntityType("claude", since: "0.4",
                         "Claude plan usage (session, weekly and per-model windows) from Claude's usage endpoint, or `claude -p /usage`.", keys: [
            SchemaKey("backend", .oneOf(SourceConfig.claudeBackends), default: .string("auto"), since: "0.4", examples: [.string("cli")],
                      "api: ask Anthropic's usage endpoint with the Claude Code login's access token (read, never refreshed or "
                      + "written); cli: run the command in argv; auto: the API when a token is found, else, or when the API "
                      + "fails, the CLI."),
            SchemaKey("argv", .list(.string), since: "0.4",
                      examples: [.array([.string("~/.local/bin/claude"), .string("-p"), .string(ClaudeUsage.noPersistence), .string("/usage")])],
                      "The command to run for backend cli (and for auto's fallback). Default: claude -p --no-session-persistence /usage, claude found on PATH; set it when it isn't."),
        ] + ignoredClaudeKeys + common("5m", "visible")),
        SchemaEntityType("astro", since: "0.4", "Sunrise, sunset, day length, the sun's arc and the moon's phase for a place, computed offline.", keys: [
            SchemaKey("latitude", .number, required: true, since: "0.4", examples: [.double(38.72)],
                      "Degrees north, -90 to 90."),
            SchemaKey("longitude", .number, required: true, since: "0.4", examples: [.double(-9.14)],
                      "Degrees east, -180 to 180 (west is negative)."),
        ] + common("10m", "visible")),
        SchemaEntityType("codex", since: "0.4", "Codex plan usage (5-hour and weekly windows) from `codex app-server`.", keys: [
            SchemaKey("argv", .list(.string), since: "0.4", examples: [.array([.string("~/.local/bin/codex"), .string("app-server")])],
                      "The app server to ask. Default: codex app-server, codex found on PATH; set it when it isn't."),
        ] + common("5m", "visible")),
        SchemaEntityType("flake", since: "0.4",
                         "The inputs a Nix flake has locked (name, revision, lock time) from `nix flake metadata`, and optionally how far behind GitHub each one is.", keys: [
            SchemaKey("path", .string, kind: .text, required: true, examples: [.string("~/config")],
                      "The flake: a directory or a flake reference. A leading ~/ expands."),
            SchemaKey("behind", .boolean, since: "0.4", examples: [.bool(true)],
                      "Also ask GitHub (one GraphQL request) how many commits each GitHub input's branch has gained since "
                      + "its locked revision. Needs a token in headers.Authorization; without one, or when GitHub fails, "
                      + "`behind` stays null and the source says why."),
            SchemaKey("headers", .map(.string), kind: .text, since: "0.4",
                      examples: [.object(["Authorization": .string("Bearer {{ $secrets.github }}")])],
                      "Headers of the GitHub request (behind)."),
            SchemaKey("argv", .list(.string), since: "0.4",
                      examples: [.array([.string("nix"), .string("flake"), .string("metadata"), .string("--json")])],
                      "The command, before the flake's path. Default: nix --extra-experimental-features \"nix-command flakes\" flake metadata --json, nix found on PATH."),
            timeout("The nix command and the GitHub request fail after this long."),
        ] + common("1h", "visible")),
    ]

    /// The v0.3 Claude options: accepted and ignored (an info
    /// finding), on the claude source and the claudeUsage widget.
    static let ignoredClaudeKeys: [SchemaKey] = [
        SchemaKey("path", .string, examples: [.string("~/.claude/projects")],
                  "Ignored (it was Claude Code's log directory)."),
        SchemaKey("fiveHourLimit", .integer(minimum: 1), examples: [.int(8_000_000)],
                  "Ignored (it was a guessed 5-hour token limit)."),
        SchemaKey("weeklyLimit", .integer(minimum: 1), examples: [.int(95_000_000)],
                  "Ignored (it was a guessed weekly token limit)."),
    ]

    /// The keys every source takes with the type's
    /// `refresh` and `when` defaults.
    private static func common(_ refresh: String, _ when: String, cache: Bool = true) -> [SchemaKey] {
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
            SchemaKey("cache", .boolean, default: .bool(cache), since: "0.4", examples: [.bool(!cache)],
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
            SchemaKey("show", .list(.oneOf(WidgetConfig.systemBarItems)), default: .array(WidgetConfig.systemBarDefaultItems.map(AnyJSON.string)),
                      examples: [.array([.string("uptime"), .string("battery"), .string("network")])],
                      "Items, left to right. privacy is always drawn at the right end. Absent or empty shows every item but "
                      + "codexUsage (it runs `codex app-server`)."),
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
            SchemaKey("provider", .string, default: .string(WidgetConfig.Defaults.provider), examples: [.string("foyer")],
                      "Where remote health comes from: a source template with a url parameter. foyer (the default) runs "
                      + "`foyer-api --host <url> /api/health`."),
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
        SchemaEntityType("claudeUsage", "Claude plan usage, 5-hour and weekly percentages, from the claude source.",
                         keys: ignoredClaudeKeys),
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
