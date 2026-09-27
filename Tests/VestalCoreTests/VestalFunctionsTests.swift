import Foundation
import VestalCore
import XCTest

/// The vestal function library (EXTENSIBILITY.md §4.6): the examples of the
/// spec, and the legacy and Format-based functions against the v0.3 Swift
/// code over the same inputs.
final class VestalFunctionsTests: XCTestCase {
    /// Data for `meta`, `history`, `kv_legacy` and `host_health`.
    final class TestData: ExprData {
        var sources: [String: JQValue] = [:]
        var metas: [String: JQValue] = [:]
        var histories: [String: [HistorySample]] = [:]

        func data(_ source: String) -> JQValue? { sources[source] }
        func meta(_ source: String) -> JQValue? { metas[source] }
        func history(_ source: String, _ name: String) -> [HistorySample] { histories["\(source).\(name)"] ?? [] }
    }

    /// 2026-09-27T14:03:22Z.
    static let now = Date(timeIntervalSince1970: 1_790_517_802)
    static let utc = TimeZone(identifier: "UTC")!

    private var functions: JQFunctions {
        var f = JQFunctions()
        VestalFunctions.register(into: &f)
        return f
    }

    private func context(_ data: ExprData? = nil, zone: TimeZone = utc, locale: String = "en_US") -> JQEvalContext {
        var info: [String: Any] = [VestalFunctions.localeKey: Locale(identifier: locale)]
        if let data { info[VestalFunctions.dataKey] = data }
        return JQEvalContext(now: Self.now, timeZone: zone, userInfo: info)
    }

    /// The first output.
    private func one(_ expression: String, _ input: JQValue = .null, data: ExprData? = nil,
                     zone: TimeZone = utc) throws -> JQValue {
        try JQExpression(expression, functions: functions).first(input, context: context(data, zone: zone)) ?? .null
    }

    private func string(_ expression: String, _ input: JQValue = .null, data: ExprData? = nil) throws -> String? {
        try one(expression, input, data: data).stringValue
    }

    private func json(_ fixture: String) throws -> JQValue {
        try JQValue.parse(Data(try Fixture.data(fixture)))
    }

    // MARK: Formatting

    func testNumberFormats() throws {
        XCTAssertEqual(try string("3.14159 | fmt_fixed(2)"), "3.14")
        XCTAssertEqual(try string("\"12.5\" | fmt_fixed(1)"), "12.5", "numeric strings are numbers")
        XCTAssertEqual(try string("1234.9 | fmt_int"), "1234")
        XCTAssertEqual(try string("-3.7 | fmt_int"), "-3")
        XCTAssertEqual(try string("2.5 | fmt_number"), "2.50")
        XCTAssertEqual(try string("42 | fmt_number"), "42")
        XCTAssertEqual(try string("1234567 | fmt_thousands"), "1,234,567")
        XCTAssertEqual(try string("1234567.891 | fmt_thousands(2)"), "1,234,567.89")
        XCTAssertEqual(try string("-1234.5 | fmt_thousands"), "-1,235")
        XCTAssertEqual(try string("999 | fmt_thousands"), "999")
        XCTAssertEqual(try string("1234 | fmt_compact"), "1.2k")
        XCTAssertEqual(try string("1000 | fmt_compact"), "1k")
        XCTAssertEqual(try string("12345 | fmt_compact"), "12.3k")
        XCTAssertEqual(try string("3400000 | fmt_compact"), "3.4M")
        XCTAssertEqual(try string("2.1e9 | fmt_compact"), "2.1B")
        XCTAssertEqual(try string("1e12 | fmt_compact"), "1T")
        XCTAssertEqual(try string("999 | fmt_compact"), "999")
        XCTAssertEqual(try string("999960 | fmt_compact"), "1M")
        XCTAssertEqual(try string("-1500 | fmt_compact"), "-1.5k")
        XCTAssertEqual(try string("41.6 | fmt_percent"), "42%")
        XCTAssertEqual(try string("41.66 | fmt_percent(1)"), "41.7%")
    }

