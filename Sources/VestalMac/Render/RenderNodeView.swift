#if os(macOS)
import SwiftUI
import VestalCore

// MARK: - Node views
//
// One SwiftUI view per render-model node: the box (`NodeBoxLayout`
// with background, border, radius, clip, opacity and the click target)
// around the type's content. Containers lay out their children with the
// layouts in RenderLayout.swift; texts, icons, bars, rings, sparklines and
// dividers draw themselves. The drawing follows the GTK UI's, and the
// v0.3 SwiftUI widgets where they set the look (RoundedRectangle bars, the
// system font, SF Symbols for icons).

struct RenderNodeView: View {
    @ObservedObject var handle: NodeHandle
    /// The parent stack's axis, for a spacer's `min`.
    var parentAxis: RenderAxis?

    @Environment(\.renderStyle) private var style
    @Environment(\.renderSend) private var send
    @Environment(\.renderFrames) private var frames

    var body: some View {
        let node = handle.node
        NodeBoxLayout(spec: handle.spec, intrinsic: intrinsic(node)) {
            content(node)
        }
        .background {
            if let frames { FrameProbe(handle: handle, collector: frames) }
        }
        .modifier(NodeChrome(node: node, style: style, send: send))
        .layoutValue(key: NodeSpecKey.self, value: handle.spec)
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ node: RenderNode) -> some View {
        switch node.content {
        case .stack(let s):
            StackLayout(stack: s) {
                ForEach(handle.children) { RenderNodeView(handle: $0, parentAxis: s.axis) }
            }
        case .grid(let g):
            GridLayout(grid: g) {
                ForEach(handle.children) { RenderNodeView(handle: $0, parentAxis: nil) }
            }
        case .text(let t):
            RenderText(text: t, style: style)
        case .unknown:
            // A newer node type: its plain-text rendition.
            RenderText(text: RenderNode.Text(text: node.alt ?? "", color: "subtle"), style: style)
        case .icon(let icon):
            RenderIcon(icon: icon, style: style)
        case .bar(let bar):
            BarDrawing(bar: bar, style: style)
        case .ring(let ring):
            RingLayout {
                RingDrawing(ring: ring, style: style)
                ForEach(handle.children) { RenderNodeView(handle: $0, parentAxis: nil) }
            }
        case .spark(let spark):
            SparkDrawing(spark: spark, style: style)
        case .divider(let divider):
            DividerDrawing(divider: divider, style: style)
        case .spacer:
            Color.clear
        case .bars(let bars):
            BarsDrawing(bars: bars, style: style)
        case .stackedBar(let bar):
            StackedBarDrawing(bar: bar, style: style)
        case .heatmap(let heatmap):
            HeatmapDrawing(heatmap: heatmap, style: style)
        case .timeline(let timeline):
            TimelineDrawing(timeline: timeline, style: style)
        case .image(let image):
            ImageDrawing(image: image, style: style)
        case .analog(let analog):
            AnalogDrawing(analog: analog, style: style)
        case .flip(let flip):
            FlipDrawing(flip: flip, style: style)
        case .moon(let moon):
            MoonDrawing(moon: moon, style: style)
        }
    }

    /// The content's natural size where the type fixes it. A bar with no
    /// width is 48×6 (v0.3's mini bar), a ring 40, a spark 60×20, as on
    /// Linux.
    private func intrinsic(_ node: RenderNode) -> NodeBoxLayout.Intrinsic {
        switch node.content {
        case .stack, .grid, .text, .unknown: return .measured
        case .icon(let icon):
            // An SF Symbol keeps its own width, as v0.3's did; a font glyph
            // is centered in a size×size box.
            return RenderIcon.drawsSymbol(icon, style: style) ? .measured : .fixed(width: icon.size, height: icon.size)
        case .bar: return .fixed(width: 48, height: 6)
        case .ring: return .square(40)
        case .spark: return .fixed(width: 60, height: 20)
        case .divider(let d): return d.axis == .v ? .fixed(width: d.thickness, height: 0) : .fixed(width: 0, height: d.thickness)
        case .spacer(let s):
            return .fixed(width: parentAxis == .h ? s.min : 0, height: parentAxis == .v ? s.min : 0)
        // The core gives these a size; these are the fallbacks, as on Linux.
        case .bars: return .fixed(width: 160, height: 48)
        case .stackedBar: return .fixed(width: 60, height: 8)
        case .heatmap(let h):
            let columns = Double(h.columns), rows = Double(h.rows)
            return .fixed(width: columns * h.cell + max(0, columns - 1) * h.gap, height: rows * h.cell + max(0, rows - 1) * h.gap)
        case .timeline: return .fixed(width: 120, height: 36)
        case .image: return .fixed(width: 48, height: 48)
        case .analog(let a): return .fixed(width: a.size, height: a.size)
        case .flip(let f):
            let layout = f.layout
            return .fixed(width: layout.width, height: layout.height)
        case .moon(let m): return .fixed(width: m.size, height: m.size)
        }
    }
}

