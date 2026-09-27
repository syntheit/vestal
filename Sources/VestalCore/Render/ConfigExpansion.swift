import Foundation

// MARK: - Config expansion (EXTENSIBILITY.md §7.2, §7.4, §7.5)
//
// After the layers are merged, and before the render engine reads the
// config: the legacy adapter applies the two v0.3 couplings, templates
// are expanded (widget templates in `widgets` and views, source templates in
// `sources` and inline), and inline source objects become sources named
// `inline:<sha8>`. The result is what `vestal print-config --expanded`
// prints: widgets hold only the engine's own types, plus the internal keys
// `$params` (data parameters bound as variables), `$template` (the template
// chain) and `$widget` (the `widgets` key). A widget that can't be expanded
// becomes `{"type": "$error", "message": …}`, which draws nothing, so the
// ids of its siblings don't move.

public struct ExpandedConfig: Equatable, Sendable {
    /// The effective config, expanded.
    public var tree: AnyJSON
    public var registry: TemplateRegistry
    /// Template and adapter problems (errors and warnings).
    public var warnings: [ConfigWarning]
    /// `legacy` info diagnostics: each coupling the adapter applied.
    public var notes: [ConfigWarning]

    public init(tree: AnyJSON, registry: TemplateRegistry, warnings: [ConfigWarning], notes: [ConfigWarning]) {
        self.tree = tree; self.registry = registry; self.warnings = warnings; self.notes = notes
    }

    public var top: [String: AnyJSON] { tree.objectValue ?? [:] }

    /// The expanded sources, decoded (inline ones included).
    public var sources: [String: SourceConfig] {
        var result: [String: SourceConfig] = [:]
        for (name, json) in top["sources"]?.objectValue ?? [:] {
            if let source = ConfigExpansion.decodeSource(json) { result[name] = source }
        }
        return result
    }
}

public enum ConfigExpansion {
    /// Templates may use templates up to this depth (§7.2 rule 7).
    public static let maxDepth = 16

    public static func expand(_ merged: AnyJSON) -> ExpandedConfig {
        // Inline sources the user wrote are named first, as the v0.3 decoder
        // names them (a template parameter then holds the name).
        guard case .object(var top) = InlineSources.extract(merged) else {
            return ExpandedConfig(tree: merged, registry: .standard, warnings: [], notes: [])
        }
        let notes = LegacyAdapter.apply(&top)
        let registry = TemplateRegistry(userTemplates: top["templates"], density: ThemeConfig.density(top["theme"]))
        var expander = Expander(registry: registry, raw: top["widgets"]?.objectValue ?? [:])
        expander.warnings = registry.problems

        // Sources: source templates, named and adapter-made.
        if case .object(var sources) = top["sources"] {
            for name in sources.keys.sorted() {
                guard let definition = sources[name] else { continue }
                sources[name] = expander.source(definition, path: "sources.\(name)", depth: 0)
            }
            top["sources"] = .object(sources)
        }
        // Widgets, then views' inline children.
        if top["widgets"]?.objectValue != nil {
            var widgets: [String: AnyJSON] = [:]
            for key in expander.raw.keys.sorted() {
                widgets[key] = expander.named(key)
            }
            top["widgets"] = .object(widgets)
        }
        if case .object(var views) = top["views"] {
            for name in views.keys.sorted() {
                guard case .object(var view) = views[name] else { continue }
                for field in ["children", "order"] {
                    guard case .array(let entries) = view[field] else { continue }
                    view[field] = .array(entries.enumerated().map { index, entry in
                        if case .string = entry { return entry }
                        return expander.widget(entry, path: "views.\(name).\(field)[\(index)]", depth: 0, chain: [])
                    })
                }
                views[name] = .object(view)
            }
            top["views"] = .object(views)
        }
        let tree = registerSparklineHistories(extractInlineSources(.object(top)))
        return ExpandedConfig(tree: tree, registry: registry, warnings: expander.warnings, notes: notes)
    }