    func testBytesAndRates() throws {
        XCTAssertEqual(try string("1288490188 | fmt_bytes"), Format.bytes(1_288_490_188))
        XCTAssertEqual(try string("12884901888 | fmt_bytes"), "12G")
        XCTAssertEqual(try string("1209462790553 | fmt_bytes"), "1.1T")
        XCTAssertEqual(try string("536870912 | fmt_bytes"), "512M")
        XCTAssertEqual(try string("4194304 | fmt_bytes"), "4.0M")
        XCTAssertEqual(try string("12288 | fmt_bytes"), "12K")
        XCTAssertEqual(try string("80 | fmt_bytes"), "80B")
        for rate in [0, 80, 1023, 1024, 524_288, 1_048_575, 1_258_291, 50_000_000] {
            XCTAssertEqual(try string("\(rate) | fmt_rate"), Format.rate(Int64(rate)), "rate \(rate)")
        }
        XCTAssertEqual(try string("1258291.7 | fmt_rate"), "1.2M")
    }

    func testDurations() throws {
        XCTAssertEqual(try string("\(3 * 86400 + 4 * 3600 + 5) | fmt_duration"), "3d 4h")
        XCTAssertEqual(try string("\(4 * 3600 + 12 * 60) | fmt_duration"), "4h 12m")
        XCTAssertEqual(try string("2700 | fmt_duration"), "45m")
        XCTAssertEqual(try string("30 | fmt_duration"), "30s")
        XCTAssertEqual(try string("\(3 * 86400 + 4 * 3600) | fmt_duration(1)"), "3d")
        XCTAssertEqual(try string("0 | fmt_duration"), "0s")
        for secs in [0, 59, 3599, 3600, 7260, 86_399, 86_400, 273_600, 1_234_567] {
            XCTAssertEqual(try string("\(secs) | fmt_uptime"), Format.uptime(secs))
            XCTAssertEqual(try string("\(secs) | fmt_uptime_long"), Format.uptimeLong(secs))
        }
        XCTAssertEqual(try string("720.9 | fmt_uptime_long"), "0h 12m", "exact v0.3 rule (§13.1 8c)")
        for mins in [-3, 0, 1, 25, 59, 60, 120, 125] {
            XCTAssertEqual(try string("\(mins) | starts_in"), Format.startsIn(minutes: mins))
        }
        XCTAssertEqual(try string("25.9 | starts_in"), "in 25m")
        XCTAssertEqual(try string("-0.5 | starts_in"), "now")
    }

    func testRelativeTimes() throws {
        let now = Self.now.timeIntervalSince1970
        XCTAssertEqual(try string("\(now - 20) | fmt_relative"), "now")
        XCTAssertEqual(try string("\(now - 300) | fmt_relative"), "5m ago")
        XCTAssertEqual(try string("\(now - 3 * 3600 - 10) | fmt_relative"), "3h ago")
        XCTAssertEqual(try string("\(now - 2 * 86400) | fmt_relative"), "2d ago")
        XCTAssertEqual(try string("\(now + 25 * 60 + 5) | fmt_relative"), "in 25m")
        XCTAssertEqual(try string("\"2026-09-27T13:03:22Z\" | fmt_relative"), "1h ago", "ISO 8601 input")
        let expression = try JQExpression("fmt_relative", functions: functions)
        let ctx = context()
        _ = try expression.first(.number(now), context: ctx)
        XCTAssertTrue(ctx.nowWasCalled, "fmt_relative depends on the clock")
    }

