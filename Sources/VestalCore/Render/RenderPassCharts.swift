import Foundation

// MARK: - Chart widgets
//
// `bars`, `stackedBar`, `heatmap`, `timeline` and `image`: the data
// primitives that draw many values at once. Like `sparkline`, each takes its
// data as an expression (or a literal array), resolves every colour in the
// core, and leaves only drawing to the UIs. What a UI could not draw from
// numbers alone is composed of the other nodes: the labels under vertical
// bars, the rows of horizontal bars (a grid of `text`, `bar` and `text`) and a
// stacked bar's legend. A null data field shows the widget's `placeholder`
// when it has one, else an empty chart of the same size.

/// One entry of a `values` or `segments` array.
struct ChartEntry {
    var value: Double?
    var label: String?
    var color: String?
}

extension RenderPass {
    // MARK: Data

    /// The array a field names: an expression's single array output (or all
    /// its outputs), or a literal array. Nil for null or anything else.
    func dataArray(_ value: AnyJSON?, id: String, field: String, scope: Scope) -> [AnyJSON]? {
        switch value {
        case .string(let expression)?:
            guard let outputs = evalAll(expression, id: id, field: field, scope: scope) else { return nil }
            if outputs.count == 1, case .array(let array) = outputs[0] { return array.map(\.anyJSON) }
            let present = outputs.filter { $0 != .null }
            return present.isEmpty ? nil : present.map(\.anyJSON)
        case .array(let items)?:
            return items
        case .object?:
            return literal(value, id: id, field: field, scope: scope)?.arrayValue
        default:
            return nil
        }
    }