    /// A source definition decoded, when it is a usable one: its type's
    /// required key is there (`url`, `argv`, `path`). A preset's inline
    /// source whose parameter was left out (the system bar's privacy file,
    /// say) is not.
    static func decodeSource(_ json: AnyJSON) -> SourceConfig? {
        guard case .object(let members) = json, members["type"]?.stringValue != nil,
              let data = try? JSONEncoder().encode(json),
              let source = try? JSONDecoder().decode(SourceConfig.self, from: data)
        else { return nil }
        switch source.type {
        case "http": guard source.url != nil else { return nil }
        case "command": guard !(source.argv ?? []).isEmpty else { return nil }
        case "file": guard source.path != nil else { return nil }
        default:
            guard SourceConfig.keysByType[source.type] != nil else { return nil }
        }
        return source
    }

    /// Every usable inline source object under `widgets`, `views` and
    /// `keys` replaced by its `inline:<sha8>` name, the definitions added to
    /// `sources` (EXTENSIBILITY.md §5.1). Popups stay as written: they are
    /// expanded when opened.
    static func extractInlineSources(_ tree: AnyJSON) -> AnyJSON {
        guard case .object(var top) = tree else { return tree }
        var found: [String: AnyJSON] = [:]
        func replace(_ value: AnyJSON, inAction: Bool) -> AnyJSON {
            switch value {
            case .object(var members):
                for (key, member) in members {
                    if key == "source", case .object = member, let source = decodeSource(member) {
                        let name = source.inlineName
                        found[name] = member
                        members[key] = .string(name)
                    } else if key == "popup" {
                        continue
                    } else {
                        members[key] = replace(member, inAction: inAction || key == "action")
                    }
                }
                return .object(members)
            case .array(let items):
                return .array(items.map { replace($0, inAction: inAction) })
            default:
                return value
            }
        }
        for key in ["widgets", "views", "keys"] {
            if let value = top[key] { top[key] = replace(value, inAction: false) }
        }
        guard !found.isEmpty else { return tree }
        var sources = top["sources"]?.objectValue ?? [:]
        for (name, definition) in found where sources[name] == nil { sources[name] = definition }
        top["sources"] = .object(sources)
        return .object(top)
    }

    /// The history name a sparkline's `value` + `history` records under.
    public static func sparklineHistoryName(_ value: String) -> String {
        "w:" + SHA256.hex(value).prefix(8)
    }

    /// A sparkline with `value` and `history` (§6.3) registers that history
    /// on its source (the nearest `source` name above it), so the runtime
    /// samples it (§5.6).
    static func registerSparklineHistories(_ tree: AnyJSON) -> AnyJSON {
        guard case .object(var top) = tree, case .object(var sources)? = top["sources"] else { return tree }
        var added = false
        func walk(_ value: AnyJSON, source: String?) {
            switch value {
            case .object(let members):
                var nearest = source
                if case .string(let name)? = members["source"] { nearest = name }
                if members["type"]?.stringValue == "sparkline", case .string(let expression)? = members["value"],
                   case .object(let spec)? = members["history"], let name = nearest,
                   case .object(var definition)? = sources[name] {
                    var histories = definition["history"]?.objectValue ?? [:]
                    var entry: [String: AnyJSON] = ["value": .string(expression)]
                    if let size = spec["size"] { entry["size"] = size }
                    if let every = spec["every"] { entry["every"] = every }
                    histories[sparklineHistoryName(expression)] = .object(entry)
                    definition["history"] = .object(histories)
                    sources[name] = .object(definition)
                    added = true
                }
                for (key, member) in members where key != "source" && key != "popup" { walk(member, source: nearest) }
            case .array(let items):
                for item in items { walk(item, source: source) }
            default:
                break
            }
        }
        walk(top["widgets"] ?? .null, source: nil)
        walk(top["views"] ?? .null, source: nil)
        guard added else { return tree }
        top["sources"] = .object(sources)
        return .object(top)
    }

    // MARK: Load-time text with template parameters

    /// Parameter holes run while a config loads, on the main actor during a
    /// reload: a budget far under a frame.
    static let parameterEnvironment = ExprEnvironment(limits: JQLimits(maxSteps: 10_000, maxDuration: 0.005))

