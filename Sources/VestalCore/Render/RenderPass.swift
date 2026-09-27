import Foundation

// MARK: - One render pass (EXTENSIBILITY.md §6, §8, §10)
//
// Evaluates the expanded widget tree against one data snapshot and builds
// the render model's nodes. Per widget, in order: `source` (sets `.`,
// `$data`, `$meta`; the loading rule), `input`, `vars` (in dependency order),
// `when`; then the type's own fields. A runtime error makes its field null
// and is reported once in `diagnostics`; a compile error hides the widget
// (§4.4). Hidden widgets don't exist in the model.
//
// A pass renders each root child of the view separately and records what it
// read (sources, `now`), so the engine re-evaluates only the root children
// whose inputs changed (§4.7). Not thread-safe: one pass, one thread.

/// An action as written and the scope it was written in, for `invoke` and
/// keys (§9.3).
public struct RenderActionBinding {
    public var action: AnyJSON
    public var dot: JQValue
    public var variables: [String: JQValue]
    /// The nearest source (the widget's source for `refresh`, `media`).
    public var source: String?
}

/// A widget key before assignment (§9.2).
struct KeyCandidate: Equatable {
    /// An explicit key, normalised; nil for `auto`.
    var key: String?
    /// Letters `auto` tries, in order.
    var hint: String
    var nodeId: String
}

/// One root child of a view, rendered, with what it depends on.
struct RenderedChild {
    var node: RenderNode?
    var diagnostics: [RenderDiagnostic] = []
    var actions: [String: RenderActionBinding] = [:]
    var keys: [KeyCandidate] = []
    /// Sources it read; "*" means any.
    var sources: Set<String> = []
    var usesNow = false

    func dependsOn(_ changed: Set<String>) -> Bool {
        sources.contains("*") || !sources.isDisjoint(with: changed)
    }
}

final class RenderPass {
    let model: RenderConfigModel
    let data: RenderData
    let now: Date
    let timeZone: TimeZone
    let locale: Locale
    let os: String
    let view: String

    private var diagnostics: [RenderDiagnostic] = []
    private var diagnosticKeys: Set<String> = []
    private var actions: [String: RenderActionBinding] = [:]
    private var keys: [KeyCandidate] = []
    private var sources: Set<String> = []
    private var usesNow = false

    init(model: RenderConfigModel, data: RenderData, now: Date, view: String,
         timeZone: TimeZone = .current, locale: Locale = .current, os: String = RenderPass.currentOS) {
        self.model = model
        self.data = data
        self.now = now
        self.view = view
        self.timeZone = timeZone
        self.locale = locale
        self.os = os
    }

    static var currentOS: String {
        #if os(macOS)
        return "macos"
        #else
        return "linux"
        #endif
    }

    // MARK: Scope

    struct Scope {
        var dot: JQValue = .null
        var vars: [String: JQValue]
        var source: String?
        var style: TextStyle
    }

    func baseScope() -> Scope {
        var vars: [String: JQValue] = [
            "sources": data.sourcesValue,
            "history": data.historyValue,
            "tz": .string(timeZone.identifier),
            "os": .string(os),
            "view": .string(view),
            "widget": .string(""),
            "params": .object(JQObject()),
            "data": .null,
            "meta": .null,
        ]
        vars["item"] = nil
        return Scope(vars: vars, source: nil, style: TextStyle(size: 13 * model.scale, scale: model.scale))
    }

    // MARK: Views

    /// One root child of `spec`: a widget key or an inline widget.
    func renderRootChild(_ entry: AnyJSON, index: Int, axis: RenderAxis = .v) -> RenderedChild {
        begin()
        var node: RenderNode?
        switch entry {
        case .string(let key):
            if let widget = model.widgets[key]?.objectValue {
                var scope = baseScope()
                scope.vars["widget"] = .string(key)
                node = build(widget, id: "\(view)/\(Self.encode(key))", scope: scope, axis: axis)
            } else {
                report(id: "\(view)/\(key)", field: nil, severity: "error", code: "unknown-widget",
                       message: "no widget named \"\(key)\"")
            }
        case .object(let widget):
            let id = widget["id"]?.stringValue.map { "\(view)/\(Self.encode($0))" } ?? "\(view)/\(index)"
            node = build(widget, id: id, scope: baseScope(), axis: axis)
        default:
            break
        }
        return finish(node)
    }

    /// The view's root node around its rendered children (§9.1, §10.4).
    func root(_ spec: ViewSpec, children: [RenderedChild]) -> RenderNode {
        var nodes = children.compactMap(\.node)
        // v0.3 views (`order`): only the first *listed* entry gets no space
        // before it; when it is hidden, the next one keeps its space
        // (§13.1 rule 8b). A zero-size first node holds that place.
        if spec.usesOrder, let first = children.first, first.node == nil, !nodes.isEmpty {
            var holder = RenderNode(id: "\(view)/^", .spacer(.init()))
            holder.height = .points(0)
            holder.width = .points(0)
            nodes.insert(holder, at: 0)
        }
        var node: RenderNode
        switch spec.layout {
        case "grid":
            node = RenderNode(id: view, .grid(.init(
                columns: Array(repeating: .init(width: .fill), count: spec.columns),
                gap: spec.gap, rowGap: spec.gap, children: nodes)))
        default:
            node = RenderNode(id: view, .stack(.init(
                axis: spec.layout == "row" ? .h : .v, gap: spec.gap,
                align: RenderAlign(rawValue: spec.align) ?? .center, children: nodes)))
        }
        node.maxWidth = spec.maxWidth
        node.padding = RenderInsets(top: spec.padding[0], right: spec.padding[1], bottom: spec.padding[2], left: spec.padding[3])
        node.width = .fill
        return node
    }

    /// A popup (§9.4): its widget is already expanded and its `{"expr"}`
    /// values filled in.
    func renderPopup(_ widget: [String: AnyJSON]) -> RenderedChild {
        begin()
        let node = build(widget, id: "popup/0", scope: baseScope(), axis: .v)
        return finish(node)
    }

    private func begin() {
        diagnostics = []
        diagnosticKeys = []
        actions = [:]
        keys = []
        sources = []
        usesNow = false
        data.resetReads()
    }

    private func finish(_ node: RenderNode?) -> RenderedChild {
        RenderedChild(node: node, diagnostics: diagnostics, actions: actions, keys: keys,
                      sources: sources.union(data.reads), usesNow: usesNow)
    }

    // MARK: Widgets