// MARK: - Box chrome

/// Background, border and radius paint the padded frame (rule 4); `clip`
/// clips the subtree to it; `opacity` multiplies the subtree as one layer;
/// `action` makes the whole frame a click target that sends `invoke`.
private struct NodeChrome: ViewModifier {
    let node: RenderNode
    let style: RenderStyle
    let send: (RenderInput) -> Void

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(node.radius))
        let boxed = content.background {
            if node.background != nil || node.border != nil {
                ZStack {
                    if let background = node.background { shape.fill(style.color(background)) }
                    if let border = node.border, border.width > 0 {
                        shape.strokeBorder(style.color(border.color), lineWidth: CGFloat(border.width))
                    }
                }
            }
        }
        let clipped = boxed.modifier(ClipToBox(shape: node.clip ? shape : nil))
        let faded = clipped.modifier(SubtreeOpacity(opacity: node.opacity))
        if node.action {
            let id = node.id
            faded.contentShape(Rectangle()).onTapGesture { send(.invoke(id: id)) }
        } else {
            faded
        }
    }
}

/// `clip`: the subtree is cut at the (rounded) frame.
private struct ClipToBox: ViewModifier {
    let shape: RoundedRectangle?

    func body(content: Content) -> some View {
        if let shape {
            content.clipShape(shape)
        } else {
            content
        }
    }
}

/// `opacity` below 1 fades the subtree as one layer, as GTK does.
private struct SubtreeOpacity: ViewModifier {
    let opacity: Double

    func body(content: Content) -> some View {
        if opacity < 1 {
            content.compositingGroup().opacity(max(0, opacity))
        } else {
            content
        }
    }
}

// MARK: - Text

/// One run of text: font role, size and weight, color, tracking, a line
/// limit truncating at the tail, and its alignment in the node's box
/// (vertically centered, like a GtkLabel).
struct RenderText: View {
    let text: RenderNode.Text
    let style: RenderStyle

    var body: some View {
        let lines = text.lines.map { max(1, $0) }
        Text(text.text)
            .font(style.font(role: text.font, size: text.size, weight: text.weight))
            .tracking(CGFloat(text.tracking))
            .foregroundStyle(style.color(text.color))
            .lineLimit(lines)
            .truncationMode(.tail)
            // One line is placed by the frame's alignment, which SwiftUI
            // snaps to the pixel grid as v0.3's `.frame(width:alignment:)`
            // did; a multiline alignment would place it unsnapped.
            .multilineTextAlignment(lines == 1 ? .leading : multiline)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
    }

    private var multiline: TextAlignment {
        switch text.textAlign {
        case .start: return .leading
        case .center: return .center
        case .end: return .trailing
        }
    }

    private var frameAlignment: Alignment {
        switch text.textAlign {
        case .start: return .leading
        case .center: return .center
        case .end: return .trailing
        }
    }
}

// MARK: - Icon

/// An icon: an SF Symbol where the native mapping (or an `sf:` name) gives
/// one, else the glyph in the Phosphor font, centered in a size×size box.
/// `circle` filled is v0.3's offline dot, a circle of the icon's size.
struct RenderIcon: View {
    let icon: RenderNode.Icon
    let style: RenderStyle

    /// Whether the icon draws as an SF Symbol (and so sizes itself).
    static func drawsSymbol(_ icon: RenderNode.Icon, style: RenderStyle) -> Bool {
        if isDot(icon, style: style) { return false }
        return MainActor.assumeIsolated { NativeIcons.symbol(for: icon, mode: style.iconMode) != nil }
    }

