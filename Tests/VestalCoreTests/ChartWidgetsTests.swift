import Foundation
import VestalCore
import XCTest

// `bars`, `stackedBar`, `heatmap`, `timeline` and `image`: decoding and
// validation, the values that reach the node, layout sizes, null and empty
// data, the tree output, and the image cache.

final class ChartWidgetsTests: XCTestCase {
    /// 2026-09-27T17:03:22Z.
    static let now = Date(timeIntervalSince1970: 1_790_528_602)
    /// 2026-09-27T00:00:00Z.
    static let dayStart = 1_790_467_200.0

    // MARK: Helpers

    private func tree(_ text: String) -> AnyJSON {
        guard case .success(let tree) = AnyJSON.parse(Data(text.utf8)) else {
            XCTFail("bad JSON: \(text)")
            return .null
        }
        return tree
    }

    /// One widget in view main, with the data of source `s`.
    private func render(_ widget: String, data: String = "{}", locale: String = "en_GB", zone: String = "UTC",
                        now: Date = ChartWidgetsTests.now) -> (RenderSnapshot, RenderSession) {
        let config = """
            { "sources": { "s": { "type": "file", "path": "/s" } },
              "widgets": { "w": \(widget) },
              "views": { "main": { "children": ["w"] } } }
            """
        let model = RenderConfigModel(expanded: ConfigExpansion.expand(tree(config)))
        let session = RenderSession(model: model)
        session.timeZone = TimeZone(identifier: zone)!
        session.locale = Locale(identifier: locale)
        session.os = "linux"
        let values: [String: JQValue] = ["s": (try? JQValue.parse(data)) ?? .null]
        let snapshot = session.render(data: RenderData(sources: values, names: model.sourceNames), now: now)
        return (snapshot, session)
    }

    private func node(_ snapshot: RenderSnapshot, _ id: String = "main/w", file: StaticString = #filePath, line: UInt = #line) -> RenderNode {
        guard let found = snapshot.root.node(withId: id) else {
            XCTFail("no node \(id)", file: file, line: line)
            return RenderNode(id: id, .spacer(.init()))
        }
        return found
    }

    private func bars(_ n: RenderNode) -> RenderNode.Bars {
        guard case .bars(let b) = n.content else { XCTFail("not bars: \(n.type)"); return .init() }
        return b
    }

    private func stackedBar(_ n: RenderNode) -> RenderNode.StackedBar {
        guard case .stackedBar(let b) = n.content else { XCTFail("not a stackedBar: \(n.type)"); return .init() }
        return b
    }

    private func heatmap(_ n: RenderNode) -> RenderNode.Heatmap {
        guard case .heatmap(let h) = n.content else { XCTFail("not a heatmap: \(n.type)"); return .init() }
        return h
    }

    private func timeline(_ n: RenderNode) -> RenderNode.Timeline {
        guard case .timeline(let t) = n.content else { XCTFail("not a timeline: \(n.type)"); return .init() }
        return t
    }

    private func image(_ n: RenderNode) -> RenderNode.Image {
        guard case .image(let i) = n.content else { XCTFail("not an image: \(n.type)"); return .init() }
        return i
    }

    private func text(_ n: RenderNode) -> RenderNode.Text? {
        if case .text(let t) = n.content { return t }
        return nil
    }

    // MARK: bars

