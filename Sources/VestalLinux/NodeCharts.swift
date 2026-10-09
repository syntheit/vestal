#if os(Linux)
import CGtk4
import Foundation
import VestalCore

// MARK: - Charts
//
// The drawing of `bars`, `stackedBar`, `heatmap`, `timeline` and `image`
// nodes. The arithmetic is the macOS UI's (VestalMac/Render/RenderCharts.swift)
// line for line. Every color arrives resolved; the labels of bars and the
// legend of a stacked bar are text nodes of their own.

extension NodeView {
    /// The natural size of a chart node: what the core gave it, else these.
    static func chartSize(_ content: RenderNode.Content) -> (width: Double, height: Double)? {
        switch content {
        case .bars: return (160, 48)
        case .stackedBar: return (60, 8)
        case .heatmap(let h):
            let columns = Double(h.columns), rows = Double(h.rows)
            return (columns * h.cell + max(0, columns - 1) * h.gap, rows * h.cell + max(0, rows - 1) * h.gap)
        case .timeline: return (120, 36)
        case .image: return (48, 48)
        default: return nil
        }
    }

    // MARK: Bars

    func drawBars(_ snapshot: OpaquePointer, _ bars: RenderNode.Bars, _ box: Rect) {
        let count = bars.values.count
        guard count > 0, box.width > 0, box.height > 0 else { return }
        let theme = context.theme
        let width = bars.barWidth ?? max(0, (box.width - bars.gap * Double(count - 1)) / Double(count))
        let top = bars.max > 0 ? bars.max : 1
        for (index, value) in bars.values.enumerated() {
            let fraction = min(max(value / top, 0), 1)
            guard fraction > 0 else { continue }
            let height = max(1, box.height * fraction)
            let rect = Rect(x: box.x + Double(index) * (width + bars.gap), y: box.y + box.height - height, width: width, height: height)
            let color = theme.color(index < bars.colors.count ? bars.colors[index] : nil, default: "accent")
            fillRounded(snapshot, rect, radius: min(2, width / 2, height / 2), color: color)
        }
    }

    // MARK: Stacked bar

    func drawStackedBar(_ snapshot: OpaquePointer, _ bar: RenderNode.StackedBar, _ box: Rect) {
        guard box.width > 0, box.height > 0 else { return }
        let theme = context.theme
        pushRoundedClip(snapshot, box, radius: min(bar.radius, box.height / 2, box.width / 2))
        fillRounded(snapshot, box, radius: 0, color: theme.color(bar.trackColor))
        var x = box.x
        for segment in bar.segments {
            let width = box.width * min(max(segment.value, 0), 1)
            guard width > 0 else { continue }
            fillRounded(snapshot, Rect(x: x, y: box.y, width: width, height: box.height), radius: 0, color: theme.color(segment.color))
            x += width
        }
        gtk_snapshot_pop(snapshot)
    }

    // MARK: Heatmap

    func drawHeatmap(_ snapshot: OpaquePointer, _ heatmap: RenderNode.Heatmap, _ box: Rect) {
        let theme = context.theme
        let track = theme.color(heatmap.trackColor)
        let radius = min(heatmap.radius, heatmap.cell / 2)
        for (index, spec) in heatmap.cells.enumerated() {
            let (column, row) = heatmap.position(of: index)
            let rect = Rect(x: box.x + Double(column) * (heatmap.cell + heatmap.gap), y: box.y + Double(row) * (heatmap.cell + heatmap.gap),
                            width: heatmap.cell, height: heatmap.cell)
            fillRounded(snapshot, rect, radius: radius, color: spec.map { theme.color($0) } ?? track)
        }
    }

    // MARK: Timeline

    private static let tickLabelHeight = 12.0

    /// A one-line Pango layout in the sans role.
    private func chartLayout(_ text: String, size: Double, weight: Int) -> OpaquePointer? {
        let layout = gtk_widget_create_pango_layout(widget, text)
        let desc = pango_font_description_new()
        pango_font_description_set_family(desc, context.theme.family(role: "sans"))
        pango_font_description_set_absolute_size(desc, size * Double(PANGO_SCALE))
        pango_font_description_set_weight(desc, PangoWeight(rawValue: .init(clamping: context.theme.weight(weight))))
        pango_layout_set_font_description(layout, desc)
        pango_font_description_free(desc)
        return layout
    }

    private func chartLayoutSize(_ layout: OpaquePointer) -> (width: Double, height: Double) {
        var w: Int32 = 0, h: Int32 = 0
        pango_layout_get_pixel_size(layout, &w, &h)
        return (Double(w), Double(h))
    }

    /// Draws `layout` with its left edge at `x`, centered on `centerY`, and
    /// releases it.
    private func drawChartLayout(_ snapshot: OpaquePointer, _ layout: OpaquePointer, x: Double, centerY: Double, color: RGBA) {
        let size = chartLayoutSize(layout)
        gtk_snapshot_save(snapshot)
        var point = graphene_point_t(x: Float(x), y: Float(centerY - size.height / 2))
        gtk_snapshot_translate(snapshot, &point)
        var c = color.gdk
        gtk_snapshot_append_layout(snapshot, layout, &c)
        gtk_snapshot_restore(snapshot)
        g_object_unref(UnsafeMutableRawPointer(layout))
    }