    static func number(_ value: AnyJSON?) -> Double? {
        switch value {
        case .int(let n)?: return Double(n)
        case .double(let d)?: return d.isFinite ? d : nil
        case .string(let s)?: return Double(s.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        default: return nil
        }
    }

    /// A label from a string or a number.
    static func labelText(_ value: AnyJSON?) -> String? {
        switch value {
        case .string(let s)?: return s
        case .int(let n)?: return String(n)
        case .double(let d)?: return d.isFinite ? shortNumber(d) : nil
        default: return nil
        }
    }

    /// `23`, `23.5`, `1280`: whole numbers from 100 up, else one decimal.
    static func shortNumber(_ value: Double) -> String {
        if abs(value) >= 100 || value == value.rounded() { return String(Int(value.rounded())) }
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    func entry(_ json: AnyJSON) -> ChartEntry {
        guard case .object(let members) = json else { return ChartEntry(value: Self.number(json), label: nil, color: nil) }
        return ChartEntry(value: Self.number(members["value"]), label: Self.labelText(members["label"]),
                          color: members["color"]?.stringValue)
    }

    /// The text shown instead of a chart whose data is null, when the widget
    /// has a `placeholder`.
    func placeholderNode(_ w: [String: AnyJSON], id: String, scope: Scope) -> RenderNode? {
        guard case .string(let text)? = w["placeholder"] else { return nil }
        var style = scope.style
        style.size = 11 * scope.style.scale
        style.color = "dim"
        return textNode(id: id, text: renderText(text, id: id, field: "placeholder", scope: scope), style: style, lines: 1,
                        align: .start)
    }

    /// A colour field for one value (`$value` is it), or `fallback`.
    func chartColor(_ spec: AnyJSON?, id: String, field: String, scope: Scope, value: Double?, fallback: String) -> String {
        guard let spec else { return fallback }
        return color(spec, id: id, field: field, scope: scope, value: value.map { .number($0) } ?? .null) ?? fallback
    }

    private static let cycle = ["accent", "purple", "cyan", "teal", "orange", "good", "warn", "bad"]

    // MARK: bars

    func bars(_ w: [String: AnyJSON], id: String, scope: Scope) -> RenderNode {
        let data = dataArray(w["values"], id: id, field: "values", scope: scope)
        if data == nil, let placeholder = placeholderNode(w, id: id, scope: scope) { return placeholder }
        let entries = (data ?? []).map(entry)
        let horizontal = string(w["orientation"], id: id, field: "orientation", scope: scope) == "horizontal"
        let scale = scope.style.scale
        let present = entries.compactMap(\.value)
        var top = numeric(w["max"], id: id, field: "max", scope: scope) ?? present.max() ?? 0
        if !(top > 0) { top = 1 }
        let colors = entries.map { item -> String in
            if let own = item.color {
                return chartColor(.string(own), id: id, field: "values.color", scope: scope, value: item.value, fallback: "accent")
            }
            return chartColor(w["color"], id: id, field: "color", scope: scope, value: item.value, fallback: "accent")
        }
        let summary = entries.map { item in item.value.map(Self.shortNumber) ?? "–" }.joined(separator: ", ")

        if horizontal {
            return horizontalBars(w, id: id, scope: scope, entries: entries, colors: colors, top: top)
        }

        let gap = max(0, number(w["gap"], id: id, field: "gap", scope: scope) ?? 3) * scale
        let barWidth = number(w["barWidth"], id: id, field: "barWidth", scope: scope).flatMap { $0 > 0 ? $0 * scale : nil }
        let labels = entries.map { $0.label ?? "" }
        let showLabels = (bool(w["labels"], id: id, field: "labels", scope: scope) ?? false) && labels.contains { !$0.isEmpty }
        let count = Double(entries.count)
        let natural = barWidth.map { count * $0 + max(0, count - 1) * gap }
        let width = length(w["width"], id: id, field: "width", scope: scope) ?? .points(natural ?? 160 * scale)
        let height = length(w["height"], id: id, field: "height", scope: scope) ?? .points(48 * scale)
        var node = RenderNode(id: showLabels ? "\(id)/0" : id, .bars(.init(
            values: entries.map { $0.value ?? 0 }, max: top, colors: colors, barWidth: barWidth, gap: gap)))
        node.height = height
        guard showLabels else {
            node.width = width
            node.alt = "bars: " + summary
            return node
        }
        node.width = .fill
        var labelStyle = scope.style
        labelStyle.size = 9 * scale
        labelStyle.weight = 400
        labelStyle.color = "dim"
        labelStyle = style(w["labelStyle"], over: labelStyle, id: id, scope: scope, value: nil)
        let texts = labels.enumerated().map { index, label -> RenderNode in
            var text = textNode(id: "\(id)/1/\(index)", text: label, style: labelStyle, lines: 1, align: .center)
            text.width = barWidth.map { .points($0) } ?? .fill
            return text
        }
        let row = RenderNode(id: "\(id)/1", .stack(.init(axis: .h, gap: gap, align: .start, children: texts)))
        var outer = RenderNode(id: id, .stack(.init(axis: .v, gap: 2 * scale, align: .stretch, children: [node, row])))
        outer.width = width
        outer.alt = "bars: " + zip(labels, entries).map { "\($0.isEmpty ? "" : "\($0) ")\($1.value.map(Self.shortNumber) ?? "–")" }
            .joined(separator: ", ")
        return outer
    }

    /// Rows of label, bar and value text in a grid, so the bars line up.
    private func horizontalBars(_ w: [String: AnyJSON], id: String, scope: Scope, entries: [ChartEntry], colors: [String],
                                top: Double) -> RenderNode {
        let scale = scope.style.scale
        let showLabels = (bool(w["labels"], id: id, field: "labels", scope: scope) ?? true) && entries.contains { $0.label != nil }
        let thickness = max(1, number(w["barWidth"], id: id, field: "barWidth", scope: scope) ?? 6) * scale
        let rowGap = max(0, number(w["gap"], id: id, field: "gap", scope: scope) ?? 6) * scale
        var labelStyle = scope.style
        labelStyle.size = 10 * scale
        labelStyle.weight = 400
        labelStyle.color = "subtle"
        labelStyle = style(w["labelStyle"], over: labelStyle, id: id, scope: scope, value: nil)
        var valueStyle = scope.style
        valueStyle.size = 10 * scale
        valueStyle.weight = 400
        valueStyle.font = "mono"
        valueStyle.color = "subtle"
        valueStyle = style(w["valueStyle"], over: valueStyle, id: id, scope: scope, value: nil)
        let labelWidth = number(w["labelWidth"], id: id, field: "labelWidth", scope: scope).flatMap { $0 > 0 ? $0 * scale : nil }

        var columns: [RenderNode.Grid.Column] = []
        if showLabels { columns.append(.init(width: labelWidth.map { .points($0) } ?? .fit, align: .start)) }
        columns.append(.init(width: .fill))
        columns.append(.init(width: .fit, align: .end))
        let perRow = columns.count

        var children: [RenderNode] = []
        for (index, item) in entries.enumerated() {
            var cell = index * perRow
            if showLabels {
                children.append(textNode(id: "\(id)/\(cell)", text: item.label ?? "", style: labelStyle, lines: 1, align: .start))
                cell += 1
            }
            let fraction = item.value.map { min(max($0 / top, 0), 1) } ?? 0
            let color = colors[index]
            var bar = RenderNode(id: "\(id)/\(cell)", .bar(.init(
                value: fraction, color: color,
                trackColor: model.palette.hexValue(color).map { RenderPalette.withAlpha($0, 0.15) },
                radius: min(2 * scale, thickness / 2))))
            bar.width = .fill
            bar.height = .points(thickness)
            children.append(bar)
            let text: String
            if let value = item.value {
                text = w["format"] != nil
                    ? formatted(.number(value), w["format"], id: id, scope: scope)
                    : Self.shortNumber(value)
            } else {
                text = "–"
            }
            children.append(textNode(id: "\(id)/\(cell + 1)", text: text, style: valueStyle, lines: 1, align: .end))
        }
        var node = RenderNode(id: id, .grid(.init(columns: columns, gap: 8 * scale, rowGap: rowGap, children: children)))
        node.alt = "bars: " + entries.map { item in
            "\(item.label.map { "\($0) " } ?? "")\(item.value.map(Self.shortNumber) ?? "–")"
        }.joined(separator: ", ")
        return node
    }

    // MARK: stackedBar

    func stackedBar(_ w: [String: AnyJSON], id: String, scope: Scope) -> RenderNode {
        let data = dataArray(w["segments"], id: id, field: "segments", scope: scope)
        if data == nil, let placeholder = placeholderNode(w, id: id, scope: scope) { return placeholder }
        let scale = scope.style.scale
        let entries = (data ?? []).map(entry).filter { ($0.value ?? 0) > 0 }
        let sum = entries.reduce(0) { $0 + ($1.value ?? 0) }
        let total = numeric(w["total"], id: id, field: "total", scope: scope) ?? sum
        let whole = max(total, sum)
        var segments: [RenderNode.StackedBar.Segment] = []
        for (index, item) in entries.enumerated() {
            let fallback = Self.cycle[index % Self.cycle.count]
            let color: String
            if let own = item.color {
                color = chartColor(.string(own), id: id, field: "segments.color", scope: scope, value: item.value, fallback: fallback)
            } else {
                color = chartColor(w["color"], id: id, field: "color", scope: scope, value: item.value, fallback: fallback)
            }
            segments.append(.init(value: whole > 0 ? (item.value ?? 0) / whole : 0, color: color))
        }

        let height = length(w["height"], id: id, field: "height", scope: scope) ?? .points(8 * scale)
        let heightPoints: Double
        if case .points(let h) = height { heightPoints = h } else { heightPoints = 8 * scale }
        let radius = number(w["radius"], id: id, field: "radius", scope: scope).map { $0 * scale } ?? heightPoints / 2
        let track = w["trackColor"].flatMap { color($0, id: id, field: "trackColor", scope: scope, value: nil) } ?? "track"
        let legend = bool(w["legend"], id: id, field: "legend", scope: scope) ?? false
        let alt = "stacked bar: " + zip(entries, segments).map { item, segment in
            "\(item.label.map { "\($0) " } ?? "")\(Int((segment.value * 100).rounded()))%"
        }.joined(separator: ", ")
        let labelled = entries.enumerated().filter { !($0.element.label ?? "").isEmpty }

        var bar = RenderNode(id: legend && !labelled.isEmpty ? "\(id)/0" : id,
                             .stackedBar(.init(segments: segments, trackColor: track, radius: radius)))
        bar.height = height
        let width = length(w["width"], id: id, field: "width", scope: scope) ?? .fill
        guard legend, !labelled.isEmpty else {
            bar.width = width
            bar.alt = alt
            return bar
        }
        bar.width = .fill
        var textStyle = scope.style
        textStyle.size = 10 * scale
        textStyle.weight = 400
        textStyle.color = "subtle"
        textStyle = style(w["labelStyle"], over: textStyle, id: id, scope: scope, value: nil)
        let entriesNodes = labelled.map { index, item -> RenderNode in
            let base = "\(id)/1/\(index)"
            var dot = RenderNode(id: "\(base)/0", .bar(.init(value: 1, color: segments[index].color,
                                                           trackColor: segments[index].color, radius: 4 * scale)))
            dot.width = .points(8 * scale)
            dot.height = .points(8 * scale)
            let text = textNode(id: "\(base)/1", text: item.label ?? "", style: textStyle, lines: 1, align: .start)
            return RenderNode(id: base, .stack(.init(axis: .h, gap: 4 * scale, align: .center, children: [dot, text])))
        }
        let row = RenderNode(id: "\(id)/1", .stack(.init(axis: .h, gap: 12 * scale, align: .center, children: entriesNodes)))
        var outer = RenderNode(id: id, .stack(.init(axis: .v, gap: 6 * scale, align: .stretch, children: [bar, row])))
        outer.width = width
        outer.alt = alt
        return outer
    }

    // MARK: heatmap

    func heatmap(_ w: [String: AnyJSON], id: String, scope: Scope) -> RenderNode {
        let data = dataArray(w["values"], id: id, field: "values", scope: scope)
        if data == nil, let placeholder = placeholderNode(w, id: id, scope: scope) { return placeholder }
        let scale = scope.style.scale
        let values = (data ?? []).prefix(10_000).map { Self.number($0) }
        let rows = min(max(Int(number(w["rows"], id: id, field: "rows", scope: scope) ?? 7), 1), 366)
        let direction = string(w["direction"], id: id, field: "direction", scope: scope) == "rows" ? "rows" : "columns"
        let cell = max(1, number(w["cell"], id: id, field: "cell", scope: scope) ?? 8) * scale
        let gap = max(0, number(w["gap"], id: id, field: "gap", scope: scope) ?? 2) * scale
        let radius = max(0, number(w["radius"], id: id, field: "radius", scope: scope) ?? 2) * scale
        let track = w["trackColor"].flatMap { color($0, id: id, field: "trackColor", scope: scope, value: nil) } ?? "track"

        let present = values.compactMap { $0 }
        let low = numeric(w["min"], id: id, field: "min", scope: scope) ?? present.min() ?? 0
        let high = numeric(w["max"], id: id, field: "max", scope: scope) ?? present.max() ?? 0
        let colorOf = heatmapColors(w, id: id, scope: scope, low: low, high: high)
        let cells = values.map { value in value.map(colorOf) }

        let heat = RenderNode.Heatmap(cells: cells, rows: rows, direction: direction, cell: cell, gap: gap, radius: radius,
                                      trackColor: track)
        let columns = Double(heat.columns)
        var node = RenderNode(id: id, .heatmap(heat))
        node.width = .points(columns * cell + max(0, columns - 1) * gap)
        node.height = .points(Double(rows) * cell + Double(rows - 1) * gap)
        node.alt = "heatmap: \(cells.count) cells, \(present.count) with data"
        return node
    }

    /// The colour of a value: `steps` (the last stop at or below it, else
    /// the first), else the `scale` mixed from its low colour to its high.
    private func heatmapColors(_ w: [String: AnyJSON], id: String, scope: Scope, low: Double, high: Double) -> (Double) -> String {
        if case .array(let stops)? = w["steps"] {
            var table: [(threshold: Double, color: String)] = []
            for stop in stops {
                guard case .array(let pair) = stop, pair.count == 2, let threshold = TextStyle.size(pair[0]) else { continue }
                let color = color(pair[1], id: id, field: "steps", scope: scope, value: nil) ?? "accent"
                table.append((threshold, color))
            }
            return { value in
                var chosen = table.first?.color ?? "accent"
                for stop in table where value >= stop.threshold { chosen = stop.color }
                return chosen
            }
        }
        var endpoints = ["accent@0.2", "accent"]
        if case .array(let scale)? = w["scale"], scale.count == 2, let a = scale[0].stringValue, let b = scale[1].stringValue {
            endpoints = [a, b]
        }
        let palette = model.palette
        let from = palette.hexValue(endpoints[0]).flatMap { RGBA($0, palette: [:]) }
        let to = palette.hexValue(endpoints[1]).flatMap { RGBA($0, palette: [:]) }
        for (index, text) in endpoints.enumerated() where (index == 0 ? from : to) == nil {
            report(id: id, field: "scale", severity: "warning", code: "unknown-color", message: "unknown colour \"\(text)\"")
        }
        guard let from, let to else { return { _ in "accent" } }
        return { value in
            let t = high > low ? min(max((value - low) / (high - low), 0), 1) : 1
            return from.mixed(with: to, t: t).hex
        }
    }

    // MARK: timeline

    func timeline(_ w: [String: AnyJSON], id: String, scope: Scope) -> RenderNode {
        let data = dataArray(w["items"], id: id, field: "items", scope: scope)
        if data == nil, w["items"] != nil, let placeholder = placeholderNode(w, id: id, scope: scope) { return placeholder }
        let scale = scope.style.scale
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfDay = calendar.startOfDay(for: now)
        let from = timeField(w["from"], id: id, field: "from", scope: scope) ?? startOfDay.timeIntervalSince1970
        var to = timeField(w["to"], id: id, field: "to", scope: scope)
            ?? calendar.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: from))?.timeIntervalSince1970 ?? from + 86_400
        if !(to > from) {
            report(id: id, field: "to", severity: "warning", code: "invalid-value", message: "to is not after from; showing one day")
            to = from + 86_400
        }
        let span = to - from
        let fallback = chartColor(w["color"], id: id, field: "color", scope: scope, value: nil, fallback: "accent")

        struct Raw { var start: Double; var end: Double?; var label: String?; var color: String }
        var raw: [Raw] = []
        for (index, json) in (data ?? []).enumerated() {
            guard case .object(let members) = json else { continue }
            let field = "items[\(index)]"
            guard let start = timeValue(members["start"], id: id, field: field + ".start") else { continue }
            let end = timeValue(members["end"], id: id, field: field + ".end")
            let first = (start - from) / span
            let last = end.map { ($0 - from) / span } ?? first
            guard last >= 0, first <= 1 else { continue }
            let color = members["color"]?.stringValue.map {
                chartColor(.string($0), id: id, field: field + ".color", scope: scope, value: nil, fallback: fallback)
            } ?? fallback
            raw.append(Raw(start: min(max(first, 0), 1), end: end.map { min(max(($0 - from) / span, 0), 1) },
                           label: Self.labelText(members["label"]), color: color))
        }
        raw.sort { $0.start < $1.start }
        // Overlapping items go on lanes, each in the first lane that is free.
        var laneEnds: [Double] = []
        var items: [RenderNode.Timeline.Item] = []
        for item in raw {
            let occupied = max(item.end ?? item.start, item.start + 0.02)
            var lane = laneEnds.firstIndex { $0 <= item.start } ?? laneEnds.count
            if lane >= 4 { lane = 3 }
            if lane == laneEnds.count { laneEnds.append(occupied) } else { laneEnds[lane] = max(laneEnds[lane], occupied) }
            items.append(.init(start: Self.round(item.start), end: item.end.map(Self.round), label: item.label,
                               color: item.color, lane: lane))
        }

        var timeline = RenderNode.Timeline(items: items, ticks: ticks(from: from, to: to), lanes: max(1, laneEnds.count))
        if bool(w["now"], id: id, field: "now", scope: scope) ?? true {
            let current = now.timeIntervalSince1970
            if current <= to { usesNow = true }
            // To the minute, so the line moves (and patches go out) once a minute.
            let fraction = (floor(current / 60) * 60 - from) / span
            if fraction >= 0, fraction <= 1 { timeline.now = Self.round(fraction) }
        }
        timeline.nowColor = w["nowColor"].flatMap { color($0, id: id, field: "nowColor", scope: scope, value: nil) } ?? "accent"
        var node = RenderNode(id: id, .timeline(timeline))
        node.width = .fill
        node.height = .points(36 * scale)
        node.alt = "timeline: " + (items.isEmpty ? "no items" : items.compactMap(\.label).joined(separator: ", "))
        return node
    }

