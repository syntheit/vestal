import Foundation

// MARK: - Keys

public enum RenderKeyMap {
    /// Bound by the core; a config may not bind them.
    public static let reserved: Set<String> = ["escape", "alt+i"]
    /// `auto` never assigns these (v0.3: p is privacy, i is info).
    static let autoReserved: Set<Character> = ["i", "p"]

    static let modifierOrder = ["cmd", "ctrl", "alt", "shift"]
    static let modifierAliases = ["super": "cmd", "command": "cmd", "control": "ctrl", "opt": "alt", "option": "alt"]
    static let keyAliases = ["esc": "escape", "return": "enter", "spacebar": "space"]

    /// A key in the form the UIs send: lowercase, modifiers first in the
    /// order cmd, ctrl, alt, shift (`shift+tab`, `cmd+r`, `h`).
    public static func normalize(_ key: String) -> String {
        let parts = key.lowercased().split(separator: "+", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        guard let last = parts.last, !last.isEmpty else { return key.lowercased() }
        let modifiers = Set(parts.dropLast().map { modifierAliases[$0] ?? $0 })
        let ordered = modifierOrder.filter { modifiers.contains($0) }
        return (ordered + [keyAliases[last] ?? last]).joined(separator: "+")
    }

    /// Widget keys: explicit ones first (the first binding of a key wins),
    /// then `auto` ones in tree order, each taking the first letter of its
    /// hint that is free, never i or p. Returns key → node id.
    static func assign(_ candidates: [KeyCandidate], taken: Set<String> = []) -> [String: String] {
        var map: [String: String] = [:]
        for candidate in candidates {
            guard let key = candidate.key, !reserved.contains(key), map[key] == nil else { continue }
            map[key] = candidate.nodeId
        }
        for candidate in candidates where candidate.key == nil {
            for ch in candidate.hint.lowercased() where ch.isLetter && ch.isASCII && !autoReserved.contains(ch) {
                let key = String(ch)
                if map[key] == nil && !taken.contains(key) {
                    map[key] = candidate.nodeId
                    break
                }
            }
        }
        return map
    }
}

// MARK: - Diff

public enum RenderDiff {
    /// `replace` ops that turn `old` into `new`: top-down, a node whose own
    /// fields or ordered child ids differ is replaced whole. Nil when the
    /// roots themselves differ (send a `root` op).
    public static func ops(from old: RenderNode, to new: RenderNode) -> [RenderPatchOp]? {
        guard old.id == new.id else { return nil }
        var ops: [RenderPatchOp] = []
        diff(old, new, into: &ops)
        return ops
    }

    private static func diff(_ old: RenderNode, _ new: RenderNode, into ops: inout [RenderPatchOp]) {
        guard old != new else { return }
        if !sameOwnFields(old, new) || old.children.map(\.id) != new.children.map(\.id) {
            ops.append(.replace(id: new.id, node: new))
            return
        }
        for (a, b) in zip(old.children, new.children) { diff(a, b, into: &ops) }
    }

    /// Everything but `children` and a ring's `center`.
    static func sameOwnFields(_ a: RenderNode, _ b: RenderNode) -> Bool {
        var x = a, y = b
        x.children = x.children.map { RenderNode(id: $0.id, .spacer(.init())) }
        y.children = y.children.map { RenderNode(id: $0.id, .spacer(.init())) }
        return x == y
    }
}

// MARK: - A rendering session

/// Renders one config's views, keeping each root child's result so a change
/// re-evaluates only the root children that read it, and the `now` tick
/// only those that call `now`. The live engine and `vestal render`
/// both use it. Not thread-safe.
public final class RenderSession {
    public let model: RenderConfigModel
    public private(set) var view: String
    public var timeZone: TimeZone = .current
    public var locale: Locale = .current
    public var os: String = RenderPass.currentOS

    /// The open popup: its widget (expanded, `{"expr"}` values filled) and width.
    public private(set) var popup: (widget: [String: AnyJSON], width: Double)?

    private var children: [RenderedChild] = []
    private var popupChild: RenderedChild?
    private var renderedView: String?
    /// Key → node id of the last render (widget keys, popup first).
    public private(set) var widgetKeys: [String: String] = [:]
    public private(set) var actions: [String: RenderActionBinding] = [:]

    public init(model: RenderConfigModel, view: String? = nil) {
        self.model = model
        self.view = view.flatMap { model.views[$0] != nil ? $0 : nil } ?? model.defaultView
    }