    /// A widget's node, or nil when it is hidden.
    func build(_ w: [String: AnyJSON], id: String, scope parent: Scope, axis: RenderAxis) -> RenderNode? {
        guard let type = w["type"]?.stringValue, type != "$error" else { return nil }
        var scope = parent
        if let key = w["$widget"]?.stringValue { scope.vars["widget"] = .string(key) }
        if case .object(let params)? = w["$params"] {
            scope.vars["params"] = JQValue(AnyJSON.object(params))
            for (name, value) in params { scope.vars[name] = JQValue(value) }
        }

        // source → loading rule
        if let source = w["source"] {
            var loaded = false
            switch source {
            case .string(let name):
                sources.insert(name)
                if !model.sourceNames.contains(name) {
                    report(id: id, field: "source", severity: "error", code: "unknown-source",
                           message: "no source named \"\(name)\"")
                }
                let value = data.data(name)
                loaded = value != nil
                scope.source = name
                scope.dot = value ?? .null
                scope.vars["data"] = value ?? .null
                scope.vars["meta"] = data.meta(name) ?? .null
            default:
                // An inline source that isn't usable (a preset's optional
                // file source left without a path): never loaded.
                scope.source = nil
                scope.dot = .null
                scope.vars["data"] = .null
                scope.vars["meta"] = .null
            }
            if !loaded {
                switch w["loading"] {
                case .string("show")?:
                    break
                case .object(let alternative)?:
                    return build(alternative, id: id, scope: scope, axis: axis)
                default:
                    return nil
                }
            }
        }
        if case .string(let input)? = w["input"] {
            scope.dot = eval(input, id: id, field: "input", scope: scope) ?? .null
        }
        if case .object(let vars)? = w["vars"] {
            bindVars(vars, id: id, scope: &scope)
        }
        if let when = w["when"] {
            switch when {
            case .string(let expression):
                guard let result = eval(expression, id: id, field: "when", scope: scope), result.isTruthy else { return nil }
            case .bool(false), .null:
                return nil
            default:
                break
            }
        }
        // Widgets with a value apply their own style once it is known
        // (style fields may use `$value`).
        if !Self.valueTypes.contains(type) {
            scope.style = style(w["style"], over: scope.style, id: id, scope: scope, value: nil)
        }

        var node: RenderNode?
        switch type {
        case "stack", "row": node = stack(w, id: id, scope: scope, axis: type == "row" ? .h : .v)
        case "grid": node = grid(w, id: id, scope: scope)
        case "list": node = list(w, id: id, scope: scope)
        case "table": node = table(w, id: id, scope: scope)
        case "switch": return switchCase(w, id: id, scope: scope, axis: axis)
        case "text": node = text(w, id: id, scope: scope)
        case "icon": node = icon(w, id: id, scope: scope)
        case "progress": node = progress(w, id: id, scope: scope)
        case "gauge": node = gauge(w, id: id, scope: scope)
        case "sparkline": node = sparkline(w, id: id, scope: scope)
        case "keyValue": node = keyValue(w, id: id, scope: scope)
        case "divider": node = divider(w, id: id, scope: scope)
        case "spacer": node = spacer(w, id: id, scope: scope, axis: axis)
        default:
            report(id: id, field: "type", severity: "error", code: "unknown-type", message: "unknown widget type \"\(type)\"")
            return nil
        }
        guard var built = node else { return nil }
        box(w, into: &built, scope: scope, sizesBar: type == "progress")
        bind(w, node: &built, scope: scope)
        propagateFill(&built)
        return built
    }

    static let valueTypes: Set<String> = ["text", "progress", "gauge", "sparkline"]

    // MARK: Containers

    private func stack(_ w: [String: AnyJSON], id: String, scope: Scope, axis: RenderAxis) -> RenderNode {
        let children = childNodes(w["children"], parent: id, scope: scope, axis: axis)
        let defaultAlign: RenderAlign = axis == .h ? .center : .start
        return RenderNode(id: id, .stack(.init(
            axis: axis,
            gap: number(w["gap"], id: id, field: "gap", scope: scope) ?? 8,
            align: align(w["align"], id: id, scope: scope) ?? defaultAlign,
            justify: RenderJustify(rawValue: string(w["justify"], id: id, field: "justify", scope: scope) ?? "") ?? .start,
            children: children)))
    }

    private func childNodes(_ value: AnyJSON?, parent: String, scope: Scope, axis: RenderAxis) -> [RenderNode] {
        guard case .array(let children)? = value else { return [] }
        var nodes: [RenderNode] = []
        for (index, child) in children.enumerated() {
            let object: [String: AnyJSON]?
            var childScope = scope
            switch child {
            case .string(let key):
                object = model.widgets[key]?.objectValue
                childScope.vars["widget"] = .string(key)
                if object == nil {
                    report(id: "\(parent)/\(index)", field: nil, severity: "error", code: "unknown-widget",
                           message: "no widget named \"\(key)\"")
                }
            case .object(let o):
                object = o
            default:
                object = nil
            }
            guard let object else { continue }
            let childId = object["id"]?.stringValue.map { "\(parent)/\(Self.encode($0))" } ?? "\(parent)/\(index)"
            if let node = build(object, id: childId, scope: childScope, axis: axis) { nodes.append(node) }
        }
        return nodes
    }

    private func grid(_ w: [String: AnyJSON], id: String, scope: Scope) -> RenderNode {
        let columns = gridColumns(w["columns"], id: id, scope: scope, fallback: 2)
        let gap = number(w["gap"], id: id, field: "gap", scope: scope) ?? 12
        return RenderNode(id: id, .grid(.init(
            columns: columns, gap: gap,
            rowGap: number(w["rowGap"], id: id, field: "rowGap", scope: scope) ?? gap,
            children: childNodes(w["children"], parent: id, scope: scope, axis: .h))))
    }

    private func gridColumns(_ value: AnyJSON?, id: String, scope: Scope, fallback: Int) -> [RenderNode.Grid.Column] {
        let resolved = literal(value, id: id, field: "columns", scope: scope)
        if case .array(let specs)? = resolved {
            return specs.map { spec in
                let object = spec.objectValue ?? [:]
                let width: RenderNode.Grid.Column.Width
                switch object["width"] {
                case .string("fill")?: width = .fill
                case .string("fit")?, nil: width = object["fill"] == .bool(true) ? .fill : .fit
                case let other?: width = TextStyle.size(other).map { .points($0) } ?? .fit
                }
                let align = RenderTextAlign(rawValue: object["align"]?.stringValue ?? "start") ?? .start
                return RenderNode.Grid.Column(width: width, align: align)
            }
        }
        let count = max(1, Int(TextStyle.size(resolved) ?? Double(fallback)))
        return Array(repeating: RenderNode.Grid.Column(width: .fill), count: count)
    }

