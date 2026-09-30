#if os(Linux)
import CGtk4
import Foundation
import VestalCore

// MARK: - Stage
//
// The window's content, bottom to top: the aurora, the view's root node
// (`min(maxWidth, window width)` wide, centred both ways, and clipped at the
// bottom when taller than the window), and while a popup is open, the scrim
// and the popup's card.

final class StageView: NodeView {
    let aurora: AuroraArea
    private(set) var root: NodeView?
    private(set) var scrim: ScrimView?
    private(set) var card: CardView?

    init(context: RenderContext, aurora: AuroraArea) {
        self.aurora = aurora
        super.init(chrome: "stage", context: context)
        gtk_widget_set_parent(aurora.widget, widget)
        // The window clips anyway; this keeps an overflowing root inside.
        gtk_widget_set_overflow(widget, GTK_OVERFLOW_HIDDEN)
    }

    /// Replaces the view's tree.
    func setRoot(_ node: RenderNode?) {
        let old = root
        old?.forget()
        if let node {
            let view = NodeView(node: node, context: context, parent: nil)
            // Above the aurora, below the scrim.
            gtk_widget_insert_after(view.widget, widget, old?.widget ?? aurora.widget)
            root = view
        } else {
            root = nil
        }
        if let old { gtk_widget_unparent(old.widget) }
    }

    /// Opens, replaces or closes the popup.
    func setPopup(_ popup: RenderPopup?) {
        if let card {
            card.forget()
            gtk_widget_unparent(card.widget)
            self.card = nil
        }
        guard let popup else {
            if let scrim { gtk_widget_unparent(scrim.widget); self.scrim = nil }
            return
        }
        if scrim == nil {
            let scrim = ScrimView(context: context)
            gtk_widget_set_parent(scrim.widget, widget)
            self.scrim = scrim
        }
        let card = CardView(popup: popup, context: context)
        gtk_widget_set_parent(card.widget, widget)
        self.card = card
    }

    override func measure(horizontal: Bool, forSize: Double) -> Measure {
        // The compositor sizes the window; content never grows it.
        Measure(minimum: 0, natural: 0)
    }

    override func allocate(width: Double, height: Double) {
        place(aurora.widget, Rect(x: 0, y: 0, width: width, height: height))
        if let root {
            let w: Double
            switch root.node.width {
            case .points(let fixed)?: w = root.clampWidth(fixed)
            default: w = root.clampWidth(width)
            }
            var h: Double
            switch root.node.height {
            case .points(let fixed)?: h = fixed
            case .fill?: h = height
            case nil: h = root.fitHeight(forWidth: w).0
            }
            h = root.clampHeight(h)
            // Taller than the window: top-aligned, cut at the bottom (rule 9).
            let y = h > height ? 0 : (height - h) / 2
            place(root.widget, Rect(x: (width - w) / 2, y: y, width: w, height: h))
        }
        if let scrim { place(scrim.widget, Rect(x: 0, y: 0, width: width, height: height)) }
        if let card {
            let w = min(card.popupWidth, width)
            let h = min(card.fitHeight(forWidth: w).0, height)
            place(card.widget, Rect(x: (width - w) / 2, y: (height - h) / 2, width: w, height: h))
        }
    }

    override func snapshot(_ snapshot: OpaquePointer) {
        snapshotChildren(snapshot)
    }
}

/// The dimmed backdrop behind a popup. A click on it is Esc.
final class ScrimView: NodeView {
    init(context: RenderContext) {
        super.init(chrome: "scrim", context: context)
        let gesture = gtk_gesture_click_new()!
        let handler: @convention(c) (UnsafeMutableRawPointer?, Int32, Double, Double, gpointer?) -> Void = { gesture, _, _, _, data in
            gtk_gesture_set_state(OpaquePointer(gesture), GTK_EVENT_SEQUENCE_CLAIMED)
            Box<() -> RenderContext?>.from(data)()?.send(.key("escape"))
        }
        let weakContext: () -> RenderContext? = { [weak context] in context }
        connectSignal(UnsafeMutableRawPointer(gesture), "released", handler, data: Box(weakContext).retained())
        gtk_widget_add_controller(widget, gesture)
    }

    override func measure(horizontal: Bool, forSize: Double) -> Measure { Measure(minimum: 0, natural: 0) }
    override func allocate(width: Double, height: Double) {}

    override func snapshot(_ snapshot: OpaquePointer) {
        let bounds = Rect(x: 0, y: 0, width: Double(gtk_widget_get_width(widget)), height: Double(gtk_widget_get_height(widget)))
        fillRounded(snapshot, bounds, radius: 0, color: context.theme.color("scrim"))
    }
}

/// The popup's card: a solid `bg` card, radius 14, a 10% white stroke and a
/// soft shadow (v0.3's SystemDetailView chrome), holding the popup's
/// node at the popup's width.
final class CardView: NodeView {
    static let radius = 14.0
    let popupWidth: Double
    private let content: NodeView

    init(popup: RenderPopup, context: RenderContext) {
        popupWidth = popup.width
        content = NodeView(node: popup.node, context: context, parent: nil)
        super.init(chrome: popup.id, context: context)
        content.parent = self
        children = [content]
        // The card sits above the scrim, so a click inside it never reaches
        // the scrim's gesture.
        gtk_widget_set_parent(content.widget, widget)
    }

    override func forget() {
        content.forget()
    }

    override func measure(horizontal: Bool, forSize: Double) -> Measure {
        if horizontal { return Measure(minimum: 0, natural: popupWidth) }
        return Measure(minimum: 0, natural: content.fitHeight(forWidth: forSize >= 0 ? forSize : popupWidth).0)
    }

    override func fitHeight(forWidth width: Double) -> (Double, Double?) {
        content.fitHeight(forWidth: width)
    }

    override func allocate(width: Double, height: Double) {
        place(content.widget, Rect(x: 0, y: 0, width: width, height: height))
    }

    override func snapshot(_ snapshot: OpaquePointer) {
        let bounds = Rect(x: 0, y: 0, width: Double(gtk_widget_get_width(widget)), height: Double(gtk_widget_get_height(widget)))
        var rounded = GskRoundedRect()
        var rect = bounds.graphene
        gsk_rounded_rect_init_from_rect(&rounded, &rect, Float(Self.radius))
        var shadow = RGBA(r: 0, g: 0, b: 0, a: 0.5).gdk
        gtk_snapshot_append_outset_shadow(snapshot, &rounded, &shadow, 0, 12, 0, 24)
        fillRounded(snapshot, bounds, radius: Self.radius, color: context.theme.color("bg"))
        pushRoundedClip(snapshot, bounds, radius: Self.radius)
        snapshotChildren(snapshot)
        gtk_snapshot_pop(snapshot)
        var widths: [Float] = [1, 1, 1, 1]
        let stroke = RGBA(r: 1, g: 1, b: 1, a: 0.10).gdk
        var colors = [stroke, stroke, stroke, stroke]
        gtk_snapshot_append_border(snapshot, &rounded, &widths, &colors)
    }
}
#endif
