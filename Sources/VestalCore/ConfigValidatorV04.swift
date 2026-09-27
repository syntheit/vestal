import Foundation

// MARK: - Validation of the v0.4 model
//
// check-config's findings for what v0.4 adds (EXTENSIBILITY.md §4, §6–§9,
// §11.2): the engine's widget types and their fields, template instances,
// views with `children`, `defaultView`, key bindings, user `functions` and
// `templates`, colours and icons, and every expression: each expr field is
// compiled, and each text field's `{{ }}` holes, with the variables in scope
// at that place (§4.2: the reserved names, the enclosing `vars`, a
// template's data parameters; `$item`, `$index`, `$parent` only in rows).
// Template parameters and keys of template instances are checked by the
// expansion (ConfigExpansion), not here.
//
// Walks the merged tree next to the v0.3 walker in ConfigValidator.swift,
// which calls it; paths are validator paths (`widgets.cpu.value`).

struct V04Checker {
    var warnings: [ConfigWarning] = []
    /// Inline source objects found under widgets, for the v0.3 walker's
    /// source checks: (definition, path).
    var inlineSources: [(AnyJSON, String)] = []

    let top: [String: AnyJSON]
    let platform: ConfigPlatform
    let environment: ExprEnvironment
    let registry: TemplateRegistry
    let palette: RenderPalette
    let sourceNames: Set<String>
    let widgetNames: Set<String>

    /// Variables every widget expression may use (§4.2).
    static let widgetVariables: Set<String> = ["value", "data", "sources", "meta", "history", "params", "widget",
                                               "view", "tz", "os"]
    static let rowVariables: Set<String> = ["item", "index", "parent"]

    struct Scope {
        var variables: Set<String>
        var inRow = false

        func adding(_ names: some Sequence<String>) -> Scope {
            var s = self
            s.variables.formUnion(names)
            return s
        }

        var all: Set<String> { inRow ? variables.union(V04Checker.rowVariables) : variables }
    }

    init(top: [String: AnyJSON], platform: ConfigPlatform) {
        self.top = top
        self.platform = platform
        environment = ExprEnvironment.forFunctions(ExprEnvironment.userFunctions(of: .object(top)))
        registry = TemplateRegistry(userTemplates: top["templates"])
        palette = RenderPalette(theme: top["theme"])
        sourceNames = Set(top["sources"]?.objectValue?.keys.map { $0 } ?? [])
        widgetNames = Set(top["widgets"]?.objectValue?.keys.map { $0 } ?? [])
    }

    static var baseScope: Scope { Scope(variables: widgetVariables) }

    // MARK: Top level

    mutating func defaultView(_ value: AnyJSON) {
        guard let name = value.stringValue else {
            if value != .null { add(.wrongType, "defaultView", "expected a string, found \(value.kindDescription)", severity: .warning) }
            return
        }
        let views = Array(top["views"]?.objectValue?.keys.map { $0 } ?? [])
        if !views.contains(name) {
            add(.missingReference, "defaultView", "no view named \"\(name)\"", code: "unknown-view",
                suggestions: DidYouMean.suggestions(for: name, among: views))
        }
    }

    /// Global `keys` (§9.2).
    mutating func keys(_ value: AnyJSON?, path: String, scope: Scope = V04Checker.baseScope) {
        guard let value, value != .null else { return }
        guard case .object(let bindings) = value else {
            add(.wrongType, path, "expected an object of key → action, found \(value.kindDescription)", severity: .warning)
            return
        }
        for key in bindings.keys.sorted() {
            keyName(key, path: "\(path).\(key)", allowAuto: false)
            action(bindings[key]!, path: "\(path).\(key)", scope: scope)
        }
    }

    /// User `functions` (§4.8).
    mutating func functions(_ value: AnyJSON) {
        guard case .object(let entries) = value else {
            if value != .null { add(.wrongType, "functions", "expected an object of name → jq body", severity: .warning) }
            return
        }
        for (name, body) in entries.sorted(by: { $0.key < $1.key }) {
            guard body.stringValue != nil else {
                if body != .null { add(.wrongType, "functions.\(name)", "expected a jq expression (a string)", severity: .error) }
                continue
            }
            if let error = environment.functionErrors[name] {
                add(.invalidValue, "functions.\(name)", error.message, code: error.code, severity: .error,
                    suggestions: error.suggestion.map { [$0] } ?? [])
            }
        }
    }

