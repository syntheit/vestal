#if os(Linux)
import CGtk4
import Foundation
import VestalCore

// MARK: - Stage
//
// The window's content, bottom to top: the aurora, the view's root node
// (`min(maxWidth, window width)` wide, centered both ways, and clipped at the
// bottom when taller than the window), and while a popup is open, the scrim
// and the popup's card.

/// How a change of page is drawn.
struct PageMotionRequest {
    /// +1: the new page comes in from the right; -1: from the left.
    var direction: Int
    /// A slide; otherwise a crossfade.
    var slides: Bool
    var duration: Double
}

final class StageView: NodeView {
    let aurora: AuroraArea
    private(set) var root: NodeView?
    private(set) var scrim: ScrimView?
    private(set) var card: CardView?
    /// The page leaving, while a change of page is drawn.
    private(set) var outgoing: NodeView?
    /// The pages, for the dots.
    var pages: RenderPages? {
        didSet { if pages != oldValue { gtk_widget_queue_draw(widget) } }
    }
    /// How far a swipe has dragged the current page, in points.
    var dragOffset = 0.0 {
        didSet { gtk_widget_queue_draw(widget) }
    }
    private var motion: PageMotionRequest?
    private var motionStart = 0.0
    private var motionProgress = 1.0
    private var animationTick: guint = 0

    init(context: RenderContext, aurora: AuroraArea) {
        self.aurora = aurora
        super.init(chrome: "stage", context: context)
        gtk_widget_set_parent(aurora.widget, widget)
        // The window clips anyway; this keeps an overflowing root inside.
        gtk_widget_set_overflow(widget, GTK_OVERFLOW_HIDDEN)
    }

    /// Replaces the view's tree; with `motion`, the old tree leaves while the
    /// new one comes in.
    func setRoot(_ node: RenderNode?, motion: PageMotionRequest? = nil) {
        endMotion(keepDrag: motion != nil)
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
        guard let old else {
            dragOffset = 0
            return
        }
        if let motion, root != nil {
            outgoing = old
            gtk_widget_set_can_target(old.widget, 0)
            self.motion = motion
            motionStart = dragOffset
            dragOffset = 0
            motionProgress = 0
            animate(duration: motion.duration, step: { [weak self] t in
                self?.motionProgress = 1 - (1 - t) * (1 - t)
            }, done: { [weak self] in
                self?.animationTick = 0
                self?.endMotion(keepDrag: false)
            })
        } else {
            gtk_widget_unparent(old.widget)
        }
    }

    // MARK: Pages

    /// Ends a change of page and any drag at once: the old page goes.
    func endMotion(keepDrag: Bool) {
        stopAnimation()
        if let outgoing { gtk_widget_unparent(outgoing.widget) }
        outgoing = nil
        motion = nil
        motionProgress = 1
        if !keepDrag { dragOffset = 0 }
        gtk_widget_queue_draw(widget)
    }

    /// The dragged page returns to rest.
    func springBack() {
        let from = dragOffset
        animate(duration: 0.22, step: { [weak self] t in
            self?.dragOffset = from * (1 - (1 - (1 - t) * (1 - t)))
        }, done: { [weak self] in self?.animationTick = 0 })
    }

    private final class Animation {
        var start: gint64 = 0
        let duration: Double
        let step: (Double) -> Void
        let done: () -> Void
        init(duration: Double, step: @escaping (Double) -> Void, done: @escaping () -> Void) {
            self.duration = duration; self.step = step; self.done = done
        }
    }

