import Foundation

// MARK: - vestal explain (EXTENSIBILITY.md §11.8)
//
//   vestal explain <node id or widget key> [--view <name>] [--json] [--config <path>]
//                  [--cached|--fetch|--data <dir>] [--at <time>]
//
// Everything about one widget, for "why is my widget missing or wrong": its
// template chain, source (name and `$meta`), `input`, each `vars` value, the
// `when` result, the widget as written (expanded) and as rendered, its
// dependencies (sources, `now`), its key and action, and its diagnostics.
// A node id inside a widget (a list row, say) adds that node and its
// action's scope.

extension RenderCommands {
    public static func explain(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        platform: SourcePlatform,
        client: Client,
        cache: SnapshotCache = SnapshotCache()
    ) -> Output {
        var target: String?
        var rest: [String] = []
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if ["--view", "--config", "--data", "--at", "--timeout"].contains(argument) {
                rest.append(argument)
                if let value = iterator.next() { rest.append(value) }
            } else if argument.hasPrefix("-") && argument != "-" {
                rest.append(argument)
            } else if target == nil {
                target = argument
            } else {
                rest.append(argument)
            }
        }
        guard let target else {
            return Output(status: 2, stderr: "vestal: give a widget key or a node id\n"
                + "usage: vestal explain <node id or widget key> [--view <name>] [--json] [--config <path>] "
                + "[--cached|--fetch|--data <dir>] [--at <time>]\n")
        }
        let options: Options
        switch parse(rest) {
        case .failure(let error): return Output(status: 2, stderr: "vestal: \(error.description)\n")
        case .success(let parsed): options = parsed
        }
        guard let loaded = SourceCommands.load(options.configPath, environment: environment, home: home) else {
            return Output(status: 1, stderr: "vestal: can't read \(options.configPath ?? "-")\n")
        }
        let model = RenderConfigModel(loaded: loaded)
        let session = RenderSession(model: model, view: options.view)
        let view = session.view
        let now = options.at ?? Date()
        let draft = options.configPath != nil
            && !SourceCommands.isRunningConfig(options.configPath, environment: environment, home: home, client: client)
        let data = RenderSources.load(
            model: model, view: view, mode: options.mode, platform: platform, cache: cache,
            allowCommands: !draft || options.allowCommands, allowNetwork: !options.noNetwork,
            timeout: options.timeout, now: now, secrets: loaded.config.secrets, environment: environment, home: home)
        let snapshot = session.render(data: data, now: now)

        // The root widget the target belongs to.
        let spec = model.views[view] ?? ViewSpec(name: view, json: [:], density: model.density)
        let id: String
        if model.widgets[target] != nil {
            id = "\(view)/\(RenderPass.encode(target))"
        } else {
            id = target
        }
        var rootIndex: Int?
        var rootKey: String?
        for (index, entry) in spec.children.enumerated() {
            let rootId: String
            switch entry {
            case .string(let key): rootId = "\(view)/\(RenderPass.encode(key))"
            case .object(let o): rootId = o["id"]?.stringValue.map { "\(view)/\(RenderPass.encode($0))" } ?? "\(view)/\(index)"
            default: continue
            }
            if id == rootId || id.hasPrefix(rootId + "/") {
                rootIndex = index
                if case .string(let key) = entry { rootKey = key }
                break
            }
        }
        let node = snapshot.root.node(withId: id) ?? snapshot.popup?.node.node(withId: id)
        guard rootIndex != nil || node != nil || model.widgets[target] != nil else {
            let candidates = Array(model.widgets.keys)
            let close = DidYouMean.suggestions(for: target, among: candidates)
            return Output(status: 4, stderr: "vestal: no widget or node \"\(target)\" in view \"\(view)\""
                + (close.isEmpty ? "" : "; did you mean \(close.map { "\"\($0)\"" }.joined(separator: " or "))?") + "\n")
        }