    /// The user's template bodies, with their parameters in scope.
    mutating func templates() {
        for (name, template) in registry.user.sorted(by: { $0.key < $1.key }) {
            let data = template.params.filter(\.value.isData).map(\.key)
            let path = "templates.\(name)"
            if let body = template.widget {
                templateBody(body, path: "\(path).widget", scope: Self.baseScope.adding(data))
            } else if let body = template.source, case .object(let source) = body {
                sourceFields(source, path: "\(path).source", params: Set(data))
            }
        }
    }

    /// A template body: a widget in which `{"param": …}` objects stand for
    /// values given later.
    mutating func templateBody(_ body: AnyJSON, path: String, scope: Scope) {
        widget(body, path: path, scope: scope, inTemplate: true)
    }

    // MARK: Views

    mutating func view(_ name: String, _ view: [String: AnyJSON]) {
        let path = "views.\(name)"
        // Both set, unless the order is the built-in defaults' (a user view
        // with children over the default main view).
        let defaultOrder = DefaultConfig.tree.objectValue?["views"]?.objectValue?[name]?.objectValue?["order"]
        if view["children"] != nil && view["children"] != .null && view["order"] != nil && view["order"] != .null
            && view["order"] != defaultOrder {
            add(.invalidValue, "\(path).order", "both children and order are set; children wins", severity: .warning)
        }
        if case .array(let children)? = view["children"] {
            var seen = Set<String>()
            for (i, child) in children.enumerated() {
                let childPath = "\(path).children[\(i)]"
                if case .string(let key) = child {
                    if !widgetNames.contains(key) {
                        add(.missingReference, childPath, "no widget named \"\(key)\"", code: "unknown-widget", severity: .error,
                            suggestions: DidYouMean.suggestions(for: key, among: Array(widgetNames)))
                    } else if !seen.insert(key).inserted {
                        add(.invalidValue, childPath, "\"\(key)\" is listed twice", severity: .warning)
                    }
                } else {
                    widget(child, path: childPath, scope: Self.baseScope)
                }
            }
        }
        text(view["title"], path: "\(path).title", scope: Self.baseScope)
        if case .string(let key)? = view["key"] { keyName(key, path: "\(path).key", allowAuto: false) }
        keys(view["keys"], path: "\(path).keys")
    }

    // MARK: Widgets

    /// A widget (object or widget key) anywhere a widget goes.
    mutating func widget(_ value: AnyJSON, path: String, scope: Scope, inTemplate: Bool = false) {
        switch value {
        case .string(let key):
            // Outside template bodies the expansion reports these.
            if inTemplate, !widgetNames.contains(key) {
                add(.missingReference, path, "no widget named \"\(key)\"", code: "unknown-widget", severity: .error,
                    suggestions: DidYouMean.suggestions(for: key, among: Array(widgetNames)))
            }
        case .object(let members):
            if inTemplate, Expander.parameterReference(value) != nil { return }
            guard let written = members["type"]?.stringValue else {
                if inTemplate, members["type"].flatMap(Expander.parameterReference) != nil { return }
                if inTemplate { add(.missingKey, path, "a widget needs a \"type\"", code: "missing-required", severity: .error) }
                return
            }
            let type = WidgetConfig.canonicalType(written)
            if let entity = SchemaRegistry.v04WidgetTypes.first(where: { $0.name == type }) {
                primitive(members, entity, path: path, scope: scope, inTemplate: inTemplate)
            } else if let template = registry.lookup(type), !template.isSource {
                instance(members, template, path: path, scope: scope, inTemplate: inTemplate)
            } else if inTemplate {
                add(.unknownType, "\(path).type", "unknown widget type \"\(written)\"", code: "unknown-type", severity: .error,
                    suggestions: DidYouMean.suggestions(for: written, among: registry.widgetTypeNames), found: written)
            }
        default:
            break  // the expansion reports it
        }
    }