    /// `items` (§4.4): every output collected; a single array output is used
    /// as it is. A literal array is static data.
    private func items(_ w: [String: AnyJSON], id: String, scope: Scope) -> [JQValue] {
        var items: [JQValue]
        switch w["items"] {
        case .string(let expression)?:
            guard let outputs = evalAll(expression, id: id, field: "items", scope: scope) else { return [] }
            if outputs.count == 1, case .array(let array) = outputs[0] { items = array } else { items = outputs.filter { $0 != .null } }
        case .array(let array)?:
            items = array.map(JQValue.init)
        default:
            items = []
        }
        if case .string(let filter)? = w["filter"] {
            items = items.filter { item in
                var s = scope
                s.dot = item
                return eval(filter, id: id, field: "filter", scope: s)?.isTruthy == true
            }
        }
        if case .string(let sortBy)? = w["sortBy"] {
            let keyed = items.map { item -> (JQValue, JQValue) in
                var s = scope
                s.dot = item
                return (eval(sortBy, id: id, field: "sortBy", scope: s) ?? .null, item)
            }
            items = keyed.enumerated().sorted { a, b in
                let c = JQValue.compare(a.element.0, b.element.0)
                return c != 0 ? c < 0 : a.offset < b.offset
            }.map(\.element.1)
        }
        if bool(w["reverse"], id: id, field: "reverse", scope: scope) == true { items.reverse() }
        if let limit = number(w["limit"], id: id, field: "limit", scope: scope), limit >= 0 {
            items = Array(items.prefix(Int(limit)))
        }
        return items
    }

    /// Each row's id segment (§10.5): `@<rowId>`, percent-encoded, with
    /// `~2`, `~3` for duplicates.
    private func rowIds(_ items: [JQValue], w: [String: AnyJSON], id: String, scope: Scope) -> [String] {
        var seen: [String: Int] = [:]
        return items.enumerated().map { index, item in
            var raw = String(index)
            if case .string(let expression)? = w["rowId"] {
                var s = scope
                s.dot = item
                s.vars["item"] = item
                s.vars["index"] = .number(Double(index))
                if let value = eval(expression, id: id, field: "rowId", scope: s), value != .null {
                    raw = TextTemplate.stringify(value)
                }
            }
            var segment = "@" + Self.encode(raw)
            let count = (seen[segment] ?? 0) + 1
            seen[segment] = count
            if count > 1 {
                report(id: id, field: "rowId", severity: "warning", code: "duplicate-row-id",
                       message: "row id \"\(raw)\" appears more than once")
                segment += "~\(count)"
            }
            return "\(id)/\(segment)"
        }
    }

    private func rowScope(_ scope: Scope, item: JQValue, index: Int) -> Scope {
        var s = scope
        s.vars["parent"] = scope.vars["item"] ?? .null
        s.vars["item"] = item
        s.vars["index"] = .number(Double(index))
        s.dot = item
        return s
    }

    private func list(_ w: [String: AnyJSON], id: String, scope: Scope) -> RenderNode? {
        let rows = items(w, id: id, scope: scope)
        let direction = string(w["direction"], id: id, field: "direction", scope: scope) ?? "column"
        var children: [RenderNode] = []
        if let row = w["row"]?.objectValue {
            let ids = rowIds(rows, w: w, id: id, scope: scope)
            for (index, item) in rows.enumerated() {
                if let node = build(row, id: ids[index], scope: rowScope(scope, item: item, index: index),
                                    axis: direction == "row" ? .h : .v) {
                    children.append(node)
                }
            }
        }
        if children.isEmpty {
            switch w["empty"] {
            case .string(let text)?:
                children = [textNode(id: "\(id)/empty", text: renderText(text, id: id, field: "empty", scope: scope),
                                     style: scope.style, lines: nil, align: .start)]
            case .object(let widget)?:
                if let node = build(widget, id: "\(id)/empty", scope: scope, axis: direction == "row" ? .h : .v) {
                    children = [node]
                }
            default:
                return nil
            }
        }
        let gap = number(w["gap"], id: id, field: "gap", scope: scope) ?? 8
        switch direction {
        case "row":
            return RenderNode(id: id, .stack(.init(axis: .h, gap: gap, align: align(w["align"], id: id, scope: scope) ?? .center,
                                                  children: children)))
        case "grid":
            let columns = gridColumns(w["columns"], id: id, scope: scope, fallback: 2)
            return RenderNode(id: id, .grid(.init(columns: columns, gap: gap, rowGap: gap, children: children)))
        default:
            return RenderNode(id: id, .stack(.init(axis: .v, gap: gap, align: align(w["align"], id: id, scope: scope) ?? .start,
                                                  children: children)))
        }
    }

    private func table(_ w: [String: AnyJSON], id: String, scope: Scope) -> RenderNode? {
        let specs = (w["columns"]?.arrayValue ?? []).compactMap(\.objectValue)
        let rows = items(w, id: id, scope: scope)
        var cells: [RenderNode] = []
        if bool(w["header"], id: id, field: "header", scope: scope) ?? true {
            var header = scope.style
            header.size = 10 * header.scale
            header.weight = 600
            header.color = "dim"
            header.textCase = "upper"
            for (c, spec) in specs.enumerated() {
                let title = spec["header"]?.stringValue.map { renderText($0, id: id, field: "header", scope: scope) } ?? ""
                cells.append(textNode(id: "\(id)/h/\(c)", text: title, style: header, lines: 1,
                                      align: RenderTextAlign(rawValue: spec["align"]?.stringValue ?? "start") ?? .start))
            }
        }
        let ids = rowIds(rows, w: w, id: id, scope: scope)
        for (index, item) in rows.enumerated() {
            let s = rowScope(scope, item: item, index: index)
            for (c, spec) in specs.enumerated() {
                var cellStyle = style(spec["style"], over: s.style, id: id, scope: s, value: nil)
                var content: String
                var value: JQValue?
                if case .string(let expression)? = spec["value"] {
                    value = eval(expression, id: id, field: "columns[\(c)].value", scope: s)
                    content = value.map { formatted($0, spec["format"], id: id, scope: s) } ?? "–"
                } else {
                    content = renderText(spec["text"]?.stringValue ?? "", id: id, field: "columns[\(c)].text", scope: s)
                }
                if let color = spec["color"] { cellStyle.color = self.color(color, id: id, field: "color", scope: s, value: value) ?? cellStyle.color }
                var cell = textNode(id: "\(ids[index])/\(c)", text: content, style: cellStyle, lines: 1,
                                    align: RenderTextAlign(rawValue: spec["align"]?.stringValue ?? "start") ?? .start)
                if let action = w["rowAction"] {
                    cell.action = true
                    actions[cell.id] = RenderActionBinding(action: action, dot: s.dot, variables: s.vars, source: s.source)
                }
                cells.append(cell)
            }
        }
        if rows.isEmpty {
            switch w["empty"] {
            case .string(let text)?:
                return textNode(id: "\(id)/empty", text: renderText(text, id: id, field: "empty", scope: scope),
                                style: scope.style, lines: nil, align: .start)
            case .object(let widget)?:
                return build(widget, id: "\(id)/empty", scope: scope, axis: .v)
            default:
                return nil
            }
        }
        let columns = specs.map { spec -> RenderNode.Grid.Column in
            let width: RenderNode.Grid.Column.Width
            switch spec["width"] {
            case .string("fill")?: width = .fill
            case let other?: width = TextStyle.size(other).map { .points($0) } ?? .fit
            case nil: width = spec["fill"] == .bool(true) ? .fill : .fit
            }
            return .init(width: width, align: RenderTextAlign(rawValue: spec["align"]?.stringValue ?? "start") ?? .start)
        }
        return RenderNode(id: id, .grid(.init(
            columns: columns, gap: number(w["gap"], id: id, field: "gap", scope: scope) ?? 12,
            rowGap: number(w["rowGap"], id: id, field: "rowGap", scope: scope) ?? 6, children: cells)))
    }