    func testTimes() throws {
        XCTAssertEqual(try string("now | fmt_time(\"HH:mm\")"), "14:03")
        XCTAssertEqual(try string("now | fmt_time(\"HH:mm\"; \"Asia/Tokyo\")"), "23:03")
        XCTAssertEqual(try string("now | fmt_time(\"HH:mm\"; \"America/Argentina/Buenos_Aires\")"), "11:03")
        XCTAssertEqual(try one("now | fmt_time(\"HH:mm\")", zone: TimeZone(identifier: "America/New_York")!).stringValue,
                       "10:03", "the context's zone is the local one")
        XCTAssertThrowsError(try one("now | fmt_time(\"HH:mm\"; \"Nowhere/Else\")"))
        XCTAssertEqual(try string("now | fmt_localized(\"EEEEMMMMdy\")"), "Sunday, September 27, 2026")
        XCTAssertEqual(try string("null | fmt_time(\"HH:mm\")"), nil)
    }

    func testTextHelpers() throws {
        XCTAssertEqual(try string("\"06:15 PM\" | clock24"), "18:15")
        XCTAssertEqual(try string("\"06:15\" | clock24"), "6:15")
        XCTAssertEqual(try string("\"06:44:45\" | clock24"), "6:44")
        XCTAssertEqual(try string("\"exchange\" | capitalize"), "Exchange")
        XCTAssertEqual(try string("\"new york\" | titlecase"), "New York")
        XCTAssertEqual(try string("\"Windowlicker\" | truncate(6)"), "Window…")
        XCTAssertEqual(try string("\"short\" | truncate(6)"), "short")
    }

    func testNullStaysQuietAndNonNumbersFail() throws {
        for f in ["fmt_fixed(2)", "fmt_int", "fmt_number", "fmt_thousands", "fmt_compact", "fmt_percent", "fmt_bytes",
                  "fmt_rate", "fmt_duration", "fmt_uptime", "fmt_uptime_long", "fmt_relative", "starts_in", "clock24",
                  "capitalize", "titlecase", "truncate(3)", "step([[0, 1]])", "fmt_legacy(\"int\")"] {
            XCTAssertEqual(try one("null | \(f)"), .null, f)
        }
        XCTAssertThrowsError(try one("\"n/a\" | fmt_int")) { error in
            XCTAssertEqual((error as? JQError)?.kind, .runtime)
            XCTAssertTrue("\(error)".contains("fmt_int"))
        }
        XCTAssertEqual(try one("try (\"n/a\" | fmt_int) catch \"caught\""), .string("caught"), "catchable")
    }

    // MARK: Colours and thresholds

    func testStep() throws {
        let stops = "[[0,\"good\"],[70,\"warn\"],[90,\"bad\"]]"
        XCTAssertEqual(try string("12.5 | step(\(stops))"), "good")
        XCTAssertEqual(try string("70 | step(\(stops))"), "warn")
        XCTAssertEqual(try string("95 | step(\(stops))"), "bad")
        XCTAssertEqual(try string("-5 | step(\(stops))"), "good", "below every stop: the first")
        XCTAssertEqual(try string("\"80\" | step(\(stops))"), "warn")
        XCTAssertEqual(try one("50 | step([[0, 1], [40, 2]])"), .number(2), "any result type")
        let battery = "step([[0,\"battery-empty\"],[13,\"battery-low\"],[38,\"battery-medium\"],[63,\"battery-high\"],[88,\"battery-full\"]])"
        XCTAssertEqual(try string("81 | \(battery)"), "battery-high")
    }

