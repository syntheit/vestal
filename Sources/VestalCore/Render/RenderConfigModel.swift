import Foundation

// MARK: - The render engine's view of a config
//
// Everything the engine reads from one loaded config, prepared once: the
// expanded widgets and views, the palette and theme, the expression
// environment with the user's functions, and the sources' definitions.
// Immutable, so passes on the engine's queue and the CLI share it.

public final class RenderConfigModel: @unchecked Sendable {
    public let expanded: ExpandedConfig
    public let widgets: [String: AnyJSON]
    public let views: [String: ViewSpec]
    /// View names, sorted (the snapshot's `views` order).
    public let viewNames: [String]
    public let defaultView: String
    /// `pages`, and the views it pages between, in order.
    public let pages: PagesConfig
    public let pageOrder: [String]
    /// Global key bindings, key → action.
    public let keys: [String: AnyJSON]
    public let palette: RenderPalette
    public let theme: RenderTheme
    /// `theme.background` when it is a library background that reads data.
    let backgroundSpec: BackgroundSpec?
    public let environment: ExprEnvironment
    public let sources: [String: SourceConfig]
    public let sourceNames: Set<String>
    /// `theme.scale`.
    public let scale: Double
    /// `theme.density`: `comfortable` or `compact`.
    public let density: String
    /// The config file (nil: the built-in defaults) and its `version`, for
    /// the info popup.
    public let configPath: String?
    public let configVersion: Int

    private let lock = NSLock()
    private var textCache: [String: Result<TextTemplate, ExprError>] = [:]

    public convenience init(loaded: LoadedConfig) {
        self.init(expanded: loaded.expanded, path: loaded.path)
    }

    public init(expanded: ExpandedConfig, path: String? = nil) {
        self.expanded = expanded
        configPath = path
        let top = expanded.top
        widgets = top["widgets"]?.objectValue ?? [:]
        density = ThemeConfig.density(top["theme"])
        var views: [String: ViewSpec] = [:]
        var disabled = Set<String>()
        for (name, json) in top["views"]?.objectValue ?? [:] {
            guard let object = json.objectValue else { continue }
            // A disabled view does not exist as far as the dashboard goes.
            if case .bool(false)? = object["enabled"] { disabled.insert(name); continue }
            views[name] = ViewSpec(name: name, json: object, density: density)
        }
        self.views = views
        viewNames = views.keys.sorted()
        let pagesConfig = PagesConfig(top["pages"])
        pages = pagesConfig
        let order = RenderConfigModel.pageOrder(pages: pagesConfig, views: views, userViews: expanded.userViews)
        pageOrder = order
        let requested = top["defaultView"]?.stringValue ?? "main"
        if views[requested] != nil {
            defaultView = requested
        } else if disabled.contains(requested), let first = order.first {
            defaultView = first
        } else {
            defaultView = views["main"] != nil ? "main" : viewNames.first ?? "main"
        }
        keys = top["keys"]?.objectValue ?? [:]
        let themeJSON = top["theme"]
        palette = RenderPalette(theme: themeJSON)
        let themeObject = themeJSON?.objectValue ?? [:]
        var icons = RenderTheme.Icons()
        if let mode = themeObject["icons"]?.stringValue { icons.mode = mode }
        let background = ThemeConfig.backgroundName(themeObject["background"]) ?? "aurora"
        let spec = BackgroundSpec(themeObject["background"], palette: palette)
        backgroundSpec = spec
        theme = RenderTheme(
            background: background,
            colors: palette.colors,
            fonts: Typefaces.fonts(theme: themeObject),
            icons: icons,
            dim: RenderTheme.dim(themeObject["dim"]),
            backdrop: RenderTheme.backdrop(themeObject["backdrop"]),
            blur: RenderTheme.blur(themeObject["blur"]),
            backgroundParams: spec.map { RenderBackground(colors: $0.colors.isEmpty ? nil : $0.colors) },
            backgroundFPS: Backgrounds.fps(themeObject["backgroundFPS"]),
            backgroundResolution: Backgrounds.resolution(themeObject["backgroundResolution"]))
        environment = ExprEnvironment.forFunctions(ExprEnvironment.userFunctions(of: expanded.tree))
        sources = expanded.sources
        sourceNames = Set(top["sources"]?.objectValue?.keys.map { $0 } ?? [])
        scale = TextStyle.size(themeObject["scale"]) ?? 1
        switch top["version"] {
        case .int(let v)?: configVersion = v
        case .double(let v)?: configVersion = Int(exactly: v) ?? 1
        default: configVersion = 1
        }
    }

    /// The order `tab` cycles through: views with a key by key, then the
    /// rest by name.
    public var cycleOrder: [String] {
        Self.cycleOrder(views: views)
    }

