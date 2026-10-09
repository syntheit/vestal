#if os(Linux)
import CGtk4
import Foundation
import VestalCore

// MARK: - NodeView
//
// One render-model node on screen: its VestalNode widget, a GtkLabel for
// text, and the child NodeViews. Layout follows these rules:
//
// - Sizes: a number is exact, `fill` takes the parent's offer, absent is fit
//   (the natural size, capped by the offer). The core has already propagated
//   fill upward, so the UI never guesses flexibility.
// - Stacks place children with `spaceBefore` or `gap` between them, measure
//   fixed and fit children first and split the rest among fill children;
//   when a row still overflows, texts with a line limit shrink (and
//   truncate) down to their minimum, and anything else overflows.
// - Grids: fixed, fit (widest single-span cell) and fill columns; rows as
//   tall as their tallest cell, cells centred vertically.
// - Padding is inside the frame; min/max clamp after sizing, border-box.
//
// GTK sees natural sizes and a minimum of 0 for containers, so a container
// can always be given less than its content wants; content then overflows
// instead of GTK growing the window.

/// What every NodeView of one dashboard shares.
final class RenderContext {
    var theme: ThemeState
    /// Every NodeView by node id, for patches.
    var nodes: [String: NodeView] = [:]
    /// Clicks on `action` nodes (and keys, elsewhere) go here.
    let send: (RenderInput) -> Void

    init(theme: ThemeState, send: @escaping (RenderInput) -> Void) {
        self.theme = theme
        self.send = send
    }
}

class NodeView {
    private(set) var node: RenderNode
    private(set) var widget: WidgetPtr!
    unowned let context: RenderContext
    weak var parent: NodeView?
    var children: [NodeView] = []
    /// The label of a text node (or of an unknown node's `alt`).
    private(set) var label: WidgetPtr?
    /// An icon's glyph, laid out once.
    private var iconLayout: OpaquePointer?

    /// A NodeView and its widget for `node`, with its whole subtree. The
    /// widget is floating until it gets a parent.
    init(node: RenderNode, context: RenderContext, parent: NodeView?) {
        self.node = node
        self.context = context
        self.parent = parent
        widget = NodeWidget.make(for: self)
        build()
    }

    /// For subclasses that aren't a node (stage, scrim, card).
    init(chrome id: String, context: RenderContext) {
        self.node = RenderNode(id: id, .spacer(.init()))
        self.context = context
        widget = NodeWidget.make(for: self)
    }

    deinit {
        if let iconLayout { g_object_unref(UnsafeMutableRawPointer(iconLayout)) }
    }

    // MARK: Building

    private func build() {
        // Ids are unique. Should one repeat, the first keeps it, as
        // RenderSnapshot.apply finds the first match (root before popup).
        if context.nodes[node.id] != nil {
            uiLog("linux ui: duplicate node id \(node.id)")
        } else {
            context.nodes[node.id] = self
        }
        if node.opacity < 1 { gtk_widget_set_opacity(widget, max(0, node.opacity)) }
        if node.action { makeClickable() }

        switch node.content {
        case .text(let text):
            attachLabel(text)
        case .unknown:
            attachLabel(RenderNode.Text(text: node.alt ?? "", color: "subtle"))
        default:
            break
        }
        for child in node.children {
            let view = NodeView(node: child, context: context, parent: self)
            gtk_widget_set_parent(view.widget, widget)
            children.append(view)
        }
    }

    private func attachLabel(_ text: RenderNode.Text) {
        let label = gtk_label_new(text.text)!
        let l = opaque(label)
        let attrs = textAttributes(text)
        gtk_label_set_attributes(l, attrs)
        pango_attr_list_unref(attrs)
        if let lines = text.lines, lines >= 1 {
            gtk_label_set_ellipsize(l, PANGO_ELLIPSIZE_END)
            if lines == 1 {
                gtk_label_set_single_line_mode(l, 1)
            } else {
                gtk_label_set_wrap(l, 1)
                gtk_label_set_wrap_mode(l, PANGO_WRAP_WORD_CHAR)
                gtk_label_set_lines(l, Int32(clamping: lines))
            }
        } else {
            gtk_label_set_wrap(l, 1)
            gtk_label_set_wrap_mode(l, PANGO_WRAP_WORD_CHAR)
        }
        switch text.textAlign {
        case .start:
            gtk_label_set_xalign(l, 0)
            gtk_label_set_justify(l, GTK_JUSTIFY_LEFT)
        case .center:
            gtk_label_set_xalign(l, 0.5)
            gtk_label_set_justify(l, GTK_JUSTIFY_CENTER)
        case .end:
            gtk_label_set_xalign(l, 1)
            gtk_label_set_justify(l, GTK_JUSTIFY_RIGHT)
        }
        gtk_widget_set_can_target(label, 0)
        gtk_widget_set_parent(label, widget)
        self.label = label
    }

