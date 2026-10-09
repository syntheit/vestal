#if os(macOS)
import SwiftUI
import VestalCore

// MARK: - Render layout
//
// The render model's layout rules as SwiftUI `Layout`s. The arithmetic is the GTK
// UI's (VestalLinux/NodeView.swift), line for line where it can be, so both
// platforms lay out the same model the same way:
//
// - Every node is a `NodeBoxLayout` around its content. It is exact for a
//   number, and otherwise takes whatever size its parent proposes; asked
//   with no proposal (nil) it reports its fit size: the content's natural
//   size plus padding, clamped by min/max (border-box).
// - Parents decide: `StackLayout`, `GridLayout`, `RingLayout` and
//   `StageLayout` compute each child's frame by the rules (fill shares, fit
//   capped by the offer, `spaceBefore`, `justify`, `alignSelf`, baselines,
//   grid columns and spans) and propose exactly that frame.
//
// SwiftUI's own flexibility rules never come into it: the core has already
// propagated `fill` upward (rule 1).

/// The fields of a node that its parent's layout reads, published to it as
/// a layout value.
struct NodeSpec: Equatable {
    var width: RenderLength?
    var height: RenderLength?
    var minWidth: Double?
    var maxWidth: Double?
    var minHeight: Double?
    var maxHeight: Double?
    var padding: RenderInsets = .zero
    var spaceBefore: Double?
    var alignSelf: RenderAlign?
    var span = 1
    /// A text with a line limit: it truncates rather than overflowing.
    var truncates = false
    /// How narrow an overflowing row may squeeze it (a truncating text).
    var minimumWidth: Double = 0
    /// Whether it has a first baseline (a text, or a container holding one).
    var hasBaseline = false

    init() {}

    init(_ node: RenderNode, hasBaseline: Bool) {
        width = node.width
        height = node.height
        minWidth = node.minWidth
        maxWidth = node.maxWidth
        minHeight = node.minHeight
        maxHeight = node.maxHeight
        padding = node.padding
        spaceBefore = node.spaceBefore
        alignSelf = node.alignSelf
        span = node.span
        if case .text(let t) = node.content, t.lines != nil {
            truncates = true
            // About an ellipsis: GTK's label minimum with ellipsizing.
            minimumWidth = t.size + node.padding.horizontal
        }
        self.hasBaseline = hasBaseline
    }

    func clampWidth(_ w: Double) -> Double {
        var w = w
        if let m = maxWidth { w = min(w, m) }
        if let m = minWidth { w = max(w, m) }
        return max(0, w)
    }

    func clampHeight(_ h: Double) -> Double {
        var h = h
        if let m = maxHeight { h = min(h, m) }
        if let m = minHeight { h = max(h, m) }
        return max(0, h)
    }

    var fillsWidth: Bool { width == .fill }
    var fillsHeight: Bool { height == .fill }
}

struct NodeSpecKey: LayoutValueKey {
    static let defaultValue = NodeSpec()
}

/// A finite proposal, or nil (unspecified or infinite).
func finite(_ value: CGFloat?) -> Double? {
    guard let value, value.isFinite else { return nil }
    return Double(value)
}

// MARK: - Child measurement

/// What a parent layout asks of a child node (layout rule 8's two passes).
extension LayoutSubview {
    var spec: NodeSpec { self[NodeSpecKey.self] }

    /// Natural width, border-box: its fixed width or its content's.
    var fitWidth: Double {
        // A height is proposed so the box doesn't measure its height too.
        Double(sizeThatFits(ProposedViewSize(width: nil, height: 0)).width)
    }

    /// Width for an offer: a number is exact (and may overflow); fit is the
    /// natural width capped by the offer.
    func offeredWidth(_ offer: Double) -> Double {
        if case .points? = spec.width { return fitWidth }
        return min(fitWidth, offer)
    }

    /// Height for a width, border-box.
    func fitHeight(forWidth width: Double) -> Double {
        Double(sizeThatFits(ProposedViewSize(width: CGFloat(width), height: nil)).height)
    }

    /// The first baseline at that width, from the top; nil without one.
    func baseline(forWidth width: Double) -> Double? {
        guard spec.hasBaseline else { return nil }
        return Double(dimensions(in: ProposedViewSize(width: CGFloat(width), height: nil))[.firstTextBaseline])
    }
}