    /// The chosen case, with the switch's own box fields where the case
    /// doesn't set them (§10.3: a switch is its chosen case).
    private func switchCase(_ w: [String: AnyJSON], id: String, scope: Scope, axis: RenderAxis) -> RenderNode? {
        let on = w["on"]?.stringValue.flatMap { eval($0, id: id, field: "on", scope: scope) } ?? .null
        let key: String
        if case .string(let s) = on { key = s } else { key = on.textValue }
        let chosen: [String: AnyJSON]
        let segment: String
        if let match = w["cases"]?.objectValue?[key]?.objectValue {
            chosen = match
            segment = "=" + Self.encode(key)
        } else if let fallback = w["default"]?.objectValue {
            chosen = fallback
            segment = "=*"
        } else {
            return nil
        }
        var merged = chosen
        for field in ["width", "height", "minWidth", "maxWidth", "padding", "background", "radius", "opacity",
                      "clip", "spaceBefore", "alignSelf", "span", "action", "key", "keyHint", "alt"]
        where merged[field] == nil && w[field] != nil {
            merged[field] = w[field]
        }
        return build(merged, id: "\(id)/\(segment)", scope: scope, axis: axis)
    }

    // MARK: Primitives

    private func text(_ w: [String: AnyJSON], id: String, scope: Scope) -> RenderNode {
        var value: JQValue?
        var content: String
        if case .string(let expression)? = w["value"] {
            value = eval(expression, id: id, field: "value", scope: scope)
        }
        var s = scope
        if let value { s.vars["value"] = value } else if w["value"] != nil { s.vars["value"] = .null }
        let own = self.style(w["style"], over: s.style, id: id, scope: s, value: s.vars["value"])
        let style = shorthands(w, over: own, id: id, scope: s, value: s.vars["value"])
        if w["value"] != nil {
            if let value, value != .null {
                content = renderText(w["prefix"]?.stringValue ?? "", id: id, field: "prefix", scope: s)
                    + formatted(value, w["format"], id: id, scope: s)
                    + renderText(w["suffix"]?.stringValue ?? "", id: id, field: "suffix", scope: s)
            } else {
                content = renderText(w["placeholder"]?.stringValue ?? "–", id: id, field: "placeholder", scope: s)
            }
        } else {
            switch w["text"] {
            case .string(let t)?: content = renderText(t, id: id, field: "text", scope: s)
            case .object?: content = TextTemplate.stringify(literal(w["text"], id: id, field: "text", scope: s).map(JQValue.init))
            case let other?: content = TextTemplate.stringify(JQValue(other))
            case nil: content = ""
            }
        }
        let lines = number(w["lines"], id: id, field: "lines", scope: s).map { max(1, Int($0)) }
        let textAlign = RenderTextAlign(rawValue: string(w["align"], id: id, field: "align", scope: s) ?? "start") ?? .start
        guard let iconName = string(w["icon"], id: id, field: "icon", scope: s), !iconName.isEmpty else {
            return textNode(id: id, text: content, style: style, lines: lines, align: textAlign)
        }
        let iconSize = number(w["iconSize"], id: id, field: "iconSize", scope: s).map { $0 * style.scale } ?? style.size * 0.8
        let iconColor = w["iconColor"].flatMap { color($0, id: id, field: "iconColor", scope: s, value: value) } ?? style.color
        let weight = string(w["iconWeight"], id: id, field: "iconWeight", scope: s) ?? "regular"
        let glyph = iconNode(id: "\(id)/icon", name: iconName, weight: weight, size: iconSize, color: iconColor)
        let label = textNode(id: "\(id)/text", text: content, style: style, lines: lines, align: textAlign)
        return RenderNode(id: id, .stack(.init(axis: .h, gap: number(w["gap"], id: id, field: "gap", scope: s) ?? 5,
                                              align: .center, children: [glyph, label])))
    }

    func textNode(id: String, text: String, style: TextStyle, lines: Int?, align: RenderTextAlign) -> RenderNode {
        RenderNode(id: id, .text(.init(text: style.cased(text), size: style.size, weight: style.weight, font: style.font,
                                       color: style.color, tracking: style.tracking, lines: lines, textAlign: align)))
    }

    private func icon(_ w: [String: AnyJSON], id: String, scope: Scope) -> RenderNode {
        let name = string(w["name"], id: id, field: "name", scope: scope) ?? ""
        let weight = string(w["weight"], id: id, field: "weight", scope: scope) ?? "regular"
        let size = number(w["size"], id: id, field: "size", scope: scope).map { $0 * scope.style.scale } ?? 13 * scope.style.scale
        let color = w["color"].flatMap { self.color($0, id: id, field: "color", scope: scope, value: nil) }
            ?? w["style"]?.objectValue?["color"].flatMap { self.color($0, id: id, field: "color", scope: scope, value: nil) }
            ?? scope.style.color
        return iconNode(id: id, name: name, weight: weight, size: size, color: color)
    }

    private func iconNode(id: String, name: String, weight: String, size: Double, color: String) -> RenderNode {
        let weight = weight == "fill" ? "fill" : "regular"
        var glyph: String?
        if !name.hasPrefix("sf:") {
            glyph = IconMap.glyph(name, weight: weight)
            if glyph == nil {
                report(id: id, field: "name", severity: "warning", code: "unknown-icon", message: "unknown icon \"\(name)\"")
            }
        }
        return RenderNode(id: id, .icon(.init(name: name, glyph: glyph, weight: weight, size: size, color: color)))
    }