    /// Runs `step` with 0...1 on the frame clock for `duration` seconds
    /// (so it costs nothing once done, and nothing while unmapped).
    private func animate(duration: Double, step: @escaping (Double) -> Void, done: @escaping () -> Void) {
        stopAnimation()
        let state = Animation(duration: duration, step: step, done: done)
        let tick: GtkTickCallback = { widget, clock, data in
            let animation = Unmanaged<Animation>.fromOpaque(data!).takeUnretainedValue()
            let now = gdk_frame_clock_get_frame_time(clock)
            if animation.start == 0 { animation.start = now }
            let t = min(1, Double(now - animation.start) / 1_000_000 / animation.duration)
            animation.step(t)
            gtk_widget_queue_draw(widget)
            guard t >= 1 else { return 1 }
            animation.done()
            return 0 // removed; the destroy notify releases `animation`
        }
        animationTick = gtk_widget_add_tick_callback(widget, tick, Unmanaged.passRetained(state).toOpaque(), releaseBox)
    }

    private func stopAnimation() {
        if animationTick != 0 { gtk_widget_remove_tick_callback(widget, animationTick); animationTick = 0 }
    }

    /// Where a layer is drawn and how opaque: nil at rest.
    private func layerMotion(_ view: WidgetPtr) -> (offset: Double, opacity: Double)? {
        let width = Double(gtk_widget_get_width(widget))
        let p = motionProgress
        if let motion, let outgoing, view == outgoing.widget {
            if motion.slides {
                return (motionStart * (1 - p) - Double(motion.direction) * width * p, 1)
            }
            return (0, 1 - p)
        }
        if let motion, let root, view == root.widget {
            if motion.slides { return (Double(motion.direction) * width * (1 - p), 1) }
            return (0, p)
        }
        if let root, view == root.widget, dragOffset != 0 { return (dragOffset, 1) }
        return nil
    }

    private func drawDots(_ snapshot: OpaquePointer) {
        guard let pages, pages.indicator == "dots", pages.items.count > 1 else { return }
        let size = 7.0, spacing = 10.0, bottom = 28.0
        let width = Double(gtk_widget_get_width(widget)), height = Double(gtk_widget_get_height(widget))
        let total = Double(pages.items.count) * size + Double(pages.items.count - 1) * spacing
        var x = ((width - total) / 2).rounded()
        let y = (height - bottom - size).rounded()
        for index in pages.items.indices {
            let color = context.theme.color(index == pages.index ? "accent" : "dim")
            fillRounded(snapshot, Rect(x: x, y: y, width: size, height: size), radius: size / 2, color: color)
            x += size + spacing
        }
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
        if let outgoing { placeRoot(outgoing, width: width, height: height) }
        if let root { placeRoot(root, width: width, height: height) }
        if let scrim { place(scrim.widget, Rect(x: 0, y: 0, width: width, height: height)) }
        if let card {
            let w = min(card.popupWidth, width)
            let h = min(card.fitHeight(forWidth: w).0, height)
            place(card.widget, Rect(x: (width - w) / 2, y: (height - h) / 2, width: w, height: h))
        }
    }

    /// The view's root: `min(maxWidth, width)` wide, centered, top-aligned
    /// when taller than the window.
    private func placeRoot(_ root: NodeView, width: Double, height: Double) {
        do {
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
    }

    override func snapshot(_ snapshot: OpaquePointer) {
        // Bottom to top; the dots sit over the pages and under a popup.
        var dotsDrawn = false
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            if !dotsDrawn, current == scrim?.widget || current == card?.widget {
                drawDots(snapshot)
                dotsDrawn = true
            }
            if let layer = layerMotion(current) {
                gtk_snapshot_save(snapshot)
                var point = graphene_point_t(x: Float(layer.offset), y: 0)
                gtk_snapshot_translate(snapshot, &point)
                gtk_snapshot_push_opacity(snapshot, layer.opacity)
                gtk_widget_snapshot_child(widget, current, snapshot)
                gtk_snapshot_pop(snapshot)
                gtk_snapshot_restore(snapshot)
            } else {
                gtk_widget_snapshot_child(widget, current, snapshot)
            }
            child = gtk_widget_get_next_sibling(current)
        }
        if !dotsDrawn { drawDots(snapshot) }
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
/// soft shadow (the original SystemDetailView chrome), holding the popup's
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