    /// Source-definition text fields (EXTENSIBILITY.md §5.1).
    static let loadTimeFields = ["url", "path", "body"]
    static let loadTimeLists = ["argv", "ics"]
    static let loadTimeMaps = ["env", "headers"]

    /// `source` with every `{{ }}` hole that reads only template
    /// parameters evaluated now, so the definition (and its inline name)
    /// holds the values. Holes that read `$secrets` or `$env` stay for load
    /// time.
    static func bindParameters(_ source: AnyJSON, _ params: [String: AnyJSON]) -> AnyJSON {
        guard !params.isEmpty, case .object(var members) = source else { return source }
        var variables: [String: JQValue] = ["params": JQValue(.object(params))]
        for (name, value) in params { variables[name] = JQValue(value) }
        let names = Set(params.keys).union(["params"])
        let environment = parameterEnvironment
        func text(_ value: AnyJSON) -> AnyJSON {
            guard case .string(let s) = value, TextTemplate.hasHoles(s),
                  case .success(let template) = TextTemplate.parse(s) else { return value }
            var out = ""
            var changed = false
            for part in template.parts {
                switch part {
                case .literal(let literal):
                    out += TextTemplate.escape(literal)
                case .hole(let expression, _):
                    guard case .success(let compiled) = environment.compile(expression) else {
                        out += "{{ \(expression) }}"
                        continue
                    }
                    let used = compiled.references.variableNames
                    if !used.isEmpty, used.isSubset(of: names),
                       case .success(let result) = environment.first(compiled, input: .null, variables: variables,
                                                                       context: JQEvalContext()) {
                        out += TextTemplate.escape(TextTemplate.stringify(result))
                        changed = true
                    } else if !used.isDisjoint(with: names) {
                        // Mixed with $secrets/$env: the parameters are bound
                        // inside the hole, for load time (§5.1).
                        var prefix = ""
                        for name in used.intersection(names).sorted() {
                            let value = name == "params" ? AnyJSON.object(params) : (params[name] ?? .null)
                            prefix += "(\(value.canonicalText())) as $\(name) | "
                        }
                        out += "{{ \(prefix)\(expression) }}"
                        changed = true
                    } else {
                        out += "{{ \(expression) }}"
                    }
                }
            }
            return changed ? .string(out) : value
        }
        for field in loadTimeFields { if let v = members[field] { members[field] = text(v) } }
        for field in loadTimeLists {
            if case .array(let items)? = members[field] { members[field] = .array(items.map(text)) }
            else if let v = members[field] { members[field] = text(v) }
        }
        for field in loadTimeMaps {
            if case .object(let map)? = members[field] { members[field] = .object(map.mapValues(text)) }
        }
        return .object(members)
    }
}

// MARK: - The expander

struct Expander {
    let registry: TemplateRegistry
    /// `widgets` as merged, before expansion.
    let raw: [String: AnyJSON]
    var warnings: [ConfigWarning] = []
    private var done: [String: AnyJSON] = [:]
    private var inProgress: Set<String> = []

    init(registry: TemplateRegistry, raw: [String: AnyJSON]) {
        self.registry = registry
        self.raw = raw
    }

    static let commonSourceKeys: Set<String> = ["refresh", "when", "timeout", "transform", "history", "maxAge", "cache"]

    // MARK: Widgets

    /// `widgets.<key>`, expanded (once).
    mutating func named(_ key: String) -> AnyJSON {
        if let cached = done[key] { return cached }
        guard let value = raw[key] else {
            return errorNode("no widget named \"\(key)\"")
        }
        if inProgress.contains(key) {
            return error("widgets.\(key)", "widget \"\(key)\" refers to itself", code: "template-cycle")
        }
        inProgress.insert(key)
        var result = widget(value, path: "widgets.\(key)", depth: 0, chain: [])
        inProgress.remove(key)
        if case .object(var members) = result, members["type"]?.stringValue != "$error" {
            members["$widget"] = .string(key)
            result = .object(members)
        }
        done[key] = result
        return result
    }