    private func progress(_ w: [String: AnyJSON], id: String, scope: Scope) -> RenderNode {
        let value = numeric(w["value"], id: id, field: "value", scope: scope)
        var s = scope
        s.vars["value"] = value.map { .number($0) } ?? .null
        s.style = style(w["style"], over: scope.style, id: id, scope: s, value: s.vars["value"])
        let scope = s
        let min = numeric(w["min"], id: id, field: "min", scope: s) ?? 0
        let max = numeric(w["max"], id: id, field: "max", scope: s) ?? 100
        func fraction(_ v: Double?) -> Double? {
            guard let v, max > min else { return nil }
            return Swift.min(Swift.max((v - min) / (max - min), 0), 1)
        }
        let barColor = w["color"].flatMap { color($0, id: id, field: "color", scope: s, value: s.vars["value"]) } ?? "accent"
        var bar = RenderNode.Bar(value: fraction(value) ?? 0, radius: number(w["radius"], id: id, field: "radius", scope: s) ?? 2)
        if let overlay = fraction(numeric(w["overlay"], id: id, field: "overlay", scope: s)), overlay > 0 {
            bar.overlay = overlay
            bar.overlayColor = w["overlayColor"].flatMap { color($0, id: id, field: "overlayColor", scope: s, value: nil) } ?? "#ffffff33"
        }
        if let position = string(w["overlayPosition"], id: id, field: "overlayPosition", scope: s), position == "below" {
            bar.overlayPosition = "below"
        }
        bar.color = barColor
        bar.trackColor = w["trackColor"].flatMap { color($0, id: id, field: "trackColor", scope: s, value: nil) }
            ?? model.palette.hexValue(barColor).map { RenderPalette.withAlpha($0, 0.15) }
        var barNode = RenderNode(id: "\(id)/1", .bar(bar))
        barNode.width = length(w["width"], id: id, field: "width", scope: s) ?? .fill
        barNode.height = length(w["height"], id: id, field: "height", scope: s) ?? .points(6 * scope.style.scale)
        var children: [RenderNode] = []
        if let label = w["label"]?.stringValue {
            var labelStyle = scope.style
            labelStyle.size = 9 * scope.style.scale
            labelStyle.weight = 600
            labelStyle.color = "dim"
            labelStyle = style(w["labelStyle"], over: labelStyle, id: id, scope: s, value: nil)
            var node = textNode(id: "\(id)/0", text: renderText(label, id: id, field: "label", scope: s),
                                style: labelStyle, lines: 1, align: .end)
            node.width = length(w["labelWidth"], id: id, field: "labelWidth", scope: s)
            children.append(node)
        }
        children.append(barNode)
        let textTemplate = w["text"]?.stringValue ?? "{{ $value | round }}%"
        if !textTemplate.isEmpty {
            var textStyle = scope.style
            textStyle.size = 10 * scope.style.scale
            textStyle.font = "mono"
            textStyle.color = "subtle"
            textStyle.weight = 400
            textStyle = style(w["textStyle"], over: textStyle, id: id, scope: s, value: s.vars["value"])
            let content = value == nil ? "–" : renderText(textTemplate, id: id, field: "text", scope: s)
            var node = textNode(id: "\(id)/2", text: content, style: textStyle, lines: 1, align: .start)
            node.width = length(w["textWidth"], id: id, field: "textWidth", scope: s)
            children.append(node)
        }
        return RenderNode(id: id, .stack(.init(axis: .h, gap: number(w["gap"], id: id, field: "gap", scope: s) ?? 4,
                                              align: .center, children: children)))
    }

    private func gauge(_ w: [String: AnyJSON], id: String, scope: Scope) -> RenderNode {
        let value = numeric(w["value"], id: id, field: "value", scope: scope)
        var s = scope
        s.vars["value"] = value.map { .number($0) } ?? .null
        s.style = style(w["style"], over: scope.style, id: id, scope: s, value: s.vars["value"])
        let scope = s
        let min = numeric(w["min"], id: id, field: "min", scope: s) ?? 0
        let max = numeric(w["max"], id: id, field: "max", scope: s) ?? 100
        let fraction = value.map { v in max > min ? Swift.min(Swift.max((v - min) / (max - min), 0), 1) : 0 } ?? 0
        let ringColor = w["color"].flatMap { color($0, id: id, field: "color", scope: s, value: s.vars["value"]) } ?? "accent"
        var textStyle = scope.style
        textStyle.size = 15 * scope.style.scale
        textStyle.weight = 600
        textStyle.font = "mono"
        textStyle.color = "text"
        textStyle = style(w["textStyle"], over: textStyle, id: id, scope: s, value: s.vars["value"])
        let centerText = value == nil ? "–" : renderText(w["text"]?.stringValue ?? "{{ $value | round }}", id: id, field: "text", scope: s)
        let center = textNode(id: "\(id)/0/0", text: centerText, style: textStyle, lines: 1, align: .center)
        let size = (number(w["size"], id: id, field: "size", scope: s) ?? 64) * scope.style.scale
        var ring = RenderNode(id: "\(id)/0", .ring(.init(
            value: fraction,
            sweep: number(w["sweep"], id: id, field: "sweep", scope: s) ?? 270,
            thickness: number(w["thickness"], id: id, field: "thickness", scope: s) ?? 6,
            color: ringColor,
            trackColor: w["trackColor"].flatMap { color($0, id: id, field: "trackColor", scope: s, value: nil) }
                ?? model.palette.hexValue(ringColor).map { RenderPalette.withAlpha($0, 0.15) },
            center: center)))
        ring.width = .points(size)
        ring.height = .points(size)
        var children = [ring]
        if let label = w["label"]?.stringValue {
            var labelStyle = scope.style
            labelStyle.size = 10 * scope.style.scale
            labelStyle.weight = 600
            labelStyle.color = "subtle"
            labelStyle = style(w["labelStyle"], over: labelStyle, id: id, scope: s, value: nil)
            children.append(textNode(id: "\(id)/1", text: renderText(label, id: id, field: "label", scope: s),
                                     style: labelStyle, lines: 1, align: .center))
        }
        return RenderNode(id: id, .stack(.init(axis: .v, gap: 4, align: .center, children: children)))
    }

    private func sparkline(_ w: [String: AnyJSON], id: String, scope: Scope) -> RenderNode {
        var values: [Double] = []
        if case .string(let expression)? = w["values"], let result = eval(expression, id: id, field: "values", scope: scope) {
            values = (result.arrayValue ?? []).compactMap(Self.number)
        } else if w["history"] != nil, case .string(let expression)? = w["value"], let source = scope.source {
            values = data.history(source, ConfigExpansion.sparklineHistoryName(expression)).map(\.value)
        }
        var s = scope
        s.vars["value"] = values.last.map { .number($0) } ?? .null
        var spark = RenderNode.Spark(values: values)
        spark.min = numeric(w["min"], id: id, field: "min", scope: s)
        spark.max = numeric(w["max"], id: id, field: "max", scope: s)
        spark.color = w["color"].flatMap { color($0, id: id, field: "color", scope: s, value: s.vars["value"]) } ?? "accent"
        spark.fill = w["fill"].flatMap { color($0, id: id, field: "fill", scope: s, value: s.vars["value"]) }
        spark.strokeWidth = number(w["strokeWidth"], id: id, field: "strokeWidth", scope: s) ?? 1.5
        spark.dot = bool(w["dot"], id: id, field: "dot", scope: s) ?? false
        var node = RenderNode(id: id, .spark(spark))
        node.width = .fill
        node.height = .points(24 * scope.style.scale)
        return node
    }