/// A child's frame in its parent's content box.
struct NodeFrame {
    var x: Double, y: Double, width: Double, height: Double

    static let zero = NodeFrame(x: 0, y: 0, width: 0, height: 0)
}

extension LayoutSubview {
    /// Places the child at `frame`, relative to `origin`, proposing exactly
    /// its size.
    func place(_ frame: NodeFrame, from origin: CGPoint) {
        place(at: CGPoint(x: origin.x + CGFloat(frame.x), y: origin.y + CGFloat(frame.y)),
              anchor: .topLeading,
              proposal: ProposedViewSize(width: CGFloat(max(0, frame.width)), height: CGFloat(max(0, frame.height))))
    }
}

// MARK: - Box

/// One node's frame: its size rules, padding and baseline, around its
/// content (the only subview).
struct NodeBoxLayout: Layout {
    /// The content's natural size, when the node type fixes it.
    enum Intrinsic: Equatable {
        /// Ask the content (text, containers, SF Symbols).
        case measured
        /// Bars, sparklines, dividers, spacers, font icons.
        case fixed(width: Double, height: Double)
        /// Rings: `width` wide by default, as tall as wide.
        case square(Double)
    }

    var spec: NodeSpec
    var intrinsic: Intrinsic

    static var layoutProperties: LayoutProperties { LayoutProperties() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = width(proposed: finite(proposal.width), subviews)
        let h = height(proposed: finite(proposal.height), width: w, subviews)
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let inner = innerRect(bounds)
        content.place(at: inner.origin, anchor: .topLeading, proposal: ProposedViewSize(inner.size))
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline, spec.hasBaseline, let content = subviews.first else { return nil }
        let inner = innerRect(bounds)
        return inner.minY + content.dimensions(in: ProposedViewSize(inner.size))[.firstTextBaseline]
    }

    private func innerRect(_ bounds: CGRect) -> CGRect {
        let p = spec.padding
        return CGRect(x: bounds.minX + p.left, y: bounds.minY + p.top,
                      width: max(0, bounds.width - p.horizontal), height: max(0, bounds.height - p.vertical))
    }

    /// Exact for a number; otherwise what the parent proposes, or the fit
    /// width when it proposes nothing.
    private func width(proposed: Double?, _ subviews: Subviews) -> Double {
        if case .points(let w)? = spec.width { return spec.clampWidth(w) }
        if let proposed { return proposed }
        return spec.clampWidth(contentWidth(subviews) + spec.padding.horizontal)
    }

    private func height(proposed: Double?, width: Double, _ subviews: Subviews) -> Double {
        if case .points(let h)? = spec.height { return spec.clampHeight(h) }
        if let proposed { return proposed }
        let inner = max(0, width - spec.padding.horizontal)
        return spec.clampHeight(contentHeight(forWidth: inner, subviews) + spec.padding.vertical)
    }

    private func contentWidth(_ subviews: Subviews) -> Double {
        switch intrinsic {
        case .fixed(let w, _): return w
        case .square(let w): return w
        case .measured:
            guard let content = subviews.first else { return 0 }
            return Double(content.sizeThatFits(.unspecified).width)
        }
    }

    private func contentHeight(forWidth width: Double, _ subviews: Subviews) -> Double {
        switch intrinsic {
        case .fixed(_, let h): return h
        case .square: return width
        case .measured:
            guard let content = subviews.first else { return 0 }
            return Double(content.sizeThatFits(ProposedViewSize(width: CGFloat(width), height: nil)).height)
        }
    }
}

// MARK: - Stack

struct StackLayout: Layout {
    var stack: RenderNode.Stack

    static var layoutProperties: LayoutProperties { LayoutProperties() }

    struct Arrangement {
        var frames: [NodeFrame]
        var height: Double
        var baseline: Double?
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = finite(proposal.width) ?? naturalWidth(subviews)
        let h = finite(proposal.height) ?? arrange(subviews, width: w, height: nil).height
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(subviews, width: Double(bounds.width), height: Double(bounds.height))
        for (child, frame) in zip(subviews, layout.frames) { child.place(frame, from: bounds.origin) }
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline else { return nil }
        let layout = arrange(subviews, width: Double(bounds.width), height: Double(bounds.height))
        return layout.baseline.map { bounds.minY + CGFloat($0) }
    }

    private func gapBefore(_ index: Int, _ subviews: Subviews) -> Double {
        index == 0 ? 0 : (subviews[index].spec.spaceBefore ?? stack.gap)
    }