    /// One widget, expanded. `chain` is the templates being expanded around
    /// it, for cycles.
    mutating func widget(_ value: AnyJSON, path: String, depth: Int, chain: [String]) -> AnyJSON {
        switch value {
        case .string(let key):
            guard raw[key] != nil else {
                return error(path, "no widget named \"\(key)\"", code: "unknown-widget",
                             suggestions: DidYouMean.suggestions(for: key, among: Array(raw.keys)))
            }
            return named(key)
        case .object(var members):
            guard let written = members["type"]?.stringValue else {
                return error(path, "a widget needs a \"type\"", code: "missing-required")
            }
            if written == "$error" { return value }
            let type = WidgetConfig.canonicalType(written)
            if WidgetTypes.all.contains(type) {
                members["type"] = .string(type)
                expandChildren(&members, path: path, depth: depth, chain: chain)
                return .object(members)
            }
            if let template = registry.lookup(type), !template.isSource {
                if chain.contains(type) {
                    return error(path, "template \"\(type)\" uses itself: \((chain + [type]).joined(separator: " → "))",
                                 code: "template-cycle")
                }
                if depth >= ConfigExpansion.maxDepth {
                    return error(path, "templates nest deeper than \(ConfigExpansion.maxDepth)", code: "template-cycle")
                }
                let expanded = instance(members, template, path: path)
                return widget(expanded, path: path, depth: depth + 1, chain: chain + [type])
            }
            return error(path + ".type", "unknown widget type \"\(written)\"", code: "unknown-type",
                         suggestions: DidYouMean.suggestions(for: written, among: registry.widgetTypeNames))
        default:
            return error(path, "expected a widget (an object or a widget key), found \(value.kindDescription)",
                         code: "type-mismatch")
        }
    }

    /// The widgets a container holds, and its inline source templates.
    private mutating func expandChildren(_ members: inout [String: AnyJSON], path: String, depth: Int, chain: [String]) {
        if case .array(let children)? = members["children"] {
            members["children"] = .array(children.enumerated().map { index, child in
                widget(child, path: "\(path).children[\(index)]", depth: depth, chain: chain)
            })
        }
        for key in ["row", "default"] {
            if let child = members[key] { members[key] = widget(child, path: "\(path).\(key)", depth: depth, chain: chain) }
        }
        for key in ["empty", "loading"] {
            if case .object? = members[key] {
                members[key] = widget(members[key]!, path: "\(path).\(key)", depth: depth, chain: chain)
            }
        }
        if case .object(var cases)? = members["cases"] {
            for name in cases.keys.sorted() {
                cases[name] = widget(cases[name]!, path: "\(path).cases.\(name)", depth: depth, chain: chain)
            }
            members["cases"] = .object(cases)
        }
        if case .object? = members["source"] {
            members["source"] = source(members["source"]!, path: "\(path).source", depth: depth)
        }
    }