    /// Font (role family, absolute size in logical pixels, numeric weight),
    /// colour and tracking, as Pango attributes over the whole text. The
    /// caller owns the returned list.
    private func textAttributes(_ text: RenderNode.Text) -> OpaquePointer? {
        let attrs = pango_attr_list_new()
        let desc = pango_font_description_new()
        pango_font_description_set_family(desc, context.theme.family(role: text.font))
        pango_font_description_set_absolute_size(desc, text.size * Double(PANGO_SCALE))
        pango_font_description_set_weight(desc, PangoWeight(rawValue: .init(clamping: context.theme.weight(text.weight))))
        pango_attr_list_insert(attrs, pango_attr_font_desc_new(desc))
        pango_font_description_free(desc)
        let c = context.theme.color(text.color)
        pango_attr_list_insert(attrs, pango_attr_foreground_new(UInt16(c.r * 65535), UInt16(c.g * 65535), UInt16(c.b * 65535)))
        pango_attr_list_insert(attrs, pango_attr_foreground_alpha_new(UInt16(max(1, c.a * 65535))))
        if text.tracking != 0 {
            pango_attr_list_insert(attrs, pango_attr_letter_spacing_new(pixels(text.tracking * Double(PANGO_SCALE))))
        }
        return attrs
    }

    private func makeClickable() {
        let gesture = gtk_gesture_click_new()!
        let handler: @convention(c) (UnsafeMutableRawPointer?, Int32, Double, Double, gpointer?) -> Void = { gesture, _, x, y, data in
            // A release outside the node (a drag off it) is no click.
            let view = Box<() -> NodeView?>.from(data)()
            guard let view, let gesture else { return }
            let w = Double(gtk_widget_get_width(view.widget)), h = Double(gtk_widget_get_height(view.widget))
            guard x >= 0, y >= 0, x <= w, y <= h else { return }
            gtk_gesture_set_state(OpaquePointer(gesture), GTK_EVENT_SEQUENCE_CLAIMED)
            view.context.send(.invoke(id: view.node.id))
        }
        let weakSelf: () -> NodeView? = { [weak self] in self }
        connectSignal(UnsafeMutableRawPointer(gesture), "released", handler, data: Box(weakSelf).retained())
        gtk_widget_add_controller(widget, gesture)
        gtk_widget_set_cursor_from_name(widget, "pointer")
    }

    /// Unregisters this subtree's ids (before it is dropped).
    func forget() {
        if context.nodes[node.id] === self { context.nodes[node.id] = nil }
        for child in children { child.forget() }
    }

    /// Swaps the child `old` for a new subtree built from `node` (a patch's
    /// `replace`), in place: nothing else is rebuilt.
    func replaceChild(_ old: NodeView, with node: RenderNode) {
        guard let index = children.firstIndex(where: { $0 === old }) else { return }
        old.forget()
        let view = NodeView(node: node, context: context, parent: self)
        gtk_widget_insert_after(view.widget, widget, old.widget)
        gtk_widget_unparent(old.widget)
        children[index] = view
        self.node.children[index] = node
    }

    // MARK: Sizes

    /// The parent stack's axis, for a spacer's `min`.
    private var parentAxis: RenderAxis? {
        if case .stack(let s)? = parent?.node.content { return s.axis }
        return nil
    }

    var padding: RenderInsets { node.padding }

    func clampWidth(_ w: Double) -> Double {
        var w = w
        if let m = node.maxWidth { w = min(w, m) }
        if let m = node.minWidth { w = max(w, m) }
        return max(0, w)
    }

    func clampHeight(_ h: Double) -> Double {
        var h = h
        if let m = node.maxHeight { h = min(h, m) }
        if let m = node.minHeight { h = max(h, m) }
        return max(0, h)
    }

    /// GTK's measure. Overridden by the stage, scrim and card.
    func measure(horizontal: Bool, forSize: Double) -> Measure {
        // A minimum of 0: numeric sizes are exact, and a
        // label that doesn't fit its node overflows it (`place` never gives
        // the label itself less than its minimum).
        if horizontal { return Measure(minimum: 0, natural: fitWidth()) }
        let width = forSize >= 0 ? forSize : fitWidth()
        let (height, baseline) = fitHeight(forWidth: width)
        return Measure(minimum: 0, natural: height, baseline: baseline)
    }