    /// The common fields (§6.1): source, input, vars, when, loading, style,
    /// the box fields, action and key. Returns the scope inside the widget.
    @discardableResult
    mutating func common(_ w: [String: AnyJSON], path: String, scope outer: Scope, inTemplate: Bool) -> Scope {
        var scope = outer
        if let source = w["source"] {
            switch source {
            case .string(let name):
                if !inTemplate && !sourceNames.contains(name) {
                    add(.missingReference, "\(path).source", "no source named \"\(name)\"", code: "unknown-source",
                        severity: .error, suggestions: DidYouMean.suggestions(for: name, among: Array(sourceNames)))
                }
            case .object(let definition):
                if !(inTemplate && containsParameter(source)) {
                    inlineSources.append((source, "\(path).source"))
                }
                sourceFields(definition, path: "\(path).source", params: [])
            default:
                break
            }
        }
        expr(w["input"], path: "\(path).input", scope: scope, inTemplate: inTemplate)
        if case .object(let vars)? = w["vars"] {
            for name in vars.keys.sorted() where ExprEnvironment.reservedVariables.contains(name) {
                add(.invalidValue, "\(path).vars.\(name)", "\"\(name)\" is a reserved variable name (§4.2); rename it",
                    code: "invalid-value", severity: .error)
            }
            let withVars = scope.adding(vars.keys)
            for name in vars.keys.sorted() {
                expr(vars[name], path: "\(path).vars.\(name)", scope: withVars, inTemplate: inTemplate)
            }
            scope = withVars
        }
        if case .string? = w["when"] { expr(w["when"], path: "\(path).when", scope: scope, inTemplate: inTemplate) }
        if case .object(let loading)? = w["loading"] {
            widget(.object(loading), path: "\(path).loading", scope: scope, inTemplate: inTemplate)
        } else if case .string(let mode)? = w["loading"], !["hide", "show"].contains(mode) {
            add(.invalidValue, "\(path).loading", "unknown value \"\(mode)\" (expected hide, show or a widget)", severity: .warning)
        }
        style(w["style"], path: "\(path).style", scope: scope, inTemplate: inTemplate)
        for field in ["width", "height", "minWidth", "maxWidth", "padding", "radius", "opacity", "clip", "spaceBefore",
                      "alignSelf", "span"] {
            literal(w[field], path: "\(path).\(field)", scope: scope, inTemplate: inTemplate)
        }
        color(w["background"], path: "\(path).background", scope: scope, inTemplate: inTemplate)
        if let action = w["action"] { self.action(action, path: "\(path).action", scope: scope, inTemplate: inTemplate) }
        switch w["key"] {
        case .string(let key)?: keyName(key, path: "\(path).key", allowAuto: true)
        case let other?: literal(other, path: "\(path).key", scope: scope, inTemplate: inTemplate)
        case nil: break
        }
        text(w["keyHint"], path: "\(path).keyHint", scope: scope, inTemplate: inTemplate)
        text(w["alt"], path: "\(path).alt", scope: scope, inTemplate: inTemplate)
        return scope
    }

    /// One of the engine's own types.
    private mutating func primitive(_ w: [String: AnyJSON], _ type: SchemaEntityType, path: String, scope outer: Scope,
                                    inTemplate: Bool) {
        let keys = SchemaRegistry.widgetKeys(type)
        let known = Set(keys.map(\.name)).union(["type"]).union(WidgetTypes.internalKeys)
        for key in w.keys.sorted() where !known.contains(key) {
            add(.unknownKey, "\(path).\(key)", "unknown key for \(type.name) widgets (known: \(keys.map(\.name).sorted().joined(separator: ", ")))",
                severity: .warning, suggestions: DidYouMean.suggestions(for: key, among: keys.map(\.name)))
        }
        let scope = common(w, path: path, scope: outer, inTemplate: inTemplate)
        let own = type.keys
        for key in own {
            guard let value = w[key.name] else { continue }
            let fieldPath = "\(path).\(key.name)"
            switch key.name {
            case "children":
                if case .array(let children) = value {
                    for (i, child) in children.enumerated() {
                        if inTemplate, Expander.parameterReference(child) != nil { continue }
                        widget(child, path: "\(fieldPath)[\(i)]", scope: scope, inTemplate: inTemplate)
                    }
                }
            case "row":
                widget(value, path: fieldPath, scope: rowScope(scope), inTemplate: inTemplate)
            case "default":
                widget(value, path: fieldPath, scope: scope, inTemplate: inTemplate)
            case "cases":
                if case .object(let cases) = value {
                    for name in cases.keys.sorted() {
                        widget(cases[name]!, path: "\(fieldPath).\(name)", scope: scope, inTemplate: inTemplate)
                    }
                }
            case "empty":
                if case .object = value { widget(value, path: fieldPath, scope: scope, inTemplate: inTemplate) }
                else { text(value, path: fieldPath, scope: scope, inTemplate: inTemplate) }
            case "items":
                if type.name == "keyValue" {
                    keyValueItems(value, path: fieldPath, scope: scope, inTemplate: inTemplate)
                } else if case .string = value {
                    expr(value, path: fieldPath, scope: scope, inTemplate: inTemplate)
                }
            case "columns" where type.name == "table":
                tableColumns(value, path: fieldPath, scope: rowScope(scope), inTemplate: inTemplate)
            case "rowId":
                expr(value, path: fieldPath, scope: rowScope(scope), inTemplate: inTemplate)
            case "rowAction":
                action(value, path: fieldPath, scope: rowScope(scope), inTemplate: inTemplate)
            case "name" where type.name == "icon", "icon" where type.name == "text":
                icon(value, path: fieldPath, scope: scope, inTemplate: inTemplate)
            case "labelStyle", "textStyle", "valueStyle":
                style(value, path: fieldPath, scope: scope, inTemplate: inTemplate)
            case "color", "trackColor", "overlayColor", "iconColor", "fill":
                color(value, path: fieldPath, scope: scope.adding(["value"]), inTemplate: inTemplate)
            default:
                switch key.kind {
                case .expr:
                    if case .string = value { expr(value, path: fieldPath, scope: scope, inTemplate: inTemplate) }
                    else { literal(value, path: fieldPath, scope: scope, inTemplate: inTemplate) }
                case .text:
                    text(value, path: fieldPath, scope: scope, inTemplate: inTemplate)
                case .literal:
                    literal(value, path: fieldPath, scope: scope, inTemplate: inTemplate)
                }
            }
        }
    }