    /// A template instance: parameters substituted into the body, common
    /// fields applied to its root (§7.2 rules 1–6).
    private mutating func instance(_ members: [String: AnyJSON], _ template: TemplateDefinition, path: String) -> AnyJSON {
        guard let body = template.widget else { return errorNode("template \"\(template.name)\" has no widget") }
        // A v0.3 widget type keeps v0.3's rules: the validator reports its
        // problems, and a value of the wrong type counts as absent.
        let legacy = template.builtin && WidgetConfig.keysByType[template.name] != nil
        var values: [String: AnyJSON] = [:]
        var common: [String: AnyJSON] = [:]
        var style: [String: AnyJSON] = [:]
        var carried: [String: AnyJSON] = [:]
        for (key, value) in members where key != "type" {
            if WidgetTypes.internalKeys.contains(key) {
                carried[key] = value
            } else if template.params[key] != nil {
                values[key] = value
            } else if WidgetTypes.commonFields.contains(key) {
                common[key] = value
            } else if WidgetTypes.styleShorthands.contains(key) {
                style[key] = value
            } else if !legacy {
                let known = Array(template.params.keys) + Array(WidgetTypes.commonFields)
                warnings.append(ConfigWarning(
                    kind: .unknownKey, path: "\(path).\(key)",
                    message: "unknown key \"\(key)\" for a \(template.name) (parameters: \(template.params.keys.sorted().joined(separator: ", ")))",
                    suggestions: DidYouMean.suggestions(for: key, among: known)))
            }
        }
        var resolved: [String: AnyJSON] = [:]
        for name in template.params.keys.sorted() {
            let param = template.params[name]!
            var value = values[name]
            if value == .null { value = nil }
            if legacy, let given = value,
               !param.accepts(given) || (param.enumValues.map { !$0.contains(given) } ?? false) {
                value = nil
            }
            if value == nil { value = param.defaultValue }
            guard let value else {
                if param.required {
                    if legacy { return errorNode("\(template.name) needs \"\(name)\"") }
                    return error(path, "\(template.name) needs \"\(name)\"", code: "missing-required")
                }
                continue
            }
            guard param.accepts(value) else {
                return error("\(path).\(name)", "\"\(name)\" must be \(param.typeDescription), found \(value.kindDescription)",
                             code: "type-mismatch", expected: param.type, found: value.jsonTypeName)
            }
            if let allowed = param.enumValues, !allowed.contains(value), value.objectValue == nil {
                return error("\(path).\(name)", "\"\(name)\" must be one of \(allowed.map { $0.canonicalText() }.joined(separator: ", "))",
                             code: "invalid-value", found: value.canonicalText())
            }
            resolved[name] = value
        }
        guard case .object(var root)? = substitute(body, resolved) else {
            return errorNode("template \"\(template.name)\" expands to nothing")
        }
        let data = resolved.filter { template.params[$0.key]?.isData == true }
        root = bindSourceParameters(root, data)
        for (key, value) in common {
            switch key {
            case "vars", "style":
                root[key] = merged(root[key], value)
            default:
                root[key] = value
            }
        }
        if !style.isEmpty { root["style"] = merged(root["style"], .object(style)) }
        var params = carried["$params"]?.objectValue ?? [:]
        params.merge(data) { _, new in new }
        if !params.isEmpty { root["$params"] = .object(params) }
        root["$template"] = .array((carried["$template"]?.arrayValue ?? []) + [.string(template.name)])
        if let widget = carried["$widget"] { root["$widget"] = widget }
        return .object(root)
    }

    // MARK: Sources

    /// A source definition with source templates expanded (§7.4).
    mutating func source(_ value: AnyJSON, path: String, depth: Int) -> AnyJSON {
        guard case .object(let members) = value, let type = members["type"]?.stringValue,
              SourceConfig.keysByType[SourceConfig.canonicalType(type)] == nil,
              let template = registry.lookup(type)
        else { return value }
        guard let body = template.source else {
            warnings.append(ConfigWarning(kind: .invalidValue, path: "\(path).type",
                                          message: "\"\(type)\" is a widget template, not a source template",
                                          severity: .error))
            return value
        }
        if depth >= ConfigExpansion.maxDepth {
            warnings.append(ConfigWarning(kind: .invalidValue, path: path, message: "source templates nest too deep",
                                          code: "template-cycle", severity: .error))
            return value
        }
        var values: [String: AnyJSON] = [:]
        var overrides: [String: AnyJSON] = [:]
        for (key, member) in members where key != "type" {
            if template.params[key] != nil {
                values[key] = member
            } else if Self.commonSourceKeys.contains(key) {
                overrides[key] = member
            } else {
                warnings.append(ConfigWarning(
                    kind: .unknownKey, path: "\(path).\(key)", message: "unknown key \"\(key)\" for a \(type) source",
                    suggestions: DidYouMean.suggestions(for: key, among: Array(template.params.keys) + Array(Self.commonSourceKeys))))
            }
        }
        var resolved: [String: AnyJSON] = [:]
        for name in template.params.keys.sorted() {
            let param = template.params[name]!
            var v = values[name]
            if v == .null { v = nil }
            if v == nil { v = param.defaultValue }
            guard let v else {
                if param.required {
                    warnings.append(ConfigWarning(kind: .missingKey, path: path, message: "\(type) needs \"\(name)\"",
                                                  severity: .error))
                }
                continue
            }
            guard param.accepts(v) else {
                warnings.append(ConfigWarning(kind: .wrongType, path: "\(path).\(name)",
                                              message: "\"\(name)\" must be \(param.typeDescription)", severity: .error,
                                              expected: param.type, found: v.jsonTypeName))
                continue
            }
            resolved[name] = v
        }
        guard case .object(var root)? = substitute(body, resolved) else { return value }
        let data = resolved.filter { template.params[$0.key]?.isData == true }
        root = ConfigExpansion.bindParameters(.object(root), data).objectValue ?? root
        for (key, v) in overrides { root[key] = v }
        return source(.object(root), path: path, depth: depth + 1)
    }