    /// Natural width, border-box: the fixed width, or the content's plus
    /// padding; clamped.
    func fitWidth() -> Double {
        if case .points(let w)? = node.width { return clampWidth(w) }
        return clampWidth(contentWidth() + padding.horizontal)
    }

    /// Height for a width, border-box, and the first baseline.
    func fitHeight(forWidth width: Double) -> (Double, Double?) {
        let inner = max(0, width - padding.horizontal)
        let (content, baseline) = contentHeight(forWidth: inner)
        if case .points(let h)? = node.height { return (clampHeight(h), baseline.map { $0 + padding.top }) }
        return (clampHeight(content + padding.vertical), baseline.map { $0 + padding.top })
    }

    /// How narrow an overflowing row may squeeze a text: its label's
    /// minimum (the ellipsis, or the longest word) plus padding.
    private func minimumContentWidth() -> Double {
        guard let label else { return 0 }
        return minimumWidth(label) + padding.horizontal
    }

    /// The content's natural width, without padding.
    func contentWidth() -> Double {
        switch node.content {
        case .text(let text):
            // Pango's extents leave out the letter spacing after the last
            // character; without it a tracked label wraps at its own width.
            return (label.map(naturalWidth) ?? 0) + abs(text.tracking).rounded(.up)
        case .unknown:
            return label.map(naturalWidth) ?? 0
        case .icon(let icon):
            return icon.size
        case .bar:
            return 48 // v0.3's mini bar; a bar normally has a width or fills.
        case .ring:
            return 40
        case .spark:
            return 60
        case .bars, .stackedBar, .heatmap, .timeline, .image:
            return Self.chartSize(node.content)?.width ?? 0
        case .divider(let d):
            return d.axis == .v ? d.thickness : 0
        case .spacer(let s):
            return parentAxis == .h ? s.min : 0
        case .stack(let s):
            return stackNaturalWidth(s)
        case .grid(let g):
            return gridColumns(g, width: nil).reduce(0, +) + g.gap * Double(max(0, effectiveColumns(g).count - 1))
        }
    }

    /// The content's height for an inner width, and its first baseline
    /// (relative to the content's top).
    func contentHeight(forWidth width: Double) -> (Double, Double?) {
        switch node.content {
        case .text, .unknown:
            guard let label else { return (0, nil) }
            return naturalHeight(label, forWidth: max(width, minimumWidth(label)))
        case .icon(let icon):
            return (icon.size, nil)
        case .bar:
            return (6, nil)
        case .ring:
            return (width, nil) // square
        case .spark:
            return (20, nil)
        case .bars, .stackedBar, .heatmap, .timeline, .image:
            return (Self.chartSize(node.content)?.height ?? 0, nil)
        case .divider(let d):
            return (d.axis == .h ? d.thickness : 0, nil)
        case .spacer(let s):
            return (parentAxis == .v ? s.min : 0, nil)
        case .stack(let s):
            let layout = arrangeStack(s, width: width, height: nil)
            return (layout.height, layout.baseline)
        case .grid(let g):
            let layout = arrangeGrid(g, width: width)
            return (layout.height, layout.baseline)
        }
    }

    // MARK: Allocation

    /// GTK's size_allocate: places the children in the padded frame.
    func allocate(width: Double, height: Double) {
        let inner = Rect(x: 0, y: 0, width: width, height: height).inset(padding)
        switch node.content {
        case .text, .unknown:
            if let label { place(label, inner) }
        case .stack(let s):
            let layout = arrangeStack(s, width: inner.width, height: inner.height)
            for (child, frame) in zip(children, layout.frames) {
                place(child.widget, Rect(x: inner.x + frame.x, y: inner.y + frame.y, width: frame.width, height: frame.height))
            }
        case .grid(let g):
            let layout = arrangeGrid(g, width: inner.width)
            for (child, frame) in zip(children, layout.frames) {
                place(child.widget, Rect(x: inner.x + frame.x, y: inner.y + frame.y, width: frame.width, height: frame.height))
            }
        case .ring:
            if let center = children.first {
                let w = center.node.width == .fill ? center.clampWidth(inner.width) : center.offeredWidth(inner.width)
                let h = center.node.height == .fill ? center.clampHeight(inner.height) : center.fitHeight(forWidth: w).0
                place(center.widget, Rect(x: inner.x + (inner.width - w) / 2, y: inner.y + (inner.height - h) / 2, width: w, height: h))
            }
        default:
            break
        }
    }

    // MARK: Stack

    struct Arrangement {
        var frames: [Rect]
        var height: Double
        var baseline: Double?
    }

