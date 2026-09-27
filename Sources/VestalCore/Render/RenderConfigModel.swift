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
    /// Global key bindings (§9.2), key → action.
    public let keys: [String: AnyJSON]
    public let palette: RenderPalette
    public let theme: RenderTheme
    public let environment: ExprEnvironment
    public let sources: [String: SourceConfig]
    public let sourceNames: Set<String>
    /// `theme.scale` (§8.1).
    public let scale: Double

    private let lock = NSLock()
    private var textCache: [String: Result<TextTemplate, ExprError>] = [:]

    public convenience init(loaded: LoadedConfig) {
        self.init(expanded: loaded.expanded)
    }

    public init(expanded: ExpandedConfig) {
        self.expanded = expanded
        let top = expanded.top
        widgets = top["widgets"]?.objectValue ?? [:]
        var views: [String: ViewSpec] = [:]
        for (name, json) in top["views"]?.objectValue ?? [:] {
            if let object = json.objectValue { views[name] = ViewSpec(name: name, json: object) }
        }
        self.views = views
        viewNames = views.keys.sorted()
        let requested = top["defaultView"]?.stringValue ?? "main"
        defaultView = views[requested] != nil ? requested : (views["main"] != nil ? "main" : viewNames.first ?? "main")
        keys = top["keys"]?.objectValue ?? [:]
        let themeJSON = top["theme"]
        palette = RenderPalette(theme: themeJSON)
        let themeObject = themeJSON?.objectValue ?? [:]
        let fonts = themeObject["fonts"]?.objectValue ?? [:]
        var icons = RenderTheme.Icons()
        if let mode = themeObject["icons"]?.stringValue { icons.mode = mode }
        theme = RenderTheme(
            background: themeObject["background"]?.stringValue.flatMap { ThemeConfig.backgrounds.contains($0) ? $0 : nil } ?? "aurora",
            colors: palette.colors,
            fonts: RenderTheme.Fonts(sans: fonts["sans"]?.stringValue ?? themeObject["font"]?.stringValue,
                                     mono: fonts["mono"]?.stringValue, rounded: fonts["rounded"]?.stringValue),
            icons: icons)
        environment = ExprEnvironment.forFunctions(ExprEnvironment.userFunctions(of: expanded.tree))
        sources = expanded.sources
        sourceNames = Set(top["sources"]?.objectValue?.keys.map { $0 } ?? [])
        scale = TextStyle.size(themeObject["scale"]) ?? 1
    }

    /// The order `tab` cycles through: views with a key by key, then the
    /// rest by name (§9.1).
    public var cycleOrder: [String] {
        let keyed = viewNames.filter { views[$0]?.key != nil }.sorted { (views[$0]!.key!, $0) < (views[$1]!.key!, $1) }
        return keyed + viewNames.filter { views[$0]?.key == nil }
    }

    /// The views as the snapshot lists them.
    public var viewInfos: [RenderViewInfo] {
        viewNames.map { name in
            let spec = views[name]!
            return RenderViewInfo(name: name, title: spec.title, key: spec.key)
        }
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

/// A view (§9.1).
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
    /// Written with v0.3's `order` (not `children`): only the first *listed*
    /// entry gets no space before it (§13.1 rule 8b).
    public var usesOrder: Bool
    public var keys: [String: AnyJSON]

    init(name: String, json: [String: AnyJSON]) {
        self.name = name
        title = json["title"]?.stringValue ?? (name.prefix(1).uppercased() + name.dropFirst())
        key = json["key"]?.stringValue
        let layout = json["layout"]?.stringValue ?? "stack"
        self.layout = ["stack", "row", "grid"].contains(layout) ? layout : "stack"
        columns = json["columns"].flatMap { if case .int(let n) = $0, n >= 1 { return n }; return nil } ?? 2
        gap = TextStyle.size(json["gap"]) ?? 24
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
/// dependency tracking (§4.7).
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
    /// `transform` (§5.1).
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
