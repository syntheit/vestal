#if os(macOS)
import AppKit
import SwiftUI
import VestalCore

// MARK: - Render store
//
// The render model as SwiftUI observes it: one `NodeHandle` per node, in a
// tree that mirrors the model's, and an index from node id to handle. A
// snapshot rebuilds the tree; a patch's `replace` finds the handle by id and
// swaps its fields and children in place, so only that node's view (and the
// new views under it) is drawn again; ancestors and siblings are untouched.
// `root`, `popup` and `theme` ops publish only what they name. The GTK UI
// (VestalLinux/Dashboard.swift) applies patches with the same rules.
//
// The engine or `vestal render-file` feeds it on the main actor:
//
//   let store = RenderStore { input in … }  clicks and keys come back here
//   store.apply(snapshot)                   a whole model
//   store.apply(patch)                      ops in order; false: resync
//   RenderStageView(store: store)           draws it

/// One node on screen. Its view observes it; a `replace` of its id updates
/// it in place.
@MainActor
final class NodeHandle: ObservableObject, Identifiable {
    private static var serials = 0

    /// Stable for the life of the handle, for ForEach.
    let id: Int
    /// Bumped before every change, which publishes it to the node's view.
    @Published private var revision = 0
    /// The node's own fields. Views draw children from `children`, never
    /// from `node.children`, which is not kept current.
    private(set) var node: RenderNode
    private(set) var children: [NodeHandle]
    private(set) var spec: NodeSpec
    weak var parent: NodeHandle?

    init(node: RenderNode, children: [NodeHandle]) {
        Self.serials += 1
        id = Self.serials
        self.node = node
        self.children = children
        spec = NodeSpec(node, hasBaseline: Self.hasBaseline(node, children))
        for child in children { child.parent = self }
    }

    /// New fields and children (a `replace`), published once.
    func update(node: RenderNode, children: [NodeHandle]) {
        revision += 1
        self.node = node
        self.children = children
        spec = NodeSpec(node, hasBaseline: Self.hasBaseline(node, children))
        for child in children { child.parent = self }
    }

    /// Recomputes `hasBaseline` after a descendant changed; true when it
    /// changed (and was published).
    func refreshBaseline() -> Bool {
        let has = Self.hasBaseline(node, children)
        guard has != spec.hasBaseline else { return false }
        revision += 1
        spec.hasBaseline = has
        return true
    }

    /// A text has a first baseline, and so does a stack or grid holding
    /// one (layout rule 6); rings and drawings don't.
    private static func hasBaseline(_ node: RenderNode, _ children: [NodeHandle]) -> Bool {
        switch node.content {
        case .text, .unknown: return true
        case .stack, .grid: return children.contains { $0.spec.hasBaseline }
        default: return false
        }
    }
}

/// The popup being shown: its card width and its tree.
@MainActor
struct PopupState {
    var id: String
    var width: Double
    var handle: NodeHandle
}

@MainActor
public final class RenderStore: ObservableObject {
    /// The last model applied, with patches.
    public private(set) var snapshot: RenderSnapshot?
    @Published private(set) var root: NodeHandle?
    @Published private(set) var popup: PopupState?
    @Published private(set) var style = RenderStyle.default
    /// The theme for the library background, which follows data that
    /// `style` does not (see `setTheme`).
    @Published private(set) var background = RenderStyle.default.theme
    /// The pages and the current one (two or more), for the dots.
    @Published private(set) var pages: RenderPages?
    /// A change of page being drawn: the old page leaving while the new one
    /// comes in. Nil at rest.
    @Published private(set) var pageChange: PageChange?
    /// How far the current page is dragged by a swipe, in points.
    @Published var dragOffset: Double = 0
    /// The stage's width, for sliding pages by a screen (set by the stage).
    var stageWidth = 0.0
    /// 0 when a change of page begins, animated to 1 (`runChange`).
    @Published private(set) var pageProgress: Double = 1
    /// Whether changes of view are animated: the app turns it on while the
    /// dashboard is on screen, so the view a show opens on just appears.
    var pagesLive = false
    private var changeSerial = 0
    /// Clicks on `action` nodes (`invoke`), and `escape` for a click on the
    /// popup's scrim. Keys are the host's to send (the key monitor).
    public let send: (RenderInput) -> Void
    /// Overrides `theme.icons.mode` (`vestal render-file --icons`).
    public let iconMode: String?

    /// Every handle by node id. Ids are unique; should one repeat,
    /// the first keeps it, as `RenderSnapshot.apply` finds the first match
    /// (root before popup).
    private var index: [String: NodeHandle] = [:]

    public init(iconMode: String? = nil, send: @escaping (RenderInput) -> Void) {
        self.iconMode = iconMode
        self.send = send
        IconFonts.register()
    }

    // MARK: Model

    /// Draws a whole model: theme, the view's tree and the popup.
    public func apply(_ snapshot: RenderSnapshot) {
        if self.snapshot?.theme != snapshot.theme || self.snapshot == nil { setTheme(snapshot.theme) }
        let previous = self.snapshot, outgoing = root
        self.snapshot = snapshot
        if pages != snapshot.pages { pages = snapshot.pages }
        index = [:]
        root = build(snapshot.root)
        if let previous, let outgoing, previous.view != snapshot.view { beginChange(outgoing: outgoing, to: snapshot) }
        popup = snapshot.popup.map { PopupState(id: $0.id, width: $0.width, handle: build($0.node)) }
    }

