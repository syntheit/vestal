#if os(Linux)
import CGtk4
import Foundation
import VestalCore

// MARK: - VestalNode widget
//
// Every render-model node is one `VestalNode`, a minimal GtkWidget subclass
// registered here. Its measure, size_allocate and snapshot vfuncs call the
// Swift `NodeView` attached to it, which implements the layout rules of §10.4
// and draws backgrounds, borders, bars, rings, sparklines, dividers and icon
// glyphs. Text is a GtkLabel child of its node.
//
// Ownership: the widget holds a strong reference to its NodeView (object
// qdata, released when the widget is finalized); a NodeView points back at
// its widget without a reference. GTK owns the widgets through the widget
// tree, so dropping a subtree is `gtk_widget_unparent` on its root.

enum NodeWidget {
    /// The `VestalNode` GType, registered on first use.
    static let type: GType = {
        var info = GTypeInfo(
            class_size: guint16(MemoryLayout<GtkWidgetClass>.size),
            base_init: nil,
            base_finalize: nil,
            class_init: { klass, _ in NodeWidget.classInit(klass) },
            class_finalize: nil,
            class_data: nil,
            instance_size: guint16(MemoryLayout<GtkWidget>.size),
            n_preallocs: 0,
            instance_init: nil,
            value_table: nil)
        return g_type_register_static(gtk_widget_get_type(), "VestalNode", &info, GTypeFlags(rawValue: 0))
    }()

    private static let quark: GQuark = g_quark_from_static_string("vestal-node-view")
    private static var parentObjectClass: UnsafeMutablePointer<GObjectClass>?

    /// A new, floating VestalNode owned by `view`.
    static func make(for view: NodeView) -> WidgetPtr {
        let object = g_object_new_with_properties(type, 0, nil, nil)!
        let widget: WidgetPtr = cast(object)
        g_object_set_qdata_full(object, quark, Unmanaged.passRetained(view).toOpaque(), releaseBox)
        return widget
    }

    /// The NodeView of a VestalNode.
    static func view(of widget: UnsafeMutableRawPointer?) -> NodeView? {
        guard let widget, let data = g_object_get_qdata(cast(widget), quark) else { return nil }
        return Unmanaged<NodeView>.fromOpaque(data).takeUnretainedValue()
    }

    private static func classInit(_ klass: gpointer?) {
        let widgetClass: UnsafeMutablePointer<GtkWidgetClass> = cast(klass)
        parentObjectClass = cast(g_type_class_peek_parent(klass))

        widgetClass.pointee.parent_class.dispose = { object in
            // Children go with their parent (GTK doesn't do this for
            // subclasses of GtkWidget).
            let widget: WidgetPtr = cast(object)
            var child = gtk_widget_get_first_child(widget)
            while let current = child {
                child = gtk_widget_get_next_sibling(current)
                gtk_widget_unparent(current)
            }
            NodeWidget.parentObjectClass?.pointee.dispose?(object)
        }
        widgetClass.pointee.get_request_mode = { _ in GTK_SIZE_REQUEST_HEIGHT_FOR_WIDTH }
        widgetClass.pointee.measure = { widget, orientation, forSize, minimum, natural, minimumBaseline, naturalBaseline in
            let m = NodeWidget.view(of: widget)?.measure(horizontal: orientation == GTK_ORIENTATION_HORIZONTAL,
                                                         forSize: Double(forSize))
                ?? Measure(minimum: 0, natural: 0)
            minimum?.pointee = pixels(m.minimum.rounded(.up))
            natural?.pointee = pixels(max(m.minimum, m.natural).rounded(.up))
            // Baselines stay inside NodeView's own layout (arrangeRow); GTK
            // would reject one below a minimum height of 0.
            minimumBaseline?.pointee = -1
            naturalBaseline?.pointee = -1
        }
        widgetClass.pointee.size_allocate = { widget, width, height, _ in
            NodeWidget.view(of: widget)?.allocate(width: Double(width), height: Double(height))
        }
        widgetClass.pointee.snapshot = { widget, snapshot in
            guard let widget, let snapshot else { return }
            NodeWidget.view(of: widget)?.snapshot(snapshot)
        }
        gtk_widget_class_set_css_name(widgetClass, "vestal-node")
    }
}

/// A measurement for GTK: minimum and natural size on one axis, and on the
/// vertical axis the first baseline, if any.
struct Measure {
    var minimum: Double
    var natural: Double
    var baseline: Double? = nil
}

struct Rect {
    var x: Double, y: Double, width: Double, height: Double

    static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    var graphene: graphene_rect_t {
        graphene_rect_t(origin: graphene_point_t(x: Float(x), y: Float(y)),
                        size: graphene_size_t(width: Float(width), height: Float(height)))
    }

    func inset(_ p: RenderInsets) -> Rect {
        Rect(x: x + p.left, y: y + p.top, width: max(0, width - p.horizontal), height: max(0, height - p.vertical))
    }
}

/// Allocates `child` at `frame` in its parent's coordinates. Edges are
/// rounded independently so rounding never accumulates along a stack; the
/// size is at least the child's minimum, so GTK never sees it underallocated
/// (content that doesn't fit overflows, as §10.4 rule 2 says).
func place(_ child: WidgetPtr, _ frame: Rect, baseline: Int32 = -1) {
    var minW: Int32 = 0, minH: Int32 = 0
    gtk_widget_measure(child, GTK_ORIENTATION_HORIZONTAL, -1, &minW, nil, nil, nil)
    let x0 = frame.x.rounded(), y0 = frame.y.rounded()
    var width = pixels((frame.x + frame.width).rounded() - x0)
    width = max(width, minW)
    gtk_widget_measure(child, GTK_ORIENTATION_VERTICAL, width, &minH, nil, nil, nil)
    var height = pixels((frame.y + frame.height).rounded() - y0)
    height = max(height, minH)
    var allocation = GtkAllocation(x: pixels(x0), y: pixels(y0), width: width, height: height)
    gtk_widget_size_allocate(child, &allocation, baseline)
}

/// A size or position in whole logical pixels for GTK: non-finite values
/// are 0, and huge ones are clamped (a model may say `"width": 1e100`).
func pixels(_ value: Double) -> Int32 {
    guard value.isFinite else { return 0 }
    return Int32(max(-1_000_000, min(1_000_000, value)))
}

/// Natural width of a widget (any: a VestalNode or a label).
func naturalWidth(_ widget: WidgetPtr) -> Double {
    var minimum: Int32 = 0, natural: Int32 = 0
    gtk_widget_measure(widget, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, &natural, nil, nil)
    return Double(max(minimum, natural))
}

func minimumWidth(_ widget: WidgetPtr) -> Double {
    var minimum: Int32 = 0
    gtk_widget_measure(widget, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, nil, nil, nil)
    return Double(minimum)
}

/// Natural height of a widget for a width, and its baseline.
func naturalHeight(_ widget: WidgetPtr, forWidth width: Double) -> (height: Double, baseline: Double?) {
    var minimum: Int32 = 0, natural: Int32 = 0, minBase: Int32 = -1, natBase: Int32 = -1
    gtk_widget_measure(widget, GTK_ORIENTATION_VERTICAL, pixels(width.rounded()), &minimum, &natural, &minBase, &natBase)
    return (Double(max(minimum, natural)), natBase >= 0 ? Double(natBase) : nil)
}
#endif