    private func gapBefore(_ index: Int, _ gap: Double) -> Double {
        index == 0 ? 0 : (children[index].node.spaceBefore ?? gap)
    }

    private func stackNaturalWidth(_ s: RenderNode.Stack) -> Double {
        if s.axis == .h {
            var total = 0.0
            for (i, child) in children.enumerated() { total += gapBefore(i, s.gap) + child.fitWidth() }
            return total
        }
        return children.map { $0.fitWidth() }.max() ?? 0
    }

    private func alignment(of child: NodeView, in s: RenderNode.Stack) -> RenderAlign {
        child.node.alignSelf ?? s.align
    }

    /// Frames of the children in a stack whose content box is `width` wide
    /// and, when allocating, `height` tall (nil while measuring).
    func arrangeStack(_ s: RenderNode.Stack, width: Double, height: Double?) -> Arrangement {
        s.axis == .h ? arrangeRow(s, width: width, height: height) : arrangeColumn(s, width: width, height: height)
    }

    private func arrangeRow(_ s: RenderNode.Stack, width: Double, height: Double?) -> Arrangement {
        let n = children.count
        guard n > 0 else { return Arrangement(frames: [], height: 0, baseline: nil) }
        var widths = [Double](repeating: 0, count: n)
        var fills: [Int] = []
        var used = 0.0
        for (i, child) in children.enumerated() {
            used += gapBefore(i, s.gap)
            if child.node.width == .fill {
                fills.append(i)
            } else {
                widths[i] = child.offeredWidth(width)
                used += widths[i]
            }
        }
        var remaining = width - used
        if !fills.isEmpty {
            let share = max(0, remaining) / Double(fills.count)
            for i in fills {
                widths[i] = children[i].clampWidth(share)
                remaining -= widths[i]
            }
        } else if remaining < 0 {
            // Overflow: texts with a line limit give way, down to their
            // minimum, in proportion to what each can give.
            let shrinkable = children.indices.filter { children[$0].truncates && children[$0].node.width == nil }
            let capacity = shrinkable.map { widths[$0] - children[$0].minimumContentWidth() }.map { max(0, $0) }
            let total = capacity.reduce(0, +)
            if total > 0 {
                let deficit = min(-remaining, total)
                for (k, i) in shrinkable.enumerated() {
                    widths[i] -= deficit * capacity[k] / total
                }
                remaining += deficit
            }
        }

        // Heights and baselines at those widths.
        var heights = [Double](repeating: 0, count: n)
        var baselines = [Double?](repeating: nil, count: n)
        for (i, child) in children.enumerated() {
            let (h, b) = child.fitHeight(forWidth: widths[i])
            heights[i] = h
            baselines[i] = b
        }
        let stretches: (Int) -> Bool = { i in
            self.children[i].node.height == .fill || self.alignment(of: self.children[i], in: s) == .stretch
        }
        // The row's own height: its offer, or its tallest child (baseline
        // children counted as ascent plus descent).
        var ascent = 0.0, descent = 0.0, tallest = 0.0
        for i in 0..<n {
            if alignment(of: children[i], in: s) == .baseline, let b = baselines[i] {
                ascent = max(ascent, b)
                descent = max(descent, heights[i] - b)
            } else {
                tallest = max(tallest, heights[i])
            }
        }
        let natural = max(tallest, ascent + descent)
        let rowHeight = height ?? natural

        var frames: [Rect] = []
        var x = 0.0
        var extraGap = 0.0
        if fills.isEmpty, remaining > 0 {
            switch s.justify {
            case .start: break
            case .center: x = remaining / 2
            case .end: x = remaining
            case .between: extraGap = n > 1 ? remaining / Double(n - 1) : 0
            }
        }
        var baseline: Double?
        for (i, child) in children.enumerated() {
            if i > 0 { x += gapBefore(i, s.gap) + extraGap }
            var h = heights[i]
            if stretches(i) { h = child.clampHeight(rowHeight) }
            let y: Double
            switch alignment(of: child, in: s) {
            case .start, .stretch: y = 0
            case .center: y = (rowHeight - h) / 2
            case .end: y = rowHeight - h
            case .baseline:
                if let b = baselines[i] { y = ascent - b + max(0, (rowHeight - natural) / 2) } else { y = (rowHeight - h) / 2 }
            }
            if baseline == nil, let b = baselines[i] { baseline = y + b }
            frames.append(Rect(x: x, y: y, width: widths[i], height: h))
            x += widths[i]
        }
        return Arrangement(frames: frames, height: natural, baseline: baseline)
    }

