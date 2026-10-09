import Foundation
import VestalCore
import XCTest

// The drawn clock faces: `analog` and `flip` nodes, the ring's new fields,
// the arithmetic the UIs share (angles, geometry, flip layout and diffing),
// the `clock` preset's `face` param, the tree output and the minor version.

final class ClockFacesTests: XCTestCase {
    /// 2026-09-27T17:03:22Z.
    static let now = Date(timeIntervalSince1970: 1_790_528_602)

    // MARK: Helpers

    private func tree(_ text: String) -> AnyJSON {
        guard case .success(let tree) = AnyJSON.parse(Data(text.utf8)) else {
            XCTFail("bad JSON: \(text)")
            return .null
        }
        return tree
    }

    private func render(_ widget: String, zone: String = "UTC", now: Date = ClockFacesTests.now) -> RenderSnapshot {
        let config = """
            { "widgets": { "w": \(widget) }, "views": { "main": { "children": ["w"] } } }
            """
        let model = RenderConfigModel(expanded: ConfigExpansion.expand(tree(config)))
        let session = RenderSession(model: model)
        session.timeZone = TimeZone(identifier: zone)!
        session.locale = Locale(identifier: "en_GB")
        session.os = "linux"
        return session.render(data: RenderData(sources: [:], names: model.sourceNames), now: now)
    }