    private static func round(_ fraction: Double) -> Double {
        (fraction * 100_000).rounded() / 100_000
    }

    /// `from` or `to`: a number of epoch seconds, a time written out, or an
    /// expression.
    private func timeField(_ value: AnyJSON?, id: String, field: String, scope: Scope) -> Double? {
        switch value {
        case nil, .null?:
            return nil
        case .int(let n)?:
            return Double(n)
        case .double(let d)?:
            return d.isFinite ? d : nil
        case .string(let text)?:
            if let literal = VestalFunctions.parseISO8601(text) ?? Double(text.trimmingCharacters(in: .whitespaces)) { return literal }
            return timeValue(eval(text, id: id, field: field, scope: scope).map(\.anyJSON), id: id, field: field)
        case .object?:
            return timeValue(literal(value, id: id, field: field, scope: scope), id: id, field: field)
        default:
            return nil
        }
    }

    /// A time in an item: epoch seconds or ISO 8601 text.
    private func timeValue(_ value: AnyJSON?, id: String, field: String) -> Double? {
        guard let value, value != .null else { return nil }
        do {
            return try VestalFunctions.time(JQValue(value), "timeline")
        } catch {
            report(id: id, field: field, severity: "warning", code: "invalid-value", message: "\(error)")
            return nil
        }
    }