        var report: [String: AnyJSON] = ["id": .string(id), "view": .string(view), "shown": .bool(node != nil)]
        let pass = RenderPass(model: model, data: data, now: now, view: view)
        let widgetKey = model.widgets[target] != nil ? target : rootKey
        if let widgetKey, let widget = model.widgets[widgetKey]?.objectValue {
            report["widget"] = .string(widgetKey)
            report["templates"] = widget["$template"] ?? .array([])
            report["written"] = .object(widget.filter { $0.key != "$params" && $0.key != "$template" && $0.key != "$widget" })
            if let params = widget["$params"] { report["params"] = params }
            report["trace"] = .object(pass.trace(widget, widgetKey: widgetKey))
        }
        if let rootIndex {
            let child = pass.renderRootChild(spec.children[rootIndex], index: rootIndex)
            report["dependencies"] = .object([
                "sources": .array(child.sources.sorted().map(AnyJSON.string)),
                "now": .bool(child.usesNow),
            ])
        }
        if let node, let data = try? RenderJSON.encoder.encode(node), let json = AnyJSON.decode(data) {
            report["resolved"] = json
        }
        if let binding = session.actions[id] {
            var action: [String: AnyJSON] = ["action": binding.action, ".": binding.dot.anyJSON]
            if let source = binding.source { action["source"] = .string(source) }
            report["action"] = .object(action)
        }
        if let key = session.widgetKeys.first(where: { $0.value == id })?.key { report["key"] = .string(key) }
        let diagnostics = snapshot.diagnostics.filter { d in
            guard let did = d.id else { return false }
            return did == id || did.hasPrefix(id + "/")
        }
        report["diagnostics"] = .array(diagnostics.map { d in
            var o: [String: AnyJSON] = ["severity": .string(d.severity), "code": .string(d.code), "message": .string(d.message)]
            if let id = d.id { o["id"] = .string(id) }
            if let field = d.field { o["field"] = .string(field) }
            return .object(o)
        })
        if options.json {
            return Output(status: 0, stdout: AnyJSON.object(report).prettyPrinted() + "\n")
        }
        return Output(status: 0, stdout: explainText(report))
    }

    static func explainText(_ report: [String: AnyJSON]) -> String {
        var out = ""
        func line(_ label: String, _ value: AnyJSON?) {
            guard let value else { return }
            let text: String
            if case .string(let s) = value { text = s } else { text = value.canonicalText() }
            out += label.padding(toLength: 14, withPad: " ", startingAt: 0) + text + "\n"
        }
        line("id", report["id"])
        line("widget", report["widget"])
        line("shown", report["shown"])
        line("templates", report["templates"])
        if case .object(let trace)? = report["trace"] {
            line("source", trace["source"])
            line("meta", trace["meta"])
            line("input", trace["input"])
            if case .object(let vars)? = trace["vars"] {
                for name in vars.keys.sorted() { line("vars.\(name)", vars[name]) }
            }
            line("when", trace["when"])
            line("stopped at", trace["stoppedAt"])
        }
        line("params", report["params"])
        line("depends on", report["dependencies"])
        line("key", report["key"])
        line("action", report["action"])
        if case .array(let diagnostics)? = report["diagnostics"] {
            out += "diagnostics   \(diagnostics.count)\n"
            for d in diagnostics {
                let o = d.objectValue ?? [:]
                out += "  \(o["severity"]?.stringValue ?? "") \(o["code"]?.stringValue ?? "")"
                    + " [\(o["id"]?.stringValue ?? "")] \(o["field"]?.stringValue ?? ""): \(o["message"]?.stringValue ?? "")\n"
            }
        }
        if let resolved = report["resolved"] { out += "resolved\n" + resolved.prettyPrinted() + "\n" }
        if let written = report["written"] { out += "written\n" + written.prettyPrinted() + "\n" }
        return out
    }
}

extension RenderPass {
    /// A root widget's evaluation steps (source → input → vars → when), for
    /// `vestal explain`.
    func trace(_ w: [String: AnyJSON], widgetKey: String) -> [String: AnyJSON] {
        var out: [String: AnyJSON] = [:]
        var scope = baseScope()
        scope.vars["widget"] = .string(widgetKey)
        if case .object(let params)? = w["$params"] {
            scope.vars["params"] = JQValue(AnyJSON.object(params))
            for (name, value) in params { scope.vars[name] = JQValue(value) }
        }
        let id = "\(view)/\(RenderPass.encode(widgetKey))"
        if case .string(let name)? = w["source"] {
            out["source"] = .string(name)
            out["meta"] = data.meta(name)?.anyJSON ?? .null
            let value = data.data(name)
            scope.dot = value ?? .null
            scope.vars["data"] = value ?? .null
            scope.vars["meta"] = data.meta(name) ?? .null
            if value == nil && w["loading"]?.stringValue != "show" && w["loading"]?.objectValue == nil {
                out["stoppedAt"] = .string("source \"\(name)\" has no data yet (loading: hide)")
                return out
            }
        }
        if case .string(let input)? = w["input"] {
            scope.dot = eval(input, id: id, field: "input", scope: scope) ?? .null
            out["input"] = scope.dot.anyJSON
        }
        if case .object(let vars)? = w["vars"] {
            var values: [String: AnyJSON] = [:]
            for name in vars.keys.sorted() {
                if case .string(let expression)? = vars[name] {
                    let value = eval(expression, id: id, field: "vars.\(name)", scope: scope) ?? .null
                    scope.vars[name] = value
                    values[name] = value.anyJSON
                }
            }
            out["vars"] = .object(values)
        }
        if case .string(let when)? = w["when"] {
            let result = eval(when, id: id, field: "when", scope: scope)
            out["when"] = result?.anyJSON ?? .null
            if !(result?.isTruthy ?? false) { out["stoppedAt"] = .string("when is \(result?.jsonText() ?? "null")") }
        }
        return out
    }
}