    /// Applies a patch's ops in order, replacing only the named subtrees.
    /// Returns false when the patch doesn't follow the last applied `seq`
    /// (or names an unknown node): the caller should ask for a snapshot
    /// (`{"cmd": "snapshot"}`) and apply it.
    @discardableResult
    public func apply(_ patch: RenderPatch) -> Bool {
        guard var model = snapshot, patch.base == model.seq else { return false }
        for op in patch.ops {
            do { try model.apply(op) } catch { return false }
            switch op {
            case .replace(let id, let node):
                guard replace(id: id, with: node) else { return false }
            case .root(let node, let view):
                let outgoing = root, previousView = snapshot?.view
                forgetTree(root)
                root = build(node)
                if let outgoing, previousView != view { beginChange(outgoing: outgoing, to: model) }
            case .popup(let new):
                setPopup(new)
            case .theme(let theme):
                setTheme(theme)
            case .views, .diagnostics, .unknown:
                break
            }
        }
        model.seq = patch.seq
        snapshot = model
        return true
    }

    // MARK: Page changes

    /// Starts drawing the move to `snapshot`'s view: from `outgoing`, the
    /// page that was on screen (still showing the drag offset it was left at).
    private func beginChange(outgoing: NodeHandle, to snapshot: RenderSnapshot) {
        let start = dragOffset
        dragOffset = 0
        guard pagesLive, let pages = snapshot.pages else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let kind = PageMotion.kind(transition: pages.transition, direction: pages.direction, reduceMotion: reduce)
        guard kind != "none" else { return }
        changeSerial += 1
        let change = PageChange(serial: changeSerial, outgoing: outgoing, direction: pages.direction ?? 0, slides: kind == "slide",
                                startOffset: start, duration: kind == "slide" ? PageMotion.slideDuration : PageMotion.fadeDuration)
        pageProgress = 0
        pageChange = change
        DispatchQueue.main.asyncAfter(deadline: .now() + change.duration + 0.1) { [weak self] in
            guard let self, self.pageChange?.serial == change.serial else { return }
            self.pageChange = nil
            self.pageProgress = 1
        }
    }

    /// The stage drew the first frame of change `serial`: animate it.
    func runChange(_ serial: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let change = self.pageChange, change.serial == serial else { return }
            withAnimation(.easeOut(duration: change.duration)) { self.pageProgress = 1 }
        }
    }

    /// The dashboard is leaving or arriving: nothing animates, and a swipe
    /// in progress is dropped.
    func stopPageAnimations() {
        pageChange = nil
        pageProgress = 1
        dragOffset = 0
    }

    private func setTheme(_ theme: RenderTheme) {
        // What a library background reads from a source changes every few
        // seconds (the load); it must not redraw the nodes, which only the
        // look of the theme does.
        if background != theme { background = theme }
        var rest = theme
        rest.backgroundParams = style.theme.backgroundParams
        if rest != style.theme || snapshot == nil {
            style = RenderStyle(theme, iconMode: iconMode.flatMap(RenderIconMode.init(rawValue:)))
        }
    }

    private func setPopup(_ new: RenderPopup?) {
        if let old = popup { forgetTree(old.handle) }
        popup = new.map { PopupState(id: $0.id, width: $0.width, handle: build($0.node)) }
    }

    /// Swaps the subtree `id` for `node`, in place: the handle keeps its
    /// identity (so its parent is not drawn again) and gets new children.
    private func replace(id: String, with node: RenderNode) -> Bool {
        guard let handle = index[id] else { return false }
        for child in handle.children { forgetTree(child) }
        if node.id != id {
            if index[id] === handle { index[id] = nil }
            register(node.id, handle)
        }
        handle.update(node: node, children: node.children.map { build($0) })
        // A container whose first text came or went changes its ancestors'
        // baselines.
        var ancestor = handle.parent
        while let current = ancestor, current.refreshBaseline() { ancestor = current.parent }
        return true
    }

    // MARK: Handles

    private func build(_ node: RenderNode) -> NodeHandle {
        let children = node.children.map { build($0) }
        let handle = NodeHandle(node: node, children: children)
        register(node.id, handle)
        return handle
    }

    /// `build` registers children before their parent, so a parent that
    /// repeats a descendant's id takes it over: the first in tree order
    /// (parents first) keeps an id, as on Linux.
    private func register(_ id: String, _ handle: NodeHandle) {
        if let existing = index[id], existing !== handle, isAncestor(handle, of: existing) {
            // A parent sharing its child's id: the parent comes first.
            index[id] = handle
        } else if index[id] == nil {
            index[id] = handle
        } else if index[id] !== handle {
            NSLog("%@", "[vestal] duplicate node id \(id)")
        }
    }

    private func isAncestor(_ a: NodeHandle, of b: NodeHandle) -> Bool {
        var current = b.parent
        while let c = current {
            if c === a { return true }
            current = c.parent
        }
        return false
    }

    /// Unregisters a subtree's ids (before it is dropped).
    private func forgetTree(_ handle: NodeHandle?) {
        guard let handle else { return }
        if index[handle.node.id] === handle { index[handle.node.id] = nil }
        for child in handle.children { forgetTree(child) }
    }
}
#endif
