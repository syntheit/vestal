import Foundation

// MARK: - Actions and keys (EXTENSIBILITY.md §9.2, §9.3)
//
// A click (`invoke`) or a key resolves to a widget's action, evaluated in
// the scope the widget was written in (so `.` is the row's item). The
// session carries out what only changes the model (`popup`, `close`,
// `view`); everything else comes back as effects for the host to run
// (`run`, `open`, `copy`, `refresh`, `media`, `audio`, `hide`). `vestal
// render --press` runs only the model's part: rendering never runs a
// command.

public enum RenderActionEffect: Equatable, Sendable {
    /// Run an argv without a shell (`~` expanded), then refresh `refreshAfter`
    /// (nil: the widget's source). `optimistic` replaces the source's data
    /// until the next fetch.
    case run(argv: [String], env: [String: String], timeout: TimeInterval?, refreshAfter: [String],
             optimistic: AnyJSON?, source: String?)
    case open(String)
    case copy(String)
    /// Fetch these sources now (`*`: all).
    case refresh([String])
    /// `playPause`, `next` or `previous` on a media source.
    case media(String, source: String?)
    /// `toggleMute`, `volumeUp` or `volumeDown`.
    case audio(String)
    case hide
    /// The popup opened, closed, or the view changed: re-render.
    case changed
}

extension RenderSession {
    /// What a click on node `id` does.
    public func invoke(_ id: String, data: RenderData, now: Date) -> [RenderActionEffect] {
        guard let binding = actions[id] else { return [] }
        return perform(binding, data: data, now: now)
    }

    /// What key `key` does (§9.2 precedence): widget keys (the popup's
    /// first), the view's `keys`, global `keys` and view shorthands, then
    /// `tab` cycling. `escape` closes the popup, else hides.
    public func key(_ key: String, data: RenderData, now: Date) -> [RenderActionEffect] {
        let key = RenderKeyMap.normalize(key)
        if key == "escape" {
            if popup != nil {
                closePopup()
                return [.changed]
            }
            return [.hide]
        }
        if let id = widgetKeys[key], let binding = actions[id] {
            return perform(binding, data: data, now: now)
        }
        let base = RenderActionBinding(action: .null, dot: .null, variables: [:], source: nil)
        if let action = model.views[view]?.keys.first(where: { RenderKeyMap.normalize($0.key) == key })?.value {
            return perform(RenderActionBinding(action: action, dot: .null, variables: base.variables, source: nil),
                           data: data, now: now)
        }
        if let action = model.keys.first(where: { RenderKeyMap.normalize($0.key) == key })?.value {
            return perform(RenderActionBinding(action: action, dot: .null, variables: [:], source: nil), data: data, now: now)
        }
        if let target = model.viewInfos.first(where: { $0.key.map(RenderKeyMap.normalize) == key })?.name {
            return perform(RenderActionBinding(action: .object(["view": .string(target)]), dot: .null, variables: [:], source: nil),
                           data: data, now: now)
        }
        let order = model.cycleOrder
        if key == "tab" || key == "shift+tab", order.count > 1, let index = order.firstIndex(of: view) {
            let step = key == "tab" ? 1 : order.count - 1
            setView(order[(index + step) % order.count])
            closePopup()
            return [.changed]
        }
        return []
    }

    /// An action or a list of them, in order.
    func perform(_ binding: RenderActionBinding, data: RenderData, now: Date) -> [RenderActionEffect] {
        let pass = RenderPass(model: model, data: data, now: now, view: view, timeZone: timeZone, locale: locale, os: os)
        var scope = pass.baseScope()
        scope.dot = binding.dot
        scope.vars.merge(binding.variables) { _, new in new }
        scope.source = binding.source
        let list: [AnyJSON]
        switch binding.action {
        case .array(let items): list = items
        case .null: list = []
        default: list = [binding.action]
        }
        var effects: [RenderActionEffect] = []
        for action in list {
            guard case .object(let members) = action else { continue }
            effects += perform(members, pass: pass, scope: scope)
        }
        return effects
    }

