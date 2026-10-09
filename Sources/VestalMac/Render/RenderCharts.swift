#if os(macOS)
import AppKit
import SwiftUI
import VestalCore

// MARK: - Chart drawings
//
// The drawing of `bars`, `stackedBar`, `heatmap`, `timeline` and `image`
// nodes, after the GTK UI's (VestalLinux/NodeView.swift, MARK: Charts),
// which does the same arithmetic. Every colour arrives resolved; the labels
// of bars and the legend of a stacked bar are text nodes of their own.

// MARK: - Bars

/// Columns from the left edge, bottom-aligned, `value / max` tall (at least
/// one point when above zero), with the corners rounded by 2.
struct BarsDrawing: View {
    let bars: RenderNode.Bars
    let style: RenderStyle

    var body: some View {
        Canvas { context, size in
            let count = bars.values.count
            guard count > 0, size.width > 0, size.height > 0 else { return }
            let gap = CGFloat(bars.gap)
            let width = bars.barWidth.map { CGFloat($0) } ?? max(0, (size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            let top = bars.max > 0 ? bars.max : 1
            for (index, value) in bars.values.enumerated() {
                let fraction = min(max(value / top, 0), 1)
                guard fraction > 0 else { continue }
                let height = max(1, size.height * CGFloat(fraction))
                let rect = CGRect(x: CGFloat(index) * (width + gap), y: size.height - height, width: width, height: height)
                let color = style.color(index < bars.colors.count ? bars.colors[index] : nil, default: "accent")
                context.fill(RoundedRectangle(cornerRadius: min(2, width / 2, height / 2)).path(in: rect), with: .color(color))
            }
        }
    }
}

// MARK: - Stacked bar

/// A track with the segments from the left edge, all inside one rounded
/// shape.
struct StackedBarDrawing: View {
    let bar: RenderNode.StackedBar
    let style: RenderStyle

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let radius = min(CGFloat(bar.radius), size.height / 2, size.width / 2)
            let shape = RoundedRectangle(cornerRadius: radius).path(in: CGRect(origin: .zero, size: size))
            context.fill(shape, with: .color(style.color(bar.trackColor)))
            context.clip(to: shape)
            var x: CGFloat = 0
            for segment in bar.segments {
                let width = size.width * CGFloat(min(max(segment.value, 0), 1))
                guard width > 0 else { continue }
                context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(style.color(segment.color)))
                x += width
            }
        }
    }
}

// MARK: - Heatmap

/// Square cells in a grid; an empty cell is drawn in the track colour.
struct HeatmapDrawing: View {
    let heatmap: RenderNode.Heatmap
    let style: RenderStyle

    var body: some View {
        Canvas { context, _ in
            let cell = CGFloat(heatmap.cell), gap = CGFloat(heatmap.gap)
            let radius = min(CGFloat(heatmap.radius), cell / 2)
            let track = style.color(heatmap.trackColor)
            for (index, spec) in heatmap.cells.enumerated() {
                let (column, row) = heatmap.position(of: index)
                let rect = CGRect(x: CGFloat(column) * (cell + gap), y: CGFloat(row) * (cell + gap), width: cell, height: cell)
                context.fill(RoundedRectangle(cornerRadius: radius).path(in: rect), with: .color(spec.map { style.color($0) } ?? track))
            }
        }
    }
}

// MARK: - Timeline

/// Items on lanes above a time axis with tick labels, and a line at the
/// current time. An item's label is drawn inside its bar, cut with an ellipsis when it
/// doesn't fit and omitted when not even a letter does;
/// a tick label only when it clears the previous one.
struct TimelineDrawing: View {
    let timeline: RenderNode.Timeline
    let style: RenderStyle

    static let labelHeight: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let width = size.width
            let axisY = timeline.ticks.isEmpty ? size.height : max(0, size.height - Self.labelHeight)
            let area = max(0, axisY - 2)
            let lanes = CGFloat(max(timeline.lanes, 1))
            let laneGap: CGFloat = 2
            let laneHeight = max(1, (area - laneGap * (lanes - 1)) / lanes)