    /// +1 or -1 when the last change of view went to a later or earlier
    /// page; nil when it had no direction. Reported in the snapshot's
    /// `pages` so a UI knows which way to slide.
    public private(set) var pageDirection: Int?

    /// Switches to `name`. The direction of the change is `direction`, else
    /// taken from where the two views sit in the paging order.
    public func setView(_ name: String, direction: Int? = nil) {
        guard model.views[name] != nil else { return }
        if name != view {
            if let direction {
                pageDirection = direction
            } else if let from = model.pageOrder.firstIndex(of: view), let to = model.pageOrder.firstIndex(of: name) {
                pageDirection = to > from ? 1 : -1
            } else {
                pageDirection = nil
            }
        }
        view = name
    }

    /// Whether the open popup is the built-in info popup (`alt+i`).
    public internal(set) var infoOpen = false

    /// Opens `widget` as the popup, `width` points wide before `theme.scale`
    /// (a fixed size).
    public func openPopup(_ widget: [String: AnyJSON], width: Double) {
        popup = (widget, width * model.scale)
        popupChild = nil
        infoOpen = false
    }

    public func closePopup() {
        popup = nil
        popupChild = nil
        infoOpen = false
    }

    /// The model now. `changed` names the sources whose data changed since
    /// the last render (nil: everything, as on show); `tick` re-evaluates
    /// what calls `now`.
    public func render(data: RenderData, now: Date, changed: Set<String>? = nil, tick: Bool = false) -> RenderSnapshot {
        let pass = RenderPass(model: model, data: data, now: now, view: view, timeZone: timeZone, locale: locale, os: os)
        let spec = model.views[view] ?? ViewSpec(name: view, json: [:], density: model.density)
        let full = changed == nil || renderedView != view || children.count != spec.children.count
        let axis: RenderAxis = spec.layout == "row" ? .h : .v
        if full {
            children = spec.children.enumerated().map { pass.renderRootChild($1, index: $0, axis: axis) }
        } else {
            for (index, entry) in spec.children.enumerated()
            where children[index].dependsOn(changed ?? []) || (tick && children[index].usesNow) {
                children[index] = pass.renderRootChild(entry, index: index, axis: axis)
            }
        }
        renderedView = view
        if let popup {
            if full || popupChild == nil || popupChild!.dependsOn(changed ?? []) || (tick && popupChild!.usesNow) {
                popupChild = pass.renderPopup(popup.widget)
            }
        }
        let root = pass.root(spec, children: children)

        // Keys and actions: popup first (popup keys first), then the view.
        var candidates: [KeyCandidate] = []
        var bindings: [String: RenderActionBinding] = [:]
        if let popupChild {
            candidates += popupChild.keys
            bindings.merge(popupChild.actions) { a, _ in a }
        }
        for child in children {
            candidates += child.keys
            bindings.merge(child.actions) { a, _ in a }
        }
        widgetKeys = RenderKeyMap.assign(candidates)
        actions = bindings

        var diagnostics: [RenderDiagnostic] = []
        for problem in model.palette.problems {
            diagnostics.append(RenderDiagnostic(severity: "warning", code: "unknown-color", message: problem))
        }
        for (source, problem) in data.problems.sorted(by: { $0.key < $1.key }) {
            diagnostics.append(RenderDiagnostic(id: nil, field: source, severity: "error", code: "expr-runtime",
                                                message: "source \(source): \(problem)"))
        }
        for child in children { diagnostics += child.diagnostics }
        if let popupChild { diagnostics += popupChild.diagnostics }

        let renderedPopup = popup.flatMap { state in
            popupChild?.node.map { RenderPopup(width: state.width, node: $0) }
        }
        return RenderSnapshot(seq: 1, view: view, views: model.viewInfos,
                              pages: model.renderPages(view: view, direction: pageDirection),
                              visible: true, theme: model.theme, root: root, popup: renderedPopup, diagnostics: diagnostics)
    }

    /// Every source any root child or the popup read in the last render.
    public var sourcesRead: Set<String> {
        var all = Set<String>()
        for child in children { all.formUnion(child.sources) }
        if let popupChild { all.formUnion(popupChild.sources) }
        return all
    }

    /// Whether anything rendered calls `now` (the 1 s tick is needed).
    public var usesNow: Bool {
        children.contains(where: \.usesNow) || popupChild?.usesNow == true
    }
}