    private func arrangeColumn(_ s: RenderNode.Stack, width: Double, height: Double?) -> Arrangement {
        let n = children.count
        guard n > 0 else { return Arrangement(frames: [], height: 0, baseline: nil) }
        var widths = [Double](repeating: 0, count: n)
        var heights = [Double](repeating: 0, count: n)
        var baselines = [Double?](repeating: nil, count: n)
        var fills: [Int] = []
        var used = 0.0
        for (i, child) in children.enumerated() {
            used += gapBefore(i, s.gap)
            if child.node.width == .fill || alignment(of: child, in: s) == .stretch {
                widths[i] = child.clampWidth(width)
            } else {
                widths[i] = child.offeredWidth(width)
            }
            let (h, b) = child.fitHeight(forWidth: widths[i])
            baselines[i] = b
            if child.node.height == .fill, height != nil {
                fills.append(i)
            } else {
                heights[i] = h
                used += h
            }
        }
        var remaining = (height ?? used) - used
        if !fills.isEmpty {
            let share = max(0, remaining) / Double(fills.count)
            for i in fills {
                heights[i] = children[i].clampHeight(share)
                remaining -= heights[i]
            }
        }
        var y = 0.0
        var extraGap = 0.0
        if fills.isEmpty, remaining > 0 {
            switch s.justify {
            case .start: break
            case .center: y = remaining / 2
            case .end: y = remaining
            case .between: extraGap = n > 1 ? remaining / Double(n - 1) : 0
            }
        }
        var frames: [Rect] = []
        var baseline: Double?
        for (i, child) in children.enumerated() {
            if i > 0 { y += gapBefore(i, s.gap) + extraGap }
            let x: Double
            switch alignment(of: child, in: s) {
            case .start, .stretch, .baseline: x = 0
            case .center: x = (width - widths[i]) / 2
            case .end: x = width - widths[i]
            }
            if baseline == nil, let b = baselines[i] { baseline = y + b }
            frames.append(Rect(x: x, y: y, width: widths[i], height: heights[i]))
            y += heights[i]
        }
        return Arrangement(frames: frames, height: y, baseline: baseline)
    }

    /// Width for an offer: a number is exact (and may overflow); fit is the
    /// natural width capped by the offer.
    func offeredWidth(_ offer: Double) -> Double {
        if case .points = node.width { return fitWidth() }
        return min(fitWidth(), offer)
    }

    /// A text with a line limit: it truncates rather than overflowing.
    var truncates: Bool {
        if case .text(let t) = node.content { return t.lines != nil }
        return false
    }

    // MARK: Grid

    private func effectiveColumns(_ g: RenderNode.Grid) -> [RenderNode.Grid.Column] {
        g.columns.isEmpty ? [RenderNode.Grid.Column()] : g.columns
    }

    /// Row and first column of each child, honouring `span`.
    private func gridCells(_ g: RenderNode.Grid) -> [(row: Int, column: Int, span: Int)] {
        let count = effectiveColumns(g).count
        var cells: [(Int, Int, Int)] = []
        var row = 0, column = 0
        for child in children {
            let span = min(max(1, child.node.span), count)
            if column + span > count { row += 1; column = 0 }
            cells.append((row, column, span))
            column += span
            if column >= count { row += 1; column = 0 }
        }
        return cells
    }

    /// Column widths for a content width (nil: natural widths).
    private func gridColumns(_ g: RenderNode.Grid, width: Double?) -> [Double] {
        let columns = effectiveColumns(g)
        let cells = gridCells(g)
        var widest = [Double](repeating: 0, count: columns.count)
        for (child, cell) in zip(children, cells) where cell.span == 1 {
            widest[cell.column] = max(widest[cell.column], child.fitWidth())
        }
        var widths = [Double](repeating: 0, count: columns.count)
        var fills: [Int] = []
        var used = g.gap * Double(max(0, columns.count - 1))
        for (i, column) in columns.enumerated() {
            switch column.width {
            case .points(let w): widths[i] = w; used += w
            case .fit: widths[i] = widest[i]; used += widest[i]
            case .fill:
                if width == nil { widths[i] = widest[i] } else { fills.append(i) }
            }
        }
        if let width, !fills.isEmpty {
            let share = max(0, width - used) / Double(fills.count)
            for i in fills { widths[i] = share }
        }
        return widths
    }