    private static func isDot(_ icon: RenderNode.Icon, style: RenderStyle) -> Bool {
        style.iconMode == .native && icon.name == "circle" && icon.weight == "fill"
    }

    var body: some View {
        let color = style.color(icon.color)
        let size = CGFloat(icon.size)
        if Self.isDot(icon, style: style) {
            Circle().fill(color).frame(width: size, height: size)
        } else if let symbol = NativeIcons.symbol(for: icon, mode: style.iconMode) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let glyph = icon.glyph, !glyph.isEmpty {
            Text(glyph)
                .font(.custom(style.theme.icons.fonts[icon.weight] ?? (icon.weight == "fill" ? "Phosphor-Fill" : "Phosphor"),
                              fixedSize: size))
                .foregroundStyle(color)
                .fixedSize()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // An `sf:` name this macOS lacks: nothing, as off macOS.
            Color.clear
        }
    }
}

// MARK: - Bar

/// A rounded track, then the fill from the leading edge, with the overlay
/// above or below it. Tracks default to the color at 15%, the overlay to
/// white at 20% (v0.3's MiniBar).
struct BarDrawing: View {
    let bar: RenderNode.Bar
    let style: RenderStyle
    /// Segment widths snap to device pixels, as v0.3's `.frame(width:)`
    /// did (SwiftUI rounds frames to the pixel grid).
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let color = style.color(bar.color, default: "accent")
        let track = bar.trackColor.map { style.color($0) } ?? style.rgba(bar.color, default: "accent").withAlpha(0.15).color
        let overlay = bar.overlayColor.map { style.color($0) } ?? Color(white: 1, opacity: 0.2)
        // The tick overhangs the bar above and below: the canvas grows by that
        // much on both sides (negative padding keeps the layout box), and the
        // bar is drawn between.
        let overhang = CGFloat(max(bar.tickOverhang, 0))
        Canvas { context, canvas in
            let size = CGSize(width: canvas.width, height: canvas.height - 2 * overhang)
            let radius = min(CGFloat(bar.radius), size.height / 2)
            func segment(_ fraction: Double, _ c: Color, from: Double = 0, gradient: [Color]? = nil) {
                let f = min(max(fraction, 0), 1)
                guard f > from else { return }
                let scale = max(displayScale, 1)
                let x = from > 0 ? (size.width * CGFloat(from) * scale).rounded() / scale : 0
                let rect = CGRect(x: x, y: overhang, width: (size.width * CGFloat(f) * scale).rounded() / scale - x, height: size.height)
                let path = RoundedRectangle(cornerRadius: radius).path(in: rect)
                if let gradient, gradient.count >= 2 {
                    context.fill(path, with: .linearGradient(Gradient(colors: gradient),
                                                             startPoint: CGPoint(x: rect.minX, y: rect.midY),
                                                             endPoint: CGPoint(x: rect.maxX, y: rect.midY)))
                } else {
                    context.fill(path, with: .color(c))
                }
            }
            segment(1, track)
            if let o = bar.overlay, bar.overlayPosition == "below" { segment(o, overlay) }
            segment(bar.value, color, from: bar.start, gradient: bar.gradient?.map { style.color($0) })
            if let o = bar.overlay, bar.overlayPosition != "below" { segment(o, overlay) }
            if let tick = bar.tick {
                let x = size.width * CGFloat(min(max(tick, 0), 1))
                let width: CGFloat = 1.5
                let rect = CGRect(x: min(max(x - width / 2, 0), size.width - width), y: 0, width: width, height: canvas.height)
                context.fill(Path(rect), with: .color(bar.tickColor.map { style.color($0) } ?? Color(white: 1, opacity: 0.55)))
            }
        }
        .padding(.vertical, -overhang)
    }
}

// MARK: - Ring

/// An arc track of `sweep` degrees with its gap centered at the bottom, and
/// the fill arc with round caps.
struct RingDrawing: View {
    let ring: RenderNode.Ring
    let style: RenderStyle