    private func rowScope(_ scope: Scope) -> Scope {
        var s = scope
        s.inRow = true
        return s
    }

    /// A template instance: its common fields and its code parameters (the
    /// expansion checks the parameters' names, types and required ones).
    private mutating func instance(_ w: [String: AnyJSON], _ template: TemplateDefinition, path: String, scope outer: Scope,
                                   inTemplate: Bool) {
        // Code parameters are substituted into the body, where the
        // template's data parameters and the body's vars are in scope too.
        var bodyVars = Set<String>()
        if let body = template.widget { collectVars(body, into: &bodyVars) }
        let data = template.params.filter(\.value.isData).map(\.key)
        // The instance's own vars land on the body's root.
        let ownVars = w["vars"]?.objectValue?.keys.map { $0 } ?? []
        let inner = outer.adding(data).adding(bodyVars).adding(ownVars).adding(["value"])
        var commons: [String: AnyJSON] = [:]
        for (key, value) in w where key != "type" {
            if let param = template.params[key] {
                let fieldPath = "\(path).\(key)"
                switch param.type {
                case "expr": expr(value, path: fieldPath, scope: rowScope(inner), inTemplate: inTemplate)
                case "text": text(value, path: fieldPath, scope: rowScope(inner), inTemplate: inTemplate)
                case "widget": widget(value, path: fieldPath, scope: inner, inTemplate: inTemplate)
                case "widgets":
                    if case .array(let children) = value {
                        for (i, child) in children.enumerated() {
                            widget(child, path: "\(fieldPath)[\(i)]", scope: inner, inTemplate: inTemplate)
                        }
                    }
                case "color": color(value, path: fieldPath, scope: inner, inTemplate: inTemplate)
                case "icon": icon(value, path: fieldPath, scope: inner, inTemplate: inTemplate)
                case "source":
                    if case .string(let name) = value, !inTemplate, !sourceNames.contains(name) {
                        add(.missingReference, fieldPath, "no source named \"\(name)\"", code: "unknown-source", severity: .error,
                            suggestions: DidYouMean.suggestions(for: name, among: Array(sourceNames)))
                    } else if case .object(let definition) = value {
                        inlineSources.append((value, fieldPath))
                        sourceFields(definition, path: fieldPath, params: [])
                    }
                default:
                    break
                }
            } else if WidgetTypes.commonFields.contains(key) {
                commons[key] = value
            }
        }
        common(commons, path: path, scope: outer.adding(data).adding(bodyVars), inTemplate: inTemplate)
        for key in WidgetTypes.styleShorthands where template.params[key] == nil {
            if key == "color" { color(w[key], path: "\(path).color", scope: outer, inTemplate: inTemplate) }
            else { literal(w[key], path: "\(path).\(key)", scope: outer, inTemplate: inTemplate) }
        }
    }