    private static func cycleOrder(views: [String: ViewSpec]) -> [String] {
        let names = views.keys.sorted()
        let keyed = names.filter { views[$0]?.key != nil }.sorted { (views[$0]!.key!, $0) < (views[$1]!.key!, $1) }
        return keyed + names.filter { views[$0]?.key == nil }
    }

    /// The pages, in paging order: `pages.order` (known, enabled views
    /// once each), else the cycle order of the views the user's own config
    /// defines (all of them when it defines none).
    private static func pageOrder(pages: PagesConfig, views: [String: ViewSpec], userViews: Set<String>?) -> [String] {
        guard let written = pages.order else {
            guard let userViews else { return cycleOrder(views: views) }
            return cycleOrder(views: views).filter(userViews.contains)
        }
        var seen = Set<String>()
        return written.filter { views[$0] != nil && seen.insert($0).inserted }
    }

    /// The views as the snapshot lists them.
    public var viewInfos: [RenderViewInfo] {
        viewNames.map { name in
            let spec = views[name]!
            return RenderViewInfo(name: name, title: spec.title, key: spec.key)
        }
    }

    /// The snapshot's `pages` for `view`: nil with fewer than two pages.
    func renderPages(view: String, direction: Int?) -> RenderPages? {
        guard pageOrder.count > 1 else { return nil }
        let items = pageOrder.map { name -> RenderViewInfo in
            let spec = views[name]!
            return RenderViewInfo(name: name, title: spec.title, key: spec.key)
        }
        return RenderPages(items: items, index: pageOrder.firstIndex(of: view), direction: direction,
                           transition: pages.transition, indicator: pages.indicator, swipe: pages.swipe, wrap: pages.wrap)
    }

    /// A text field parsed once.
    func template(_ text: String) -> Result<TextTemplate, ExprError> {
        lock.lock()
        defer { lock.unlock() }
        if let cached = textCache[text] { return cached }
        let parsed = TextTemplate.parse(text)
        if textCache.count > 20_000 { textCache.removeAll() }
        textCache[text] = parsed
        return parsed
    }
}

/// A view.
public struct ViewSpec: Equatable, Sendable {
    public var name: String
    public var title: String
    public var key: String?
    /// `stack`, `row` or `grid`.
    public var layout: String
    public var columns: Int
    public var gap: Double
    public var align: String
    public var padding: [Double]
    public var maxWidth: Double
    /// Widget keys (strings) or inline widgets, expanded.
    public var children: [AnyJSON]
    /// Written with the original `order` (not `children`): only the first *listed*
    /// entry gets no space before it.
    public var usesOrder: Bool
    public var keys: [String: AnyJSON]

    /// `density`: `theme.density`; `compact` halves the default `gap`.
    init(name: String, json: [String: AnyJSON], density: String = "comfortable") {
        self.name = name
        title = json["title"]?.stringValue ?? (name.prefix(1).uppercased() + name.dropFirst())
        key = json["key"]?.stringValue
        let layout = json["layout"]?.stringValue ?? "stack"
        self.layout = ["stack", "row", "grid"].contains(layout) ? layout : "stack"
        columns = json["columns"].flatMap { if case .int(let n) = $0, n >= 1 { return n }; return nil } ?? 2
        gap = TextStyle.size(json["gap"]) ?? (density == "compact" ? 12 : 24)
        align = json["align"]?.stringValue ?? "center"
        switch json["padding"] {
        case .array(let items)? where items.count == 4:
            padding = items.map { TextStyle.size($0) ?? 0 }
        default:
            let p = TextStyle.size(json["padding"]) ?? 48
            padding = [p, p, p, p]
        }
        maxWidth = TextStyle.size(json["maxWidth"]) ?? 680
        if case .array(let children)? = json["children"] {
            self.children = children
            usesOrder = false
        } else {
            children = json["order"]?.arrayValue ?? []
            usesOrder = true
        }
        keys = json["keys"]?.objectValue ?? [:]
    }
}

// MARK: - Data for one pass

/// The sources' data, metadata and histories at one moment, as expressions
/// see them (`ExprData`). Records which sources a pass read, for
/// dependency tracking.
public final class RenderData: ExprData {
    /// Transformed data of the sources that have some.
    public let sources: [String: JQValue]
    public let metas: [String: JQValue]
    public let histories: [String: [String: [HistorySample]]]
    /// Every source name the config defines.
    public let names: Set<String>
    /// Sources whose transform failed, with the error.
    public let problems: [String: String]

    private(set) var reads: Set<String> = []
    /// How often `meta` was asked (`$meta` moves with the clock: its age).
    private(set) var metaReads = 0