    var body: some View {
        let color = style.color(ring.color, default: "accent")
        let track = ring.trackColor.map { style.color($0) } ?? style.rgba(ring.color, default: "accent").withAlpha(0.15).color
        Canvas { context, size in
            let side = min(size.width, size.height)
            guard side > 0 else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let geometry = RingGeometry(side: Double(side), ring: ring)
            let radius = CGFloat(geometry.radius)
            let sweep = geometry.sweep
            // Angles grow clockwise on screen (y down); 90° points straight
            // down, so the gap is centered at the bottom (a full circle
            // starts at the top).
            let start = geometry.start
            let stroke = StrokeStyle(lineWidth: CGFloat(ring.thickness), lineCap: .round)
            func arc(_ fraction: Double) -> Path {
                var path = Path()
                path.addArc(center: center, radius: radius, startAngle: .radians(start),
                            endAngle: .radians(start + sweep * fraction), clockwise: false)
                return path
            }
            context.stroke(arc(1), with: .color(track), style: stroke)
            let value = min(max(ring.value, 0), 1)
            if value > 0 { context.stroke(arc(value), with: .color(color), style: stroke) }
            if ring.ticks > 0 || ring.dot || !ring.labels.isEmpty {
                var marks = context
                RingMarks.draw(&marks, ring: ring, geometry: geometry, center: center, style: style)
            }
        }
    }
}

// MARK: - Spark

/// A polyline, x evenly spaced, y scaled to min…max (top = max), with an
/// optional fill to the bottom and a dot on the last value.
struct SparkDrawing: View {
    let spark: RenderNode.Spark
    let style: RenderStyle

    var body: some View {
        let color = style.color(spark.color, default: "accent")
        let fill = spark.fill.map { style.color($0) }
        Canvas { context, size in
            let values = spark.values
            guard values.count >= 2, size.width > 0, size.height > 0 else { return }
            let lo = spark.min ?? values.min()!, hi = spark.max ?? values.max()!
            let inset = spark.strokeWidth / 2 + (spark.dotAt != nil ? spark.strokeWidth * 2.5 : spark.dot ? spark.strokeWidth : 0)
            let plot = CGRect(x: inset, y: inset, width: max(0, Double(size.width) - 2 * inset),
                              height: max(0, Double(size.height) - 2 * inset))
            func point(_ i: Int) -> CGPoint {
                let x = plot.minX + plot.width * CGFloat(i) / CGFloat(values.count - 1)
                let t = hi > lo ? (min(max(values[i], lo), hi) - lo) / (hi - lo) : 0.5
                return CGPoint(x: x, y: plot.minY + plot.height * CGFloat(1 - t))
            }
            var line = Path()
            line.move(to: point(0))
            for i in 1..<values.count { line.addLine(to: point(i)) }
            if let fill {
                var area = Path()
                area.move(to: CGPoint(x: point(0).x, y: size.height))
                area.addLine(to: point(0))
                for i in 1..<values.count { area.addLine(to: point(i)) }
                area.addLine(to: CGPoint(x: point(values.count - 1).x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(fill))
            }
            context.stroke(line, with: .color(color),
                           style: StrokeStyle(lineWidth: CGFloat(spark.strokeWidth), lineCap: .round, lineJoin: .round))
            if let at = spark.dotAt {
                // Between two points, at a fraction of the width.
                let position = min(max(at, 0), 1) * Double(values.count - 1)
                let i = min(Int(position), values.count - 2)
                let a = point(i), b = point(i + 1)
                let t = CGFloat(position - Double(i))
                let r = CGFloat(spark.strokeWidth * 2.5)
                let x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t
                context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                             with: .color(spark.dotColor.map { style.color($0) } ?? color))
            } else if spark.dot {
                let last = point(values.count - 1)
                let r = CGFloat(spark.strokeWidth * 1.5)
                context.fill(Path(ellipseIn: CGRect(x: last.x - r, y: last.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(color))
            }
        }
    }
}

// MARK: - Divider

/// A rule `thickness` thick, centered across its box: `h` fills the width,
/// `v` the height.
struct DividerDrawing: View {
    let divider: RenderNode.Divider
    let style: RenderStyle

    var body: some View {
        let color = style.color(divider.color)
        Canvas { context, size in
            let t = CGFloat(divider.thickness)
            let rect = divider.axis == .h
                ? CGRect(x: 0, y: (size.height - t) / 2, width: size.width, height: t)
                : CGRect(x: (size.width - t) / 2, y: 0, width: t, height: size.height)
            context.fill(Path(rect), with: .color(color))
        }
    }
}
#endif