    func testColours() throws {
        XCTAssertEqual(try string("\"accent\" | alpha(0.15)"), "#7aa1f726")
        XCTAssertEqual(try string("\"#ffffff\" | alpha(0.2)"), "#ffffff33")
        XCTAssertEqual(try string("\"#fff\" | alpha(1)"), "#ffffffff")
        XCTAssertEqual(try string("color_mix(\"#000000\"; \"#ffffff\"; 0.5)"), "#808080ff")
        XCTAssertEqual(try string("color_mix(\"good\"; \"bad\"; 0)"), "#73cf8fff")
        XCTAssertEqual(try string("color_mix(\"good\"; \"bad\"; 2)"), "#f06b6bff", "t is clamped")
        XCTAssertEqual(try string("color_mix(\"accent@0.5\"; \"accent\"; 0)"), "#7aa1f780")
        XCTAssertThrowsError(try one("\"nocolour\" | alpha(0.5)"))
        let custom = JQEvalContext(now: Self.now, timeZone: Self.utc,
                                   userInfo: [VestalFunctions.paletteKey: ["brand": "#e01e5aff"]])
        XCTAssertEqual(try JQExpression("\"brand\" | alpha(0.5)", functions: functions).first(.null, context: custom),
                       .string("#e01e5a80"))
    }

    // MARK: Time and data

    func testToEpoch() throws {
        XCTAssertEqual(try one("\"2026-09-26T18:02:11Z\" | to_epoch"), .number(1_790_445_731))
        XCTAssertEqual(try one("\"2026-09-26T18:02:11.250Z\" | to_epoch"), .number(1_790_445_731.25))
        XCTAssertEqual(try one("\"2026-09-26T15:02:11-03:00\" | to_epoch"), .number(1_790_445_731))
        XCTAssertEqual(try one("\"2026-09-26T20:02:11+0200\" | to_epoch"), .number(1_790_445_731))
        XCTAssertEqual(try one("\"2026-09-26\" | to_epoch"), .number(1_790_380_800))
        XCTAssertEqual(try one("1790000000 | to_epoch"), .number(1_790_000_000))
        XCTAssertEqual(try one("\"yesterday\" | to_epoch"), .null)
        XCTAssertEqual(try one("\"2026-02-30\" | to_epoch"), .null)
        XCTAssertEqual(try one("\"2026-09-22T15:00:00.000Z\" | to_epoch"),
                       try one("\"2026-09-22T15:00:00Z\" | fromdate"))
    }

    func testZonesAndSun() throws {
        XCTAssertEqual(try one("\"Europe/Lisbon\" | tz_valid"), .bool(true))
        XCTAssertEqual(try one("\"Mars/Olympus\" | tz_valid"), .bool(false))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        for (sunrise, sunset) in [("6:15", "18:40"), ("15:00", "20:00"), ("5:00", "12:00"), ("bad", "18:00")] {
            let expected = Format.sunContext(sunrise: sunrise, sunset: sunset, now: Self.now, calendar: calendar)
            XCTAssertEqual(try one("sun_context(\"\(sunrise)\"; \"\(sunset)\")"),
                           expected.map(JQValue.string) ?? .null, "\(sunrise)-\(sunset)")
        }
        XCTAssertEqual(try string("sun_context(\"6:15\"; \"18:40\")"), "sets in 4h 37m")
        XCTAssertEqual(try one("sun_context(null; \"18:40\")"), .null)
    }

    func testFindWhereUniqPct() throws {
        let rows: JQValue = try JQValue.parse("""
            [{"casa": "blue", "compra": 1180}, {"casa": "oficial", "compra": 1045.5}, {"casa": "blue", "compra": 1}]
            """)
        XCTAssertEqual(try one("find({casa: \"blue\"}) | .compra", rows), .number(1180))
        XCTAssertEqual(try one("find({casa: \"none\"})", rows), .null)
        XCTAssertEqual(try one("find({compra: 1045.50})", rows), try one(".[1]", rows), "numbers compare numerically")
        XCTAssertEqual(try one("where({casa: \"blue\"}) | length", rows), .number(2))
        XCTAssertEqual(try one("uniq_by(.casa) | map(.compra)", rows), try JQValue.parse("[1180, 1045.5]"))
        XCTAssertEqual(try one("[3, 1, 3, 2, 1] | uniq_by(.)"), try JQValue.parse("[3, 1, 2]"), "keeps the order")
        XCTAssertEqual(try one("pct(1; 4)"), .number(25))
        XCTAssertEqual(try one("pct(1; 0)"), .null)
        XCTAssertEqual(try one("pct(null; 4)"), .null)
    }