    private func perform(_ members: [String: AnyJSON], pass: RenderPass, scope: RenderPass.Scope) -> [RenderActionEffect] {
        func text(_ value: AnyJSON?) -> String? {
            guard case .string(let t)? = value else { return nil }
            return pass.renderText(t, id: "action", field: "action", scope: scope)
        }
        var effects: [RenderActionEffect] = []
        var hides = false
        if case .object(let widget)? = members["popup"] {
            openPopup(expandPopup(widget, pass: pass, scope: scope),
                      width: TextStyle.size(members["width"]) ?? 520)
            effects.append(.changed)
        } else if members["close"] != nil {
            closePopup()
            effects.append(.changed)
        } else if let name = text(members["view"]) {
            if model.views[name] != nil {
                setView(name)
                closePopup()
                effects.append(.changed)
            }
        } else if case .array(let argv)? = members["run"] {
            let resolved = argv.compactMap { text($0) }
            var env: [String: String] = [:]
            for (key, value) in members["env"]?.objectValue ?? [:] { env[key] = text(value) ?? "" }
            var refreshAfter: [String] = scope.source.map { [$0] } ?? []
            switch members["refreshAfter"] {
            case .bool(false)?: refreshAfter = []
            case .array(let names)?: refreshAfter = names.compactMap(\.stringValue)
            case .string(let name)?: refreshAfter = [name]
            default: break
            }
            var optimistic: AnyJSON?
            if case .string(let expression)? = members["optimistic"] {
                optimistic = pass.eval(expression, id: "action", field: "optimistic", scope: scope)?.anyJSON
            }
            effects.append(.run(argv: resolved, env: env,
                                timeout: members["timeout"]?.stringValue.flatMap(ConfigDuration.seconds),
                                refreshAfter: refreshAfter, optimistic: optimistic, source: scope.source))
        } else if let url = text(members["open"]) {
            effects.append(.open(url))
            hides = true
        } else if let copied = text(members["copy"]) {
            effects.append(.copy(copied))
        } else if let refresh = members["refresh"] {
            switch refresh {
            case .bool(true): effects.append(.refresh(scope.source.map { [$0] } ?? []))
            case .string(let name): effects.append(.refresh([name]))
            case .array(let names): effects.append(.refresh(names.compactMap(\.stringValue)))
            default: break
            }
        } else if let command = members["media"]?.stringValue {
            effects.append(.media(command, source: members["source"]?.stringValue ?? scope.source))
        } else if let command = members["audio"]?.stringValue {
            effects.append(.audio(command))
        } else if members["hide"] == .bool(true) && members.count == 1 {
            return [.hide]
        }
        if case .bool(let explicit)? = members["hide"] { hides = explicit }
        if hides { effects.append(.hide) }
        return effects
    }

    /// A popup's widget at click time: its `{"expr"}` values evaluated in the
    /// clicked widget's scope, its text-valued parameters too, then
    /// templates expanded (§9.3).
    private func expandPopup(_ widget: [String: AnyJSON], pass: RenderPass, scope: RenderPass.Scope) -> [String: AnyJSON] {
        var resolved: [String: AnyJSON] = [:]
        let template = widget["type"]?.stringValue.flatMap { model.expanded.registry.lookup($0) }
        for (key, value) in widget {
            if case .object(let members) = value, members.count == 1, case .string(let expression)? = members["expr"] {
                resolved[key] = pass.eval(expression, id: "popup", field: key, scope: scope)?.anyJSON ?? .null
            } else if case .string(let text) = value, let param = template?.params[key], param.isData,
                      TextTemplate.hasHoles(text) {
                resolved[key] = .string(pass.renderText(text, id: "popup", field: key, scope: scope))
            } else {
                resolved[key] = value
            }
        }
        var expander = Expander(registry: model.expanded.registry, raw: model.widgets)
        let expanded = expander.widget(.object(resolved), path: "popup", depth: 0, chain: [])
        return ConfigExpansion.extractInlineSources(.object(["widgets": .object(["popup": expanded])]))
            .objectValue?["widgets"]?.objectValue?["popup"]?.objectValue ?? [:]
    }
}