    private func collectVars(_ value: AnyJSON, into names: inout Set<String>) {
        switch value {
        case .object(let members):
            if case .object(let vars)? = members["vars"] { names.formUnion(vars.keys) }
            for (key, member) in members where key != "vars" { collectVars(member, into: &names) }
        case .array(let items):
            for item in items { collectVars(item, into: &names) }
        default:
            break
        }
    }

    private func containsParameter(_ value: AnyJSON) -> Bool {
        if Expander.parameterReference(value) != nil { return true }
        switch value {
        case .object(let members): return members.values.contains(where: containsParameter)
        case .array(let items): return items.contains(where: containsParameter)
        default: return false
        }
    }

    private mutating func keyValueItems(_ value: AnyJSON, path: String, scope: Scope, inTemplate: Bool) {
        guard case .array(let items) = value else { return }
        let shape = SchemaRegistry.shape("keyValueItem")
        for (i, entry) in items.enumerated() {
            let itemPath = "\(path)[\(i)]"
            guard case .object(let item) = entry else { continue }
            for key in item.keys.sorted() where shape.key(key) == nil {
                add(.unknownKey, "\(itemPath).\(key)", "unknown key for keyValue items (known: \(shape.keyNames.joined(separator: ", ")))",
                    severity: .warning, suggestions: DidYouMean.suggestions(for: key, among: shape.keyNames))
            }
            var s = scope
            if case .string(let name)? = item["source"], !inTemplate, !sourceNames.contains(name) {
                add(.missingReference, "\(itemPath).source", "no source named \"\(name)\"", code: "unknown-source", severity: .error,
                    suggestions: DidYouMean.suggestions(for: name, among: Array(sourceNames)))
            }
            if case .object(let vars)? = item["vars"] {
                s = s.adding(vars.keys)
                for name in vars.keys.sorted() { expr(vars[name], path: "\(itemPath).vars.\(name)", scope: s, inTemplate: inTemplate) }
            }
            expr(item["when"], path: "\(itemPath).when", scope: s, inTemplate: inTemplate)
            expr(item["value"], path: "\(itemPath).value", scope: s, inTemplate: inTemplate)
            text(item["label"], path: "\(itemPath).label", scope: s, inTemplate: inTemplate)
            text(item["text"], path: "\(itemPath).text", scope: s, inTemplate: inTemplate)
            color(item["color"], path: "\(itemPath).color", scope: s.adding(["value"]), inTemplate: inTemplate)
            if let action = item["action"] { self.action(action, path: "\(itemPath).action", scope: s, inTemplate: inTemplate) }
            if case .string(let key)? = item["key"] { keyName(key, path: "\(itemPath).key", allowAuto: true) }
        }
    }

    private mutating func tableColumns(_ value: AnyJSON, path: String, scope: Scope, inTemplate: Bool) {
        guard case .array(let columns) = value else { return }
        let shape = SchemaRegistry.shape("tableColumn")
        for (i, entry) in columns.enumerated() {
            let columnPath = "\(path)[\(i)]"
            guard case .object(let column) = entry else { continue }
            for key in column.keys.sorted() where shape.key(key) == nil {
                add(.unknownKey, "\(columnPath).\(key)", "unknown key for table columns (known: \(shape.keyNames.joined(separator: ", ")))",
                    severity: .warning, suggestions: DidYouMean.suggestions(for: key, among: shape.keyNames))
            }
            text(column["header"], path: "\(columnPath).header", scope: scope, inTemplate: inTemplate)
            text(column["text"], path: "\(columnPath).text", scope: scope, inTemplate: inTemplate)
            expr(column["value"], path: "\(columnPath).value", scope: scope, inTemplate: inTemplate)
            style(column["style"], path: "\(columnPath).style", scope: scope, inTemplate: inTemplate)
            color(column["color"], path: "\(columnPath).color", scope: scope.adding(["value"]), inTemplate: inTemplate)
        }
    }

    // MARK: Actions (§9.3)

    static let actionKeys = ["run", "open", "copy", "refresh", "view", "popup", "close", "media", "audio", "hide"]
    static let actionSiblings: Set<String> = ["timeout", "env", "optimistic", "refreshAfter", "width", "source", "hide"]