    private func keyValue(_ w: [String: AnyJSON], id: String, scope: Scope) -> RenderNode? {
        var children: [RenderNode] = []
        for (index, entry) in (w["items"]?.arrayValue ?? []).enumerated() {
            guard let item = entry.objectValue else { continue }
            let itemId = "\(id)/\(index)"
            var s = scope
            if case .string(let name)? = item["source"] {
                sources.insert(name)
                guard let value = data.data(name) else { continue }
                s.source = name
                s.dot = value
                s.vars["data"] = value
                s.vars["meta"] = data.meta(name) ?? .null
            }
            if case .object(let vars)? = item["vars"] { bindVars(vars, id: itemId, scope: &s) }
            if case .string(let when)? = item["when"] {
                guard let result = eval(when, id: itemId, field: "when", scope: s), result.isTruthy else { continue }
            }
            let content: String
            var value: JQValue?
            if case .string(let text)? = item["text"] {
                content = renderText(text, id: itemId, field: "text", scope: s)
            } else if case .string(let expression)? = item["value"] {
                value = eval(expression, id: itemId, field: "value", scope: s)
                guard let value, value != .null else { continue }
                s.vars["value"] = value
                content = formatted(value, item["format"], id: itemId, scope: s)
            } else {
                continue
            }
            var labelStyle = scope.style
            labelStyle.size = 10 * scope.style.scale
            labelStyle.weight = 600
            labelStyle.color = "subtle"
            labelStyle = style(w["labelStyle"], over: labelStyle, id: id, scope: s, value: nil)
            var valueStyle = scope.style
            valueStyle.size = 14 * scope.style.scale
            valueStyle = style(w["valueStyle"], over: valueStyle, id: id, scope: s, value: value)
            if let color = item["color"] { valueStyle.color = self.color(color, id: itemId, field: "color", scope: s, value: value) ?? valueStyle.color }
            var node = RenderNode(id: itemId, .stack(.init(
                axis: .v, gap: 3, align: align(w["align"], id: id, scope: scope) ?? .center,
                children: [
                    textNode(id: "\(itemId)/0", text: renderText(item["label"]?.stringValue ?? "", id: itemId, field: "label", scope: s),
                             style: labelStyle, lines: nil, align: .start),
                    textNode(id: "\(itemId)/1", text: content, style: valueStyle, lines: nil, align: .start),
                ])))
            bind(item, node: &node, scope: s)
            children.append(node)
        }
        guard !children.isEmpty else { return nil }
        return RenderNode(id: id, .stack(.init(axis: .h, gap: number(w["gap"], id: id, field: "gap", scope: scope) ?? 24,
                                              align: .center, children: children)))
    }

    private func divider(_ w: [String: AnyJSON], id: String, scope: Scope) -> RenderNode {
        let axis: RenderAxis = string(w["axis"], id: id, field: "axis", scope: scope) == "v" ? .v : .h
        var node = RenderNode(id: id, .divider(.init(
            axis: axis,
            thickness: number(w["thickness"], id: id, field: "thickness", scope: scope) ?? 0.5,
            color: w["color"].flatMap { color($0, id: id, field: "color", scope: scope, value: nil) } ?? "dim")))
        if axis == .h { node.width = .fill }
        return node
    }

    private func spacer(_ w: [String: AnyJSON], id: String, scope: Scope, axis: RenderAxis) -> RenderNode {
        var node = RenderNode(id: id, .spacer(.init(min: number(w["min"], id: id, field: "min", scope: scope) ?? 0)))
        // Fixed when sized; else flexible along the parent's axis.
        if w["width"] == nil && w["height"] == nil {
            if axis == .h { node.width = .fill } else { node.height = .fill }
        }
        return node
    }

    // MARK: Common fields

    /// Box fields (§6.1, §10.3). A progress widget's `width` and `height`
    /// size its bar instead.
    private func box(_ w: [String: AnyJSON], into node: inout RenderNode, scope: Scope, sizesBar: Bool) {
        let id = node.id
        if !sizesBar {
            if let width = length(w["width"], id: id, field: "width", scope: scope) { node.width = width }
            if let height = length(w["height"], id: id, field: "height", scope: scope) { node.height = height }
        }
        if let v = number(w["minWidth"], id: id, field: "minWidth", scope: scope) { node.minWidth = v }
        if let v = number(w["maxWidth"], id: id, field: "maxWidth", scope: scope) { node.maxWidth = v }
        if let v = number(w["minHeight"], id: id, field: "minHeight", scope: scope) { node.minHeight = v }
        if let v = number(w["maxHeight"], id: id, field: "maxHeight", scope: scope) { node.maxHeight = v }
        switch literal(w["padding"], id: id, field: "padding", scope: scope) {
        case .array(let items)? where items.count == 4:
            let p = items.map { TextStyle.size($0) ?? 0 }
            node.padding = RenderInsets(top: p[0], right: p[1], bottom: p[2], left: p[3])
        case let value?:
            if let p = TextStyle.size(value) { node.padding = RenderInsets(top: p, right: p, bottom: p, left: p) }
        case nil:
            break
        }
        if let background = w["background"] { node.background = color(background, id: id, field: "background", scope: scope, value: nil) }
        if let v = number(w["radius"], id: id, field: "radius", scope: scope) {
            if case .bar = node.content {} else { node.radius = v }
        }
        if let v = number(w["opacity"], id: id, field: "opacity", scope: scope) { node.opacity = Swift.min(Swift.max(v, 0), 1) }
        if let v = bool(w["clip"], id: id, field: "clip", scope: scope) { node.clip = v }
        if let v = number(w["spaceBefore"], id: id, field: "spaceBefore", scope: scope) { node.spaceBefore = v }
        if let v = string(w["alignSelf"], id: id, field: "alignSelf", scope: scope), let a = RenderAlign(rawValue: v), a != .baseline {
            node.alignSelf = a
        }
        if let v = number(w["span"], id: id, field: "span", scope: scope) { node.span = Swift.max(1, Int(v)) }
        if case .string(let alt)? = w["alt"] { node.alt = renderText(alt, id: id, field: "alt", scope: scope) }
    }

