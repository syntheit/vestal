import Foundation
import VestalCore
import XCTest

// `worldClocks`, `sunMoon`, `countdowns`, `forecast` and `aiPlan`, and the
// two bar and sparkline additions they rest on (`progress` start and tick,
// `sparkline` dotAt).

final class TimePresetsTests: XCTestCase {
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

    /// One widget in view main. `sources` maps a name to the (already
    /// transformed) data its file source gives.
    private func render(_ widget: String, sources: [String: String] = [:], now: Date = TimePresetsTests.now,
                        zone: String = "UTC") -> RenderSnapshot {
        let declared = sources.keys.sorted().map { #""\#($0)": { "type": "file", "path": "/\#($0)" }"# }.joined(separator: ", ")
        let config = """
            { "sources": { \(declared) },
              "widgets": { "w": \(widget) },
              "views": { "main": { "children": ["w"] } } }
            """
        let model = RenderConfigModel(expanded: ConfigExpansion.expand(tree(config)))
        let session = RenderSession(model: model)
        session.timeZone = TimeZone(identifier: zone)!
        session.locale = Locale(identifier: "en_GB")
        session.os = "linux"
        var values: [String: JQValue] = [:]
        for (name, text) in sources { values[name] = (try? JQValue.parse(text)) ?? .null }
        let snapshot = session.render(data: RenderData(sources: values, names: model.sourceNames), now: now)
        XCTAssertEqual(snapshot.diagnostics.map(\.message), [])
        return snapshot
    }

    private func texts(_ snapshot: RenderSnapshot) -> [String] {
        var all: [String] = []
        snapshot.root.walk { node in if case .text(let t) = node.content { all.append(t.text) } }
        return all
    }

    private func bars(_ snapshot: RenderSnapshot) -> [RenderNode.Bar] {
        var all: [RenderNode.Bar] = []
        snapshot.root.walk { node in if case .bar(let b) = node.content { all.append(b) } }
        return all
    }

    private func number(_ value: AnyJSON?) -> Double {
        switch value {
        case .int(let i)?: return Double(i)
        case .double(let d)?: return d
        default: return .nan
        }
    }

    // MARK: worldClocks

    func testWorldClocksShowTimeOffsetAndWorkingHours() {
        let widget = """
            { "type": "worldClocks", "cities": [
              { "label": "LA", "zone": "America/Los_Angeles" },
              { "label": "Mumbai", "zone": "Asia/Kolkata" },
              { "label": "Nowhere", "zone": "Mars/Olympus" },
              { "label": "UTC", "zone": "UTC" },
              { "label": "LA", "zone": "America/Vancouver" } ] }
            """
        let all = texts(render(widget))
        // 17:03 UTC: 10:03 in Los Angeles (UTC-7, working), 22:33 in Mumbai (+5:30), the zone itself is "local".
        XCTAssertEqual(all, ["LA", "10:03", "−7h · working", "Mumbai", "22:33", "+5.5h", "UTC", "17:03", "local · working"])
    }

    func testWorldClocksWorkHoursAndTwelveHourClock() {
        let widget = """
            { "type": "worldClocks", "hour12": true, "workHours": [11, 12], "cities": [{ "label": "LA", "zone": "America/Los_Angeles" }] }
            """
        XCTAssertEqual(texts(render(widget)), ["LA", "10:03 AM", "−7h"])
        // The same city at 11:30 its time is within [11, 12).
        let later = Self.now.addingTimeInterval(87 * 60)
        XCTAssertEqual(texts(render(widget, now: later)), ["LA", "11:30 AM", "−7h · working"])
    }

    func testWorldClocksDayAndNightIcon() {
        let widget = #"{ "type": "worldClocks", "cities": [{ "label": "LA", "zone": "America/Los_Angeles" }, { "label": "Tokyo", "zone": "Asia/Tokyo" }] }"#
        var icons: [String] = []
        render(widget).root.walk { node in if case .icon(let i) = node.content { icons.append(i.name) } }
        XCTAssertEqual(icons, ["sun", "moon"], "10:03 in LA, 02:03 in Tokyo")
    }

    func testWorldClocksOffsetFollowsDaylightSaving() {
        let widget = #"{ "type": "worldClocks", "cities": [{ "label": "Sydney", "zone": "Australia/Sydney" }] }"#
        // Sydney's summer time starts on the first Sunday of October (the 4th in 2026).
        XCTAssertEqual(texts(render(widget)).last, "+10h")
        XCTAssertEqual(texts(render(widget, now: Date(timeIntervalSince1970: 1_790_528_602 + 30 * 86400))).last, "+11h")
    }

    // MARK: countdowns

    func testCountdownsDaysSortingAndProgress() {
        let widget = """
            { "type": "countdowns", "items": [
              { "title": "Far", "date": "2026-12-26" },
              { "title": "Trip", "date": "2026-10-07", "since": "2026-09-17" },
              { "title": "Today", "date": "2026-09-27", "since": "2026-09-01" },
              { "title": "Past", "date": "2026-09-26" },
              { "title": "Bad", "date": "soon" } ] }
            """
        let snapshot = render(widget)
        XCTAssertEqual(texts(snapshot), ["0", "Today", "today", "10", "Trip", "days", "90", "Far", "days"])
        let progress = bars(snapshot)
        XCTAssertEqual(progress.count, 2, "only the items with a since have a bar")
        XCTAssertEqual(progress[0].value, 26.0 / 26.0, accuracy: 0.001, "the day itself: all of the wait has passed")
        XCTAssertEqual(progress[1].value, 0.5, accuracy: 0.001, "10 of 20 days")
    }

    func testCountdownColoursAreAutomaticOrGiven() {
        let widget = """
            { "type": "countdowns", "items": [
              { "title": "Soon", "date": "2026-10-05", "since": "2026-09-01" },
              { "title": "Mid", "date": "2026-11-15", "since": "2026-09-01" },
              { "title": "Late", "date": "2027-03-01", "since": "2026-09-01" },
              { "title": "Set", "date": "2027-03-02", "since": "2026-09-01", "color": "good" } ] }
            """
        XCTAssertEqual(bars(render(widget)).map(\.color), ["warn", "accent", "#ffffff66", "good"], "plain text at 40% is white at 0x66")
    }

    func testCountdownUsesTheLocalDate() {
        let widget = #"{ "type": "countdowns", "items": [{ "title": "X", "date": "2026-09-28" }] }"#
        // 17:03 UTC is already the 28th in Auckland (+13): the day has come.
        XCTAssertEqual(texts(render(widget, zone: "Pacific/Auckland")).first, "0")
        XCTAssertEqual(texts(render(widget, zone: "UTC")).first, "1")
    }

    // MARK: aiPlan

    private func window(_ percent: Int, _ resetsIn: Double, label: String? = nil) -> String {
        let reset = Int(Self.now.timeIntervalSince1970 + resetsIn)
        return #"{ "percent": \#(percent), "resetsAt": \#(reset)\#(label.map { #", "label": "\#($0)""# } ?? "") }"#
    }

    func testAIPlanBarsLabelsResetsAndEvenPaceTick() {
        let claude = """
            { "plan": null, "session": \(window(62, 8200)), "weekly": \(window(48, 3.5 * 86400)),
              "extra": [\(window(91, 3.5 * 86400, label: "Fable"))] }
            """
        let codex = #"{ "plan": "pro", "session": null, "weekly": \#(window(34, 6 * 86400)), "extra": [] }"#
        let snapshot = render(#"{ "type": "aiPlan", "claudePlan": "Max" }"#, sources: ["claude": claude, "codex": codex])
        XCTAssertEqual(texts(snapshot), [
            "Claude", "Max",
            "5 hours", "62%", "resets 19:20",
            "Week", "48%", "resets Thu",
            "Fable week", "91%", "resets Thu",
            "Codex", "Pro",
            "Week", "34%", "resets Sat",
            "White tick: where usage would be at an even pace through the week.",
        ])
        let all = bars(snapshot)
        XCTAssertEqual(all.map(\.value), [0.62, 0.48, 0.91, 0.34])
        XCTAssertNil(all[0].tick, "no pace for the 5-hour window")
        XCTAssertEqual(try XCTUnwrap(all[1].tick), 0.5, accuracy: 0.001, "3.5 of 7 days left: halfway")
        XCTAssertEqual(try XCTUnwrap(all[3].tick), 1.0 / 7, accuracy: 0.001, "6 of 7 days left")
        XCTAssertEqual(all.map(\.color), ["orange", "orange", "bad", "teal"], "red from 90%")
    }

    func testAIPlanWindowThatHasResetIsZeroAndAServiceWithoutDataIsLeftOut() {
        let claude = #"{ "plan": null, "session": \#(window(80, -100)), "weekly": null, "extra": [] }"#
        let snapshot = render(#"{ "type": "aiPlan", "hint": false }"#, sources: ["claude": claude])
        XCTAssertEqual(texts(snapshot), ["Claude", "5 hours", "0%", "new window"])
        XCTAssertEqual(bars(snapshot).map(\.value), [0])
    }

    // MARK: sunMoon

    private func sky(latitude: Double, longitude: Double, at now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let data = Astro.data(latitude: latitude, longitude: longitude, now: now, calendar: calendar)
        return String(decoding: data.canonicalData(), as: UTF8.self)
    }

    private func sparkline(_ snapshot: RenderSnapshot) -> RenderNode.Spark? {
        var found: RenderNode.Spark?
        snapshot.root.walk { node in if case .spark(let s) = node.content { found = s } }
        return found
    }

    func testSunMoonByDayNightAndPolar() throws {
        let place = (38.72, -9.14)
        let data = try XCTUnwrap(tree(sky(latitude: place.0, longitude: place.1, at: Self.now)).objectValue)
        let rise = number(data["sunrise"]), set = number(data["sunset"])
        let widget = #"{ "type": "sunMoon" }"#
        func at(_ epoch: Double) -> RenderSnapshot {
            render(widget, sources: ["astro": sky(latitude: place.0, longitude: place.1, at: Self.now)], now: Date(timeIntervalSince1970: epoch))
        }
        // Midday: the dot is half way, the sun sets in about 6 hours.
        let noon = at((rise + set) / 2)
        let spark = try XCTUnwrap(sparkline(noon))
        XCTAssertEqual(try XCTUnwrap(spark.dotAt), 0.5, accuracy: 0.01)
        XCTAssertEqual(spark.values.count, 49)
        XCTAssertEqual(spark.min, 0)
        XCTAssertEqual(try XCTUnwrap(spark.max), number(data["peak"]), accuracy: 0.01)
        XCTAssertTrue(texts(noon).contains { $0.hasPrefix("sets in 5h") || $0.hasPrefix("sets in 6h") }, "\(texts(noon))")
        XCTAssertTrue(texts(noon).contains { $0.hasPrefix("day 11h") && $0.contains("/day") })
        // Before sunrise there is no dot and it says when the sun comes up; after sunset, below the horizon.
        let dawn = at(rise - 3600)
        XCTAssertNil(try XCTUnwrap(sparkline(dawn)).dotAt)
        XCTAssertTrue(texts(dawn).contains("rises in 1h"), "\(texts(dawn))")
        let night = at(set + 3600)
        XCTAssertNil(try XCTUnwrap(sparkline(night)).dotAt)
        XCTAssertTrue(texts(night).contains("below the horizon"))
        // The sunrise and sunset times label the arc, in the clock's zone.
        XCTAssertEqual(texts(noon).filter { $0.range(of: #"^\d\d:\d\d$"#, options: .regularExpression) != nil }.count, 2)
    }

    func testSunMoonInPolarDay() throws {
        let june = Date(timeIntervalSince1970: 1_718_967_600)
        let snapshot = render(#"{ "type": "sunMoon" }"#, sources: ["astro": sky(latitude: 69.65, longitude: 18.96, at: june)], now: june)
        XCTAssertTrue(texts(snapshot).contains("the sun stays up"), "\(texts(snapshot))")
        XCTAssertEqual(sparkline(snapshot)?.values, [], "no arc to draw")
        XCTAssertFalse(texts(snapshot).contains { $0.hasPrefix("day ") }, "no day length either")
    }

    func testSunMoonMoonLineNamesTheNextFullOrNewMoon() throws {
        // 2024-01-18: first quarter 7 days after the new moon of the 11th.
        let waxing = Date(timeIntervalSince1970: 1_704_974_220 + 7.4 * 86400)
        let a = texts(render(#"{ "type": "sunMoon" }"#, sources: ["astro": sky(latitude: 51.5, longitude: 0, at: waxing)], now: waxing))
        XCTAssertTrue(a.contains("First quarter"), "\(a)")
        XCTAssertTrue(a.contains { $0.hasSuffix("full in 8d") || $0.hasSuffix("full in 7d") }, "\(a)")
        let waning = Date(timeIntervalSince1970: 1_706_205_240 + 4 * 86400)
        let b = texts(render(#"{ "type": "sunMoon" }"#, sources: ["astro": sky(latitude: 51.5, longitude: 0, at: waning)], now: waning))
        XCTAssertTrue(b.contains("Waning gibbous"), "\(b)")
        XCTAssertTrue(b.contains { $0.contains("new in ") }, "\(b)")
    }

    // MARK: forecast

    /// The `openMeteo` source's shape: 24 hours from 17:00 UTC, three days.
    private func forecastData() -> String {
        let start = Int(Self.now.timeIntervalSince1970) / 3600 * 3600
        let hours = (0..<24).map { i in
            #"{ "time": \#(start + i * 3600), "temp": \#(20 - i / 2), "rain": \#(i >= 3 && i <= 5 ? 70 : 0) }"#
        }.joined(separator: ", ")
        let midnight = Int(Self.now.timeIntervalSince1970) / 86400 * 86400
        let days = [(2, 10, 19), (61, 8, 14), (0, 12, 22)].enumerated().map { i, d in
            #"{ "time": \#(midnight + i * 86400), "code": \#(d.0), "min": \#(d.1), "max": \#(d.2), "rain": 0 }"#
        }.joined(separator: ", ")
        return #"{ "tz": "UTC", "temp": 18.4, "code": 2, "hours": [\#(hours)], "days": [\#(days)] }"#
    }

    func testForecastBarsRainAndRanges() throws {
        let snapshot = render(#"{ "type": "forecast" }"#, sources: ["forecast": forecastData()])
        let all = texts(snapshot)
        XCTAssertEqual(all.first, "18°")
        XCTAssertEqual(all[1], "Rain from 20:00", "the first hour at 40% or more, in the place's zone")
        // Twelve hours of labels from the current hour.
        XCTAssertEqual(Array(all[2..<14]), ["17", "18", "19", "20", "21", "22", "23", "00", "01", "02", "03", "04"])
        XCTAssertEqual(Array(all.suffix(9)), ["Today", "10°", "19°", "Mon", "8°", "14°", "Tue", "12°", "22°"])
        // Range bars share one scale (8 to 22): start at the low, end at the high.
        let ranges = bars(snapshot)
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges[0].start, (10.0 - 8) / 14, accuracy: 0.001)
        XCTAssertEqual(ranges[0].value, (19.0 - 8) / 14, accuracy: 0.001)
        XCTAssertEqual(ranges[1].start, 0, "the lowest low sits on the left edge")
        XCTAssertEqual(ranges[2].value, 1, "the highest high on the right edge")
    }

    func testForecastWithNoRainAndLimits() {
        let none = forecastData().replacingOccurrences(of: #""rain": 70"#, with: #""rain": 0"#)
        let snapshot = render(#"{ "type": "forecast", "hours": 4, "days": 2 }"#, sources: ["forecast": none])
        let all = texts(snapshot)
        XCTAssertEqual(all[1], "No rain expected")
        XCTAssertEqual(Array(all[2..<6]), ["17", "18", "19", "20"])
        XCTAssertEqual(bars(snapshot).count, 2)
    }

    func testOpenMeteoTemplateExpandsToAnHTTPSource() throws {
        let imperial = ConfigExpansion.expand(tree(#"""
            { "sources": { "f": { "type": "openMeteo", "latitude": 38.72, "longitude": -9.14, "units": "imperial" } } }
            """#))
        XCTAssertEqual(imperial.warnings.filter { $0.severity == .error }.map(\.description), [])
        let source = try XCTUnwrap(imperial.sources["f"])
        XCTAssertEqual(source.type, "http")
        let url = try XCTUnwrap(source.url)
        XCTAssertTrue(url.hasPrefix("https://api.open-meteo.com/v1/forecast?latitude=38.72&longitude=-9.14&"), url)
        XCTAssertTrue(url.hasSuffix("temperature_unit=fahrenheit"), url)
        XCTAssertFalse(url.contains("key="), "no API key")
        XCTAssertEqual(source.refresh, "30m")
        XCTAssertEqual(source.when, "visible")
        XCTAssertNotNil(source.transform)
        let metric = ConfigExpansion.expand(tree(#"{ "sources": { "f": { "type": "openMeteo", "latitude": 1, "longitude": 2 } } }"#))
        XCTAssertTrue(try XCTUnwrap(metric.sources["f"]?.url).hasSuffix("temperature_unit=celsius"))
    }

    // MARK: progress and sparkline additions

    func testProgressStartAndTick() throws {
        let snapshot = render(#"{ "type": "progress", "start": 20, "value": 60, "tick": 90, "tickColor": "bad", "text": "" }"#)
        let bar = try XCTUnwrap(bars(snapshot).first)
        XCTAssertEqual(bar.start, 0.2, accuracy: 0.0001)
        XCTAssertEqual(bar.value, 0.6, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(bar.tick), 0.9, accuracy: 0.0001)
        XCTAssertEqual(bar.tickColor, "bad")
        // Absent: the bar is what it was.
        let plain = try XCTUnwrap(bars(render(#"{ "type": "progress", "value": 50 }"#)).first)
        XCTAssertEqual(plain.start, 0)
        XCTAssertNil(plain.tick)
        XCTAssertNil(plain.tickColor)
    }

    func testProgressStartAndTickScaleWithMinAndMax() throws {
        let bar = try XCTUnwrap(bars(render(#"{ "type": "progress", "min": 10, "max": 30, "start": 15, "value": 25, "tick": 50, "text": "" }"#)).first)
        XCTAssertEqual(bar.start, 0.25, accuracy: 0.0001)
        XCTAssertEqual(bar.value, 0.75, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(bar.tick), 1, "clamped")
    }

    func testNewBarAndSparklineFieldsRoundTripAndStayOutOfPlainNodes() throws {
        let bar = RenderNode(id: "b", .bar(.init(value: 0.6, color: "accent", start: 0.2, tick: 0.5, tickColor: "#ffffff8c")))
        let spark = RenderNode(id: "s", .spark(.init(values: [1, 2, 3], dot: false, dotAt: 0.25, dotColor: "warn")))
        for node in [bar, spark] {
            let data = try JSONEncoder().encode(node)
            XCTAssertEqual(try JSONDecoder().decode(RenderNode.self, from: data), node)
        }
        // A plain bar and sparkline write none of the new keys.
        let plain = try JSONEncoder().encode(RenderNode(id: "p", .bar(.init(value: 0.6))))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("start"))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("tick"))
        let plainSpark = try JSONEncoder().encode(RenderNode(id: "q", .spark(.init(values: [1, 2]))))
        XCTAssertFalse(String(decoding: plainSpark, as: UTF8.self).contains("dotAt"))
    }

    func testSparklineDotAt() throws {
        let widget = #"{ "type": "sparkline", "values": "[1, 3, 2, 5]", "dotAt": "0.4", "dotColor": "warn" }"#
        let spark = try XCTUnwrap(sparkline(render(widget)))
        XCTAssertEqual(spark.dotAt, 0.4)
        XCTAssertEqual(spark.dotColor, "warn")
        XCTAssertFalse(spark.dot)
        // Out of range is clamped, null is no dot.
        XCTAssertEqual(try XCTUnwrap(sparkline(render(#"{ "type": "sparkline", "values": "[1, 2]", "dotAt": "3" }"#))).dotAt, 1)
        XCTAssertNil(try XCTUnwrap(sparkline(render(#"{ "type": "sparkline", "values": "[1, 2]", "dotAt": "null" }"#))).dotAt)
    }
}
