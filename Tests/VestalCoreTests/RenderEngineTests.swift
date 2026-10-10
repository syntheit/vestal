import Foundation
import VestalCore
import XCTest

// The render pass through RenderSession:
// small configs, fixed data, time, zone and locale.

final class RenderEngineTests: XCTestCase {
    /// 2026-09-27T17:03:22Z.
    static let now = Date(timeIntervalSince1970: 1_790_528_602)

    private func tree(_ text: String) -> AnyJSON {
        guard case .success(let tree) = AnyJSON.parse(Data(text.utf8)) else {
            XCTFail("bad JSON: \(text)")
            return .null
        }
        return tree
    }

    private func model(_ config: String) -> RenderConfigModel {
        RenderConfigModel(expanded: ConfigExpansion.expand(tree(config)))
    }

    private func session(_ model: RenderConfigModel, view: String? = nil) -> RenderSession {
        let session = RenderSession(model: model, view: view)
        session.timeZone = TimeZone(identifier: "UTC")!
        session.locale = Locale(identifier: "en_US_POSIX")
        session.os = "linux"
        return session
    }

    private func data(_ model: RenderConfigModel, _ sources: [String: String], metas: [String: String] = [:]) -> RenderData {
        var values: [String: JQValue] = [:]
        for (name, text) in sources { values[name] = try? JQValue.parse(text) }
        var metaValues: [String: JQValue] = [:]
        for (name, text) in metas { metaValues[name] = try? JQValue.parse(text) }
        return RenderData(sources: values, metas: metaValues, names: model.sourceNames)
    }

    /// Renders the main view of `config`, whose `widgets` are shown in key
    /// order unless it has views.
    private func render(_ config: String, sources: [String: String] = [:], now: Date = RenderEngineTests.now)
        -> RenderSnapshot {
        let m = model(config)
        return session(m).render(data: data(m, sources), now: now)
    }