    private func node(_ snapshot: RenderSnapshot, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> RenderNode {
        guard let found = snapshot.root.node(withId: id) else {
            XCTFail("no node \(id)", file: file, line: line)
            return RenderNode(id: id, .spacer(.init()))
        }
        return found
    }

    private func analog(_ n: RenderNode) -> RenderNode.Analog {
        guard case .analog(let a) = n.content else { XCTFail("not analog: \(n.type)"); return .init() }
        return a
    }

    private func flip(_ n: RenderNode) -> RenderNode.Flip {
        guard case .flip(let f) = n.content else { XCTFail("not flip: \(n.type)"); return .init() }
        return f
    }

    private func ring(_ n: RenderNode) -> RenderNode.Ring {
        guard case .ring(let r) = n.content else { XCTFail("not a ring: \(n.type)"); return .init() }
        return r
    }

    // MARK: Angle math

    func testHandAnglesAtWholeHours() {
        let a = AnalogMath.angles(hour: 3, minute: 0, second: 0)
        XCTAssertEqual(a.hour, 90, accuracy: 1e-9)
        XCTAssertEqual(a.minute, 0, accuracy: 1e-9)
        XCTAssertEqual(a.second, 0, accuracy: 1e-9)
        XCTAssertEqual(AnalogMath.angles(hour: 12, minute: 0, second: 0).hour, 0, accuracy: 1e-9)
        XCTAssertEqual(AnalogMath.angles(hour: 15, minute: 0, second: 0).hour, 90, accuracy: 1e-9, "24-hour clocks wrap at 12")
    }

    func testHandsMoveContinuously() {
        // 10:10:30: the minute hand is half way to 11, the hour hand 5/12 of an hour past 10.
        let a = AnalogMath.angles(hour: 10, minute: 10, second: 30)
        XCTAssertEqual(a.second, 180, accuracy: 1e-9)
        XCTAssertEqual(a.minute, (10 + 30.0 / 60) * 6, accuracy: 1e-9)
        XCTAssertEqual(a.hour, (10 + 10.0 / 60 + 30.0 / 3600) * 30, accuracy: 1e-9)
    }

    func testStepModeUsesWholeSecondsAndSweepTheFraction() {
        let time = AnalogMath.Time(hour: 1, minute: 2, second: 3.75, day: 9)
        XCTAssertEqual(AnalogMath.angles(time, mode: "step").second, 18, accuracy: 1e-9)
        XCTAssertEqual(AnalogMath.angles(time, mode: "none").second, 18, accuracy: 1e-9)
        XCTAssertEqual(AnalogMath.angles(time, mode: "sweep").second, 22.5, accuracy: 1e-9)
    }

    func testTimeInAZone() {
        let tokyo = AnalogMath.time(Self.now, zone: "Asia/Tokyo")
        XCTAssertEqual(tokyo.hour, 2)
        XCTAssertEqual(tokyo.minute, 3)
        XCTAssertEqual(tokyo.day, 28, "past midnight there")
        XCTAssertEqual(tokyo.second, 22, accuracy: 1e-6)
        let utc = AnalogMath.time(Self.now, zone: "UTC")
        XCTAssertEqual(utc.hour, 17)
        XCTAssertEqual(utc.day, 27)
        XCTAssertEqual(AnalogMath.time(Self.now.addingTimeInterval(0.5), zone: "UTC").second, 22.5, accuracy: 1e-3)
    }

    func testPointIsClockwiseFromTwelve() {
        let top = AnalogMath.point(center: 100, radius: 50, degrees: 0)
        XCTAssertEqual(top.x, 100, accuracy: 1e-9)
        XCTAssertEqual(top.y, 50, accuracy: 1e-9)
        let right = AnalogMath.point(center: 100, radius: 50, degrees: 90)
        XCTAssertEqual(right.x, 150, accuracy: 1e-9)
        XCTAssertEqual(right.y, 100, accuracy: 1e-9)
    }

    // MARK: Geometry

    func testQuietGeometry() {
        let g = AnalogGeometry(size: 236, ticks: "none", seconds: "none", dateWindow: false, numerals: false)
        XCTAssertEqual(g.center, 118)
        XCTAssertEqual(g.hour, AnalogGeometry.Hand(length: 58, tail: 0, width: 5))
        XCTAssertEqual(g.minute, AnalogGeometry.Hand(length: 92, tail: 0, width: 3))
        XCTAssertNil(g.second)
        XCTAssertEqual(g.dotY, 14)
        XCTAssertEqual(g.dotRadius, 2.5)
        XCTAssertEqual(g.pivotRadius, 5)
        XCTAssertEqual(g.pivotHole, 0)
        XCTAssertTrue(g.ticks.isEmpty)
        XCTAssertNil(g.window)
    }

    func testFullGeometryAndScaling() {
        let g = AnalogGeometry(size: 260, ticks: "minutes", seconds: "sweep", dateWindow: true, numerals: false)
        XCTAssertEqual(g.hour, AnalogGeometry.Hand(length: 66, tail: 14, width: 6))
        XCTAssertEqual(g.minute, AnalogGeometry.Hand(length: 102, tail: 16, width: 4))
        XCTAssertEqual(g.second, AnalogGeometry.Hand(length: 114, tail: 26, width: 1.6))
        XCTAssertEqual(g.ticks.count, 60)
        XCTAssertEqual(g.ticks.filter(\.major).count, 12)
        XCTAssertEqual(g.ticks[5].degrees, 30)
        XCTAssertEqual(g.hourTickLength, 15)
        XCTAssertEqual(g.tickOuter, 123)
        XCTAssertEqual(g.window?.x, 130 + 58)
        XCTAssertEqual(g.window?.width, 32)
        XCTAssertEqual(g.dotRadius, 0)
        let half = AnalogGeometry(size: 130, ticks: "minutes", seconds: "sweep", dateWindow: false, numerals: false)
        XCTAssertEqual(half.minute.length, 51, accuracy: 1e-9, "everything scales with the size")
        XCTAssertEqual(AnalogGeometry(size: 260, ticks: "hours", seconds: "none", dateWindow: false, numerals: false).ticks.count, 12)
    }

    // MARK: Flip layout

    func testFlipLayoutOfTimeWithSeconds() {
        let layout = FlipLayout.layout(text: "10:42", small: "07", size: 90, smallSize: 40)
        XCTAssertEqual(layout.tileCount, 6)
        XCTAssertEqual(layout.height, 114)
        // 4 big tiles (80) and the colon cell (21), 4 gaps of 6; then 14, two small tiles (36) and 3.
        XCTAssertEqual(layout.width, 454.0)
        XCTAssertEqual(FlipLayout.characters(layout), ["1", "0", "4", "2", "0", "7"])
        let tiles = layout.items.filter { $0.kind == .tile }
        XCTAssertEqual(tiles.map(\.index), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(tiles[0].x, 0)
        XCTAssertEqual(tiles[2].x, 80 + 6 + 80 + 6 + 21 + 6)
        XCTAssertEqual(tiles[0].y, 0)
        XCTAssertEqual(tiles[4].y, 114 - 52, "small tiles sit on the same bottom line")
        XCTAssertEqual(layout.items.filter { $0.kind == .colon }.count, 1)
    }

    func testFlipLayoutScalesAndHandlesNoSmallGroup() {
        let layout = FlipLayout.layout(text: "9 5", small: "", size: 45, smallSize: 20)
        XCTAssertEqual(layout.tileCount, 2)
        XCTAssertEqual(layout.height, 57)
        XCTAssertEqual(layout.items.map(\.kind), [.tile, .space, .tile])
        XCTAssertEqual(FlipLayout.layout(text: "", small: "", size: 90, smallSize: 40).width, 0)
    }

    func testColonSquares() {
        let squares = FlipLayout.colonSquares(height: 114, scale: 1)
        XCTAssertEqual(squares.y, [19, 50])
        XCTAssertEqual(squares.side, 9)
    }

    // MARK: Flip diffing

    func testOnlyChangedTilesFold() {
        XCTAssertEqual(FlipLayout.changedTiles(old: ["1", "7", "0", "3"], new: ["1", "7", "0", "4"]), [3])
        XCTAssertEqual(FlipLayout.changedTiles(old: ["1", "7", "0", "9"], new: ["1", "8", "1", "0"]), [1, 2, 3])
        XCTAssertEqual(FlipLayout.changedTiles(old: ["1", "7"], new: ["1", "7"]), [])
    }

    func testNewOrReshapedNodesDoNotFold() {
        XCTAssertEqual(FlipLayout.changedTiles(old: [], new: ["1", "2"]), [], "no previous text")
        XCTAssertEqual(FlipLayout.changedTiles(old: ["1", "2"], new: ["1", "2", "3"]), [], "a different number of tiles")
    }

    func testFoldTiming() throws {
        let start = try XCTUnwrap(FlipTiming.angles(elapsed: 0))
        XCTAssertEqual(start.top, 0, accuracy: 1e-9)
        XCTAssertEqual(start.bottom, 90)
        let middle = try XCTUnwrap(FlipTiming.angles(elapsed: 170))
        XCTAssertEqual(middle.top, 90, accuracy: 1e-9, "the top half is down after 170 ms")
        XCTAssertEqual(middle.bottom, 90, accuracy: 1e-9)
        let late = try XCTUnwrap(FlipTiming.angles(elapsed: 339))
        XCTAssertEqual(late.top, 90)
        XCTAssertLessThan(late.bottom, 1)
        XCTAssertNil(FlipTiming.angles(elapsed: 340), "done after the second half")
        let early = try XCTUnwrap(FlipTiming.angles(elapsed: 85))
        XCTAssertGreaterThan(early.top, 0)
        XCTAssertLessThan(early.top, 90)
    }

    // MARK: Ring geometry

    func testPlainRingGeometryIsUnchanged() {
        let g = RingGeometry(side: 64, ring: RenderNode.Ring(value: 0.5))
        XCTAssertEqual(g.radius, 29)
        XCTAssertEqual(g.sweep, 270 * Double.pi / 180, accuracy: 1e-12)
        XCTAssertEqual(g.start, Double.pi / 2 + (2 * Double.pi - g.sweep) / 2, accuracy: 1e-12, "the gap is at the bottom")
    }

    func testFullRingStartsAtTheTopAndLeavesRoomForMarks() {
        let g = RingGeometry(side: 272, ring: RenderNode.Ring(sweep: 360, thickness: 5, ticks: 24))
        XCTAssertEqual(g.start, -Double.pi / 2, accuracy: 1e-12)
        XCTAssertEqual(g.radius, 136 - 15)
        XCTAssertTrue(g.isFull)
        XCTAssertEqual(g.angle(at: 0.25), 0, accuracy: 1e-12, "a quarter is three o'clock")
        XCTAssertEqual(g.tickFraction(6), 0.25, accuracy: 1e-12)
        XCTAssertTrue(g.isMajor(0))
        XCTAssertTrue(g.isMajor(6))
        XCTAssertFalse(g.isMajor(5))
        XCTAssertEqual(g.labelFraction(3, of: 4), 0.75, accuracy: 1e-12)
        XCTAssertEqual(g.labelRadius, 121 - 20)
        XCTAssertEqual(g.tickRadii(major: true).outer, 121 + 15)
        XCTAssertEqual(g.tickRadii(major: false).inner, 121 + 9)
    }

    func testAnArcHasMarksOnItsEnds() {
        let g = RingGeometry(side: 100, ring: RenderNode.Ring(sweep: 180, ticks: 5))
        XCTAssertFalse(g.isFull)
        XCTAssertEqual(g.tickFraction(0), 0)
        XCTAssertEqual(g.tickFraction(4), 1)
        XCTAssertEqual(g.labelFraction(2, of: 3), 1)
    }

    // MARK: Model coding

    func testAnalogAndFlipRoundTrip() throws {
        let a = RenderNode(id: "a", .analog(.init(size: 260, ticks: "minutes", seconds: "sweep", dateWindow: true, numerals: true,
                                                  zone: "Asia/Tokyo", color: "dim", faceColor: "#00000052", secondsColor: "warn",
                                                  pivotColor: "good")))
        XCTAssertEqual(try RenderJSON.decoder.decode(RenderNode.self, from: RenderJSON.encoder.encode(a)), a)
        let f = RenderNode(id: "f", .flip(.init(text: "10:42", small: "07", size: 60, smallSize: 27, color: "accent", tile: "#112233ff",
                                                tileBottom: "#001122ff", animate: false)))
        XCTAssertEqual(try RenderJSON.decoder.decode(RenderNode.self, from: RenderJSON.encoder.encode(f)), f)
        let r = RenderNode(id: "r", .ring(.init(value: 0.4, sweep: 360, thickness: 5, dot: true, dotColor: "accent", ticks: 24,
                                                labels: ["00", "06", "12", "18"])))
        XCTAssertEqual(try RenderJSON.decoder.decode(RenderNode.self, from: RenderJSON.encoder.encode(r)), r)
    }

    func testDefaultsAreLeftOut() throws {
        let a = String(decoding: try RenderJSON.encoder.encode(RenderNode(id: "a", .analog(.init()))), as: UTF8.self)
        XCTAssertEqual(a, #"{"id":"a","type":"analog"}"#)
        let f = String(decoding: try RenderJSON.encoder.encode(RenderNode(id: "f", .flip(.init(text: "12")))), as: UTF8.self)
        XCTAssertEqual(f, #"{"id":"f","text":"12","type":"flip"}"#)
        let r = String(decoding: try RenderJSON.encoder.encode(RenderNode(id: "r", .ring(.init(value: 0.5)))), as: UTF8.self)
        XCTAssertEqual(r, #"{"id":"r","type":"ring","value":0.5}"#, "a plain ring has none of the new fields")
    }

    func testTheMinorVersion() {
        XCTAssertEqual(RenderProtocol.minor, 3)
        XCTAssertEqual(RenderDowngrade.nodeTypeMinor["analog"], 2)
        XCTAssertEqual(RenderDowngrade.nodeTypeMinor["flip"], 2)
        let s = render(#"{ "type": "stack", "children": [ { "type": "flip", "text": "10:42" }, { "type": "analog" } ] }"#)
        let old = RenderDowngrade.snapshot(s, toMinor: 1)
        XCTAssertEqual(old.minor, 1)
        if case .text(let t) = node(old, "main/w/0").content { XCTAssertEqual(t.text, "10:42") } else { XCTFail("flip is not text") }
        if case .text(let t) = node(old, "main/w/1").content { XCTAssertEqual(t.text, "clock") } else { XCTFail("analog is not text") }
        XCTAssertEqual(node(old, "main/w/0").width, node(s, "main/w/0").width, "the size is kept")
    }

    // MARK: Widgets

    func testAnalogWidget() {
        let s = render(#"{ "type": "analog", "size": 200, "ticks": "minutes", "seconds": "sweep", "dateWindow": true, "zone": "Asia/Tokyo" }"#)
        let n = node(s, "main/w")
        let a = analog(n)
        XCTAssertEqual(a.size, 200)
        XCTAssertEqual(a.ticks, "minutes")
        XCTAssertEqual(a.seconds, "sweep")
        XCTAssertTrue(a.dateWindow)
        XCTAssertEqual(a.zone, "Asia/Tokyo")
        XCTAssertEqual(a.secondsColor, "bad")
        XCTAssertEqual(a.pivotColor, "bad", "the pivot follows the seconds hand")
        XCTAssertEqual(n.width, .points(200))
        XCTAssertEqual(n.height, .points(200))
        XCTAssertEqual(s.diagnostics.count, 0)
    }

    func testAnalogDefaults() {
        let quiet = analog(node(render(#"{ "type": "analog", "ticks": "none" }"#), "main/w"))
        XCTAssertEqual(quiet.size, 236)
        XCTAssertEqual(quiet.seconds, "none")
        XCTAssertEqual(quiet.pivotColor, "accent")
        let ticks = analog(node(render(#"{ "type": "analog" }"#), "main/w"))
        XCTAssertEqual(ticks.ticks, "hours")
        XCTAssertEqual(ticks.size, 260)
        XCTAssertEqual(analog(node(render(#"{ "type": "analog", "seconds": true }"#), "main/w")).seconds, "step")
        XCTAssertEqual(analog(node(render(#"{ "type": "analog", "seconds": "step" }"#), "main/w")).seconds, "step")
        XCTAssertEqual(analog(node(render(#"{ "type": "analog", "size": 0 }"#), "main/w")).size, 260, "0 is the face's own size")
    }

    func testAnalogReportsBadValues() {
        let s = render(#"{ "type": "analog", "ticks": "weekly", "seconds": "fast", "zone": "Nowhere/Land" }"#)
        XCTAssertEqual(analog(node(s, "main/w")).ticks, "hours")
        XCTAssertEqual(analog(node(s, "main/w")).seconds, "none")
        XCTAssertNil(analog(node(s, "main/w")).zone)
        XCTAssertEqual(s.diagnostics.count, 3)
    }

    func testAnalogScalesWithTheTheme() {
        let s = render(#"{ "type": "analog", "size": 100, "style": { "scale": 2 } }"#)
        XCTAssertEqual(analog(node(s, "main/w")).size, 200)
    }

    func testFlipWidgetTextAndSize() {
        let s = render(#"{ "type": "flip", "text": "{{ now | fmt_time(\"HH:mm\") }}", "small": "{{ now | fmt_time(\"ss\") }}" }"#)
        let n = node(s, "main/w")
        let f = flip(n)
        XCTAssertEqual(f.text, "17:03")
        XCTAssertEqual(f.small, "22")
        XCTAssertEqual(f.size, 90)
        XCTAssertEqual(f.smallSize, 40)
        XCTAssertTrue(f.animate)
        XCTAssertEqual(n.width, .points(454))
        XCTAssertEqual(n.height, .points(114))
        XCTAssertEqual(n.alt, "17:03 22")
    }

    func testFlipTileColorsComeFromThePalette() {
        let f = flip(node(render(#"{ "type": "flip", "text": "1" }"#), "main/w"))
        XCTAssertEqual(f.tile, "#2a2c35ff", "bg #1a1c26 with 7% white")
        XCTAssertEqual(f.tileBottom, "#1f212aff", "bg with 2% white")
        let own = flip(node(render(##"{ "type": "flip", "text": "1", "tileColor": "#336699" }"##), "main/w"))
        XCTAssertEqual(own.tile, "#336699ff")
        XCTAssertNotEqual(own.tileBottom, own.tile)
    }

    func testFlipSmallSizeFollowsTheBigOne() {
        let f = flip(node(render(#"{ "type": "flip", "text": "12", "small": "34", "size": 45 }"#), "main/w"))
        XCTAssertEqual(f.size, 45)
        XCTAssertEqual(f.smallSize, 20)
    }

    func testGaugeRingFields() {
        let s = render(#"""
            { "type": "gauge", "value": 25, "size": 200, "thickness": 5, "sweep": 360, "ticks": 24, "dot": true, "dotColor": "accent",
              "labels": ["00", "{{ 3 + 3 }}", "12", "18"], "center": { "type": "text", "text": "hi" } }
            """#)
        let r = ring(node(s, "main/w/0"))
        XCTAssertEqual(r.sweep, 360)
        XCTAssertEqual(r.ticks, 24)
        XCTAssertTrue(r.dot)
        XCTAssertEqual(r.dotColor, "accent")
        XCTAssertEqual(r.labels, ["00", "6", "12", "18"])
        XCTAssertEqual(r.value, 0.25)
        if case .text(let t)? = r.center?.content { XCTAssertEqual(t.text, "hi") } else { XCTFail("no center text") }
    }

    func testPlainGaugeHasNoNewFields() {
        let r = ring(node(render(#"{ "type": "gauge", "value": 50 }"#), "main/w/0"))
        XCTAssertFalse(r.dot)
        XCTAssertEqual(r.ticks, 0)
        XCTAssertEqual(r.labels, [])
    }

    // MARK: The clock preset

    private func clock(_ settings: String) -> RenderSnapshot {
        render(#"{ "type": "clock", \#(settings) "worldClocks": [{ "label": "TYO", "tz": "Asia/Tokyo" }] }"#)
    }

    func testDefaultClockKeepsItsNodesAndIds() {
        let s = clock("")
        XCTAssertNotNil(s.root.node(withId: "main/w/0"))
        XCTAssertNotNil(s.root.node(withId: "main/w/1"))
        XCTAssertNotNil(s.root.node(withId: "main/w/2"))
        XCTAssertNil(s.root.node(withId: "main/w/analog"))
        XCTAssertEqual(s.root.node(withId: "main/w/2")?.children.count, 1, "the world clock row")
        var types = Set<String>()
        s.root.walk { types.insert($0.type) }
        XCTAssertFalse(types.contains("analog"))
        XCTAssertFalse(types.contains("flip"))
    }

    func testAnalogFace() {
        let s = clock(#""face": "analog", "ticks": "minutes", "seconds": "sweep", "dateWindow": true,"#)
        let a = analog(node(s, "main/w/analog/0"))
        XCTAssertEqual(a.ticks, "minutes")
        XCTAssertEqual(a.seconds, "sweep")
        XCTAssertTrue(a.dateWindow)
        XCTAssertEqual(a.size, 260)
        XCTAssertNil(s.root.node(withId: "main/w/0"), "the text time is gone")
        XCTAssertNil(s.root.node(withId: "main/w/analog/1"), "the date is in the window")
        XCTAssertNotNil(s.root.node(withId: "main/w/2"), "world clocks stay under the dial")
        XCTAssertEqual(s.diagnostics.count, 0)
    }

    func testQuietAnalogFaceHasTheDateUnderIt() {
        let s = clock(#""face": "analog","#)
        let a = analog(node(s, "main/w/analog/0"))
        XCTAssertEqual(a.ticks, "none")
        XCTAssertEqual(a.size, 236)
        XCTAssertNotNil(s.root.node(withId: "main/w/analog/1"))
    }

    func testAnalogSubdialsForTheWorldClocks() {
        let s = render(#"""
            { "type": "clock", "face": "analog", "subdials": "worldClocks",
              "worldClocks": [{ "label": "NYC", "tz": "America/New_York" }, { "label": "TYO", "tz": "Asia/Tokyo" }] }
            """#)
        var dials: [RenderNode.Analog] = [], texts: [String] = []
        s.root.walk { n in
            if case .analog(let a) = n.content { dials.append(a) }
            if case .text(let t) = n.content { texts.append(t.text) }
        }
        XCTAssertEqual(dials.count, 3, "the local dial and one per world clock")
        XCTAssertEqual(dials[1].zone, "America/New_York")
        XCTAssertEqual(dials[2].zone, "Asia/Tokyo")
        XCTAssertEqual(dials[1].ticks, "dots")
        XCTAssertEqual(dials[1].size, 64)
        XCTAssertNotNil(dials[1].nightFaceColor)
        XCTAssertNil(dials[0].nightFaceColor)
        // 17:03 UTC: 13:03 in New York (4 hours behind, day), 02:03 in Tokyo (9 ahead, night).
        XCTAssertTrue(texts.contains("\u{2212}4h \u{00B7} day"), "\(texts)")
        XCTAssertTrue(texts.contains("+9h \u{00B7} night"), "\(texts)")
        XCTAssertEqual(s.diagnostics.count, 0, "\(s.diagnostics)")
        // Without it the row of times stays.
        var plain = 0
        render(#"{ "type": "clock", "face": "analog", "worldClocks": [{ "label": "TYO", "tz": "Asia/Tokyo" }] }"#).root.walk {
            if case .analog = $0.content { plain += 1 }
        }
        XCTAssertEqual(plain, 1)
    }

    func testAnalogDotTicksAndDayNight() throws {
        let g = AnalogGeometry(size: 64, ticks: "dots", seconds: "none", dateWindow: false, numerals: false)
        XCTAssertEqual(g.dotMarks.count, 12)
        XCTAssertEqual(g.dotMarks.filter(\.major).map(\.degrees), [0, 90, 180, 270])
        XCTAssertEqual(g.ticks.count, 0)
        XCTAssertEqual(g.hour.length, 15, accuracy: 1e-9)
        XCTAssertEqual(g.minute.length, 23, accuracy: 1e-9)
        XCTAssertEqual(g.tickDotOrbit, 27, accuracy: 1e-9)
        XCTAssertEqual(g.pivotRadius, 2, accuracy: 1e-9)
        XCTAssertTrue(AnalogGeometry(size: 64, ticks: "hours", seconds: "none", dateWindow: false, numerals: false).dotMarks.isEmpty)
        XCTAssertFalse(AnalogMath.isDay(hour: 6))
        XCTAssertTrue(AnalogMath.isDay(hour: 7))
        XCTAssertTrue(AnalogMath.isDay(hour: 18))
        XCTAssertFalse(AnalogMath.isDay(hour: 19))
        let n = analog(node(render(##"{ "type": "analog", "size": 64, "ticks": "dots", "faceColor": "text@0.12", "nightFaceColor": "#00000052" }"##), "main/w"))
        XCTAssertEqual(n.ticks, "dots")
        XCTAssertEqual(n.nightFaceColor, "#00000052")
        let node = RenderNode(id: "a", .analog(n))
        XCTAssertEqual(try JSONDecoder().decode(RenderNode.self, from: JSONEncoder().encode(node)), node)
    }

    // MARK: Matrix

    private func matrix(_ n: RenderNode) -> RenderNode.Matrix {
        guard case .matrix(let m) = n.content else { XCTFail("not matrix: \(n.type)"); return .init() }
        return m
    }

    func testMatrixGeometryDotsAndSegments() {
        let dots = MatrixGeometry.layout(text: "12:34", segments: false, size: 84)
        XCTAssertEqual(dots.cells.count, 4 * 35 + 2)
        XCTAssertEqual(dots.width, 4 * 72 + 24 - 12)
        XCTAssertEqual(dots.height, 84)
        let eight = MatrixGeometry.layout(text: "8", segments: false, size: 84)
        XCTAssertEqual(eight.cells.filter(\.lit).count, 17)
        XCTAssertEqual(eight.cells.count, 35, "the unlit dots are there too")
        XCTAssertEqual(eight.cells[0].x, 6)
        XCTAssertEqual(eight.cells[0].radius, 4.3, accuracy: 1e-9)
        let segs = MatrixGeometry.layout(text: "1 8:", segments: true, size: 84)
        XCTAssertEqual(segs.cells.count, 7 * 3 + 2)
        XCTAssertEqual(segs.cells.prefix(7).filter(\.lit).count, 2, "a one lights two segments")
        XCTAssertEqual(segs.cells[7..<14].filter(\.lit).count, 0, "a blank digit is all unlit")
        XCTAssertEqual(segs.height, 86)
        XCTAssertEqual(segs.width, 56 * 3 + 22 - 10)
        // The size scales everything.
        XCTAssertEqual(MatrixGeometry.layout(text: "12:34", segments: false, size: 42).width, dots.width / 2, accuracy: 1e-9)
        XCTAssertEqual(MatrixGeometry.layout(text: "", segments: false, size: 84).width, 0)
    }

    func testMatrixFaceFollowsTheClock() {
        let s = clock(#""face": "matrix", "color": "orange", "seconds": true,"#)
        let m = matrix(node(s, "main/w/matrix/0"))
        XCTAssertEqual(m.text, "17:03:22")
        XCTAssertEqual(m.cells, "dots")
        XCTAssertEqual(m.color, "orange")
        XCTAssertEqual(m.size, 84)
        XCTAssertNotNil(m.offColor)
        XCTAssertNotNil(s.root.node(withId: "main/w/2"), "world clocks stay under it")
        XCTAssertEqual(s.diagnostics.count, 0, "\(s.diagnostics)")
        // Seconds are on by default; false drops them.
        XCTAssertEqual(matrix(node(clock(#""face": "matrix","#), "main/w/matrix/0")).text, "17:03:22")
        XCTAssertEqual(matrix(node(clock(#""face": "matrix", "seconds": false,"#), "main/w/matrix/0")).text, "17:03")
        // 12-hour time pads the hour with a blank, so the digits don't move.
        let early = Date(timeIntervalSince1970: 1_790_528_602 - 12 * 3600)
        let twelve = render(#"{ "type": "clock", "face": "matrix", "cells": "segments", "hour12": true }"#, now: early)
        let t = matrix(node(twelve, "main/w/matrix/0"))
        XCTAssertEqual(t.text, " 5:03:22")
        XCTAssertEqual(t.cells, "segments")
        XCTAssertEqual(node(twelve, "main/w/matrix/0").width, .points(t.layout.width))
    }

    func testMatrixNodeCodingAndDowngrade() throws {
        let node = RenderNode(id: "m", .matrix(.init(text: "12:30", cells: "segments", size: 60, color: "#ff0000ff", offColor: "#ffffff10")))
        XCTAssertEqual(try JSONDecoder().decode(RenderNode.self, from: JSONEncoder().encode(node)), node)
        XCTAssertEqual(String(decoding: try RenderJSON.encoder.encode(RenderNode(id: "m", .matrix(.init(text: "1")))), as: UTF8.self),
                       #"{"id":"m","text":"1","type":"matrix"}"#)
        XCTAssertEqual(RenderDowngrade.nodeTypeMinor["matrix"], 3)
        var n = RenderNode(id: "m", .matrix(.init(text: "12:30")))
        n.alt = "12:30"
        if case .text(let t) = RenderDowngrade.node(n, toMinor: 2).content { XCTAssertEqual(t.text, "12:30") } else { XCTFail("not text") }
    }

    func testFlipFace() {
        let s = clock(#""face": "flip", "seconds": true,"#)
        let f = flip(node(s, "main/w/flip/0"))
        XCTAssertEqual(f.text, "17:03")
        XCTAssertEqual(f.small, "22")
        XCTAssertNil(s.root.node(withId: "main/w/flip/1/1"), "no am or pm in 24 hours")
        let twelve = clock(#""face": "flip", "hour12": true,"#)
        XCTAssertEqual(flip(node(twelve, "main/w/flip/0")).text, "05:03")
        XCTAssertEqual(flip(node(twelve, "main/w/flip/0")).small, "")
        if case .text(let t)? = twelve.root.node(withId: "main/w/flip/1/1")?.content { XCTAssertEqual(t.text, "PM") } else { XCTFail("no PM tag") }
    }

    func testRingFaceFillsTheDay() {
        let s = clock(#""face": "ring","#)
        let r = ring(node(s, "main/w/ring/0"))
        XCTAssertEqual(r.sweep, 360)
        XCTAssertEqual(r.ticks, 24)
        XCTAssertTrue(r.dot)
        XCTAssertEqual(r.labels, ["00", "06", "12", "18"])
        // 17:03:22 of the day.
        XCTAssertEqual(r.value, Double(61402) / 86400.0, accuracy: 1e-6)
        let texts = s.root.node(withId: "main/w/ring/0")?.children.first?.children ?? []
        XCTAssertEqual(texts.count, 2)
    }

    func testRingFaceAcrossWorkHours() {
        let s = clock(#""face": "ring", "span": "work","#)
        let r = ring(node(s, "main/w/ring/0"))
        XCTAssertEqual(r.value, Double(61402 - 32400) / 32400.0, accuracy: 1e-6)
        XCTAssertEqual(r.labels, ["09", "11", "13", "15"])
        let custom = ring(node(clock(#""face": "ring", "span": ["08:00", "20:00"],"#), "main/w/ring/0"))
        XCTAssertEqual(custom.value, Double(61402 - 28800) / 43200.0, accuracy: 1e-6)
        XCTAssertEqual(custom.labels, ["08", "11", "14", "17"])
    }

    func testRingFaceClampsOutsideTheSpan() {
        let early = Date(timeIntervalSince1970: 1_790_467_200 + 6 * 3600)  // 06:00 UTC
        let r = ring(node(render(#"{ "type": "clock", "face": "ring", "span": "work" }"#, now: early), "main/w/ring/0"))
        XCTAssertEqual(r.value, 0)
    }

    // MARK: Validation, schema and samples

    func testSchemaKnowsTheNewTypes() {
        for type in ["analog", "flip"] {
            XCTAssertNotNil(SchemaRegistry.v04WidgetTypes.first { $0.name == type }, type)
        }
        let gauge = SchemaRegistry.v04WidgetTypes.first { $0.name == "gauge" }
        let keys = Set(gauge?.keys.map(\.name) ?? [])
        XCTAssertTrue(keys.isSuperset(of: ["dot", "dotColor", "ticks", "labels", "center"]))
    }

    func testCheckConfigAcceptsAndCatchesFaces() throws {
        let dir = try makeTemporaryDirectory()
        let good = dir.appendingPathComponent("good.json")
        try Data(#"""
            { "version": 1, "widgets": { "a": { "type": "analog", "ticks": "minutes", "seconds": "sweep", "dateWindow": true },
                                        "f": { "type": "flip", "text": "12:00" },
                                        "c": { "type": "clock", "face": "flip", "seconds": true } },
              "views": { "main": { "children": ["a", "f", "c"] } } }
            """#.utf8).write(to: good)
        let ok = ConfigCommands.checkConfig([good.path, "--json"])
        XCTAssertEqual(ok.status, 0, ok.stdout)
        let bad = dir.appendingPathComponent("bad.json")
        try Data(#"""
            { "version": 1, "widgets": { "a": { "type": "analog", "tix": 3, "faceColor": "nope" } },
              "views": { "main": { "children": ["a"] } } }
            """#.utf8).write(to: bad)
        let found = ConfigCommands.checkConfig([bad.path, "--json"])
        XCTAssertTrue(found.stdout.contains("tix"), found.stdout)
    }

    func testFaceHelpersAreNotUserFacingPresets() {
        for name in ["clockAnalog", "clockFlip", "clockMatrix", "clockRing"] {
            XCTAssertTrue(SampleLibrary.helpers.contains(name), name)
            XCTAssertNotNil(TemplateRegistry.standard.builtins[name], name)
        }
    }

    // MARK: Text output

    func testTreeAndTextOutput() {
        let s = clock(#""face": "flip", "seconds": true,"#)
        let tree = RenderText.tree(s)
        XCTAssertTrue(tree.contains(#"flip "17:03" small="22" size=90 w=454 h=114 [main/w/flip/0]"#), tree)
        let analogTree = RenderText.tree(clock(#""face": "analog", "ticks": "hours", "seconds": "step","#))
        XCTAssertTrue(analogTree.contains("analog size=260 ticks=hours seconds=step w=260 h=260 [main/w/analog/0]"), analogTree)
        let ringTree = RenderText.tree(clock(#""face": "ring","#))
        XCTAssertTrue(ringTree.contains("sweep=360"), ringTree)
        XCTAssertTrue(ringTree.contains("dot ticks=24 labels=[00,06,12,18]"), ringTree)
        let picture = RenderText.picture(s)
        XCTAssertTrue(picture.contains("17:03 22"), picture)
    }
}