    /// Inline source objects in a template body get the template's data
    /// parameters in their load-time text.
    private func bindSourceParameters(_ root: [String: AnyJSON], _ params: [String: AnyJSON]) -> [String: AnyJSON] {
        guard !params.isEmpty else { return root }
        func walk(_ value: AnyJSON) -> AnyJSON {
            switch value {
            case .object(var members):
                for (key, member) in members {
                    if key == "source", case .object = member {
                        members[key] = ConfigExpansion.bindParameters(member, params)
                    } else if key != "$params" {
                        members[key] = walk(member)
                    }
                }
                return .object(members)
            case .array(let items):
                return .array(items.map(walk))
            default:
                return value
            }
        }
        return walk(.object(root)).objectValue ?? root
    }

    // MARK: Helpers

    /// Rule 1–3: `{"param": "name"}` (or `"name.key"`) replaced by the value;
    /// null or absent removes the key or element; an array value spliced into
    /// an array.
    private func substitute(_ value: AnyJSON, _ values: [String: AnyJSON]) -> AnyJSON? {
        switch value {
        case .object(let members):
            if let reference = Self.parameterReference(value) {
                return Self.lookup(reference, values)
            }
            var out: [String: AnyJSON] = [:]
            for (key, member) in members {
                if let s = substitute(member, values) { out[key] = s }
            }
            return .object(out)
        case .array(let items):
            var out: [AnyJSON] = []
            for item in items {
                if let reference = Self.parameterReference(item) {
                    guard let v = Self.lookup(reference, values) else { continue }
                    if case .array(let spliced) = v { out.append(contentsOf: spliced) } else { out.append(v) }
                } else if let s = substitute(item, values) {
                    out.append(s)
                }
            }
            return .array(out)
        default:
            return value
        }
    }

    static func parameterReference(_ value: AnyJSON) -> String? {
        guard case .object(let members) = value, members.count == 1, case .string(let name)? = members["param"] else {
            return nil
        }
        return name
    }

    static func lookup(_ reference: String, _ values: [String: AnyJSON]) -> AnyJSON? {
        let parts = reference.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var current = values[parts[0]]
        for part in parts.dropFirst() {
            current = current?.objectValue?[part]
        }
        if current == .null { return nil }
        return current
    }

    private func merged(_ base: AnyJSON?, _ overlay: AnyJSON) -> AnyJSON {
        guard case .object(var b)? = base, case .object(let o) = overlay else { return overlay }
        for (key, value) in o { b[key] = value }
        return .object(b)
    }

    /// Problems check-config's validator reports itself (a widget's type,
    /// references to `widgets`); the expansion only draws nothing for them.
    static let validatorCodes: Set<String> = ["unknown-type", "unknown-widget"]

    private mutating func error(_ path: String, _ message: String, code: String,
                                suggestions: [String] = [], expected: String? = nil, found: String? = nil) -> AnyJSON {
        if Self.validatorCodes.contains(code) || message == "a widget needs a \"type\"" { return errorNode(message) }
        warnings.append(ConfigWarning(kind: code == "unknown-type" ? .unknownType : .invalidValue, path: path,
                                      message: message + "; the widget is not shown", code: code, severity: .error,
                                      suggestions: suggestions, expected: expected, found: found))
        return errorNode(message)
    }

    private func errorNode(_ message: String) -> AnyJSON {
        .object(["type": .string("$error"), "message": .string(message)])
    }
}