    private func node(_ snapshot: RenderSnapshot, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> RenderNode? {
        let found = snapshot.root.node(withId: id) ?? snapshot.popup?.node.node(withId: id)
        if found == nil { XCTFail("no node \(id)", file: file, line: line) }
        return found
    }

    private func text(_ node: RenderNode?) -> RenderNode.Text? {
        if case .text(let t)? = node?.content { return t }
        return nil
    }

    private func stack(_ node: RenderNode?) -> RenderNode.Stack? {
        if case .stack(let s)? = node?.content { return s }
        return nil
    }

    /// One widget `w` in view main, with source `s` (a file source).
    private func one(_ widget: String) -> String {
        """
        { "sources": { "s": { "type": "file", "path": "/s" }, "t": { "type": "file", "path": "/t" } },
          "widgets": { "w": \(widget) },
          "views": { "main": { "children": ["w"] } } }
        """
    }

    // MARK: Views and containers

    func testViewRootAndStackDefaults() {
        let s = render(one(#"{ "type": "stack", "children": [ { "type": "text", "text": "a" }, { "type": "row", "children": [] } ] }"#))
        XCTAssertEqual(s.root.id, "main")
        XCTAssertEqual(s.root.maxWidth, 680)
        XCTAssertEqual(s.root.padding, RenderInsets(top: 48, right: 48, bottom: 48, left: 48))
        XCTAssertEqual(s.root.width, .fill)
        XCTAssertEqual(stack(s.root)?.gap, 24)
        XCTAssertEqual(stack(s.root)?.align, .center)
        let w = stack(node(s, "main/w"))
        XCTAssertEqual(w?.axis, .v)
        XCTAssertEqual(w?.gap, 8)
        XCTAssertEqual(w?.align, .start)
        let row = stack(node(s, "main/w/1"))
        XCTAssertEqual(row?.axis, .h)
        XCTAssertEqual(row?.align, .center)
        XCTAssertEqual(text(node(s, "main/w/0"))?.text, "a")
        XCTAssertEqual(s.views, [RenderViewInfo(name: "main", title: "Main", key: nil)])
        XCTAssertEqual(s.theme.colors["good"], "#73cf8fff")
    }

    func testGrid() {
        let s = render(one("""
            { "type": "grid", "columns": [ { "width": 170 }, { "width": "fill", "align": "end" }, { "width": "fit" } ],
              "rowGap": 4, "children": [ { "type": "text", "text": "a", "span": 2 }, { "type": "text", "text": "b" } ] }
            """))
        guard case .grid(let g)? = node(s, "main/w")?.content else { return XCTFail("not a grid") }
        XCTAssertEqual(g.columns, [.init(width: .points(170)), .init(width: .fill, align: .end), .init(width: .fit)])
        XCTAssertEqual(g.gap, 12)
        XCTAssertEqual(g.rowGap, 4)
        XCTAssertEqual(node(s, "main/w/0")?.span, 2)
        let counted = render(one(#"{ "type": "grid", "columns": 3, "children": [] }"#))
        guard case .grid(let c)? = node(counted, "main/w")?.content else { return XCTFail("not a grid") }
        XCTAssertEqual(c.columns.count, 3)
        XCTAssertEqual(c.rowGap, 12)
    }

    func testListFilterSortReverseLimitAndIds() {
        let items = #"[{"n": "c", "v": 3}, {"n": "a/b@x", "v": 1}, {"n": "d", "v": 4}, {"n": "e", "v": 0}]"#
        let s = render(one("""
            { "type": "list", "source": "s", "items": ".", "filter": ".v > 0", "sortBy": ".v", "reverse": true, "limit": 2,
              "rowId": ".n", "row": { "type": "text", "text": "{{ $index }}:{{ .n }}:{{ $item.v }}" } }
            """), sources: ["s": items])
        let list = node(s, "main/w")
        XCTAssertEqual(list?.children.map(\.id), ["main/w/@d", "main/w/@c"])
        XCTAssertEqual(text(node(s, "main/w/@d"))?.text, "0:d:4")
        let all = render(one("""
            { "type": "list", "source": "s", "items": ".[]", "sortBy": ".v", "rowId": ".n", "direction": "row", "gap": 3,
              "row": { "type": "text", "text": "{{ .n }}" } }
            """), sources: ["s": items])
        XCTAssertEqual(node(all, "main/w")?.children.map(\.id), ["main/w/@e", "main/w/@a%2Fb%40x", "main/w/@c", "main/w/@d"])
        XCTAssertEqual(stack(node(all, "main/w"))?.axis, .h)
        XCTAssertEqual(stack(node(all, "main/w"))?.gap, 3)
    }

    func testDuplicateRowIdsAndStaticItems() {
        let s = render(one("""
            { "type": "list", "items": [ {"k": "x"}, {"k": "x"}, {"k": "y"} ], "rowId": ".k", "row": { "type": "text", "text": "{{ .k }}" } }
            """))
        XCTAssertEqual(node(s, "main/w")?.children.map(\.id), ["main/w/@x", "main/w/@x~2", "main/w/@y"])
        XCTAssertEqual(s.diagnostics.filter { $0.code == "duplicate-row-id" }.count, 1)
        let byIndex = render(one(#"{ "type": "list", "items": [1, 2], "row": { "type": "text", "text": "{{ . }}" } }"#))
        XCTAssertEqual(node(byIndex, "main/w")?.children.map(\.id), ["main/w/@0", "main/w/@1"])
    }

    func testListEmptyAndHidden() {
        let hidden = render(one(#"{ "type": "list", "items": [], "row": { "type": "text", "text": "x" } }"#))
        XCTAssertTrue(hidden.root.children.isEmpty)
        let textEmpty = render(one(#"{ "type": "list", "items": [], "empty": "Nothing", "row": { "type": "text" } }"#))
        XCTAssertEqual(text(node(textEmpty, "main/w/empty"))?.text, "Nothing")
        let widgetEmpty = render(one(#"{ "type": "list", "items": [], "empty": { "type": "spacer", "height": 0 }, "row": { "type": "text" } }"#))
        XCTAssertEqual(node(widgetEmpty, "main/w/empty")?.height, .points(0))
    }

    func testTable() {
        let s = render(one("""
            { "type": "table", "source": "s", "items": ".", "rowId": ".m",
              "columns": [ { "header": "Mount", "text": "{{ .m }}" },
                           { "header": "Used", "value": ".p", "format": "percent", "align": "end",
                             "color": { "steps": [[0, "text"], [80, "bad"]] } } ] }
            """), sources: ["s": #"[{"m": "/", "p": 91.4}, {"m": "/home", "p": 12}]"#])
        guard case .grid(let g)? = node(s, "main/w")?.content else { return XCTFail("not a grid") }
        XCTAssertEqual(g.columns.map(\.align), [.start, .end])
        XCTAssertEqual(g.gap, 12)
        XCTAssertEqual(g.rowGap, 6)
        let header = text(node(s, "main/w/h/1"))
        XCTAssertEqual(header?.text, "USED")
        XCTAssertEqual(header?.size, 10)
        XCTAssertEqual(header?.color, "dim")
        XCTAssertEqual(text(node(s, "main/w/@%2F/1"))?.text, "91%")
        XCTAssertEqual(text(node(s, "main/w/@%2F/1"))?.color, "bad")
        XCTAssertEqual(text(node(s, "main/w/@%2Fhome/1"))?.color, "text")
    }

    func testSwitchCasesAndDefault() {
        let config = one("""
            { "type": "switch", "source": "s", "on": ".state", "width": "fill",
              "cases": { "playing": { "type": "text", "text": "play" } }, "default": { "type": "text", "text": "other" } }
            """)
        let playing = render(config, sources: ["s": #"{"state": "playing"}"#])
        XCTAssertEqual(text(node(playing, "main/w/=playing"))?.text, "play")
        XCTAssertEqual(node(playing, "main/w/=playing")?.width, .fill)  // the switch's box fields
        let other = render(config, sources: ["s": #"{"state": "stopped"}"#])
        XCTAssertEqual(text(node(other, "main/w/=*"))?.text, "other")
        let none = render(one(#"{ "type": "switch", "on": "\"x\"", "cases": {} }"#))
        XCTAssertTrue(none.root.children.isEmpty)
    }

    // MARK: Primitives

    func testTextValueFormatsAndPlaceholder() {
        let cases: [(String, String, String)] = [
            ("3.14159", "fixed:1", "3.1"), ("1234.9", "int", "1234"), ("2.5", "number", "2.50"),
            ("41.6", "percent", "42%"), ("41.66", "percent:1", "41.7%"), ("1234567", "thousands", "1,234,567"),
            ("3400000", "compact", "3.4M"), ("1288490188", "bytes", "1.2G"), ("1258291", "rate", "1.2M"),
            ("273600", "duration", "3d 4h"), ("273600", "uptime", "3d"), ("25", "startsIn", "in 25m"),
            ("1790528302", "relative", "5m ago"), ("1790528602", "time:HH:mm", "17:03"),
        ]
        for (value, format, expected) in cases {
            let s = render(one(#"{ "type": "text", "value": "\#(value)", "format": "\#(format)" }"#))
            XCTAssertEqual(text(node(s, "main/w"))?.text, expected, format)
            XCTAssertTrue(s.diagnostics.isEmpty, "\(format): \(s.diagnostics)")
        }
        let affixed = render(one(#"{ "type": "text", "value": "5", "prefix": "$", "suffix": " {{ $value + 1 }}" }"#))
        XCTAssertEqual(text(node(affixed, "main/w"))?.text, "$5 6")
        let placeholder = render(one(#"{ "type": "text", "value": "null", "suffix": "x" }"#))
        XCTAssertEqual(text(node(placeholder, "main/w"))?.text, "–")
        let custom = render(one(#"{ "type": "text", "value": ".missing", "placeholder": "n/a" }"#))
        XCTAssertEqual(text(node(custom, "main/w"))?.text, "n/a")
        let unknown = render(one(#"{ "type": "text", "value": "1", "format": "bogus" }"#))
        XCTAssertEqual(text(node(unknown, "main/w"))?.text, "1")
        XCTAssertEqual(unknown.diagnostics.first?.code, "invalid-value")
    }

    func testTextDefaultsAndLeadingIcon() {
        let plain = render(one(#"{ "type": "text", "text": "hi", "lines": 1, "align": "end" }"#))
        let t = text(node(plain, "main/w"))
        XCTAssertEqual(t, RenderNode.Text(text: "hi", size: 13, weight: 400, font: "sans", color: "text", lines: 1, textAlign: .end))
        let iconed = render(one(#"{ "type": "text", "text": "x", "icon": "circle", "iconColor": "accent", "size": 20 }"#))
        let row = stack(node(iconed, "main/w"))
        XCTAssertEqual(row?.gap, 5)
        guard case .icon(let icon)? = node(iconed, "main/w/icon")?.content else { return XCTFail("no icon") }
        XCTAssertEqual(icon.size, 16)
        XCTAssertEqual(icon.color, "accent")
        XCTAssertEqual(text(node(iconed, "main/w/text"))?.size, 20)
    }

    func testIcons() {
        let s = render(one("""
            { "type": "stack", "children": [ { "type": "icon", "name": "clock" }, { "type": "icon", "name": "play", "weight": "fill", "size": 10, "color": "good" },
              { "type": "icon", "name": "sf:hourglass" }, { "type": "icon", "name": "no-such-icon" },
              { "type": "icon", "name": { "expr": "\\"battery-\\" + \\"full\\"" } } ] }
            """))
        guard case .icon(let clock)? = node(s, "main/w/0")?.content,
              case .icon(let play)? = node(s, "main/w/1")?.content,
              case .icon(let sf)? = node(s, "main/w/2")?.content,
              case .icon(let computed)? = node(s, "main/w/4")?.content else { return XCTFail("icons") }
        XCTAssertEqual(clock.glyph, IconMap.glyph("clock", weight: "regular"))
        XCTAssertNotNil(clock.glyph)
        XCTAssertEqual(clock.size, 13)
        XCTAssertEqual(play.weight, "fill")
        XCTAssertEqual(play.glyph, IconMap.glyph("play", weight: "fill"))
        XCTAssertEqual(play.color, "good")
        XCTAssertNil(sf.glyph)
        XCTAssertEqual(computed.name, "battery-full")
        XCTAssertEqual(s.diagnostics.map(\.code), ["unknown-icon"])
    }

    func testProgress() {
        let s = render(one("""
            { "type": "progress", "source": "s", "label": "RAM", "labelWidth": 24, "value": ".p", "overlay": ".o",
              "width": 48, "textWidth": 30, "color": "purple" }
            """), sources: ["s": #"{"p": 61, "o": 12}"#])
        let outer = stack(node(s, "main/w"))
        XCTAssertEqual(outer?.axis, .h)
        XCTAssertEqual(outer?.gap, 4)
        XCTAssertEqual(text(node(s, "main/w/0")), RenderNode.Text(text: "RAM", size: 9, weight: 600, color: "dim", lines: 1, textAlign: .end))
        // labelWidth and textWidth are minimums: a wider font widens the frame.
        XCTAssertNil(node(s, "main/w/0")?.width)
        XCTAssertEqual(node(s, "main/w/0")?.minWidth, 24)
        XCTAssertNil(node(s, "main/w/2")?.width)
        XCTAssertEqual(node(s, "main/w/2")?.minWidth, 30)
        guard case .bar(let bar)? = node(s, "main/w/1")?.content else { return XCTFail("no bar") }
        XCTAssertEqual(bar.value, 0.61, accuracy: 1e-9)
        XCTAssertEqual(bar.overlay ?? 0, 0.12, accuracy: 1e-9)
        XCTAssertEqual(bar.color, "purple")
        XCTAssertEqual(bar.trackColor, "#ba99f726")
        XCTAssertEqual(bar.overlayColor, "#ffffff33")
        XCTAssertEqual(node(s, "main/w/1")?.width, .points(48))
        XCTAssertEqual(node(s, "main/w/1")?.height, .points(6))
        XCTAssertEqual(text(node(s, "main/w/2"))?.text, "61%")
        XCTAssertEqual(text(node(s, "main/w/2"))?.font, "mono")
        let empty = render(one(#"{ "type": "progress", "value": "null", "text": "" }"#))
        guard case .bar(let none)? = node(empty, "main/w/1")?.content else { return XCTFail("no bar") }
        XCTAssertEqual(none.value, 0)
        XCTAssertNil(none.overlay)
        XCTAssertEqual(node(empty, "main/w")?.children.count, 1)
        XCTAssertEqual(node(empty, "main/w")?.width, .fill)  // the fill bar, propagated
    }

    func testThemeScaleMultipliesFixedSizes() {
        // Text, icons and fixed sizes, not gaps or padding.
        let s = render("""
            { "theme": { "scale": 1.5 },
              "sources": { "s": { "type": "file", "path": "/s" } },
              "widgets": {
                "r": { "type": "row", "gap": 10, "padding": 4, "children": [
                  { "type": "text", "text": "a", "width": 60, "minHeight": 10, "maxWidth": 80 },
                  { "type": "spacer", "width": 84 },
                  { "type": "row", "style": { "scale": 2 }, "children": [ { "type": "text", "text": "c", "width": 10 } ] }
                ] },
                "p": { "type": "progress", "source": "s", "value": ".p", "label": "CPU", "labelWidth": 24, "width": 48, "textWidth": 30 },
                "g": { "type": "grid", "columns": [ { "width": 40 }, { "width": "fit" } ], "children": [] }
              },
              "views": { "main": { "maxWidth": 600, "children": ["r", "p", "g"] } } }
            """, sources: ["s": #"{"p": 50}"#])
        XCTAssertEqual(s.root.maxWidth, 900)
        XCTAssertEqual(s.root.padding, RenderInsets(top: 48, right: 48, bottom: 48, left: 48))
        XCTAssertEqual(stack(node(s, "main/r"))?.gap, 10)
        XCTAssertEqual(node(s, "main/r")?.padding, RenderInsets(top: 4, right: 4, bottom: 4, left: 4))
        XCTAssertEqual(node(s, "main/r/0")?.width, .points(90))
        XCTAssertEqual(node(s, "main/r/0")?.minHeight, 15)
        XCTAssertEqual(node(s, "main/r/0")?.maxWidth, 120)
        XCTAssertEqual(text(node(s, "main/r/0"))?.size, 19.5)
        XCTAssertEqual(node(s, "main/r/1")?.width, .points(126))
        XCTAssertEqual(node(s, "main/r/2/0")?.width, .points(30))
        XCTAssertEqual(node(s, "main/p/0")?.minWidth, 36)
        XCTAssertEqual(node(s, "main/p/1")?.width, .points(72))
        XCTAssertEqual(node(s, "main/p/1")?.height, .points(9))
        XCTAssertEqual(node(s, "main/p/2")?.minWidth, 45)
        guard case .grid(let grid)? = node(s, "main/g")?.content else { return XCTFail("no grid") }
        XCTAssertEqual(grid.columns.map(\.width), [.points(60), .fit])
        // Popups too: 520 points by default.
        let m = model(#"{ "theme": { "scale": 1.5 }, "widgets": { "w": { "type": "text", "text": "a" } }, "views": { "main": { "children": ["w"] } } }"#)
        let popupSession = session(m)
        popupSession.openPopup(["type": .string("text"), "text": .string("p")], width: 520)
        XCTAssertEqual(popupSession.render(data: data(m, [:]), now: Self.now).popup?.width, 780)
    }

    func testSystemHealthNameColumnFitsTheWidestName() {
        // One line per name, at least 60 wide (v0.3's column), wider for a
        // longer name, the same in every row.
        func names(_ hosts: [String]) -> [RenderNode] {
            let list = hosts.map { #"{ "name": "\#($0)", "source": "h" }"# }.joined(separator: ", ")
            let m = model("""
                { "sources": { "h": { "type": "file", "path": "/h" } },
                  "widgets": { "systems": { "type": "systemHealth", "hosts": [\(list)] } },
                  "views": { "main": { "children": ["systems"] } } }
                """)
            let s = session(m).render(data: data(m, ["h": #"{"cpu": {"usage_percent": 5}, "memory": {"usage_percent": 40}}"#],
                                                 metas: ["h": #"{"ok": true, "loaded": true}"#]), now: Self.now)
            var found: [RenderNode] = []
            func walk(_ n: RenderNode) {
                if case .text(let t) = n.content, t.font == "mono", t.weight == 600, t.size == 13 { found.append(n) }
                n.children.forEach(walk)
            }
            walk(s.root)
            return found
        }
        let short = names(["nas", "edge", "backup"])
        XCTAssertEqual(short.map { text($0)?.text }, ["nas", "edge", "backup"])
        for n in short {
            XCTAssertNil(n.width)
            XCTAssertEqual(n.minWidth, 60)
            XCTAssertEqual(text(n)?.lines, 1)
        }
        XCTAssertEqual(names(["edge", "workstation-01"]).map(\.minWidth), [112, 112])
    }

    func testGaugeSparklineKeyValueDividerSpacer() {
        let s = render("""
            { "sources": { "s": { "type": "file", "path": "/s" }, "r": { "type": "file", "path": "/r" } },
              "widgets": {
                "g": { "type": "gauge", "source": "s", "value": ".cpu", "label": "CPU", "color": { "steps": [[0, "good"], [70, "warn"]] } },
                "k": { "type": "sparkline", "source": "s", "values": ".hist", "min": 0, "max": 100, "dot": true, "fill": "accent@0.15" },
                "kv": { "type": "keyValue", "source": "s", "items": [
                          { "label": "A", "value": ".cpu", "format": "fixed:1" },
                          { "label": "B", "text": "{{ .cpu * 2 }}", "color": "bad" },
                          { "label": "C", "source": "r", "value": ".x" },
                          { "label": "D", "value": ".missing" },
                          { "label": "E", "value": "1", "when": "false" } ] },
                "d": { "type": "divider" },
                "r2": { "type": "row", "children": [ { "type": "spacer" }, { "type": "divider", "axis": "v" } ] }
              },
              "views": { "main": { "children": ["g", "k", "kv", "d", "r2"] } } }
            """, sources: ["s": #"{"cpu": 75, "hist": [1, 5, 3]}"#])
        guard case .ring(let ring)? = node(s, "main/g/0")?.content else { return XCTFail("no ring") }
        XCTAssertEqual(ring.value, 0.75, accuracy: 1e-9)
        XCTAssertEqual(ring.color, "warn")
        XCTAssertEqual(ring.sweep, 270)
        XCTAssertEqual(node(s, "main/g/0")?.width, .points(64))
        XCTAssertEqual(text(node(s, "main/g/0/0"))?.text, "75")
        XCTAssertEqual(text(node(s, "main/g/1"))?.text, "CPU")
        guard case .spark(let spark)? = node(s, "main/k")?.content else { return XCTFail("no spark") }
        XCTAssertEqual(spark.values, [1, 5, 3])
        XCTAssertEqual(spark.min, 0)
        XCTAssertEqual(spark.max, 100)
        XCTAssertTrue(spark.dot)
        XCTAssertEqual(spark.fill, "#7aa1f726")
        XCTAssertEqual(node(s, "main/k")?.height, .points(24))
        XCTAssertEqual(node(s, "main/kv")?.children.map(\.id), ["main/kv/0", "main/kv/1"])
        XCTAssertEqual(text(node(s, "main/kv/0/1"))?.text, "75.0")
        XCTAssertEqual(text(node(s, "main/kv/1/1"))?.text, "150")
        XCTAssertEqual(text(node(s, "main/kv/1/1"))?.color, "bad")
        XCTAssertEqual(text(node(s, "main/kv/0/0"))?.size, 10)
        XCTAssertEqual(stack(node(s, "main/kv"))?.gap, 24)
        XCTAssertEqual(node(s, "main/d")?.width, .fill)
        XCTAssertEqual(node(s, "main/r2/0")?.width, .fill)  // spacer along the row
        XCTAssertNil(node(s, "main/r2/1")?.width)          // a vertical rule doesn't fill width
        XCTAssertEqual(node(s, "main/r2")?.width, .fill)
        let hiddenKV = render(one(#"{ "type": "keyValue", "items": [ { "label": "x", "value": "null" } ] }"#))
        XCTAssertTrue(hiddenKV.root.children.isEmpty)
    }

    // MARK: Styles and colors

    func testStyleInheritanceTokensEmphasisAndCase() {
        let s = render(one("""
            { "type": "stack", "style": { "size": "lg", "color": "subtle", "font": "mono" }, "children": [
                { "type": "text", "text": "a" },
                { "type": "text", "text": "b", "style": { "weight": "bold", "case": "upper", "tracking": 1.5 } },
                { "type": "text", "text": "c", "style": { "emphasis": "strong" } },
                { "type": "text", "text": "d", "style": { "emphasis": "faint", "size": 30 }, "weight": 250 } ] }
            """))
        XCTAssertEqual(text(node(s, "main/w/0")), RenderNode.Text(text: "a", size: 14, font: "mono", color: "subtle"))
        XCTAssertEqual(text(node(s, "main/w/1")), RenderNode.Text(text: "B", size: 14, weight: 700, font: "mono", color: "subtle", tracking: 1.5))
        XCTAssertEqual(text(node(s, "main/w/2"))?.weight, 600)
        XCTAssertEqual(text(node(s, "main/w/2"))?.color, "text")
        XCTAssertEqual(text(node(s, "main/w/3"))?.color, "dim")
        XCTAssertEqual(text(node(s, "main/w/3"))?.size, 30)
        XCTAssertEqual(text(node(s, "main/w/3"))?.weight, 250)
    }

    func testColourForms() {
        let s = render(one("""
            { "type": "stack", "source": "s", "children": [
                { "type": "text", "value": ".n", "style": { "color": { "steps": [[0, "good"], [90, "bad"]] } } },
                { "type": "text", "text": "x", "style": { "color": { "steps": [[0, "good"], [50, "warn"]], "of": ".n" } } },
                { "type": "text", "text": "x", "style": { "color": "accent@0.5" } },
                { "type": "text", "text": "x", "style": { "color": "#abc" } },
                { "type": "text", "text": "x", "style": { "color": { "expr": "if .n > 50 then \\"red\\" else \\"green\\" end" } } },
                { "type": "text", "text": "x", "style": { "color": "nope" } },
                { "type": "text", "value": "5", "style": { "color": { "steps": [[10, "cyan"], [20, "bad"]] } } } ] }
            """), sources: ["s": #"{"n": 95}"#])
        XCTAssertEqual(text(node(s, "main/w/0"))?.color, "bad")
        XCTAssertEqual(text(node(s, "main/w/1"))?.color, "warn")
        XCTAssertEqual(text(node(s, "main/w/2"))?.color, "#7aa1f780")
        XCTAssertEqual(text(node(s, "main/w/3"))?.color, "#aabbccff")
        XCTAssertEqual(text(node(s, "main/w/4"))?.color, "red")
        XCTAssertEqual(text(node(s, "main/w/5"))?.color, "text")
        XCTAssertEqual(text(node(s, "main/w/6"))?.color, "cyan")  // below every stop: the first
        XCTAssertEqual(s.diagnostics.map(\.code), ["unknown-color"])
    }

    func testPaletteFromTheme() {
        let s = render("""
            { "theme": { "palette": "ember", "palettes": { "ember": { "extends": "tokyo-night", "colors": { "accent": "#ff9e64", "good": "teal", "brand": "#e01e5a" } } },
                         "colors": { "brand": "#e01e5a80" } },
              "widgets": { "w": { "type": "text", "text": "x", "style": { "color": "brand" } } },
              "views": { "main": { "children": ["w"] } } }
            """)
        XCTAssertEqual(s.theme.colors["accent"], "#ff9e64ff")
        XCTAssertEqual(s.theme.colors["good"], "#73d6c2ff")
        XCTAssertEqual(s.theme.colors["brand"], "#e01e5a80")
        XCTAssertEqual(text(node(s, "main/w"))?.color, "brand")
    }

    // MARK: Layout rules

    func testFillPropagatesUpward() {
        let s = render(one("""
            { "type": "stack", "children": [ { "type": "row", "children": [ { "type": "text", "text": "x", "width": "fill" } ] },
                                             { "type": "row", "width": 100, "children": [ { "type": "spacer" } ] } ] }
            """))
        XCTAssertEqual(node(s, "main/w/0")?.width, .fill)
        XCTAssertEqual(node(s, "main/w")?.width, .fill)
        XCTAssertEqual(node(s, "main/w/1")?.width, .points(100))
    }

    func testLoadingRule() {
        let hide = render(one(#"{ "type": "text", "source": "s", "text": "x" }"#))
        XCTAssertTrue(hide.root.children.isEmpty)
        let show = render(one(#"{ "type": "text", "source": "s", "loading": "show", "text": "[{{ .a }}]" }"#))
        XCTAssertEqual(text(node(show, "main/w"))?.text, "[]")
        let alternative = render(one(#"{ "type": "text", "source": "s", "loading": { "type": "text", "text": "loading…" }, "text": "x" }"#))
        XCTAssertEqual(text(node(alternative, "main/w"))?.text, "loading…")
        let loaded = render(one(#"{ "type": "text", "source": "s", "text": "{{ .a }} {{ $data.a }} {{ $meta.ok }}" }"#), sources: ["s": #"{"a": 1}"#])
        XCTAssertEqual(text(node(loaded, "main/w"))?.text, "1 1 ")
    }

    func testOrderViewsKeepTheFirstEntrysSpace() {
        let config = """
            { "widgets": { "a": { "type": "text", "text": "a", "when": "false" }, "b": { "type": "text", "text": "b", "spaceBefore": 28 } },
              "views": { "main": { "VIEWKEY": ["a", "b"] } } }
            """
        let order = render(config.replacingOccurrences(of: "VIEWKEY", with: "order"))
        XCTAssertEqual(order.root.children.map(\.id), ["main/^", "main/b"])
        XCTAssertEqual(order.root.children.first?.height, .points(0))
        let children = render(config.replacingOccurrences(of: "VIEWKEY", with: "children"))
        XCTAssertEqual(children.root.children.map(\.id), ["main/b"])
    }

    func testCompileAndRuntimeErrors() {
        let s = render("""
            { "sources": { "s": { "type": "file", "path": "/s" } },
              "widgets": { "a": { "type": "text", "text": "a", "when": ".x | rond" },
                           "b": { "type": "text", "source": "s", "text": "[{{ .v | tonumber }}]" } },
              "views": { "main": { "children": ["a", "b"] } } }
            """, sources: ["s": #"{"v": "n/a"}"#])
        XCTAssertEqual(s.root.children.map(\.id), ["main/b"])
        XCTAssertEqual(text(node(s, "main/b"))?.text, "[]")
        XCTAssertEqual(s.diagnostics.map(\.code), ["expr-unknown-function", "expr-runtime"])
        XCTAssertEqual(s.diagnostics.first?.id, "main/a")
        XCTAssertEqual(s.diagnostics.first?.field, "when")
        XCTAssertEqual(s.diagnostics.last?.id, "main/b")
    }

    func testIdsAndVariables() {
        let s = render("""
            { "widgets": { "a/b": { "type": "stack", "children": [
                  { "type": "text", "id": "named", "text": "{{ $widget }} {{ $view }} {{ $os }} {{ $tz }}" },
                  "leaf" ] },
                "leaf": { "type": "text", "text": "{{ $widget }}" } },
              "views": { "main": { "children": ["a/b", { "type": "text", "text": "inline {{ $widget }}." }] } } }
            """)
        // Darwin's Foundation names UTC "GMT".
        XCTAssertEqual(text(node(s, "main/a%2Fb/named"))?.text, "a/b main linux \(TimeZone(identifier: "UTC")!.identifier)")
        XCTAssertEqual(text(node(s, "main/a%2Fb/1"))?.text, "leaf")
        XCTAssertEqual(text(node(s, "main/1"))?.text, "inline .")
    }

    func testVarsInDependencyOrder() {
        let s = render(one(#"{ "type": "text", "vars": { "a": "$b + 1", "b": "$c * 2", "c": "3" }, "text": "{{ $a }}" }"#))
        XCTAssertEqual(text(node(s, "main/w"))?.text, "7")
    }

    // MARK: Keys and actions

    private func keyed() -> RenderConfigModel {
        model("""
            { "keys": { "g": { "open": "https://example.com" } },
              "widgets": {
                "hosts": { "type": "list", "items": [ {"name": "nas"}, {"name": "hub"}, {"name": "iphone"} ], "rowId": ".name",
                  "row": { "type": "text", "text": "{{ .name }}", "key": "auto", "keyHint": "{{ .name }}",
                           "action": { "popup": { "type": "text", "text": { "expr": ".name | ascii_upcase" },
                                                  "key": "x", "action": { "close": true } }, "width": 300 } } },
                "explicit": { "type": "text", "text": "Edit", "key": "shift+E", "action": { "copy": "copied {{ 1 + 1 }}" } }
              },
              "views": { "main": { "children": ["hosts", "explicit"], "keys": { "r": { "view": "other" } } },
                         "other": { "key": "2", "children": ["explicit"] } } }
            """)
    }

    func testWidgetKeysAutoAndExplicit() {
        let m = keyed()
        let session = self.session(m)
        let d = data(m, [:])
        _ = session.render(data: d, now: Self.now)
        XCTAssertEqual(session.widgetKeys["n"], "main/hosts/@nas")
        XCTAssertEqual(session.widgetKeys["h"], "main/hosts/@hub")
        XCTAssertEqual(session.widgetKeys["o"], "main/hosts/@iphone")  // i and p are never auto keys
        XCTAssertEqual(session.widgetKeys["shift+e"], "main/explicit")
        XCTAssertEqual(session.key("Shift+E", data: d, now: Self.now), [.copy("copied 2")])
        XCTAssertEqual(RenderKeyMap.normalize("Super+Shift+R"), "cmd+shift+r")
        XCTAssertEqual(RenderKeyMap.normalize("esc"), "escape")
    }

    func testPopupOpensFirstInKeysAndCloses() {
        let m = keyed()
        let session = self.session(m)
        let d = data(m, [:])
        var s = session.render(data: d, now: Self.now)
        XCTAssertEqual(session.invoke("main/hosts/@hub", data: d, now: Self.now), [.changed])
        s = session.render(data: d, now: Self.now)
        XCTAssertEqual(s.popup?.width, 300)
        XCTAssertEqual(s.popup?.node.id, "popup/0")
        XCTAssertEqual(text(s.popup?.node)?.text, "HUB")
        XCTAssertEqual(session.widgetKeys["x"], "popup/0")
        XCTAssertEqual(session.key("x", data: d, now: Self.now), [.changed])
        s = session.render(data: d, now: Self.now)
        XCTAssertNil(s.popup)
        // Escape closes an open popup, else hides.
        _ = session.key("n", data: d, now: Self.now)
        XCTAssertNotNil(session.popup)
        XCTAssertEqual(session.key("escape", data: d, now: Self.now), [.changed])
        XCTAssertNil(session.popup)
        XCTAssertEqual(session.key("escape", data: d, now: Self.now), [.hide])
    }

    func testViewKeysGlobalKeysAndTabs() {
        let m = keyed()
        let session = self.session(m)
        let d = data(m, [:])
        _ = session.render(data: d, now: Self.now)
        XCTAssertEqual(session.key("g", data: d, now: Self.now), [.open("https://example.com"), .hide])
        XCTAssertEqual(session.key("r", data: d, now: Self.now), [.changed])
        XCTAssertEqual(session.view, "other")
        XCTAssertEqual(session.key("tab", data: d, now: Self.now), [.changed])
        XCTAssertEqual(session.view, "main")
        XCTAssertEqual(session.key("shift+tab", data: d, now: Self.now), [.changed])
        XCTAssertEqual(session.view, "other")
        XCTAssertEqual(session.key("tab", data: d, now: Self.now), [.changed])
        XCTAssertEqual(session.key("2", data: d, now: Self.now), [.changed])  // the view's key shorthand
        XCTAssertEqual(session.view, "other")
        let s = session.render(data: d, now: Self.now)
        XCTAssertEqual(s.view, "other")
        XCTAssertEqual(s.root.children.map(\.id), ["other/explicit"])
        XCTAssertEqual(s.views.map(\.name), ["main", "other"])
        XCTAssertEqual(session.key("q", data: d, now: Self.now), [])
    }

    func testRunAndOtherActionEffects() {
        let m = model("""
            { "sources": { "s": { "type": "file", "path": "/s", "parse": "exists" } },
              "widgets": {
                "p": { "type": "text", "source": "s", "loading": "show", "text": "{{ .exists }}",
                       "action": { "run": ["~/bin/toggle", "{{ .exists }}"], "optimistic": ". + {exists: (.exists | not)}" } },
                "m": { "type": "text", "source": "s", "text": "m", "action": [ { "media": "playPause" }, { "refresh": true }, { "audio": "toggleMute", "hide": true } ] }
              },
              "views": { "main": { "children": ["p", "m"] } } }
            """)
        let session = self.session(m)
        let d = data(m, ["s": #"{"exists": false}"#])
        _ = session.render(data: d, now: Self.now)
        XCTAssertEqual(session.invoke("main/p", data: d, now: Self.now),
                       [.run(argv: ["~/bin/toggle", "false"], env: [:], timeout: nil, refreshAfter: ["s"],
                             optimistic: .object(["exists": .bool(true)]), source: "s")])
        XCTAssertEqual(session.invoke("main/m", data: d, now: Self.now),
                       [.media("playPause", source: "s"), .refresh(["s"]), .audio("toggleMute", source: "s"), .hide])
        XCTAssertEqual(session.invoke("main/nothing", data: d, now: Self.now), [])
    }

    // MARK: Dependencies and diffs

    func testOnlyRootChildrenThatReadAChangeAreEvaluated() {
        let m = model("""
            { "sources": { "s": { "type": "file", "path": "/s" }, "t": { "type": "file", "path": "/t" } },
              "widgets": { "a": { "type": "text", "source": "s", "text": "{{ .v }}" },
                           "b": { "type": "text", "source": "t", "text": "{{ .v }}" },
                           "clock": { "type": "text", "text": "{{ now | fmt_time(\\"HH:mm:ss\\") }}" } },
              "views": { "main": { "children": ["a", "b", "clock"] } } }
            """)
        let session = self.session(m)
        _ = session.render(data: data(m, ["s": #"{"v": 1}"#, "t": #"{"v": 1}"#]), now: Self.now)
        XCTAssertTrue(session.usesNow)
        XCTAssertTrue(session.sourcesRead.isSuperset(of: ["s", "t"]))
        // Both changed, but only `t` is said to have: `a` keeps its old text.
        let later = Self.now.addingTimeInterval(1)
        var s = session.render(data: data(m, ["s": #"{"v": 2}"#, "t": #"{"v": 2}"#]), now: later, changed: ["t"])
        XCTAssertEqual(text(node(s, "main/a"))?.text, "1")
        XCTAssertEqual(text(node(s, "main/b"))?.text, "2")
        XCTAssertEqual(text(node(s, "main/clock"))?.text, "17:03:22")  // no tick
        s = session.render(data: data(m, ["s": #"{"v": 3}"#, "t": #"{"v": 3}"#]), now: later, changed: [], tick: true)
        XCTAssertEqual(text(node(s, "main/clock"))?.text, "17:03:23")
        XCTAssertEqual(text(node(s, "main/a"))?.text, "1")
        s = session.render(data: data(m, ["s": #"{"v": 3}"#, "t": #"{"v": 3}"#]), now: later)
        XCTAssertEqual(text(node(s, "main/a"))?.text, "3")
    }

    func testDiffReplacesOnlyWhatChanged() {
        let config = """
            { "sources": { "s": { "type": "file", "path": "/s" } },
              "widgets": { "l": { "type": "list", "source": "s", "items": ".", "rowId": ".id", "row": { "type": "text", "text": "{{ .t }}" } },
                           "x": { "type": "text", "text": "static" } },
              "views": { "main": { "children": ["l", "x"] } } }
            """
        let before = render(config, sources: ["s": #"[{"id": "a", "t": "one"}, {"id": "b", "t": "two"}]"#])
        let after = render(config, sources: ["s": #"[{"id": "a", "t": "one"}, {"id": "b", "t": "TWO"}]"#])
        let ops = RenderDiff.ops(from: before.root, to: after.root)
        XCTAssertEqual(ops?.count, 1)
        if case .replace(let id, let node)? = ops?.first {
            XCTAssertEqual(id, "main/l/@b")
            XCTAssertEqual(text(node)?.text, "TWO")
        } else {
            XCTFail("\(String(describing: ops))")
        }
        let reordered = render(config, sources: ["s": #"[{"id": "b", "t": "two"}, {"id": "a", "t": "one"}]"#])
        guard case .replace(let parent, _)? = RenderDiff.ops(from: before.root, to: reordered.root)?.first else { return XCTFail("no op") }
        XCTAssertEqual(parent, "main/l")
        XCTAssertEqual(RenderDiff.ops(from: before.root, to: before.root), [])
        var patched = before
        patched.seq = 1
        let patch = RenderPatch(seq: 2, base: 1, ops: RenderDiff.ops(from: before.root, to: after.root) ?? [])
        XCTAssertEqual(try patched.applying(patch).root, after.root)
    }
}