    mutating func action(_ value: AnyJSON, path: String, scope: Scope, inTemplate: Bool = false) {
        switch value {
        case .array(let list):
            for (i, item) in list.enumerated() { action(item, path: "\(path)[\(i)]", scope: scope, inTemplate: inTemplate) }
        case .object(let members):
            if inTemplate, Expander.parameterReference(value) != nil { return }
            let kinds = Self.actionKeys.filter { members[$0] != nil }
            let named = kinds.filter { $0 != "hide" }
            if named.isEmpty && members["hide"] == nil {
                add(.missingKey, path, "an action needs one of \(Self.actionKeys.joined(separator: ", "))", code: "missing-required",
                    severity: .error)
            } else if named.count > 1 {
                add(.invalidValue, path, "an action holds one of \(named.joined(separator: ", ")); use a list for several",
                    severity: .error)
            }
            for key in members.keys.sorted() where !Self.actionKeys.contains(key) && !Self.actionSiblings.contains(key) {
                add(.unknownKey, "\(path).\(key)", "unknown action key", severity: .warning,
                    suggestions: DidYouMean.suggestions(for: key, among: Self.actionKeys + Array(Self.actionSiblings)))
            }
            if case .array(let argv)? = members["run"] {
                for (i, arg) in argv.enumerated() { text(arg, path: "\(path).run[\(i)]", scope: scope, inTemplate: inTemplate) }
            }
            for key in ["open", "copy", "view"] { text(members[key], path: "\(path).\(key)", scope: scope, inTemplate: inTemplate) }
            if case .object(let env)? = members["env"] {
                for name in env.keys.sorted() { text(env[name], path: "\(path).env.\(name)", scope: scope, inTemplate: inTemplate) }
            }
            expr(members["optimistic"], path: "\(path).optimistic", scope: scope, inTemplate: inTemplate)
            if case .object(let popup)? = members["popup"] {
                // `{"expr"}` values are evaluated when the popup opens, in this scope.
                var fields = popup
                for (key, field) in popup {
                    if case .object(let o) = field, o.count == 1, o["expr"] != nil {
                        expr(o["expr"], path: "\(path).popup.\(key).expr", scope: scope, inTemplate: inTemplate)
                        fields[key] = .object([:])
                    }
                }
                widget(.object(fields), path: "\(path).popup", scope: scope.adding(Self.rowVariables), inTemplate: inTemplate)
            }
        default:
            if inTemplate { return }
            add(.wrongType, path, "expected an action (an object) or a list of them", severity: .error,
                expected: "object", found: value.jsonTypeName)
        }
    }

    // MARK: Keys (§9.2)

    static let namedKeys: Set<String> = Set([
        "tab", "space", "enter", "return", "escape", "esc", "left", "right", "up", "down", "home", "end",
        "pageup", "pagedown", "backspace", "delete",
    ]).union((1...20).map { "f\($0)" })
    static let modifiers: Set<String> = ["cmd", "super", "command", "ctrl", "control", "alt", "opt", "option", "shift"]

    mutating func keyName(_ key: String, path: String, allowAuto: Bool) {
        if allowAuto && key == "auto" { return }
        let parts = key.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let last = parts.last ?? ""
        let validLast = Self.namedKeys.contains(last) || (last.count == 1 && last.unicodeScalars.first.map { $0.value > 0x20 } == true)
        guard validLast, parts.dropLast().allSatisfy({ Self.modifiers.contains($0) }) else {
            add(.invalidValue, path, "\"\(key)\" is not a key (a letter, digit, tab, space, enter, left, f5, ... "
                + "with cmd, ctrl, alt and shift joined by +)", code: "invalid-key", severity: .error, found: key)
            return
        }
        if RenderKeyMap.reserved.contains(RenderKeyMap.normalize(key)) {
            add(.invalidValue, path, "\"\(key)\" is reserved (escape closes or hides, alt+i shows the info popup)",
                code: "key-conflict", severity: .error, found: key)
        }
    }

    // MARK: Values

    /// A literal field, which may be `{"expr": …}` (R3).
    mutating func literal(_ value: AnyJSON?, path: String, scope: Scope, inTemplate: Bool = false) {
        guard case .object(let members)? = value else { return }
        if members.count == 1, case .string? = members["expr"] {
            expr(members["expr"], path: "\(path).expr", scope: scope.adding(["value"]), inTemplate: inTemplate)
        }
    }