    /// Tick labels at a step that gives at most nine of them: whole hours
    /// for a day, days for a week. Hours follow the locale's 12 or 24 hour
    /// clock.
    private func ticks(from: Double, to: Double) -> [RenderNode.Timeline.Tick] {
        let span = to - from
        let steps: [Double] = [300, 600, 900, 1800, 3600, 7200, 10_800, 14_400, 21_600, 43_200, 86_400, 172_800, 604_800]
        let step = steps.first { span / $0 <= 8.001 } ?? 604_800
        let pattern = step >= 86_400 ? "MMMd" : (step.truncatingRemainder(dividingBy: 3600) == 0 ? "j" : "jm")
        var times: [Double] = []
        if step < 86_400 {
            let offset = Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: from)))
            var t = (((from + offset) / step).rounded(.up)) * step - offset
            while t <= to + 0.5, times.count < 24 {
                times.append(t)
                t += step
            }
        } else {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            var day = calendar.startOfDay(for: Date(timeIntervalSince1970: from))
            if day.timeIntervalSince1970 < from { day = calendar.date(byAdding: .day, value: 1, to: day) ?? day }
            let days = Int(step / 86_400)
            while day.timeIntervalSince1970 <= to + 0.5, times.count < 24 {
                times.append(day.timeIntervalSince1970)
                guard let next = calendar.date(byAdding: .day, value: days, to: day) else { break }
                day = next
            }
        }
        var ticks = times.compactMap { time -> RenderNode.Timeline.Tick? in
            guard let label = try? VestalFunctions.formatDate(time, pattern: pattern, template: true, zone: timeZone, locale: locale)
            else { return nil }
            return .init(at: Self.round((time - from) / span), label: label)
        }
        // A day from midnight to midnight would label both ends "00".
        if ticks.count > 2, ticks.last?.label == ticks.first?.label { ticks.removeLast() }
        return ticks
    }

    // MARK: image

    func image(_ w: [String: AnyJSON], id: String, scope: Scope) -> RenderNode {
        var source: String?
        switch w["src"] {
        case .string(let text)?: source = renderText(text, id: id, field: "src", scope: scope)
        case .object?: source = literal(w["src"], id: id, field: "src", scope: scope)?.stringValue
        default: break
        }
        source = source?.trimmingCharacters(in: .whitespaces)
        var path: String?
        if let source, !source.isEmpty {
            if ImageCache.isRemote(source) {
                let cache = ImageCache.shared
                path = cache.cachedPath(for: source)
                if path == nil {
                    // Draws empty until the fetch lands; then `image:<key>`
                    // changes and this widget renders again.
                    sources.insert(ImageCache.sourcePrefix + ImageCache.key(for: source))
                    cache.request(source)
                }
            } else {
                let expanded = ImageCache.expandedPath(source)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), !isDirectory.boolValue {
                    path = expanded
                }
            }
        }
        let fit = string(w["fit"], id: id, field: "fit", scope: scope) == "contain" ? "contain" : "cover"
        let radius = max(0, number(w["radius"], id: id, field: "radius", scope: scope) ?? 6) * scope.style.scale
        var node = RenderNode(id: id, .image(.init(path: path, fit: fit, radius: radius)))
        node.width = .points(48 * scope.style.scale)
        node.height = .points(48 * scope.style.scale)
        node.alt = "image"
        return node
    }
}