    func testVerticalBarsFromNumbers() {
        let (s, _) = render(#"{ "type": "bars", "values": "[3, 6, 12]" }"#)
        let n = node(s)
        XCTAssertEqual(bars(n).values, [3, 6, 12])
        XCTAssertEqual(bars(n).max, 12, "the largest value")
        XCTAssertEqual(bars(n).colors, ["accent", "accent", "accent"])
        XCTAssertNil(bars(n).barWidth)
        XCTAssertEqual(bars(n).gap, 3)
        XCTAssertEqual(n.width, .points(160))
        XCTAssertEqual(n.height, .points(48))
        XCTAssertEqual(n.alt, "bars: 3, 6, 12")
        XCTAssertEqual(RenderText.tree(s).split(separator: "\n").first { $0.contains("bars") },
                       "  bars values=[3,6,12] max=12 color=accent w=160 h=48 [main/w]")
    }

    func testVerticalBarsFromObjectsWithLabelsAndColours() {
        let (s, _) = render(#"""
            { "type": "bars", "labels": true, "barWidth": 10, "gap": 4, "max": 20, "height": 40,
              "values": [ { "value": 5, "label": "a" }, { "value": 15, "label": "b", "color": "bad" }, { "value": null }, 20 ],
              "color": { "steps": [[0, "good"], [10, "warn"]] } }
            """#)
        // Labels make a stack: the columns, then a row of one text each.
        let outer = node(s)
        guard case .stack(let st) = outer.content else { return XCTFail("not a stack") }
        XCTAssertEqual(st.axis, .v)
        XCTAssertEqual(st.align, .stretch)
        XCTAssertEqual(outer.width, .points(4 * 10 + 3 * 4), "n bars and n-1 gaps when barWidth is set")
        XCTAssertEqual(outer.alt, "bars: a 5, b 15, –, 20")
        let b = node(s, "main/w/0")
        XCTAssertEqual(bars(b).values, [5, 15, 0, 20])
        XCTAssertEqual(bars(b).max, 20)
        XCTAssertEqual(bars(b).colors, ["good", "bad", "accent", "warn"], "a null has no value for the steps")
        XCTAssertEqual(bars(b).barWidth, 10)
        XCTAssertEqual(b.width, .fill)
        XCTAssertEqual(b.height, .points(40))
        let row = node(s, "main/w/1")
        guard case .stack(let labels) = row.content else { return XCTFail("no label row") }
        XCTAssertEqual(labels.gap, 4)
        XCTAssertEqual(row.children.compactMap { text($0)?.text }, ["a", "b", "", ""])
        XCTAssertEqual(row.children.map(\.width), Array(repeating: .points(10), count: 4))
        XCTAssertEqual(text(row.children[0])?.size, 9)
        XCTAssertEqual(text(row.children[0])?.color, "dim")
        XCTAssertEqual(text(row.children[0])?.textAlign, .center)
    }

    func testLabelsShareTheWidthWithoutABarWidth() {
        let (s, _) = render(#"{ "type": "bars", "labels": true, "values": [ { "value": 1, "label": "x" }, { "value": 2, "label": "y" } ] }"#)
        XCTAssertEqual(node(s).width, .points(160))
        XCTAssertEqual(node(s, "main/w/1").children.map(\.width), [.fill, .fill])
        // No label anywhere: no row.
        let (plain, _) = render(#"{ "type": "bars", "labels": true, "values": [1, 2] }"#)
        XCTAssertEqual(bars(node(plain)).values, [1, 2])
        XCTAssertNil(plain.root.node(withId: "main/w/1"))
    }

    func testHorizontalBarsAreAGrid() {
        let (s, _) = render(#"""
            { "type": "bars", "orientation": "horizontal", "source": "s", "max": 200,
              "values": "[.items[] | {value, label: .name}]", "barWidth": 8, "gap": 4 }
            """#, data: #"{"items": [{"name": "node", "value": 50}, {"name": "swift", "value": 150.4}, {"name": "idle", "value": 0}]}"#)
        let n = node(s)
        guard case .grid(let g) = n.content else { return XCTFail("not a grid") }
        XCTAssertEqual(g.columns, [.init(width: .fit, align: .start), .init(width: .fill), .init(width: .fit, align: .end)])
        XCTAssertEqual(g.rowGap, 4)
        XCTAssertEqual(g.gap, 8)
        XCTAssertEqual(n.width, .fill, "a fill column makes the grid fill")
        XCTAssertEqual(g.children.count, 9)
        XCTAssertEqual(text(g.children[0])?.text, "node")
        guard case .bar(let first) = g.children[1].content else { return XCTFail("no bar") }
        XCTAssertEqual(first.value, 0.25, accuracy: 1e-9)
        XCTAssertEqual(g.children[1].height, .points(8))
        XCTAssertEqual(g.children[1].width, .fill)
        XCTAssertEqual(text(g.children[2])?.text, "50")
        XCTAssertEqual(text(g.children[2])?.font, "mono")
        XCTAssertEqual(text(g.children[5])?.text, "150")
        XCTAssertEqual(text(g.children[8])?.text, "0")
        XCTAssertEqual(g.children.map(\.id).prefix(3), ["main/w/0", "main/w/1", "main/w/2"])
        XCTAssertEqual(n.alt, "bars: node 50, swift 150, idle 0")
    }

    func testHorizontalBarsWithoutLabelsAndWithAFormat() {
        let (s, _) = render(#"""
            { "type": "bars", "orientation": "horizontal", "labels": false, "format": "percent", "values": [12, 50], "max": 100 }
            """#)
        guard case .grid(let g) = node(s).content else { return XCTFail("not a grid") }
        XCTAssertEqual(g.columns.count, 2)
        XCTAssertEqual(g.rowGap, 6)
        XCTAssertEqual(g.children.count, 4)
        XCTAssertEqual(text(g.children[1])?.text, "12%")
        guard case .bar(let b) = g.children[0].content else { return XCTFail("no bar") }
        XCTAssertEqual(b.value, 0.12, accuracy: 1e-9)
        XCTAssertEqual(g.children[0].height, .points(6))
    }

    func testBarsNullEmptyAndPlaceholder() {
        let (missing, _) = render(#"{ "type": "bars", "source": "s", "values": ".nope", "height": 30 }"#)
        XCTAssertEqual(bars(node(missing)).values, [])
        XCTAssertEqual(node(missing).height, .points(30), "an empty chart keeps its size")
        XCTAssertEqual(node(missing).width, .points(160))
        let (placeholder, _) = render(#"{ "type": "bars", "source": "s", "values": ".nope", "placeholder": "n/a" }"#)
        XCTAssertEqual(text(node(placeholder))?.text, "n/a")
        XCTAssertEqual(text(node(placeholder))?.color, "dim")
        let (empty, _) = render(#"{ "type": "bars", "values": "[]", "placeholder": "n/a" }"#)
        XCTAssertEqual(bars(node(empty)).values, [], "an empty array is data, not null")
        let (zero, _) = render(#"{ "type": "bars", "values": [0, 0] }"#)
        XCTAssertEqual(bars(node(zero)).max, 1, "never zero")
        // Horizontal with nothing: an empty grid.
        let (none, _) = render(#"{ "type": "bars", "orientation": "horizontal", "values": "[]" }"#)
        XCTAssertTrue(node(none).children.isEmpty)
    }

    // MARK: stackedBar

    func testStackedBarSharesAndTotal() {
        let (s, _) = render(#"""
            { "type": "stackedBar", "total": 200,
              "segments": [ { "value": 50, "label": "A", "color": "bad" }, { "value": 25, "label": "B" }, { "value": 0, "label": "gone" }, { "value": null } ] }
            """#)
        let n = node(s)
        XCTAssertEqual(stackedBar(n).segments.map(\.color), ["bad", "purple"], "zero and null segments are dropped; the cycle colours the rest")
        XCTAssertEqual(stackedBar(n).segments[0].value, 0.25, accuracy: 1e-9)
        XCTAssertEqual(stackedBar(n).segments[1].value, 0.125, accuracy: 1e-9)
        XCTAssertEqual(stackedBar(n).trackColor, "track")
        XCTAssertEqual(stackedBar(n).radius, 4, "half the height")
        XCTAssertEqual(n.width, .fill)
        XCTAssertEqual(n.height, .points(8))
        XCTAssertEqual(n.alt, "stacked bar: A 25%, B 13%")
    }

    func testStackedBarWithoutTotalFillsTheBar() {
        let (s, _) = render(#"{ "type": "stackedBar", "segments": [ { "value": 3 }, { "value": 1 } ], "height": 12, "radius": 2, "trackColor": "dim" }"#)
        let n = node(s)
        XCTAssertEqual(stackedBar(n).segments.map(\.value), [0.75, 0.25])
        XCTAssertEqual(stackedBar(n).radius, 2)
        XCTAssertEqual(stackedBar(n).trackColor, "dim")
        XCTAssertEqual(n.height, .points(12))
        // Segments beyond the total are scaled down to fit.
        let (over, _) = render(#"{ "type": "stackedBar", "total": 2, "segments": [ { "value": 3 }, { "value": 1 } ] }"#)
        XCTAssertEqual(stackedBar(node(over)).segments.map(\.value), [0.75, 0.25])
    }

    func testStackedBarLegend() {
        let (s, _) = render(#"""
            { "type": "stackedBar", "legend": true, "source": "s", "width": 200,
              "segments": "[.parts[] | {value, label: .name}]" }
            """#, data: #"{"parts": [{"name": "Used", "value": 30}, {"name": "", "value": 10}, {"name": "Cache", "value": 20}]}"#)
        let outer = node(s)
        XCTAssertEqual(outer.width, .points(200))
        guard case .stack(let st) = outer.content else { return XCTFail("not a stack") }
        XCTAssertEqual(st.align, .stretch)
        XCTAssertEqual(stackedBar(node(s, "main/w/0")).segments.count, 3)
        XCTAssertEqual(node(s, "main/w/0").width, .fill)
        let legend = node(s, "main/w/1")
        XCTAssertEqual(legend.children.count, 2, "only labelled segments")
        // A dot and a label per entry, in the segment's colour.
        let first = legend.children[0]
        guard case .bar(let dot) = first.children[0].content else { return XCTFail("no dot") }
        XCTAssertEqual(dot.color, "accent")
        XCTAssertEqual(first.children[0].width, .points(8))
        XCTAssertEqual(first.children[0].height, .points(8))
        XCTAssertEqual(text(first.children[1])?.text, "Used")
        XCTAssertEqual(text(first.children[1])?.color, "subtle")
        guard case .bar(let second) = legend.children[1].children[0].content else { return XCTFail("no dot") }
        XCTAssertEqual(second.color, "cyan", "the third segment's colour: the dot matches its segment")
        XCTAssertEqual(stackedBar(node(s, "main/w/0")).segments[2].color, "cyan")
    }

    func testStackedBarNullAndPlaceholder() {
        let (missing, _) = render(#"{ "type": "stackedBar", "source": "s", "segments": ".nope" }"#)
        XCTAssertEqual(stackedBar(node(missing)).segments, [])
        XCTAssertEqual(node(missing).height, .points(8))
        let (placeholder, _) = render(#"{ "type": "stackedBar", "source": "s", "segments": ".nope", "placeholder": "–" }"#)
        XCTAssertEqual(text(node(placeholder))?.text, "–")
    }

    // MARK: heatmap

    func testHeatmapScaleAndNullCells() {
        let (s, _) = render(#"""
            { "type": "heatmap", "values": [0, 5, 10, null], "rows": 2, "scale": ["#000000", "#ffffff"], "cell": 8, "gap": 2 }
            """#)
        let n = node(s)
        let h = heatmap(n)
        XCTAssertEqual(h.cells, ["#000000ff", "#808080ff", "#ffffffff", nil])
        XCTAssertEqual(h.rows, 2)
        XCTAssertEqual(h.columns, 2)
        XCTAssertEqual(n.width, .points(18))
        XCTAssertEqual(n.height, .points(18))
        XCTAssertEqual(h.trackColor, "track")
        XCTAssertEqual(h.radius, 2)
        XCTAssertEqual(RenderText.tree(s).split(separator: "\n").first { $0.contains("heatmap") },
                       "  heatmap cells=4 empty=1 rows=2 cell=8 colors=3 w=18 h=18 [main/w]")
    }

    func testHeatmapDefaultsAndExplicitRange() {
        let (s, _) = render(#"{ "type": "heatmap", "values": [1, 2, 3, 4, 5, 6, 7, 8] }"#)
        let h = heatmap(node(s))
        XCTAssertEqual(h.rows, 7)
        XCTAssertEqual(h.direction, "columns")
        XCTAssertEqual(h.columns, 2)
        XCTAssertEqual(node(s).width, .points(2 * 8 + 2))
        XCTAssertEqual(node(s).height, .points(7 * 8 + 6 * 2))
        XCTAssertEqual(h.cells.first, "#7aa1f733", "the default scale's low end: accent at 20%")
        XCTAssertEqual(h.cells.last, "#7aa1f7ff")
        // `min` and `max` fix the ends of the scale.
        let (fixed, _) = render(##"{ "type": "heatmap", "values": [5, 5], "min": 0, "max": 10, "scale": ["#000000", "#ffffff"] }"##)
        XCTAssertEqual(heatmap(node(fixed)).cells, ["#808080ff", "#808080ff"])
        // All the same: the high end.
        let (same, _) = render(##"{ "type": "heatmap", "values": [4, 4], "scale": ["#000000", "#ffffff"] }"##)
        XCTAssertEqual(heatmap(node(same)).cells, ["#ffffffff", "#ffffffff"])
    }

    func testHeatmapSteps() {
        let (s, _) = render(#"{ "type": "heatmap", "values": [0, 3, 5, 9], "steps": [[0, "track"], [4, "good"], [8, "bad"]] }"#)
        XCTAssertEqual(heatmap(node(s)).cells, ["track", "track", "good", "bad"])
    }

    func testHeatmapDirectionAndPositions() {
        let (rows, _) = render(#"{ "type": "heatmap", "values": [1, 2, 3, 4, 5], "rows": 2, "direction": "rows" }"#)
        let h = heatmap(node(rows))
        XCTAssertEqual(h.direction, "rows")
        XCTAssertEqual(h.columns, 3)
        let across = (0..<5).map { h.position(of: $0) }.map { "\($0.column),\($0.row)" }
        XCTAssertEqual(across, ["0,0", "1,0", "2,0", "0,1", "1,1"], "row by row")
        let (cols, _) = render(#"{ "type": "heatmap", "values": [1, 2, 3, 4, 5], "rows": 2 }"#)
        let down = (0..<5).map { heatmap(node(cols)).position(of: $0) }.map { "\($0.column),\($0.row)" }
        XCTAssertEqual(down, ["0,0", "0,1", "1,0", "1,1", "2,0"], "column by column")
    }

    func testHeatmapNullAndEmpty() {
        let (missing, _) = render(#"{ "type": "heatmap", "source": "s", "values": ".nope" }"#)
        XCTAssertEqual(heatmap(node(missing)).cells, [])
        XCTAssertEqual(node(missing).height, .points(7 * 8 + 6 * 2), "the rows keep their height")
        let (placeholder, _) = render(#"{ "type": "heatmap", "source": "s", "values": ".nope", "placeholder": "no data" }"#)
        XCTAssertEqual(text(node(placeholder))?.text, "no data")
        let (allNull, _) = render(#"{ "type": "heatmap", "values": [null, null] }"#)
        XCTAssertEqual(heatmap(node(allNull)).cells, [nil, nil])
    }

    // MARK: timeline

    func testTimelineRangeItemsAndNow() {
        let from = Self.dayStart
        let (s, session) = render("""
            { "type": "timeline", "from": \(Int(from)), "to": "\(Int(from) + 86400)",
              "items": [ { "start": \(Int(from) + 9 * 3600), "end": \(Int(from) + 11 * 3600), "label": "Long" },
                         { "start": \(Int(from) + 10 * 3600), "end": \(Int(from) + 12 * 3600), "label": "Overlaps", "color": "bad" },
                         { "start": \(Int(from) + 15 * 3600), "label": "Point" },
                         { "start": "2026-09-27T20:00:00Z", "end": "2026-09-28T06:00:00Z", "label": "Past midnight" },
                         { "start": \(Int(from) - 7200), "end": \(Int(from) - 3600), "label": "Before" },
                         { "end": 5, "label": "No start" } ] }
            """)
        let n = node(s)
        let t = timeline(n)
        XCTAssertEqual(t.items.map { $0.label ?? "" }, ["Long", "Overlaps", "Point", "Past midnight"], "sorted by start; out of range and unstarted dropped")
        XCTAssertEqual(t.items[0].start, 9.0 / 24, accuracy: 1e-5)
        XCTAssertEqual(t.items[0].end ?? 0, 11.0 / 24, accuracy: 1e-5)
        XCTAssertEqual(t.items[0].lane, 0)
        XCTAssertEqual(t.items[1].lane, 1, "overlapping items take the next lane")
        XCTAssertEqual(t.items[1].color, "bad")
        XCTAssertEqual(t.items[0].color, "accent")
        XCTAssertNil(t.items[2].end, "no end: a point")
        XCTAssertEqual(t.items[2].lane, 0)
        XCTAssertEqual(t.items[3].end ?? 0, 1, accuracy: 1e-9, "clipped at the right edge")
        XCTAssertEqual(t.lanes, 2)
        XCTAssertEqual(t.now ?? 0, (17.0 * 3600 + 3 * 60) / 86400, accuracy: 1e-5, "to the minute")
        XCTAssertEqual(t.nowColor, "accent")
        XCTAssertEqual(n.width, .fill)
        XCTAssertEqual(n.height, .points(36))
        XCTAssertTrue(session.usesNow, "the line moves: the engine ticks")
        XCTAssertEqual(n.alt, "timeline: Long, Overlaps, Point, Past midnight")
    }

    func testTimelineTicksFollowTheClockSetting() {
        let (h24, _) = render(#"{ "type": "timeline", "items": [] }"#, locale: "en_GB")
        XCTAssertEqual(timeline(node(h24)).ticks.map(\.label), ["00", "03", "06", "09", "12", "15", "18", "21"])
        XCTAssertEqual(timeline(node(h24)).ticks.map(\.at), (0..<8).map { Double($0) / 8 })
        let (h12, _) = render(#"{ "type": "timeline", "items": [] }"#, locale: "en_US")
        let labels = timeline(node(h12)).ticks.map(\.label)
        XCTAssertEqual(labels.count, 8)
        XCTAssertTrue(labels[4].contains("12") && labels[4].contains("PM"), "\(labels)")
        XCTAssertTrue(labels[1].contains("3") && labels[1].contains("AM"), "\(labels)")
        // A day in another zone starts at its own midnight.
        let (tz, _) = render(#"{ "type": "timeline", "items": [ { "start": "2026-09-27T12:00:00Z", "label": "noon UTC" } ] }"#,
                             zone: "America/Argentina/Buenos_Aires")
        XCTAssertEqual(timeline(node(tz)).items[0].start, 9.0 / 24, accuracy: 1e-5, "09:00 in Buenos Aires")
    }

    func testTimelineShortRangesHaveMinuteTicks() {
        let from = Int(Self.dayStart) + 9 * 3600
        let (s, _) = render(#"{ "type": "timeline", "from": \#(from), "to": \#(from + 7200), "items": [], "now": false }"#)
        let t = timeline(node(s))
        XCTAssertEqual(t.ticks.first?.label, "09:00")
        XCTAssertEqual(t.ticks[1].label, "09:15")
        XCTAssertEqual(t.ticks.count, 9)
        XCTAssertNil(t.now)
        let (week, _) = render(#"{ "type": "timeline", "from": \#(Int(Self.dayStart)), "to": \#(Int(Self.dayStart) + 7 * 86400), "items": [] }"#)
        XCTAssertEqual(timeline(node(week)).ticks.count, 8)
        XCTAssertTrue(timeline(node(week)).ticks[0].label.contains("27"), "days, not hours")
    }

    func testTimelineTimesAreExpressions() {
        let (s, _) = render(#"""
            { "type": "timeline", "source": "s", "from": ".from", "to": ".to | to_epoch", "now": false,
              "items": ".events" }
            """#, data: #"{"from": 1000, "to": "1970-01-01T00:33:20Z", "events": [ { "start": 1250, "end": 1500, "label": "x" } ]}"#)
        let t = timeline(node(s))
        XCTAssertEqual(t.items[0].start, 0.25, accuracy: 1e-9)
        XCTAssertEqual(t.items[0].end ?? 0, 0.5, accuracy: 1e-9)
    }

    func testTimelineNowOffAndOutOfRangeAndPlaceholder() {
        let (off, session) = render(#"{ "type": "timeline", "now": false, "items": [] }"#)
        XCTAssertNil(timeline(node(off)).now)
        XCTAssertFalse(session.usesNow)
        let past = Int(Self.dayStart) - 86400
        let (before, _) = render(#"{ "type": "timeline", "from": \#(past), "to": \#(past + 3600), "items": [] }"#)
        XCTAssertNil(timeline(node(before)).now, "outside the range")
        let (backwards, _) = render(#"{ "type": "timeline", "from": 100, "to": 50, "items": [] }"#)
        XCTAssertEqual(backwards.diagnostics.map(\.code), ["invalid-value"])
        let (missing, _) = render(#"{ "type": "timeline", "source": "s", "items": ".nope", "placeholder": "free day" }"#)
        XCTAssertEqual(text(node(missing))?.text, "free day")
        let (axisOnly, _) = render(#"{ "type": "timeline", "source": "s", "items": ".nope" }"#)
        XCTAssertEqual(timeline(node(axisOnly)).ticks.count, 8, "without a placeholder the axis stays")
        let (bad, _) = render(#"{ "type": "timeline", "items": [ { "start": "yesterday", "label": "x" } ] }"#)
        XCTAssertEqual(timeline(node(bad)).items, [])
        XCTAssertEqual(bad.diagnostics.first?.code, "invalid-value")
    }

    // MARK: image

    private func png() -> Data {
        Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0])
    }

    func testImageFromALocalFile() throws {
        let dir = try makeTemporaryDirectory()
        let file = dir.appendingPathComponent("cover.png")
        try png().write(to: file)
        let (s, session) = render(#"{ "type": "image", "src": "\#(file.path)" }"#)
        let n = node(s)
        XCTAssertEqual(image(n).path, file.path)
        XCTAssertEqual(image(n).fit, "cover")
        XCTAssertEqual(image(n).radius, 6)
        XCTAssertEqual(n.width, .points(48))
        XCTAssertEqual(n.height, .points(48))
        XCTAssertEqual(s.diagnostics, [])
        XCTAssertEqual(session.sourcesRead, [], "a local file waits for nothing")
        XCTAssertTrue(RenderText.tree(s).contains(" fit=cover w=48 h=48 [main/w]"), RenderText.tree(s))
        XCTAssertTrue(RenderText.tree(s).contains("  image \""), RenderText.tree(s))

        let (sized, _) = render(#"{ "type": "image", "src": "\#(file.path)", "width": 64, "height": 32, "fit": "contain", "radius": 12 }"#)
        XCTAssertEqual(image(node(sized)).fit, "contain")
        XCTAssertEqual(image(node(sized)).radius, 12)
        XCTAssertEqual(node(sized).width, .points(64))
        XCTAssertEqual(node(sized).height, .points(32))
    }

    func testImageSrcIsText() throws {
        let dir = try makeTemporaryDirectory()
        let file = dir.appendingPathComponent("a.png")
        try png().write(to: file)
        let (holes, _) = render(#"{ "type": "image", "source": "s", "src": "{{ .dir }}/a.png" }"#, data: #"{"dir": "\#(dir.path)"}"#)
        XCTAssertEqual(image(node(holes)).path, file.path)
        let (computed, _) = render(#"{ "type": "image", "source": "s", "src": { "expr": ".dir + \"/a.png\"" } }"#, data: #"{"dir": "\#(dir.path)"}"#)
        XCTAssertEqual(image(node(computed)).path, file.path)
    }

    func testMissingOrEmptyImageIsTheEmptyState() throws {
        for widget in [#"{ "type": "image", "src": "/nowhere/at/all.png" }"#, #"{ "type": "image", "src": "" }"#,
                       #"{ "type": "image", "source": "s", "src": ".nope" }"#, #"{ "type": "image" }"#,
                       #"{ "type": "image", "src": { "expr": "null" } }"#] {
            let (s, _) = render(widget)
            XCTAssertNil(image(node(s)).path, widget)
            XCTAssertEqual(node(s).width, .points(48), widget)
            XCTAssertEqual(s.diagnostics.filter { $0.severity == "error" }, [], "no error text for \(widget)")
        }
        // A directory is not a picture.
        let dir = try makeTemporaryDirectory()
        let (isDirectory, _) = render(#"{ "type": "image", "src": "\#(dir.path)" }"#)
        XCTAssertNil(image(node(isDirectory)).path)
        XCTAssertEqual(ImageCache.expandedPath("~/a.png"), NSHomeDirectory() + "/a.png")
        XCTAssertEqual(ImageCache.expandedPath("/x/a.png"), "/x/a.png")
    }

    func testRemoteImageUsesTheCacheFile() throws {
        let cache = ImageCache.shared
        let saved = (cache.directory, cache.fetchesRemote)
        cache.directory = try makeTemporaryDirectory().appendingPathComponent("images").path
        cache.fetchesRemote = false
        addTeardownBlock { cache.directory = saved.0; cache.fetchesRemote = saved.1 }

        let url = "https://art.test/covers/1.jpg"
        let (before, session) = render(#"{ "type": "image", "src": "\#(url)" }"#)
        XCTAssertNil(image(node(before)).path, "not fetched yet, and never fetched here")
        XCTAssertEqual(session.sourcesRead, ["image:" + SHA256.hex(url)], "the widget waits for its picture")
        XCTAssertNil(cache.cachedPath(for: url))

        // The cache path is the hash of the URL.
        let path = cache.path(for: url)
        XCTAssertEqual(path, cache.directory + "/" + SHA256.hex(url))
        XCTAssertEqual(SHA256.hex(url).count, 64)
        XCTAssertNotEqual(cache.path(for: url + "?v=2"), path, "another URL, another file")
        try FileManager.default.createDirectory(atPath: cache.directory, withIntermediateDirectories: true)
        try png().write(to: URL(fileURLWithPath: path))
        let (after, afterSession) = render(#"{ "type": "image", "src": "\#(url)" }"#)
        XCTAssertEqual(image(node(after)).path, path)
        XCTAssertEqual(afterSession.sourcesRead, [])
        XCTAssertEqual(after.diagnostics, [])
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func wait(_ condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }

    func testFetchStoresThePictureOnceAndTellsObservers() throws {
        let cache = ImageCache(directory: try makeTemporaryDirectory().appendingPathComponent("images").path)
        let calls = Counter()
        let received = Counter()
        let picture = png()
        cache.fetcher = { _, limit in
            XCTAssertEqual(limit, 5 * 1024 * 1024)
            _ = calls.next()
            return picture
        }
        cache.observe { key in if key == SHA256.hex("https://art.test/a.png") { _ = received.next() } }
        let url = "https://art.test/a.png"
        cache.request(url)
        XCTAssertEqual(calls.value, 0, "fetching is off until the engine turns it on")
        cache.fetchesRemote = true
        cache.request(url)
        wait { cache.cachedPath(for: url) != nil && received.value == 1 }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(cache.cachedPath(for: url)))), picture)
        XCTAssertEqual(received.value, 1)
        // Cached: not fetched again.
        cache.request(url)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(calls.value, 1)
        // Not an http(s) URL: ignored.
        cache.request("ftp://art.test/a.png")
        cache.request("/tmp/a.png")
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(calls.value, 1)
    }

    func testFailedFetchLeavesTheEmptyState() throws {
        let cache = ImageCache(directory: try makeTemporaryDirectory().appendingPathComponent("images").path)
        cache.fetchesRemote = true
        let calls = Counter()
        let received = Counter()
        struct Offline: Error {}
        cache.fetcher = { _, _ in _ = calls.next(); throw Offline() }
        cache.observe { _ in _ = received.next() }
        let url = "https://art.test/b.png"
        cache.request(url)
        wait { calls.value == 1 }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertNil(cache.cachedPath(for: url))
        XCTAssertEqual(received.value, 0)
        // Tried again only after the retry interval.
        cache.request(url)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(calls.value, 1)

        // Something that is not a picture (an error page), and a body past the limit.
        let html = "https://art.test/c.png"
        cache.fetcher = { _, _ in _ = calls.next(); return Data("<html>404</html>".utf8) }
        cache.request(html)
        wait { calls.value == 2 }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertNil(cache.cachedPath(for: html))
        let huge = "https://art.test/d.png"
        cache.fetcher = { _, _ in _ = calls.next(); return Data([0x89, 0x50, 0x4e, 0x47]) + Data(count: ImageCache.maxBytes) }
        cache.request(huge)
        wait { calls.value == 3 }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertNil(cache.cachedPath(for: huge))
        XCTAssertEqual(received.value, 0)
    }

    func testImageCacheRecognisesPictures() {
        XCTAssertTrue(ImageCache.isRemote("https://a/b.png"))
        XCTAssertTrue(ImageCache.isRemote("HTTP://a/b.png"))
        XCTAssertFalse(ImageCache.isRemote("/a/b.png"))
        XCTAssertFalse(ImageCache.isRemote("~/b.png"))
    }

    // MARK: Model coding and the minor version

    func testNodesRoundTripAndOmitDefaults() throws {
        let nodes: [RenderNode] = [
            RenderNode(id: "a", .bars(.init(values: [1, 2], max: 2, colors: ["good", "bad"], barWidth: 6, gap: 2))),
            RenderNode(id: "b", .stackedBar(.init(segments: [.init(value: 0.5, color: "accent")], trackColor: "dim", radius: 2))),
            RenderNode(id: "c", .heatmap(.init(cells: ["#ffffffff", nil], rows: 2, direction: "rows", cell: 10, gap: 3, radius: 4, trackColor: "dim"))),
            RenderNode(id: "d", .timeline(.init(items: [.init(start: 0.1, end: 0.2, label: "x", color: "accent", lane: 1), .init(start: 0.5, color: "bad")],
                                                ticks: [.init(at: 0, label: "00")], lanes: 2, now: 0.4, nowColor: "bad"))),
            RenderNode(id: "e", .image(.init(path: "/tmp/a.png", fit: "contain", radius: 10))),
        ]
        for node in nodes {
            let data = try RenderJSON.encoder.encode(node)
            XCTAssertEqual(try RenderJSON.decoder.decode(RenderNode.self, from: data), node, node.type)
        }
        func encoded(_ n: RenderNode) -> String { String(decoding: (try? RenderJSON.encoder.encode(n)) ?? Data(), as: UTF8.self) }
        XCTAssertEqual(encoded(RenderNode(id: "a", .bars(.init(values: [1], max: 1)))), #"{"id":"a","type":"bars","values":[1]}"#)
        XCTAssertEqual(encoded(RenderNode(id: "b", .stackedBar(.init(segments: [.init(value: 1, color: "good")])))),
                       #"{"id":"b","segments":[{"color":"good","value":1}],"type":"stackedBar"}"#)
        XCTAssertEqual(encoded(RenderNode(id: "c", .heatmap(.init(cells: [nil])))), #"{"cells":[null],"id":"c","type":"heatmap"}"#)
        XCTAssertEqual(encoded(RenderNode(id: "e", .image(.init()))), #"{"id":"e","type":"image"}"#)
        // A shape's corner is its own, as for `bar`.
        let decoded = try RenderJSON.decoder.decode(RenderNode.self, from: Data(#"{"id":"e","type":"image","radius":9,"path":"/x"}"#.utf8))
        XCTAssertEqual(image(decoded).radius, 9)
        XCTAssertEqual(decoded.radius, 0)
        // Unknown choices decode as the default.
        let lenient = try RenderJSON.decoder.decode(RenderNode.self, from: Data(#"{"id":"h","type":"heatmap","direction":"diagonal","rows":0}"#.utf8))
        XCTAssertEqual(heatmap(lenient).direction, "columns")
        XCTAssertEqual(heatmap(lenient).rows, 1)
    }

    func testTheMinorVersionAndOlderClients() {
        XCTAssertEqual(RenderProtocol.minor, 1)
        for type in ["bars", "stackedBar", "heatmap", "timeline", "image"] {
            XCTAssertEqual(RenderDowngrade.nodeTypeMinor[type], 1, type)
        }
        let (s, _) = render(#"{ "type": "stack", "children": [ { "type": "bars", "values": [1, 2] }, { "type": "image", "src": "/x" } ] }"#)
        let old = RenderDowngrade.snapshot(s, toMinor: 0)
        XCTAssertEqual(old.minor, 0)
        let first = node(old, "main/w/0")
        XCTAssertEqual(text(first)?.text, "bars: 1, 2", "a text with the alt")
        XCTAssertEqual(first.width, .points(160))
        XCTAssertEqual(text(node(old, "main/w/1"))?.text, "image")
        XCTAssertEqual(RenderDowngrade.snapshot(s, toMinor: 1), s)
    }

    // MARK: The showcase

    func testChartsExampleRendersItsGolden() throws {
        let path = Fixture.example("charts.json")
        let loaded = ConfigLoader.load(path: path.path)
        XCTAssertFalse(loaded.hasErrors, "\(loaded.warnings)")
        XCTAssertEqual(loaded.warnings, [])
        let model = RenderConfigModel(loaded: loaded)
        let session = RenderSession(model: model)
        session.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Argentina/Buenos_Aires"))
        session.locale = Locale(identifier: "en_GB")
        let data = RenderSources.load(
            model: model, view: session.view, mode: .fixtures(Fixture.url("charts").path), platform: SourcePlatform(),
            cache: SnapshotCache(directory: try makeTemporaryDirectory().path), allowCommands: false, allowNetwork: false,
            timeout: 1, now: Self.now)
        let snapshot = session.render(data: data, now: Self.now)
        XCTAssertEqual(snapshot.diagnostics, [])
        XCTAssertEqual(snapshot.root.duplicateIds, [])
        let tree = RenderText.tree(snapshot)
        let golden = Fixture.url("charts.golden.txt")
        if ProcessInfo.processInfo.environment["VESTAL_UPDATE_GOLDENS"] == "1" {
            try Data(tree.utf8).write(to: golden)
            return
        }
        XCTAssertEqual(tree, try String(contentsOf: golden, encoding: .utf8))
        // All five types are in it, and it round-trips.
        var types = Set<String>()
        snapshot.root.walk { types.insert($0.type) }
        XCTAssertTrue(types.isSuperset(of: ["bars", "stackedBar", "heatmap", "timeline", "image"]))
        let decoded = try RenderJSON.decoder.decode(RenderSnapshot.self, from: Data(RenderCommands.jsonText(snapshot).utf8))
        XCTAssertEqual(decoded, snapshot)
    }

    // MARK: check-config

    private func diagnostics(_ widget: String) -> [ConfigDiagnostic] {
        let text = #"{"sources": {"s": {"type": "file", "path": "/s"}}, "widgets": {"w": \#(widget)}}"#
        let loaded = ConfigLoader.load(data: Data(text.utf8), path: "test.json", platform: .linux, otherPlatforms: false)
        return ConfigDiagnostics.make(loaded, user: AnyJSON.decode(Data(text.utf8))?.objectValue, platform: .linux)
            .filter { $0.severity != .info }
    }

    private func find(_ all: [ConfigDiagnostic], _ pointer: String) -> ConfigDiagnostic? {
        all.first { $0.pointer == pointer }
    }

    func testValidConfigsAreClean() {
        for widget in [
            #"{"type": "bars", "values": "[1, 2]", "orientation": "horizontal", "labels": false, "barWidth": 4, "color": {"steps": [[0, "good"]]}}"#,
            #"{"type": "bars", "values": [1, {"value": 2}], "barWidth": {"expr": "4"}}"#,
            #"{"type": "stackedBar", "segments": "[{value: 1}]", "total": ".x", "legend": true, "color": "good"}"#,
            ##"{"type": "heatmap", "values": [1, null], "rows": 5, "scale": ["#000", "good"], "direction": "rows"}"##,
            #"{"type": "heatmap", "values": "[1]", "steps": [[0, "track"], [5, "good"]]}"#,
            #"{"type": "timeline", "from": "2026-09-27T08:00:00-03:00", "to": 1790528602, "items": "[]", "now": false, "nowColor": "bad"}"#,
            #"{"type": "timeline", "from": "now - 3600", "to": "now + 3600"}"#,
            #"{"type": "image", "src": "~/a.png", "fit": "contain", "radius": 4}"#,
            #"{"type": "image", "src": "https://x.test/{{ .id }}.png", "source": "s"}"#,
        ] {
            XCTAssertEqual(diagnostics(widget).map(\.message), [], widget)
        }
    }

    func testBadValuesAreErrorsWithPointers() throws {
        let orientation = try XCTUnwrap(find(diagnostics(#"{"type": "bars", "values": "[1]", "orientation": "vertcal"}"#), "/widgets/w/orientation"))
        XCTAssertEqual(orientation.code, "invalid-value")
        XCTAssertEqual(orientation.severity, .error)
        XCTAssertEqual(orientation.suggestions, ["vertical"])
        XCTAssertTrue(orientation.message.contains("expected vertical or horizontal"), orientation.message)

        let width = try XCTUnwrap(find(diagnostics(#"{"type": "bars", "values": "[1]", "barWidth": "wide"}"#), "/widgets/w/barWidth"))
        XCTAssertEqual(width.severity, .error)
        XCTAssertTrue(width.message.hasPrefix("expected a number"), width.message)
        XCTAssertNotNil(find(diagnostics(#"{"type": "bars", "values": "[1]", "labels": "yes"}"#), "/widgets/w/labels"))
        XCTAssertNotNil(find(diagnostics(#"{"type": "stackedBar", "segments": "[]", "legend": 1}"#), "/widgets/w/legend"))
        XCTAssertNotNil(find(diagnostics(#"{"type": "heatmap", "values": "[]", "direction": "diagonal"}"#), "/widgets/w/direction"))
        XCTAssertNotNil(find(diagnostics(#"{"type": "heatmap", "values": "[]", "cell": "big"}"#), "/widgets/w/cell"))
        XCTAssertNotNil(find(diagnostics(#"{"type": "image", "src": "/a", "fit": "stretch"}"#), "/widgets/w/fit"))
        XCTAssertNotNil(find(diagnostics(#"{"type": "timeline", "now": "always"}"#), "/widgets/w/now"))
    }

    func testHeatmapShapes() throws {
        XCTAssertNotNil(find(diagnostics(#"{"type": "heatmap", "values": "[]", "rows": 0}"#), "/widgets/w/rows"))
        XCTAssertNotNil(find(diagnostics(#"{"type": "heatmap", "values": "[]", "rows": 2.5}"#), "/widgets/w/rows"))
        XCTAssertNotNil(find(diagnostics(#"{"type": "heatmap", "values": "[]", "rows": 400}"#), "/widgets/w/rows"))
        let one = try XCTUnwrap(find(diagnostics(#"{"type": "heatmap", "values": "[]", "scale": ["good"]}"#), "/widgets/w/scale"))
        XCTAssertEqual(one.message, "scale needs two colours, [low, high]")
        let unknown = try XCTUnwrap(find(diagnostics(#"{"type": "heatmap", "values": "[]", "scale": ["good", "gren"]}"#), "/widgets/w/scale/1"))
        XCTAssertEqual(unknown.code, "unknown-color")
        XCTAssertNotNil(find(diagnostics(#"{"type": "heatmap", "values": "[]", "steps": [[0, "good"], ["x"]]}"#), "/widgets/w/steps/1"))
        XCTAssertNotNil(find(diagnostics(#"{"type": "heatmap", "values": "[]", "steps": [[0, "nope"]]}"#), "/widgets/w/steps/0/1"))
        XCTAssertNotNil(find(diagnostics(#"{"type": "heatmap", "values": "[]", "steps": "x"}"#), "/widgets/w/steps"))
    }

    func testMissingAndMisplacedData() throws {
        let missing = try XCTUnwrap(find(diagnostics(#"{"type": "bars"}"#), "/widgets/w"))
        XCTAssertEqual(missing.code, "missing-required")
        XCTAssertEqual(missing.severity, .warning)
        XCTAssertNotNil(find(diagnostics(#"{"type": "stackedBar"}"#), "/widgets/w"))
        XCTAssertNotNil(find(diagnostics(#"{"type": "heatmap"}"#), "/widgets/w"))
        XCTAssertNotNil(find(diagnostics(#"{"type": "image"}"#), "/widgets/w"))
        XCTAssertNil(find(diagnostics(#"{"type": "timeline"}"#), "/widgets/w"), "the axis alone is fine")
        XCTAssertNotNil(find(diagnostics(#"{"type": "bars", "values": 5}"#), "/widgets/w/values"))
        XCTAssertNotNil(find(diagnostics(#"{"type": "image", "src": 5}"#), "/widgets/w/src"))
    }

    func testExpressionsAreCheckedWherePointed() throws {
        XCTAssertEqual(find(diagnostics(#"{"type": "bars", "values": ".a |"}"#), "/widgets/w/values")?.code, "expr-syntax")
        XCTAssertEqual(find(diagnostics(#"{"type": "stackedBar", "segments": "[]", "total": ".a |"}"#), "/widgets/w/total")?.code, "expr-syntax")
        XCTAssertEqual(find(diagnostics(#"{"type": "timeline", "from": "now |"}"#), "/widgets/w/from")?.code, "expr-syntax")
        XCTAssertNotNil(find(diagnostics(#"{"type": "image", "src": "{{ .a | }}"}"#), "/widgets/w/src"))
        let typo = try XCTUnwrap(find(diagnostics(#"{"type": "bars", "values": "[]", "orientaton": "horizontal"}"#), "/widgets/w/orientaton"))
        XCTAssertEqual(typo.suggestions.first, "orientation")
        XCTAssertEqual(find(diagnostics(#"{"type": "bars", "values": "[]", "color": "grene"}"#), "/widgets/w/color")?.code, "unknown-color")
    }
}