// MARK: - The legacy adapter (§7.5)

public enum LegacyAdapter {
    /// Applies the two v0.3 couplings to the merged config and returns a
    /// `legacy` note for each. A config with none of the v0.3 types it reads
    /// is left alone. Local hosts without a name get this machine's short
    /// name, as v0.3's decoder gave them.
    static func apply(_ top: inout [String: AnyJSON]) -> [ConfigWarning] {
        guard case .object(var widgets)? = top["widgets"] else { return [] }
        var notes: [ConfigWarning] = []
        func note(_ path: String, _ message: String) {
            notes.append(ConfigWarning(kind: .invalidValue, path: path, message: message, code: "legacy", severity: .info))
        }
        func type(_ widget: AnyJSON) -> String? {
            widget.objectValue?["type"]?.stringValue.map(WidgetConfig.canonicalType)
        }
        let keys = widgets.keys.sorted()
        // (v0.3's third coupling, a system bar taking its Claude options from
        // the first claudeUsage widget, is gone: those options are ignored
        // now, and both read the `claude` source.)

        // 1. The `p` key: the first system bar of the default view whose
        //    privacy item shows.
        let defaultView = top["defaultView"]?.stringValue ?? "main"
        let view = top["views"]?.objectValue?[defaultView]?.objectValue ?? [:]
        let order = (view["children"] ?? view["order"])?.arrayValue?.compactMap(\.stringValue) ?? []
        for key in order {
            guard let widget = widgets[key], type(widget) == "systemBar", case .object(var bar) = widget,
                  privacyShows(bar) else { continue }
            if bar["privacyKey"] == nil {
                bar["privacyKey"] = .string("p")
                widgets[key] = .object(bar)
                note("widgets.\(key)", "systemBar '\(key)' gets the privacy key p (first system bar with privacy in view '\(defaultView)')")
            }
            break
        }

        // 2. Remote hosts become the sources `host:<name>`.
        var sources = top["sources"]?.objectValue ?? [:]
        for key in keys where type(widgets[key]!) == "systemHealth" {
            guard case .object(var health) = widgets[key]!, case .array(var hosts)? = health["hosts"] else { continue }
            let provider = health["provider"]?.stringValue ?? WidgetConfig.Defaults.provider
            var made: [String] = []
            for i in hosts.indices {
                guard case .object(var host) = hosts[i] else { continue }
                if host["name"] == nil, host["source"]?.stringValue == HostConfig.local {
                    host["name"] = .string(LocalHost.shortName)
                    hosts[i] = .object(host)
                }
                guard let name = host["name"]?.stringValue, let url = host["url"]?.stringValue,
                      host["source"] == nil else { continue }
                let sourceName = "host:\(name)"
                guard sources[sourceName] == nil else { continue }
                let interval = host["interval"]?.stringValue.flatMap { ConfigDuration.parse($0) != nil ? $0 : nil }
                sources[sourceName] = .object([
                    "type": .string(provider),
                    "url": .string(url),
                    "refresh": .string(interval ?? HostConfig.defaultInterval),
                ])
                made.append(sourceName)
            }
            health["hosts"] = .array(hosts)
            widgets[key] = .object(health)
            if !made.isEmpty {
                note("widgets.\(key)", "systemHealth '\(key)' reads its remote hosts from the sources \(made.joined(separator: ", "))")
            }
        }
        if !sources.isEmpty { top["sources"] = .object(sources) }
        top["widgets"] = .object(widgets)
        return notes
    }

    /// v0.3's rule: "privacy" in `show` (absent or empty means every item),
    /// with both `privacy.command` and `privacy.stateFile` set.
    static func privacyShows(_ bar: [String: AnyJSON]) -> Bool {
        let show = bar["show"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard show.isEmpty || show.contains("privacy") else { return false }
        let privacy = bar["privacy"]?.objectValue ?? [:]
        let command = privacy["command"]?.arrayValue ?? []
        let stateFile = privacy["stateFile"]?.stringValue ?? ""
        return !command.isEmpty && !stateFile.isEmpty
    }
}