    mutating func style(_ value: AnyJSON?, path: String, scope: Scope, inTemplate: Bool = false) {
        guard case .object(let fields)? = value else { return }
        let shape = SchemaRegistry.shape("style")
        for key in fields.keys.sorted() where shape.key(key) == nil {
            add(.unknownKey, "\(path).\(key)", "unknown style key (known: \(shape.keyNames.joined(separator: ", ")))",
                severity: .warning, suggestions: DidYouMean.suggestions(for: key, among: shape.keyNames))
        }
        for (key, field) in fields where key != "color" {
            literal(field, path: "\(path).\(key)", scope: scope, inTemplate: inTemplate)
        }
        color(fields["color"], path: "\(path).color", scope: scope.adding(["value"]), inTemplate: inTemplate)
    }

    /// A colour (§8.3): a palette name, hex, `name@alpha`, `{"steps", "of"}`
    /// or `{"expr"}`.
    mutating func color(_ value: AnyJSON?, path: String, scope: Scope, inTemplate: Bool = false) {
        switch value {
        case .string(let text)?:
            if palette.resolve(text) == nil {
                add(.invalidValue, path, "unknown colour \"\(text)\"", code: "unknown-color", severity: .error,
                    suggestions: DidYouMean.suggestions(for: RenderPalette.baseName(text), among: palette.colors.keys.sorted()),
                    found: text)
            }
        case .object(let members)?:
            if inTemplate, Expander.parameterReference(value!) != nil { return }
            if case .string? = members["expr"] {
                expr(members["expr"], path: "\(path).expr", scope: scope.adding(["value"]), inTemplate: inTemplate)
            } else if case .array(let stops)? = members["steps"] {
                for (i, stop) in stops.enumerated() {
                    guard case .array(let pair) = stop, pair.count == 2, TextStyle.size(pair[0]) != nil else {
                        add(.invalidValue, "\(path).steps[\(i)]", "a step is [threshold, colour]", severity: .error)
                        continue
                    }
                    color(pair[1], path: "\(path).steps[\(i)][1]", scope: scope, inTemplate: inTemplate)
                }
                expr(members["of"], path: "\(path).of", scope: scope, inTemplate: inTemplate)
            } else {
                add(.invalidValue, path, "not a colour: a name, #rrggbb[aa], {\"steps\": …} or {\"expr\": …}",
                    code: "unknown-color", severity: .error)
            }
        default:
            break
        }
    }

    /// An icon name (§8.6): in the bundled set, or `sf:` under `platform.macos`.
    mutating func icon(_ value: AnyJSON?, path: String, scope: Scope, inTemplate: Bool = false) {
        switch value {
        case .string(let name)?:
            if name.hasPrefix("sf:") {
                if platform != .macos {
                    add(.invalidValue, path, "\"\(name)\" is an SF Symbol: only allowed in platform.macos", code: "platform-only",
                        severity: .error, found: name)
                }
            } else if !name.isEmpty && !IconMap.contains(name) {
                add(.invalidValue, path, "unknown icon \"\(name)\"", code: "unknown-icon", severity: .error,
                    suggestions: DidYouMean.suggestions(for: name, among: IconMap.names), found: name)
            }
        default:
            literal(value, path: path, scope: scope, inTemplate: inTemplate)
        }
    }

    // MARK: Sources

    /// A source definition's expressions: `transform`, history values, and
    /// the load-time text (only `$secrets`, `$env` and the parameters).
    mutating func sourceFields(_ source: [String: AnyJSON], path: String, params: Set<String>) {
        expr(source["transform"], path: "\(path).transform", scope: Scope(variables: []), checkVariables: true)
        if case .object(let histories)? = source["history"] {
            for name in histories.keys.sorted() {
                expr(histories[name]?.objectValue?["value"], path: "\(path).history.\(name).value", scope: Scope(variables: []))
            }
        }
        let scope = Scope(variables: params.union(["secrets", "env", "params"]))
        for field in ConfigExpansion.loadTimeFields { text(source[field], path: "\(path).\(field)", scope: scope) }
        for field in ConfigExpansion.loadTimeLists {
            if case .array(let items)? = source[field] {
                for (i, item) in items.enumerated() { text(item, path: "\(path).\(field)[\(i)]", scope: scope) }
            } else {
                text(source[field], path: "\(path).\(field)", scope: scope)
            }
        }
        for field in ConfigExpansion.loadTimeMaps {
            if case .object(let map)? = source[field] {
                for key in map.keys.sorted() { text(map[key], path: "\(path).\(field).\(key)", scope: scope) }
            }
        }
    }

    // MARK: Expressions

