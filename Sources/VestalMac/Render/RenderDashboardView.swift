#if os(macOS)
import SwiftUI
import VestalCore

// MARK: - Dashboard (v0.4)
//
// The window's content since v0.4: the aurora (for `theme.background:
// "aurora"`) or a background of the library (BackgroundView) over the window's blur (tinted by `theme.dim` when set) or
// solid color, exactly as v0.3's
// DashboardView draws it, and the render engine's model over that
// (RenderStageView: the view's root centered, the popup with its scrim).

struct RenderDashboardView: View {
    @ObservedObject var store: RenderStore
    /// `theme.background` is "aurora" (the default).
    let aurora: Bool

    var body: some View {
        ZStack {
            Color.clear
            // theme.dim: the palette's `bg` over the window's material,
            // under the aurora. Unset, nothing: the HUD material's own tint.
            if let dim = store.style.theme.dim, store.style.theme.background != "none" {
                store.style.rgba("bg").withAlpha(dim).color
                    .allowsHitTesting(false)
            }
            if aurora {
                AuroraView()
                    .allowsHitTesting(false)
            } else if Backgrounds.isLibrary(store.background.background) {
                BackgroundView(theme: store.background)
                    .allowsHitTesting(false)
            }
            RenderStageView(store: store)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row animations

extension RenderStore {
    /// Whether `patch` adds or removes rows: a root child (a section that
    /// appears), or a list row (ids ending in an `@` component).
    /// v0.3 eased those in over 0.3 s after the first frame (hosts, list
    /// entries, the weather section); the app animates such patches.
    func changesRows(_ patch: RenderPatch) -> Bool {
        guard let snapshot else { return false }
        for op in patch.ops {
            switch op {
            case .replace(let id, let node):
                guard let old = snapshot.root.node(withId: id) ?? snapshot.popup?.node.node(withId: id) else { continue }
                if Self.rows(old, isRoot: id == snapshot.root.id) != Self.rows(node, isRoot: id == snapshot.root.id) { return true }
            case .root(let node, let view):
                if view == snapshot.view, Self.rows(snapshot.root, isRoot: true) != Self.rows(node, isRoot: true) { return true }
            default:
                continue
            }
        }
        return false
    }

    /// The ids of `node`'s list rows, and its children's when it is the root.
    private static func rows(_ node: RenderNode, isRoot: Bool) -> Set<String> {
        var ids: Set<String> = isRoot ? Set(node.children.map(\.id)) : []
        func visit(_ n: RenderNode) {
            if n.id.split(separator: "/").last?.hasPrefix("@") == true { ids.insert(n.id) }
            n.children.forEach(visit)
        }
        visit(node)
        return ids
    }
}
#endif