    func arrangeGrid(_ g: RenderNode.Grid, width: Double) -> Arrangement {
        let columns = effectiveColumns(g)
        let widths = gridColumns(g, width: width)
        let cells = gridCells(g)
        var xs: [Double] = []
        var x = 0.0
        for w in widths { xs.append(x); x += w + g.gap }

        var frames = [Rect](repeating: .zero, count: children.count)
        var rowHeights: [Int: Double] = [:]
        var cellHeights = [Double](repeating: 0, count: children.count)
        var baselines = [Double?](repeating: nil, count: children.count)
        for (i, (child, cell)) in zip(children, cells).enumerated() {
            let cellWidth = widths[cell.column..<(cell.column + cell.span)].reduce(0, +) + g.gap * Double(cell.span - 1)
            let w = child.node.width == .fill || child.node.alignSelf == .stretch
                ? child.clampWidth(cellWidth) : child.offeredWidth(cellWidth)
            let (h, b) = child.fitHeight(forWidth: w)
            cellHeights[i] = h
            baselines[i] = b
            if child.node.height != .fill { rowHeights[cell.row] = max(rowHeights[cell.row] ?? 0, h) }
            let align: RenderTextAlign
            switch child.node.alignSelf {
            case .center?: align = .center
            case .end?: align = .end
            case .start?, .stretch?, .baseline?: align = .start
            case nil: align = columns[cell.column].align
            }
            let offset: Double
            switch align {
            case .start: offset = 0
            case .center: offset = (cellWidth - w) / 2
            case .end: offset = cellWidth - w
            }
            frames[i] = Rect(x: xs[cell.column] + offset, y: 0, width: w, height: h)
        }
        // A row holding only fill-height cells is as tall as the tallest of
        // their natural heights.
        for (i, (child, cell)) in zip(children, cells).enumerated() where child.node.height == .fill && rowHeights[cell.row] == nil {
            rowHeights[cell.row] = cells.indices
                .filter { cells[$0].row == cell.row }
                .map { cellHeights[$0] }
                .max() ?? cellHeights[i]
        }
        let rows = (cells.map(\.row).max() ?? -1) + 1
        var ys: [Double] = []
        var y = 0.0
        for row in 0..<rows {
            ys.append(y)
            y += (rowHeights[row] ?? 0) + (row < rows - 1 ? g.rowGap : 0)
        }
        var baseline: Double?
        for (i, (child, cell)) in zip(children, cells).enumerated() {
            let rowHeight = rowHeights[cell.row] ?? cellHeights[i]
            if child.node.height == .fill { frames[i].height = child.clampHeight(rowHeight) }
            frames[i].y = ys[cell.row] + (rowHeight - frames[i].height) / 2
            if baseline == nil, let b = baselines[i] { baseline = frames[i].y + b }
        }
        return Arrangement(frames: frames, height: y, baseline: baseline)
    }

    // MARK: Drawing

    /// GTK's snapshot: box (background, border), the node's own drawing,
    /// then the children, clipped when `clip` is set.
    func snapshot(_ snapshot: OpaquePointer) {
        let bounds = Rect(x: 0, y: 0, width: Double(gtk_widget_get_width(widget)), height: Double(gtk_widget_get_height(widget)))
        drawBox(snapshot, bounds)
        let inner = bounds.inset(padding)
        switch node.content {
        case .icon(let icon): drawIcon(snapshot, icon, inner)
        case .bar(let bar): drawBar(snapshot, bar, inner)
        case .ring(let ring): drawRing(snapshot, ring, inner)
        case .spark(let spark): drawSpark(snapshot, spark, inner)
        case .bars(let bars): drawBars(snapshot, bars, inner)
        case .stackedBar(let bar): drawStackedBar(snapshot, bar, inner)
        case .heatmap(let heatmap): drawHeatmap(snapshot, heatmap, inner)
        case .timeline(let timeline): drawTimeline(snapshot, timeline, inner)
        case .image(let image): drawImage(snapshot, image, inner)
        case .divider(let divider): drawDivider(snapshot, divider, inner)
        default: break
        }
        if node.clip { pushRoundedClip(snapshot, bounds, radius: node.radius) }
        snapshotChildren(snapshot)
        if node.clip { gtk_snapshot_pop(snapshot) }
    }