            let grid = style.color("dim@0.3")
            for tick in timeline.ticks {
                let x = (CGFloat(tick.at) * width).rounded() + 0.25
                context.fill(Path(CGRect(x: x - 0.25, y: 0, width: 0.5, height: area)), with: .color(grid))
            }

            for item in timeline.items {
                let x0 = CGFloat(item.start) * width
                let top = CGFloat(item.lane) * (laneHeight + laneGap)
                let color = style.color(item.color)
                guard let end = item.end else {
                    let r = min(laneHeight / 2, 4)
                    context.fill(Path(ellipseIn: CGRect(x: x0 - r, y: top + laneHeight / 2 - r, width: 2 * r, height: 2 * r)),
                                 with: .color(color))
                    continue
                }
                let barWidth = max(CGFloat(end) * width - x0, 3)
                let rect = CGRect(x: x0, y: top, width: barWidth, height: laneHeight)
                context.fill(RoundedRectangle(cornerRadius: min(3, laneHeight / 2, barWidth / 2)).path(in: rect), with: .color(color))
                let room = barWidth - 12
                if let label = item.label, !label.isEmpty, laneHeight >= 12, room >= 14 {
                    // Whole when it fits, else cut with an ellipsis at the bar's padding.
                    let font = style.font(role: "sans", size: 10, weight: 500)
                    func resolved(_ string: String) -> (GraphicsContext.ResolvedText, CGFloat) {
                        let text = context.resolve(Text(string).font(font).foregroundStyle(style.color("bg")))
                        return (text, text.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width)
                    }
                    var (text, measured) = resolved(label)
                    var characters = Array(label)
                    while measured > room, characters.count > 1 {
                        characters.removeLast()
                        (text, measured) = resolved(String(characters).trimmingCharacters(in: .whitespaces) + "…")
                    }
                    if measured <= room {
                        context.draw(text, at: CGPoint(x: x0 + 6, y: top + laneHeight / 2), anchor: .leading)
                    }
                }
            }

            if let now = timeline.now {
                let x = CGFloat(now) * width
                context.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: area)), with: .color(style.color(timeline.nowColor)))
            }

            var right: CGFloat = -.infinity
            for tick in timeline.ticks where !tick.label.isEmpty {
                let text = context.resolve(Text(tick.label).font(style.font(role: "sans", size: 9, weight: 400))
                    .foregroundStyle(style.color("dim")))
                let measured = text.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
                var left = CGFloat(tick.at) * width - measured.width / 2
                left = min(max(left, 0), max(0, width - measured.width))
                guard left >= right + 4 else { continue }
                context.draw(text, at: CGPoint(x: left, y: axisY + Self.labelHeight / 2), anchor: .leading)
                right = left + measured.width
            }
        }
    }
}

// MARK: - Image

/// A picture from a local file, clipped to its corner radius; without a
/// readable file, an empty rounded rectangle in the track colour.
struct ImageDrawing: View {
    let image: RenderNode.Image
    let style: RenderStyle

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(image.radius))
        if let picture = ImageFiles.load(image.path) {
            Image(nsImage: picture)
                .resizable()
                .aspectRatio(contentMode: image.fit == "contain" ? .fit : .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(shape)
        } else {
            shape.fill(style.color("track"))
        }
    }
}

/// Decoded pictures by path, replaced when the file's date changes.
enum ImageFiles {
    private final class Entry {
        let image: NSImage
        let modified: Date?
        init(image: NSImage, modified: Date?) { self.image = image; self.modified = modified }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 64
        return cache
    }()

    static func load(_ path: String?) -> NSImage? {
        guard let path else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let entry = cache.object(forKey: path as NSString), entry.modified == modified { return entry.image }
        guard let image = NSImage(contentsOfFile: path), image.isValid else { return nil }
        cache.setObject(Entry(image: image, modified: modified), forKey: path as NSString)
        return image
    }
}
#endif
