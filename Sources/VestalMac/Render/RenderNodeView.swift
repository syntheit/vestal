#if os(macOS)
import SwiftUI
import VestalCore

// MARK: - Node views
//
// One SwiftUI view per render-model node (§10.3): the box (`NodeBoxLayout`
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
            // A newer node type: its plain-text rendition (§10.1).
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
            // is centred in a size×size box.
            return RenderIcon.drawsSymbol(icon, style: style) ? .measured : .fixed(width: icon.size, height: icon.size)
        case .bar: return .fixed(width: 48, height: 6)
        case .ring: return .square(40)
        case .spark: return .fixed(width: 60, height: 20)
        case .divider(let d): return d.axis == .v ? .fixed(width: d.thickness, height: 0) : .fixed(width: 0, height: d.thickness)
        case .spacer(let s):
            return .fixed(width: parentAxis == .h ? s.min : 0, height: parentAxis == .v ? s.min : 0)
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

/// One run of text: font role, size and weight, colour, tracking, a line
/// limit truncating at the tail, and its alignment in the node's box
/// (vertically centred, like a GtkLabel).
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
            .multilineTextAlignment(multiline)
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

/// An icon: an SF Symbol where §16.1's mapping (or an `sf:` name) gives
/// one, else the glyph in the Phosphor font, centred in a size×size box.
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
/// above or below it. Tracks default to the colour at 15%, the overlay to
/// white at 20% (v0.3's MiniBar).
struct BarDrawing: View {
    let bar: RenderNode.Bar
    let style: RenderStyle

    var body: some View {
        let color = style.color(bar.color, default: "accent")
        let track = bar.trackColor.map { style.color($0) } ?? style.rgba(bar.color, default: "accent").withAlpha(0.15).color
        let overlay = bar.overlayColor.map { style.color($0) } ?? Color(white: 1, opacity: 0.2)
        Canvas { context, size in
            let radius = min(CGFloat(bar.radius), size.height / 2)
            func segment(_ fraction: Double, _ c: Color) {
                let f = min(max(fraction, 0), 1)
                guard f > 0 else { return }
                let rect = CGRect(x: 0, y: 0, width: size.width * CGFloat(f), height: size.height)
                context.fill(RoundedRectangle(cornerRadius: radius).path(in: rect), with: .color(c))
            }
            segment(1, track)
            if let o = bar.overlay, bar.overlayPosition == "below" { segment(o, overlay) }
            segment(bar.value, color)
            if let o = bar.overlay, bar.overlayPosition != "below" { segment(o, overlay) }
        }
    }
}

// MARK: - Ring

/// An arc track of `sweep` degrees with its gap centred at the bottom, and
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
            let radius = max(0, (side - CGFloat(ring.thickness)) / 2)
            let sweep = min(max(ring.sweep, 0), 360) * .pi / 180
            // Angles grow clockwise on screen (y down); 90° points straight
            // down, so the gap is centred at the bottom.
            let start = Double.pi / 2 + (2 * .pi - sweep) / 2
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
            let inset = spark.strokeWidth / 2 + (spark.dot ? spark.strokeWidth : 0)
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
            if spark.dot {
                let last = point(values.count - 1)
                let r = CGFloat(spark.strokeWidth * 1.5)
                context.fill(Path(ellipseIn: CGRect(x: last.x - r, y: last.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(color))
            }
        }
    }
}

// MARK: - Divider

/// A rule `thickness` thick, centred across its box: `h` fills the width,
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