    func snapshotChildren(_ snapshot: OpaquePointer) {
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            gtk_widget_snapshot_child(widget, current, snapshot)
            child = gtk_widget_get_next_sibling(current)
        }
    }

    private func drawBox(_ snapshot: OpaquePointer, _ bounds: Rect) {
        if let background = node.background {
            fillRounded(snapshot, bounds, radius: node.radius, color: context.theme.color(background))
        }
        if let border = node.border, border.width > 0 {
            var rounded = GskRoundedRect()
            var rect = bounds.graphene
            gsk_rounded_rect_init_from_rect(&rounded, &rect, Float(node.radius))
            let w = Float(border.width)
            let c = context.theme.color(border.color).gdk
            var widths: [Float] = [w, w, w, w]
            var colors: [GdkRGBA] = [c, c, c, c]
            gtk_snapshot_append_border(snapshot, &rounded, &widths, &colors)
        }
    }

    // MARK: Icon

    private func drawIcon(_ snapshot: OpaquePointer, _ icon: RenderNode.Icon, _ box: Rect) {
        // `sf:` names have no glyph and draw nothing off macOS.
        guard let glyph = icon.glyph, !glyph.isEmpty else { return }
        if iconLayout == nil {
            let layout = gtk_widget_create_pango_layout(widget, glyph)
            let desc = pango_font_description_new()
            pango_font_description_set_family(desc, context.theme.iconFamily(weight: icon.weight))
            pango_font_description_set_absolute_size(desc, icon.size * Double(PANGO_SCALE))
            pango_layout_set_font_description(layout, desc)
            pango_font_description_free(desc)
            iconLayout = layout
        }
        guard let layout = iconLayout else { return }
        var ink = PangoRectangle(), logical = PangoRectangle()
        pango_layout_get_extents(layout, &ink, &logical)
        let scale = Double(PANGO_SCALE)
        // Centre the glyph's advance box horizontally and its em box
        // (ascent + descent) vertically in the size×size box.
        let x = box.x + (box.width - Double(logical.width) / scale) / 2 - Double(logical.x) / scale
        let y = box.y + (box.height - Double(logical.height) / scale) / 2 - Double(logical.y) / scale
        gtk_snapshot_save(snapshot)
        var point = graphene_point_t(x: Float(x), y: Float(y))
        gtk_snapshot_translate(snapshot, &point)
        var color = context.theme.color(icon.color).gdk
        gtk_snapshot_append_layout(snapshot, layout, &color)
        gtk_snapshot_restore(snapshot)
    }

    // MARK: Bar

    private func drawBar(_ snapshot: OpaquePointer, _ bar: RenderNode.Bar, _ box: Rect) {
        let theme = context.theme
        let color = theme.color(bar.color, default: "accent")
        let track = bar.trackColor.map { theme.color($0) } ?? color.withAlpha(0.15)
        let overlayColor = bar.overlayColor.map { theme.color($0) } ?? RGBA(r: 1, g: 1, b: 1, a: 0.2)
        let radius = min(bar.radius, box.height / 2)
        fillRounded(snapshot, box, radius: radius, color: track)
        func segment(_ fraction: Double, _ c: RGBA, from: Double = 0) {
            let f = min(max(fraction, 0), 1)
            guard f > from else { return }
            fillRounded(snapshot, Rect(x: box.x + box.width * from, y: box.y, width: box.width * (f - from), height: box.height),
                        radius: radius, color: c)
        }
        if let overlay = bar.overlay, bar.overlayPosition == "below" { segment(overlay, overlayColor) }
        segment(bar.value, color, from: bar.start)
        if let overlay = bar.overlay, bar.overlayPosition != "below" { segment(overlay, overlayColor) }
        if let tick = bar.tick {
            let width = 1.5
            let x = min(max(box.x + box.width * min(max(tick, 0), 1) - width / 2, box.x), box.x + box.width - width)
            fillRounded(snapshot, Rect(x: x, y: box.y, width: width, height: box.height), radius: 0,
                        color: bar.tickColor.map { theme.color($0) } ?? RGBA(r: 1, g: 1, b: 1, a: 0.55))
        }
    }

    // MARK: Ring

    private func drawRing(_ snapshot: OpaquePointer, _ ring: RenderNode.Ring, _ box: Rect) {
        let size = min(box.width, box.height)
        guard size > 0 else { return }
        let theme = context.theme
        let color = theme.color(ring.color, default: "accent")
        let track = ring.trackColor.map { theme.color($0) } ?? color.withAlpha(0.15)
        var rect = box.graphene
        let cr = gtk_snapshot_append_cairo(snapshot, &rect)
        defer { cairo_destroy(cr) }
        let cx = box.x + box.width / 2, cy = box.y + box.height / 2
        let radius = max(0, (size - ring.thickness) / 2)
        let sweep = min(max(ring.sweep, 0), 360) * .pi / 180
        // Angles grow clockwise (y down); 90° is straight down, so the gap
        // is centred at the bottom.
        let start = Double.pi / 2 + (2 * .pi - sweep) / 2
        cairo_set_line_width(cr, ring.thickness)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        setSource(cr, track)
        cairo_arc(cr, cx, cy, radius, start, start + sweep)
        cairo_stroke(cr)
        let value = min(max(ring.value, 0), 1)
        if value > 0 {
            setSource(cr, color)
            cairo_arc(cr, cx, cy, radius, start, start + sweep * value)
            cairo_stroke(cr)
        }
    }

    // MARK: Spark

    private func drawSpark(_ snapshot: OpaquePointer, _ spark: RenderNode.Spark, _ box: Rect) {
        let values = spark.values
        guard values.count >= 2, box.width > 0, box.height > 0 else { return }
        let theme = context.theme
        let color = theme.color(spark.color, default: "accent")
        let lo = spark.min ?? values.min()!, hi = spark.max ?? values.max()!
        let inset = spark.strokeWidth / 2 + (spark.dotAt != nil ? spark.strokeWidth * 2.5 : spark.dot ? spark.strokeWidth : 0)
        let plot = Rect(x: box.x + inset, y: box.y + inset, width: max(0, box.width - 2 * inset), height: max(0, box.height - 2 * inset))
        func point(_ i: Int) -> (Double, Double) {
            let x = plot.x + plot.width * Double(i) / Double(values.count - 1)
            let t = hi > lo ? (min(max(values[i], lo), hi) - lo) / (hi - lo) : 0.5
            return (x, plot.y + plot.height * (1 - t))
        }
        var rect = box.graphene
        let cr = gtk_snapshot_append_cairo(snapshot, &rect)
        defer { cairo_destroy(cr) }
        if let fill = spark.fill {
            let (x0, y0) = point(0)
            cairo_move_to(cr, x0, box.y + box.height)
            cairo_line_to(cr, x0, y0)
            for i in 1..<values.count { let (x, y) = point(i); cairo_line_to(cr, x, y) }
            cairo_line_to(cr, point(values.count - 1).0, box.y + box.height)
            cairo_close_path(cr)
            setSource(cr, theme.color(fill))
            cairo_fill(cr)
        }
        let (x0, y0) = point(0)
        cairo_move_to(cr, x0, y0)
        for i in 1..<values.count { let (x, y) = point(i); cairo_line_to(cr, x, y) }
        cairo_set_line_width(cr, spark.strokeWidth)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        setSource(cr, color)
        cairo_stroke(cr)
        if let at = spark.dotAt {
            // Between two points, at a fraction of the width.
            let position = min(max(at, 0), 1) * Double(values.count - 1)
            let i = min(Int(position), values.count - 2)
            let (xa, ya) = point(i), (xb, yb) = point(i + 1)
            let t = position - Double(i)
            setSource(cr, spark.dotColor.map { theme.color($0) } ?? color)
            cairo_arc(cr, xa + (xb - xa) * t, ya + (yb - ya) * t, spark.strokeWidth * 2.5, 0, 2 * .pi)
            cairo_fill(cr)
        } else if spark.dot {
            let (x, y) = point(values.count - 1)
            cairo_arc(cr, x, y, spark.strokeWidth * 1.5, 0, 2 * .pi)
            cairo_fill(cr)
        }
    }

    // MARK: Divider

    private func drawDivider(_ snapshot: OpaquePointer, _ divider: RenderNode.Divider, _ box: Rect) {
        let color = context.theme.color(divider.color)
        let t = divider.thickness
        let rect = divider.axis == .h
            ? Rect(x: box.x, y: box.y + (box.height - t) / 2, width: box.width, height: t)
            : Rect(x: box.x + (box.width - t) / 2, y: box.y, width: t, height: box.height)
        fillRounded(snapshot, rect, radius: 0, color: color)
    }
}

// MARK: - Snapshot helpers

func fillRounded(_ snapshot: OpaquePointer, _ rect: Rect, radius: Double, color: RGBA) {
    guard color.a > 0, rect.width > 0, rect.height > 0 else { return }
    var g = rect.graphene
    var c = color.gdk
    if radius > 0 {
        pushRoundedClip(snapshot, rect, radius: radius)
        gtk_snapshot_append_color(snapshot, &c, &g)
        gtk_snapshot_pop(snapshot)
    } else {
        gtk_snapshot_append_color(snapshot, &c, &g)
    }
}

func pushRoundedClip(_ snapshot: OpaquePointer, _ rect: Rect, radius: Double) {
    var rounded = GskRoundedRect()
    var g = rect.graphene
    gsk_rounded_rect_init_from_rect(&rounded, &g, Float(min(radius, rect.width / 2, rect.height / 2)))
    gtk_snapshot_push_rounded_clip(snapshot, &rounded)
}

func setSource(_ cr: OpaquePointer?, _ c: RGBA) {
    cairo_set_source_rgba(cr, c.r, c.g, c.b, c.a)
}
#endif