    func drawTimeline(_ snapshot: OpaquePointer, _ timeline: RenderNode.Timeline, _ box: Rect) {
        guard box.width > 0, box.height > 0 else { return }
        let theme = context.theme
        let width = box.width
        let axisY = timeline.ticks.isEmpty ? box.height : max(0, box.height - Self.tickLabelHeight)
        let area = max(0, axisY - 2)
        let lanes = Double(max(timeline.lanes, 1))
        let laneGap = 2.0
        let laneHeight = max(1, (area - laneGap * (lanes - 1)) / lanes)

        let grid = theme.color("dim@0.3")
        for tick in timeline.ticks {
            let x = (tick.at * width).rounded() + 0.25
            fillRounded(snapshot, Rect(x: box.x + x - 0.25, y: box.y, width: 0.5, height: area), radius: 0, color: grid)
        }

        for item in timeline.items {
            let x0 = item.start * width
            let top = Double(item.lane) * (laneHeight + laneGap)
            let color = theme.color(item.color)
            guard let end = item.end else {
                let r = min(laneHeight / 2, 4)
                fillRounded(snapshot, Rect(x: box.x + x0 - r, y: box.y + top + laneHeight / 2 - r, width: 2 * r, height: 2 * r),
                            radius: r, color: color)
                continue
            }
            let barWidth = max(end * width - x0, 3)
            fillRounded(snapshot, Rect(x: box.x + x0, y: box.y + top, width: barWidth, height: laneHeight),
                        radius: min(3, laneHeight / 2, barWidth / 2), color: color)
            let room = barWidth - 12
            if let label = item.label, !label.isEmpty, laneHeight >= 12, room >= 14, let layout = chartLayout(label, size: 10, weight: 500) {
                // Whole when it fits, else cut with an ellipsis at the bar's padding.
                if chartLayoutSize(layout).width > room {
                    pango_layout_set_width(layout, Int32(room * Double(PANGO_SCALE)))
                    pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END)
                }
                drawChartLayout(snapshot, layout, x: box.x + x0 + 6, centerY: box.y + top + laneHeight / 2, color: theme.color("bg"))
            }
        }

        if let now = timeline.now {
            fillRounded(snapshot, Rect(x: box.x + now * width - 0.75, y: box.y, width: 1.5, height: area), radius: 0,
                        color: theme.color(timeline.nowColor))
        }

        var right = -Double.infinity
        for tick in timeline.ticks where !tick.label.isEmpty {
            guard let layout = chartLayout(tick.label, size: 9, weight: 400) else { continue }
            let measured = chartLayoutSize(layout).width
            let left = min(max(tick.at * width - measured / 2, 0), max(0, width - measured))
            guard left >= right + 4 else {
                g_object_unref(UnsafeMutableRawPointer(layout))
                continue
            }
            drawChartLayout(snapshot, layout, x: box.x + left, centerY: box.y + axisY + Self.tickLabelHeight / 2, color: theme.color("dim"))
            right = left + measured
        }
    }

    // MARK: Image

    func drawImage(_ snapshot: OpaquePointer, _ image: RenderNode.Image, _ box: Rect) {
        guard box.width > 0, box.height > 0 else { return }
        guard let texture = TextureFiles.texture(image.path) else {
            fillRounded(snapshot, box, radius: image.radius, color: context.theme.color("track"))
            return
        }
        let textureWidth = Double(gdk_texture_get_width(texture)), textureHeight = Double(gdk_texture_get_height(texture))
        guard textureWidth > 0, textureHeight > 0 else { return }
        let scale = image.fit == "contain"
            ? min(box.width / textureWidth, box.height / textureHeight)
            : max(box.width / textureWidth, box.height / textureHeight)
        let width = textureWidth * scale, height = textureHeight * scale
        let drawn = Rect(x: box.x + (box.width - width) / 2, y: box.y + (box.height - height) / 2, width: width, height: height)
        pushRoundedClip(snapshot, box, radius: image.radius)
        var bounds = drawn.graphene
        gtk_snapshot_append_scaled_texture(snapshot, texture, GSK_SCALING_FILTER_TRILINEAR, &bounds)
        gtk_snapshot_pop(snapshot)
    }
}

/// Pictures decoded from files, by path, replaced when the file's date
/// changes. Main thread only.
enum TextureFiles {
    private struct Entry {
        let texture: OpaquePointer
        let modified: Date?
    }

    nonisolated(unsafe) private static var entries: [String: Entry] = [:]

    static func texture(_ path: String?) -> OpaquePointer? {
        guard let path else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let entry = entries[path], entry.modified == modified { return entry.texture }
        var error: UnsafeMutablePointer<GError>?
        guard let loaded = gdk_texture_new_from_filename(path, &error) else {
            if let error {
                uiLog("linux ui: image \(path): \(String(cString: error.pointee.message))")
                g_error_free(error)
            }
            return nil
        }
        let texture: OpaquePointer = loaded
        if let old = entries.removeValue(forKey: path) { g_object_unref(UnsafeMutableRawPointer(old.texture)) }
        if entries.count >= 32, let victim = entries.keys.first, let old = entries.removeValue(forKey: victim) {
            g_object_unref(UnsafeMutableRawPointer(old.texture))
        }
        entries[path] = Entry(texture: texture, modified: modified)
        return texture
    }
}
#endif