    /// Records the widget's action and key (§9.2, §9.3).
    private func bind(_ w: [String: AnyJSON], node: inout RenderNode, scope: Scope) {
        guard let action = w["action"], action != .null else { return }
        node.action = true
        actions[node.id] = RenderActionBinding(action: action, dot: scope.dot, variables: scope.vars, source: scope.source)
        guard let key = string(w["key"], id: node.id, field: "key", scope: scope), !key.isEmpty else { return }
        let hint: String
        if case .string(let text)? = w["keyHint"] {
            hint = renderText(text, id: node.id, field: "keyHint", scope: scope)
        } else {
            hint = Self.firstText(node) ?? ""
        }
        keys.append(KeyCandidate(key: key == "auto" ? nil : RenderKeyMap.normalize(key), hint: hint, nodeId: node.id))
    }

    static func firstText(_ node: RenderNode) -> String? {
        if case .text(let t) = node.content { return t.text }
        for child in node.children {
            if let text = firstText(child) { return text }
        }
        return nil
    }

    /// Rule 1 of §10.4: a container with a `fill` child on an axis fills on
    /// that axis too, unless its size there is fixed.
    private func propagateFill(_ node: inout RenderNode) {
        switch node.content {
        case .stack, .grid:
            let children = node.children
            if node.width == nil, children.contains(where: { $0.width == .fill }) { node.width = .fill }
            if node.height == nil, children.contains(where: { $0.height == .fill }) { node.height = .fill }
        default:
            break
        }
    }

    // MARK: Styles

    /// `style` (§8.4) over the inherited one. Fields may be `{"expr"}`.
    private func style(_ value: AnyJSON?, over base: TextStyle, id: String, scope: Scope, value current: JQValue?) -> TextStyle {
        guard case .object(let fields)? = value else { return base }
        var style = base
        var s = scope
        if let current { s.vars["value"] = current }
        if let scale = number(fields["scale"], id: id, field: "style.scale", scope: s) { style.scale *= scale }
        if let size = literal(fields["size"], id: id, field: "style.size", scope: s).flatMap(TextStyle.size) {
            style.size = size * style.scale
        }
        if let weight = literal(fields["weight"], id: id, field: "style.weight", scope: s).flatMap(TextStyle.weight) {
            style.weight = weight
        }
        if let font = string(fields["font"], id: id, field: "style.font", scope: s), TextStyle.fonts.contains(font) {
            style.font = font
        }
        if let color = fields["color"].flatMap({ self.color($0, id: id, field: "style.color", scope: s, value: current) }) {
            style.color = color
        }
        if let tracking = number(fields["tracking"], id: id, field: "style.tracking", scope: s) { style.tracking = tracking }
        if let textCase = string(fields["case"], id: id, field: "style.case", scope: s) { style.textCase = textCase }
        switch string(fields["emphasis"], id: id, field: "style.emphasis", scope: s) {
        case "strong"?:
            style.weight = Swift.min(style.weight + 200, 900)
            style.color = "text"
        case "muted"?: style.color = "subtle"
        case "faint"?: style.color = "dim"
        default: break
        }
        return style
    }

    /// `size`, `weight` and `color` given on a text directly (§8.4).
    private func shorthands(_ w: [String: AnyJSON], over base: TextStyle, id: String, scope: Scope, value: JQValue?) -> TextStyle {
        var fields: [String: AnyJSON] = [:]
        for key in WidgetTypes.styleShorthands { if let v = w[key] { fields[key] = v } }
        guard !fields.isEmpty else { return base }
        return style(.object(fields), over: base, id: id, scope: scope, value: value)
    }

    /// A colour field (§8.3): a name, hex, `name@alpha`, `{"steps", "of"}`
    /// or `{"expr"}`. Unknown names are reported and draw as `text`.
    func color(_ value: AnyJSON, id: String, field: String, scope: Scope, value current: JQValue?) -> String? {
        switch value {
        case .string(let text):
            if let resolved = model.palette.resolve(text) { return resolved }
            report(id: id, field: field, severity: "warning", code: "unknown-color", message: "unknown colour \"\(text)\"")
            return "text"
        case .object(let members):
            if case .string(let expression)? = members["expr"] {
                var s = scope
                if let current { s.vars["value"] = current }
                guard let result = eval(expression, id: id, field: field, scope: s), result != .null else { return nil }
                return color(result.anyJSON, id: id, field: field, scope: scope, value: current)
            }
            if case .array(let stops)? = members["steps"] {
                var input: JQValue? = current
                if case .string(let of)? = members["of"] { input = eval(of, id: id, field: field, scope: scope) }
                guard let x = input.flatMap(Self.number) else { return nil }
                // The last stop whose threshold ≤ x, else the first (step()).
                var first: AnyJSON?
                var chosen: AnyJSON?
                for stop in stops {
                    guard case .array(let pair) = stop, pair.count == 2, let threshold = TextStyle.size(pair[0]) else { continue }
                    if first == nil { first = pair[1] }
                    if x >= threshold { chosen = pair[1] }
                }
                return (chosen ?? first).flatMap { color($0, id: id, field: field, scope: scope, value: current) }
            }
            report(id: id, field: field, severity: "warning", code: "unknown-color", message: "not a colour")
            return nil
        default:
            return nil
        }
    }

    // MARK: Values

    /// `{"expr"}` evaluated; anything else as written (§4.1 R3).
    func literal(_ value: AnyJSON?, id: String, field: String, scope: Scope) -> AnyJSON? {
        guard let value else { return nil }
        if case .object(let members) = value, members.count == 1, case .string(let expression)? = members["expr"] {
            return eval(expression, id: id, field: field, scope: scope)?.anyJSON
        }
        return value
    }

    private func number(_ value: AnyJSON?, id: String, field: String, scope: Scope) -> Double? {
        literal(value, id: id, field: field, scope: scope).flatMap(TextStyle.size)
    }

    private func bool(_ value: AnyJSON?, id: String, field: String, scope: Scope) -> Bool? {
        if case .bool(let b)? = literal(value, id: id, field: field, scope: scope) { return b }
        return nil
    }

    private func string(_ value: AnyJSON?, id: String, field: String, scope: Scope) -> String? {
        literal(value, id: id, field: field, scope: scope)?.stringValue
    }

    /// An expr-or-literal number field (`value`, `min`, `max`, `overlay`).
    private func numeric(_ value: AnyJSON?, id: String, field: String, scope: Scope) -> Double? {
        switch value {
        case .string(let expression)?:
            return eval(expression, id: id, field: field, scope: scope).flatMap(Self.number)
        case let other?:
            return literal(other, id: id, field: field, scope: scope).flatMap(TextStyle.size)
        case nil:
            return nil
        }
    }