    /// An expr field: compiled, its variables checked against `scope`.
    mutating func expr(_ value: AnyJSON?, path: String, scope: Scope, inTemplate: Bool = false, checkVariables: Bool = true) {
        guard case .string(let source)? = value else { return }
        compile(source, path: path, offset: 0, scope: scope, checkVariables: checkVariables, legacyHint: true)
    }

    /// A text field: its `{{ }}` holes compiled.
    mutating func text(_ value: AnyJSON?, path: String, scope: Scope, inTemplate: Bool = false) {
        guard case .string(let text)? = value, TextTemplate.hasHoles(text) else { return }
        switch TextTemplate.parse(text) {
        case .failure(let error):
            report(error, path: path)
        case .success(let template):
            for (expression, offset) in template.holes {
                compile(expression, path: path, offset: offset, scope: scope, checkVariables: true, legacyHint: false)
            }
        }
    }

    private mutating func compile(_ source: String, path: String, offset: Int, scope: Scope, checkVariables: Bool,
                                  legacyHint: Bool) {
        switch environment.compile(source) {
        case .failure(var error):
            error = error.shifted(by: offset)
            // A v0.3 path in a jq field (§4.3): suggest the jq form.
            let trimmed = source.trimmingCharacters(in: .whitespaces)
            if legacyHint, !trimmed.hasPrefix("."), JQExpression.isLegacyPath(trimmed),
               error.code == "expr-unknown-function" || error.code == "expr-syntax" {
                let jq = JQExpression.normalizeLegacyPath(trimmed)
                error.message += " (a v0.3 path? in jq it is \(jq))"
                error.suggestion = jq
            }
            report(error, path: path)
        case .success(let compiled):
            guard checkVariables else { return }
            let known = scope.all
            for use in compiled.references.variables where !known.contains(use.name) {
                let message: String
                if Self.rowVariables.contains(use.name) {
                    message = "$\(use.name) is only bound inside a list or table row"
                } else if use.name == "secrets" || use.name == "env" {
                    message = "$\(use.name) is only in scope in source definitions"
                } else {
                    message = "unknown variable '$\(use.name)'"
                }
                var warning = ConfigWarning(kind: .invalidValue, path: path, message: message, code: "expr-unknown-variable",
                                            severity: .error,
                                            suggestions: DidYouMean.suggestions(for: use.name, among: Array(known)).map { "$" + $0 })
                warning.exprOffset = offset + (Self.variableOffset(use.name, in: source) ?? 0)
                warnings.append(warning)
            }
        }
    }

    static func variableOffset(_ name: String, in source: String) -> Int? {
        guard let range = source.range(of: "$" + name) else { return nil }
        return source.utf8.distance(from: source.utf8.startIndex, to: range.lowerBound.samePosition(in: source.utf8) ?? source.utf8.startIndex)
    }

    private mutating func report(_ error: ExprError, path: String) {
        var message = error.message
        if let offset = error.offset { message += " in expression at \(offset)" }
        var warning = ConfigWarning(kind: .invalidValue, path: path, message: message, code: error.code, severity: .error,
                                    suggestions: error.suggestion.map { [$0] } ?? [])
        warning.exprOffset = error.offset
        warnings.append(warning)
    }

    private mutating func add(_ kind: ConfigWarning.Kind, _ path: String, _ message: String, code: String? = nil,
                              severity: ConfigDiagnostic.Severity = .error, suggestions: [String] = [],
                              expected: String? = nil, found: String? = nil) {
        warnings.append(ConfigWarning(kind: kind, path: path, message: message, code: code, severity: severity,
                                      suggestions: suggestions, expected: expected, found: found))
    }
}

// MARK: - Checks for tests and docs

public enum ConfigChecks {
    /// Problems in the built-in templates' bodies (none, or a bug here).
    public static func builtinTemplateProblems() -> [ConfigWarning] {
        var checker = V04Checker(top: ["widgets": .object([:]), "sources": .object([:])], platform: .linux)
        for (name, template) in TemplateRegistry.standard.builtins.sorted(by: { $0.key < $1.key }) {
            let data = template.params.filter(\.value.isData).map(\.key)
            if let body = template.widget {
                checker.templateBody(body, path: "templates.\(name).widget", scope: V04Checker.baseScope.adding(data))
            } else if case .object(let source)? = template.source {
                checker.sourceFields(source, path: "templates.\(name).source", params: Set(data))
            }
        }
        return checker.warnings
    }
}