    private func alignment(_ child: LayoutSubview) -> RenderAlign {
        child.spec.alignSelf ?? stack.align
    }

    func naturalWidth(_ subviews: Subviews) -> Double {
        if stack.axis == .h {
            var total = 0.0
            for (i, child) in subviews.enumerated() { total += gapBefore(i, subviews) + child.fitWidth }
            return total
        }
        return subviews.map(\.fitWidth).max() ?? 0
    }

    /// Frames of the children in a content box `width` wide and, when
    /// placing, `height` tall (nil while measuring).
    func arrange(_ subviews: Subviews, width: Double, height: Double?) -> Arrangement {
        stack.axis == .h ? arrangeRow(subviews, width: width, height: height)
            : arrangeColumn(subviews, width: width, height: height)
    }

    private func arrangeRow(_ subviews: Subviews, width: Double, height: Double?) -> Arrangement {
        let n = subviews.count
        guard n > 0 else { return Arrangement(frames: [], height: 0, baseline: nil) }
        var widths = [Double](repeating: 0, count: n)
        var fills: [Int] = []
        var used = 0.0
        for (i, child) in subviews.enumerated() {
            used += gapBefore(i, subviews)
            if child.spec.fillsWidth {
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
                widths[i] = subviews[i].spec.clampWidth(share)
                remaining -= widths[i]
            }
        } else if remaining < 0 {
            // Overflow: texts with a line limit give way, down to their
            // minimum, in proportion to what each can give.
            let shrinkable = subviews.indices.filter { subviews[$0].spec.truncates && subviews[$0].spec.width == nil }
            let capacity = shrinkable.map { max(0, widths[$0] - subviews[$0].spec.minimumWidth) }
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
        for (i, child) in subviews.enumerated() {
            heights[i] = child.fitHeight(forWidth: widths[i])
            baselines[i] = child.baseline(forWidth: widths[i])
        }
        let stretches: (Int) -> Bool = { i in
            subviews[i].spec.fillsHeight || self.alignment(subviews[i]) == .stretch
        }
        // The row's own height: its offer, or its tallest child (baseline
        // children counted as ascent plus descent).
        var ascent = 0.0, descent = 0.0, tallest = 0.0
        for i in 0..<n {
            if alignment(subviews[i]) == .baseline, let b = baselines[i] {
                ascent = max(ascent, b)
                descent = max(descent, heights[i] - b)
            } else {
                tallest = max(tallest, heights[i])
            }
        }
        let natural = max(tallest, ascent + descent)
        let rowHeight = height ?? natural

        var frames: [NodeFrame] = []
        var x = 0.0
        var extraGap = 0.0
        if fills.isEmpty, remaining > 0 {
            switch stack.justify {
            case .start: break
            case .center: x = remaining / 2
            case .end: x = remaining
            case .between: extraGap = n > 1 ? remaining / Double(n - 1) : 0
            }
        }
        var baseline: Double?
        for (i, child) in subviews.enumerated() {
            if i > 0 { x += gapBefore(i, subviews) + extraGap }
            var h = heights[i]
            if stretches(i) { h = child.spec.clampHeight(rowHeight) }
            let y: Double
            switch alignment(child) {
            case .start, .stretch: y = 0
            case .center: y = (rowHeight - h) / 2
            case .end: y = rowHeight - h
            case .baseline:
                if let b = baselines[i] { y = ascent - b + max(0, (rowHeight - natural) / 2) } else { y = (rowHeight - h) / 2 }
            }
            if baseline == nil, let b = baselines[i] { baseline = y + b }
            frames.append(NodeFrame(x: x, y: y, width: widths[i], height: h))
            x += widths[i]
        }
        return Arrangement(frames: frames, height: natural, baseline: baseline)
    }

    private func arrangeColumn(_ subviews: Subviews, width: Double, height: Double?) -> Arrangement {
        let n = subviews.count
        guard n > 0 else { return Arrangement(frames: [], height: 0, baseline: nil) }
        var widths = [Double](repeating: 0, count: n)
        var heights = [Double](repeating: 0, count: n)
        var fills: [Int] = []
        var used = 0.0
        for (i, child) in subviews.enumerated() {
            used += gapBefore(i, subviews)
            if child.spec.fillsWidth || alignment(child) == .stretch {
                widths[i] = child.spec.clampWidth(width)
            } else {
                widths[i] = child.offeredWidth(width)
            }
            if child.spec.fillsHeight, height != nil {
                fills.append(i)
            } else {
                heights[i] = child.fitHeight(forWidth: widths[i])
                used += heights[i]
            }
        }
        var remaining = (height ?? used) - used
        if !fills.isEmpty {
            let share = max(0, remaining) / Double(fills.count)
            for i in fills {
                heights[i] = subviews[i].spec.clampHeight(share)
                remaining -= heights[i]
            }
        }
        var y = 0.0
        var extraGap = 0.0
        if fills.isEmpty, remaining > 0 {
            switch stack.justify {
            case .start: break
            case .center: y = remaining / 2
            case .end: y = remaining
            case .between: extraGap = n > 1 ? remaining / Double(n - 1) : 0
            }
        }
        var frames: [NodeFrame] = []
        var baseline: Double?
        for (i, child) in subviews.enumerated() {
            if i > 0 { y += gapBefore(i, subviews) + extraGap }
            let x: Double
            switch alignment(child) {
            case .start, .stretch, .baseline: x = 0
            case .center: x = (width - widths[i]) / 2
            case .end: x = width - widths[i]
            }
            if baseline == nil, let b = child.baseline(forWidth: widths[i]) { baseline = y + b }
            frames.append(NodeFrame(x: x, y: y, width: widths[i], height: heights[i]))
            y += heights[i]
        }
        return Arrangement(frames: frames, height: y, baseline: baseline)
    }
}

// MARK: - Grid

struct GridLayout: Layout {
    var grid: RenderNode.Grid