    private func length(_ value: AnyJSON?, id: String, field: String, scope: Scope) -> RenderLength? {
        switch literal(value, id: id, field: field, scope: scope) {
        case .string("fill")?: return .fill
        case .string("fit")?, nil: return nil
        case let other?: return TextStyle.size(other).map { .points($0) }
        }
    }

    private func align(_ value: AnyJSON?, id: String, scope: Scope) -> RenderAlign? {
        string(value, id: id, field: "align", scope: scope).flatMap(RenderAlign.init(rawValue:))
    }

    static func number(_ value: JQValue) -> Double? {
        switch value {
        case .number(let d): return d.isFinite ? d : nil
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        default: return nil
        }
    }

    /// `format` (§6.3): a name for one of the vestal functions.
    func formatted(_ value: JQValue, _ format: AnyJSON?, id: String, scope: Scope) -> String {
        guard let name = literal(format, id: id, field: "format", scope: scope)?.stringValue, !name.isEmpty else {
            return TextTemplate.stringify(value)
        }
        guard let expression = Self.formatExpression(name) else {
            report(id: id, field: "format", severity: "warning", code: "invalid-value", message: "unknown format \"\(name)\"")
            return TextTemplate.stringify(value)
        }
        var s = scope
        s.dot = value
        return TextTemplate.stringify(eval(expression, id: id, field: "format", scope: s))
    }

    static func formatExpression(_ name: String) -> String? {
        let simple = [
            "int": "fmt_int", "number": "fmt_number", "percent": "fmt_percent", "thousands": "fmt_thousands",
            "compact": "fmt_compact", "bytes": "fmt_bytes", "rate": "fmt_rate", "duration": "fmt_duration",
            "uptime": "fmt_uptime", "relative": "fmt_relative", "startsIn": "starts_in",
            "integer": "fmt_legacy(\"int\")", "decimal": "fmt_legacy(\"decimal\")",
        ]
        if let fn = simple[name] { return fn }
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let argument = parts[1]
        func quoted(_ s: String) -> String { AnyJSON.string(s).canonicalText() }
        switch parts[0] {
        case "fixed": return Int(argument).map { "fmt_fixed(\($0))" }
        case "percent": return Int(argument).map { "fmt_percent(\($0))" }
        case "thousands": return Int(argument).map { "fmt_thousands(\($0))" }
        case "duration": return Int(argument).map { "fmt_duration(\($0))" }
        case "time": return "fmt_time(\(quoted(argument)))"
        case "localized": return "fmt_localized(\(quoted(argument)))"
        default: return nil
        }
    }

    // MARK: Expressions

    /// `vars` in dependency order (a var may use the ones it names).
    private func bindVars(_ vars: [String: AnyJSON], id: String, scope: inout Scope) {
        var pending = vars.keys.sorted()
        var dependencies: [String: Set<String>] = [:]
        for name in pending {
            if case .string(let expression)? = vars[name], case .success(let compiled) = model.environment.compile(expression) {
                dependencies[name] = compiled.references.variableNames.intersection(vars.keys).subtracting([name])
            }
        }
        var bound = Set<String>()
        while !pending.isEmpty {
            let ready = pending.first { (dependencies[$0] ?? []).isSubset(of: bound) } ?? pending[0]
            pending.removeAll { $0 == ready }
            switch vars[ready] {
            case .string(let expression)?:
                scope.vars[ready] = eval(expression, id: id, field: "vars.\(ready)", scope: scope) ?? .null
            case let other?:
                scope.vars[ready] = JQValue(literal(other, id: id, field: "vars.\(ready)", scope: scope) ?? .null)
            case nil:
                break
            }
            bound.insert(ready)
        }
    }

    /// A text field: literal runs and `{{ }}` holes (§4.1 R2).
    func renderText(_ text: String, id: String, field: String, scope: Scope) -> String {
        guard TextTemplate.hasHoles(text) else { return text }
        switch model.template(text) {
        case .failure(let error):
            report(id: id, field: field, severity: "error", code: error.code, message: error.message)
            return text
        case .success(let template):
            var out = ""
            for part in template.parts {
                switch part {
                case .literal(let literal): out += literal
                case .hole(let expression, _): out += TextTemplate.stringify(eval(expression, id: id, field: field, scope: scope))
                }
            }
            return out
        }
    }

    /// The first output of `expression`; nil for none or an error (reported).
    func eval(_ expression: String, id: String, field: String, scope: Scope) -> JQValue? {
        guard let outputs = run(expression, id: id, field: field, scope: scope, all: false) else { return nil }
        return outputs.first
    }

    func evalAll(_ expression: String, id: String, field: String, scope: Scope) -> [JQValue]? {
        run(expression, id: id, field: field, scope: scope, all: true)
    }

    private func run(_ expression: String, id: String, field: String, scope: Scope, all: Bool) -> [JQValue]? {
        let compiled: JQExpression
        switch model.environment.compile(expression) {
        case .failure(let error):
            report(id: id, field: field, severity: "error", code: error.code,
                   message: error.message + (error.suggestion.map { "; did you mean '\($0)'?" } ?? ""))
            return nil
        case .success(let c):
            compiled = c
        }
        for use in compiled.references.variables where use.name == "sources" || use.name == "history" {
            sources.insert(use.path.first ?? "*")
        }
        let context = JQEvalContext(now: now, timeZone: timeZone, userInfo: [
            VestalFunctions.dataKey: data,
            VestalFunctions.localeKey: locale,
            VestalFunctions.paletteKey: model.palette.colors,
        ])
        let result: Result<[JQValue], ExprError>
        if all {
            result = model.environment.run(compiled, input: scope.dot, variables: scope.vars, context: context)
        } else {
            result = model.environment.first(compiled, input: scope.dot, variables: scope.vars, context: context).map { $0.map { [$0] } ?? [] }
        }
        if context.nowWasCalled { usesNow = true }
        switch result {
        case .success(let outputs):
            return outputs
        case .failure(let error):
            report(id: id, field: field, severity: "error", code: error.code, message: error.message)
            return nil
        }
    }

    // MARK: Diagnostics

    private func report(id: String?, field: String?, severity: String, code: String, message: String) {
        let key = "\(id ?? "")|\(field ?? "")|\(code)|\(message)"
        guard diagnosticKeys.insert(key).inserted else { return }
        diagnostics.append(RenderDiagnostic(id: id, field: field, severity: severity, code: code, message: message))
    }

    /// An id segment: `/`, `@`, `%`, `=` and `~` percent-encoded (§10.5).
    static func encode(_ segment: String) -> String {
        var out = ""
        for scalar in segment.unicodeScalars {
            switch scalar {
            case "/", "@", "%", "=", "~":
                out += String(format: "%%%02X", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