    public init(sources: [String: JQValue], metas: [String: JQValue] = [:],
                histories: [String: [String: [HistorySample]]] = [:], names: Set<String>? = nil,
                problems: [String: String] = [:]) {
        self.sources = sources
        self.metas = metas
        self.histories = histories
        self.names = names ?? Set(sources.keys)
        self.problems = problems
    }

    public func data(_ source: String) -> JQValue? {
        reads.insert(source)
        return sources[source]
    }

    public func meta(_ source: String) -> JQValue? {
        reads.insert(source)
        metaReads += 1
        return metas[source]
    }

    public func history(_ source: String, _ name: String) -> [HistorySample] {
        reads.insert(source)
        return histories[source]?[name] ?? []
    }

    func resetReads() { reads = [] }

    /// `$sources`: every defined source, null when it has no data.
    lazy var sourcesValue: JQValue = {
        var object: [String: AnyJSON] = [:]
        for name in names { object[name] = .null }
        var value = JQValue(AnyJSON.object(object))
        guard case .object(var members) = value else { return value }
        for (name, data) in sources { members[name] = data }
        value = .object(members)
        return value
    }()

    /// `$history`: source → name → values, oldest first.
    lazy var historyValue: JQValue = {
        var object: [String: AnyJSON] = [:]
        for (source, series) in histories {
            var inner: [String: AnyJSON] = [:]
            for (name, samples) in series { inner[name] = .array(samples.map { .double($0.value) }) }
            object[source] = .object(inner)
        }
        return JQValue(AnyJSON.object(object))
    }()
}

/// One source's raw state, for building `RenderData`.
public struct RenderSourceInput: Sendable {
    public var name: String
    public var definition: SourceConfig?
    /// As fetched, before `transform`.
    public var data: Data?
    public var meta: AnyJSON?
    public var histories: [String: [HistorySample]]

    public init(name: String, definition: SourceConfig?, data: Data?, meta: AnyJSON?,
                histories: [String: [HistorySample]] = [:]) {
        self.name = name; self.definition = definition; self.data = data
        self.meta = meta; self.histories = histories
    }
}

/// Parsed and transformed source data, kept while the bytes stay the same,
/// so a render doesn't re-run every transform.
public final class RenderTransformCache: @unchecked Sendable {
    private struct Entry {
        var data: Data
        var definition: SourceConfig?
        var value: JQValue?
        var error: String?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    /// `RenderData` for these inputs, transforming with `environment`.
    public func data(for inputs: [RenderSourceInput], environment: ExprEnvironment, names: Set<String>) -> RenderData {
        var sources: [String: JQValue] = [:]
        var metas: [String: JQValue] = [:]
        var histories: [String: [String: [HistorySample]]] = [:]
        var problems: [String: String] = [:]
        for input in inputs {
            if let meta = input.meta { metas[input.name] = JQValue(meta) }
            if !input.histories.isEmpty { histories[input.name] = input.histories }
            guard let data = input.data else { continue }
            let (value, error) = transformed(input.name, data, input.definition, environment)
            if let value { sources[input.name] = value }
            if let error { problems[input.name] = error }
        }
        return RenderData(sources: sources, metas: metas, histories: histories, names: names.union(sources.keys),
                          problems: problems)
    }

    private func transformed(_ name: String, _ data: Data, _ definition: SourceConfig?,
                             _ environment: ExprEnvironment) -> (JQValue?, String?) {
        lock.lock()
        if let entry = entries[name], entry.data == data, entry.definition == definition {
            lock.unlock()
            return (entry.value, entry.error)
        }
        lock.unlock()
        let result = Self.transform(data, definition, environment)
        lock.lock()
        entries[name] = Entry(data: data, definition: definition, value: result.0, error: result.1)
        lock.unlock()
        return result
    }

    /// The data widgets see: parsed (`raw` sources as a string), then
    /// `transform`.
    static func transform(_ data: Data, _ definition: SourceConfig?, _ environment: ExprEnvironment) -> (JQValue?, String?) {
        let parsed: JQValue
        if definition?.parse == "raw" {
            parsed = .string(String(decoding: data, as: UTF8.self))
        } else {
            guard let value = try? JQValue.parse(data) else { return (nil, "not valid JSON") }
            parsed = value
        }
        guard let transform = definition?.transform else { return (parsed, nil) }
        switch environment.compile(transform) {
        case .failure(let error):
            return (nil, "transform: \(error.message)")
        case .success(let expression):
            switch environment.first(expression, input: parsed, variables: [:], context: JQEvalContext()) {
            case .failure(let error): return (nil, "transform: \(error.message)")
            case .success(let value): return (value ?? .null, nil)
            }
        }
    }
}