    static var layoutProperties: LayoutProperties { LayoutProperties() }

    private var columns: [RenderNode.Grid.Column] {
        grid.columns.isEmpty ? [RenderNode.Grid.Column()] : grid.columns
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = finite(proposal.width)
            ?? columnWidths(subviews, width: nil).reduce(0, +) + grid.gap * Double(max(0, columns.count - 1))
        let h = finite(proposal.height) ?? arrange(subviews, width: w).height
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(subviews, width: Double(bounds.width))
        for (child, frame) in zip(subviews, layout.frames) { child.place(frame, from: bounds.origin) }
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline else { return nil }
        return arrange(subviews, width: Double(bounds.width)).baseline.map { bounds.minY + CGFloat($0) }
    }

    /// Row and first column of each child, honoring `span`.
    private func cells(_ subviews: Subviews) -> [(row: Int, column: Int, span: Int)] {
        let count = columns.count
        var cells: [(Int, Int, Int)] = []
        var row = 0, column = 0
        for child in subviews {
            let span = min(max(1, child.spec.span), count)
            if column + span > count { row += 1; column = 0 }
            cells.append((row, column, span))
            column += span
            if column >= count { row += 1; column = 0 }
        }
        return cells
    }

    /// Column widths for a content width (nil: natural widths). A cell with
    /// `span` > 1 doesn't count towards a fit column (rule 8).
    private func columnWidths(_ subviews: Subviews, width: Double?) -> [Double] {
        let columns = self.columns
        var widest = [Double](repeating: 0, count: columns.count)
        for (child, cell) in zip(subviews, cells(subviews)) where cell.span == 1 {
            widest[cell.column] = max(widest[cell.column], child.fitWidth)
        }
        var widths = [Double](repeating: 0, count: columns.count)
        var fills: [Int] = []
        var used = grid.gap * Double(max(0, columns.count - 1))
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

    func arrange(_ subviews: Subviews, width: Double) -> StackLayout.Arrangement {
        let columns = self.columns
        let widths = columnWidths(subviews, width: width)
        let cells = self.cells(subviews)
        var xs: [Double] = []
        var x = 0.0
        for w in widths { xs.append(x); x += w + grid.gap }

        let n = subviews.count
        var frames = [NodeFrame](repeating: .zero, count: n)
        var rowHeights: [Int: Double] = [:]
        var cellHeights = [Double](repeating: 0, count: n)
        var baselines = [Double?](repeating: nil, count: n)
        for (i, (child, cell)) in zip(subviews, cells).enumerated() {
            let cellWidth = widths[cell.column..<(cell.column + cell.span)].reduce(0, +) + grid.gap * Double(cell.span - 1)
            let w = child.spec.fillsWidth || child.spec.alignSelf == .stretch
                ? child.spec.clampWidth(cellWidth) : child.offeredWidth(cellWidth)
            let h = child.fitHeight(forWidth: w)
            cellHeights[i] = h
            baselines[i] = child.baseline(forWidth: w)
            if !child.spec.fillsHeight { rowHeights[cell.row] = max(rowHeights[cell.row] ?? 0, h) }
            let align: RenderTextAlign
            switch child.spec.alignSelf {
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
            frames[i] = NodeFrame(x: xs[cell.column] + offset, y: 0, width: w, height: h)
        }
        // A row holding only fill-height cells is as tall as the tallest of
        // their natural heights.
        for (i, (child, cell)) in zip(subviews, cells).enumerated()
        where child.spec.fillsHeight && rowHeights[cell.row] == nil {
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
            y += (rowHeights[row] ?? 0) + (row < rows - 1 ? grid.rowGap : 0)
        }
        var baseline: Double?
        for (i, (child, cell)) in zip(subviews, cells).enumerated() {
            let rowHeight = rowHeights[cell.row] ?? cellHeights[i]
            if child.spec.fillsHeight { frames[i].height = child.spec.clampHeight(rowHeight) }
            frames[i].y = ys[cell.row] + (rowHeight - frames[i].height) / 2
            if baseline == nil, let b = baselines[i] { baseline = frames[i].y + b }
        }
        return StackLayout.Arrangement(frames: frames, height: y, baseline: baseline)
    }
}

// MARK: - Ring

/// A ring's drawing (the first subview) over its whole box, and its
/// `center` node (the second, if any) centered inside.
struct RingLayout: Layout {
    static var layoutProperties: LayoutProperties { LayoutProperties() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // The box always proposes a size; 40 is the ring's natural one.
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 40, height: 40))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let drawing = subviews.first else { return }
        drawing.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        guard subviews.count > 1 else { return }
        let center = subviews[1]
        let inner = (width: Double(bounds.width), height: Double(bounds.height))
        let w = center.spec.fillsWidth ? center.spec.clampWidth(inner.width) : center.offeredWidth(inner.width)
        let h = center.spec.fillsHeight ? center.spec.clampHeight(inner.height) : center.fitHeight(forWidth: w)
        center.place(NodeFrame(x: (inner.width - w) / 2, y: (inner.height - h) / 2, width: w, height: h), from: bounds.origin)
    }
}

// MARK: - Stage

/// What a stage subview is: the view's tree, the popup's scrim, or its card.
enum StageRole: Equatable {
    case root
    case scrim
    case card(width: Double)
}

struct StageRoleKey: LayoutValueKey {
    static let defaultValue = StageRole.root
}

/// The window's content: the root node
/// `min(maxWidth, window width)` wide, centered both ways, and top-aligned
/// (cut at the bottom) when taller than the window; the scrim over the whole
/// window; the popup's card at the popup's width, centered.
struct StageLayout: Layout {
    static var layoutProperties: LayoutProperties { LayoutProperties() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 1512, height: 982))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = Double(bounds.width), height = Double(bounds.height)
        for child in subviews {
            switch child[StageRoleKey.self] {
            case .root:
                child.place(Self.rootFrame(child, width: width, height: height), from: bounds.origin)
            case .scrim:
                child.place(NodeFrame(x: 0, y: 0, width: width, height: height), from: bounds.origin)
            case .card(let popupWidth):
                let w = min(popupWidth, width)
                let h = min(child.fitHeight(forWidth: w), height)
                child.place(NodeFrame(x: (width - w) / 2, y: (height - h) / 2, width: w, height: h), from: bounds.origin)
            }
        }
    }

    static func rootFrame(_ root: LayoutSubview, width: Double, height: Double) -> NodeFrame {
        let spec = root.spec
        let w: Double
        switch spec.width {
        case .points(let fixed)?: w = spec.clampWidth(fixed)
        default: w = spec.clampWidth(width)
        }
        var h: Double
        switch spec.height {
        case .points(let fixed)?: h = fixed
        case .fill?: h = height
        case nil: h = root.fitHeight(forWidth: w)
        }
        h = spec.clampHeight(h)
        // Taller than the window: top-aligned, cut at the bottom (rule 9).
        let y = h > height ? 0 : (height - h) / 2
        return NodeFrame(x: (width - w) / 2, y: y, width: w, height: h)
    }
}
#endif