    func testMetaAndHistory() throws {
        let data = TestData()
        data.metas["btc"] = try JQValue.parse(#"{"name": "btc", "ok": true, "loaded": true, "error": null, "age": 3}"#)
        data.histories["btc.price"] = [HistorySample(time: 100, value: 1), HistorySample(time: 200, value: 2.5)]
        XCTAssertEqual(try one("meta(\"btc\").ok", data: data), .bool(true))
        XCTAssertEqual(try one("meta(\"nope\")", data: data), .null)
        XCTAssertEqual(try one("history(\"btc\"; \"price\")", data: data), try JQValue.parse("[1, 2.5]"))
        XCTAssertEqual(try one("history_times(\"btc\"; \"price\")", data: data), try JQValue.parse("[100, 200]"))
        XCTAssertEqual(try one("history(\"btc\"; \"volume\")", data: data), .array([]))
        XCTAssertEqual(try one("meta(\"btc\")"), .null, "no data provider")
    }

    // MARK: Legacy helpers

    func testPathGetUsesLegacyPaths() throws {
        let rates = try json("exchange-rates.json")
        XCTAssertEqual(try one("path_get(\"rates.BRL\")", rates), .number(5.4321))
        XCTAssertEqual(try one("path_get(\".rates.JPY\")", rates), .number(147))
        XCTAssertEqual(try one("path_get(\"rates.nope\")", rates), .null)
        let weather = try json("wttr-j1.json")
        let path = ".nearest_area[0].areaName[0].value"
        let expected = JSONPath.resolve(path, in: try Fixture.json("wttr-j1.json")) as? String
        XCTAssertEqual(try one("path_get(\"\(path)\")", weather).stringValue, expected)
        XCTAssertEqual(try one("{\"length\": 3} | path_get(\"length\")"), .number(3), "a field, never a builtin")
    }

    func testKeyValueLegacyMatchesV03() throws {
        let data = TestData()
        data.sources["dolares"] = try json("dolarapi-dolares.json")
        data.sources["rates"] = try json("exchange-rates.json")
        let full = try JQValue.parse(Data(try Data(contentsOf: Fixture.repository("examples/full.json"))))
        guard case .array(let items)? = full.objectValue?["widgets"]?.objectValue?["exchange"]?.objectValue?["items"] else {
            return XCTFail("examples/full.json has no exchange items")
        }
        let pickItems = try JSONDecoder().decode([PickItem].self, from: Data(JQValue.array(items).jsonText().utf8))
        let v03 = AsyncData.exchangeRates(pickItems, defaultSource: "dolares", parsedBySource: [
            "dolares": try Fixture.json("dolarapi-dolares.json"), "rates": try Fixture.json("exchange-rates.json"),
        ])
        let rows = try one("$items | map(kv_legacy(.; \"dolares\")) | map(select(. != null))",
                           data: data, items: .array(items))
        let expected: [JQValue] = v03.map { rate in
            .object(JQObject([("label", .string(rate.label)),
                              ("text", .string(rate.sell.isEmpty ? rate.buy : "\(rate.buy) / \(rate.sell)"))]))
        }
        XCTAssertEqual(rows, .array(expected))
        XCTAssertEqual(rows.arrayValue?.first?.objectValue?["text"], .string("1180 / 1200"))
        XCTAssertEqual(rows.arrayValue?.last?.objectValue?["text"], .string("5.43"))
        XCTAssertEqual(try one("{label: \"X\", pick: \"a\"} | kv_legacy(.; \"missing\")", data: data), .null,
                       "no data: skipped")
    }

    /// `one` with a `$items` variable.
    private func one(_ expression: String, data: ExprData, items: JQValue) throws -> JQValue {
        try JQExpression(expression, functions: functions, variables: ["items"])
            .first(.null, variables: ["items": items], context: context(data)) ?? .null
    }

    func testWeatherLegacyMatchesV03() throws {
        let fields = [
            "location": ".nearest_area[0].areaName[0].value",
            "region": ".nearest_area[0].region[0].value",
            "condition": ".current_condition[0].weatherDesc[0].value",
            "temp": ".current_condition[0].temp_C",
            "sunrise": ".weather[0].astronomy[0].sunrise",
            "sunset": ".weather[0].astronomy[0].sunset",
        ]
        let v03 = try XCTUnwrap(AsyncData.parseWeather(try Fixture.data("wttr-j1.json"), fields: fields))
        let fieldsJSON = JQValue.object(JQObject(fields.sorted { $0.key < $1.key }.map { ($0.key, JQValue.string($0.value)) }))
        let result = try JQExpression("weather_legacy($f; \"metric\")", functions: functions, variables: ["f"])
            .first(try json("wttr-j1.json"), variables: ["f": fieldsJSON], context: context()) ?? .null
        let object = try XCTUnwrap(result.objectValue)
        XCTAssertEqual(object["location"], .string(v03.location))
        XCTAssertEqual(object["condition"], .string(v03.condition))
        XCTAssertEqual(object["temp"], .string(v03.temp))
        XCTAssertEqual(object["sunrise"], v03.sunrise.map(JQValue.string) ?? .null)
        XCTAssertEqual(object["sunset"], v03.sunset.map(JQValue.string) ?? .null)
        XCTAssertEqual(try one("null | weather_legacy({}; \"metric\")"), .null)
        let imperial = try one("weather_legacy({temp: \".t\"}; \"imperial\") | .temp", try JQValue.parse(#"{"t": "+64"}"#))
        XCTAssertEqual(imperial, .string("64°F"))
    }

    func testFoyerHealthMatchesV03() throws {
        let payload = try json("foyer-health.json")
        let v03 = AsyncData.parseServerDetail(name: "box", json: try XCTUnwrap(Fixture.json("foyer-health.json") as? [String: Any]))
        let summary = AsyncData.parseFoyerHealth(name: "box", json: try XCTUnwrap(Fixture.json("foyer-health.json") as? [String: Any]))
        let system = try one("foyer_health", payload)
        func n(_ i: Int?) -> JQValue { i.map { .number(Double($0)) } ?? .null }
        XCTAssertEqual(try one(".cpu.percent", system), n(summary.cpuPercent))
        XCTAssertEqual(try one(".memory.percent", system), n(summary.ramPercent))
        XCTAssertEqual(try one(".memory.pressure", system), n(summary.memPressure))
        XCTAssertEqual(try one(".temperature.cpu", system), n(summary.cpuTemp))
        XCTAssertEqual(try one(".uptime", system), n(summary.uptimeSecs))
        XCTAssertEqual(try one(".host", system), .string("server1"))
        XCTAssertEqual(try one(".network", system), try JQValue.parse(#"{"rx": 9000, "tx": 7000}"#))
        XCTAssertEqual(try one(".disks | map(.mount)", system), try JQValue.parse(#"["tank", "scratch", "/"]"#))
        XCTAssertEqual(try one(".disks[0]", system), try JQValue.parse(
            #"{"mount": "tank", "percent": 71, "used": 11408000000000, "total": 16000000000000, "health": "ONLINE", "pool": true}"#))
        XCTAssertEqual(try one(".gpu.memTotal", system), .number(Double(v03.gpu!.memTotalMB) * 1_048_576))
        XCTAssertEqual(try one(".services", system), try JQValue.parse(
            #"{"docker": {"running": 2}, "jellyfin": {"streams": 2}, "minecraft": {"online": true, "players": 3, "max": 20}}"#))
        // Missing numbers are 0, as v0.3 showed them.
        let bare = try one("{} | foyer_health")
        XCTAssertEqual(try one("[.cpu.percent, .memory.percent, .temperature.cpu, .uptime]", bare),
                       try JQValue.parse("[0, 0, 0, 0]"))
        XCTAssertEqual(try one(".gpu", bare), .null)
    }

    func testHostHealth() throws {
        let data = TestData()
        data.sources["system"] = try JQValue.parse(#"{"cpu": {"percent": 12}}"#)
        data.sources["host:harbor"] = try JQValue.parse(#"{"cpu": {"percent": 8}}"#)
        data.metas["host:harbor"] = try JQValue.parse(#"{"ok": true, "loaded": true, "error": null}"#)
        data.sources["host:conduit"] = try JQValue.parse(#"{"cpu": {"percent": 50}}"#)
        data.metas["host:conduit"] = try JQValue.parse(#"{"ok": false, "loaded": true, "error": "timed out"}"#)
        data.metas["host:raven"] = try JQValue.parse(#"{"ok": false, "loaded": false, "error": null}"#)
        data.sources["health"] = try json("foyer-health.json")
        data.metas["health"] = try JQValue.parse(#"{"ok": true, "loaded": true, "error": null}"#)

        func health(_ host: String) throws -> JQValue {
            try one("\(host) | host_health(.; \"foyer\")", data: data)
        }
        XCTAssertEqual(try health(#"{"name": "swift", "source": "local"}"#),
                       try JQValue.parse(#"{"data": {"cpu": {"percent": 12}}, "ok": true, "seen": true}"#))
        XCTAssertEqual(try health(#"{"name": "harbor", "url": "https://h"}"#),
                       try JQValue.parse(#"{"data": {"cpu": {"percent": 8}}, "ok": true, "seen": true}"#))
        XCTAssertEqual(try health(#"{"name": "conduit", "url": "https://c"}"#),
                       try JQValue.parse(#"{"data": null, "ok": false, "seen": true}"#), "offline: no data")
        XCTAssertEqual(try health(#"{"name": "raven", "url": "https://r"}"#),
                       try JQValue.parse(#"{"data": null, "ok": false, "seen": false}"#), "not reported yet")
        XCTAssertEqual(try one(".data.cpu.percent", try health(#"{"name": "nas", "source": "health"}"#)), .number(23),
                       "a source host goes through foyer_health")
    }

    func testFormatLegacyMatchesV03() throws {
        for (value, format) in [("1045.5", "int"), ("1045.5", "integer"), ("5.4321", "decimal"), ("5.4321", "%.2f"),
                                ("42", "null"), ("2.5", "null"), ("\"n/a\"", "\"int\""), ("\"7.25\"", "\"decimal\"")] {
            let formatArg = format.hasPrefix("\"") || format == "null" ? format : "\"\(format)\""
            let foundation = try JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)
            let formatString = try JSONSerialization.jsonObject(with: Data(formatArg.utf8), options: .fragmentsAllowed) as? String
            XCTAssertEqual(try string("\(value) | fmt_legacy(\(formatArg))"),
                           legacyFormat(foundation, formatString), "\(value) \(formatArg)")
        }
    }

    func testNumbersStayAmericanUnderACommaDecimalLocale() throws {
        // mantle's LC_NUMERIC=es_AR.UTF-8 showed BRL as "5,19" once GTK had
        // run setlocale(LC_ALL, ""). The Nix test build provides the locale
        // (LOCALE_ARCHIVE in nix/checks.nix).
        let previous = setlocale(LC_NUMERIC, nil).map { String(cString: $0) } ?? "C"
        guard setlocale(LC_NUMERIC, "es_AR.UTF-8") != nil else { throw XCTSkip("no es_AR.UTF-8 locale") }
        defer { setlocale(LC_NUMERIC, previous) }
        #if os(Linux)
        XCTAssertEqual(String(format: "%.2f", 5.19), "5,19", "the comma locale is in effect")
        #endif
        XCTAssertEqual(legacyFormat(5.19, "decimal"), "5.19")
        XCTAssertEqual(legacyFormat(1540, "int"), "1540")
        XCTAssertEqual(try string("5.19 | fmt_legacy(\"decimal\")"), "5.19")
        XCTAssertEqual(try string("5.194 | fmt_fixed(2)"), "5.19")
        XCTAssertEqual(try string("2.5 | fmt_number"), "2.50")
        XCTAssertEqual(try string("1234567.891 | fmt_thousands(2)"), "1,234,567.89")
        XCTAssertEqual(try string("2500000 | fmt_compact"), "2.5M")
        XCTAssertEqual(try string("12.345 | fmt_percent(1)"), "12.3%")
        XCTAssertEqual(try string("5242880 | fmt_bytes"), "5.0M")
        XCTAssertEqual(try string("5.19 | tostring"), "5.19")
        XCTAssertEqual(Format.bytes(1_073_741_824 / 2), "0.5G")
        XCTAssertEqual(Format.rate(5_452_595), "5.2M")
        XCTAssertEqual(Format.printf("%.3f", 0.62), "0.620")
    }

    /// v0.3's `formatValue`, through a keyValueList item's `pick`.
    private func legacyFormat(_ value: Any, _ format: String?) -> String {
        let item = PickItem(label: "x", pick: "v", format: format)
        return AsyncData.exchangeRates([item], defaultSource: "s", parsedBySource: ["s": ["v": value]]).first?.buy ?? ""
    }

    func testHugeCountsAndNaNTimesDoNotTrap() throws {
        XCTAssertEqual(try one("fmt_fixed(1e300)", .number(1.5)), .string("1.50000000000000000000"))
        XCTAssertEqual(try one("fmt_fixed(-1e300)", .number(1.5)), .string("2"))
        XCTAssertEqual(try one("fmt_percent(1e300)", .number(0.5)), try one("fmt_percent(20)", .number(0.5)))
        XCTAssertEqual(try one("fmt_thousands(1e300)", 1), try one("fmt_thousands(20)", 1))
        XCTAssertEqual(try one("fmt_duration(1e300)", 90), .string("1m 30s"))
        XCTAssertEqual(try one("truncate(1e300)", "abc"), .string("abc"))
        XCTAssertThrowsError(try one("nan | fmt_relative"))
    }

    func testSignaturesCoverTheSpec() {
        let signatures = Set(VestalFunctions.signatures)
        for name in ["fmt_fixed/1", "fmt_int/0", "fmt_number/0", "fmt_thousands/0", "fmt_thousands/1", "fmt_compact/0",
                     "fmt_percent/0", "fmt_percent/1", "fmt_bytes/0", "fmt_rate/0", "fmt_duration/0", "fmt_duration/1",
                     "fmt_uptime/0", "fmt_uptime_long/0", "fmt_relative/0", "starts_in/0", "fmt_time/1", "fmt_time/2",
                     "fmt_localized/1", "fmt_localized/2", "clock24/0", "capitalize/0", "titlecase/0", "truncate/1",
                     "step/1", "color_mix/3", "alpha/1", "to_epoch/0", "tz_valid/0", "sun_context/2", "find/1", "where/1",
                     "uniq_by/1", "pct/2", "meta/1", "history/2", "history_times/2", "path_get/1", "kv_legacy/2",
                     "weather_legacy/2", "foyer_health/0", "host_health/2", "fmt_legacy/1"] {
            XCTAssertTrue(signatures.contains(name), name)
        }
        XCTAssertEqual(VestalFunctions.signatures, VestalFunctions.signatures.sorted())
        for name in VestalFunctions.legacy {
            XCTAssertTrue(signatures.contains { $0.hasPrefix(name + "/") }, name)
        }
    }
}
