import Foundation
import VestalCore
import XCTest

final class ConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    private func roundTrip(_ config: Config) throws -> Config {
        try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
    }

    func testEmptyObjectDecodesToDefaults() throws {
        let config = try decode("{}")
        XCTAssertEqual(config.version, 1)
        XCTAssertNil(config.hotkey)
        XCTAssertEqual(config.theme, ThemeConfig(palette: "tokyo-night", background: "aurora"))
        XCTAssertTrue(config.sources.isEmpty)
        XCTAssertTrue(config.widgets.isEmpty)
        XCTAssertTrue(config.views.isEmpty)
    }

    func testMissingOptionalFieldsFallBack() throws {
        let config = try decode("""
        {
          "sources": {"weather": {"type": "http", "url": "https://example.com/w"}},
          "theme": {"palette": "other"},
          "views": {"main": {}}
        }
        """)
        XCTAssertEqual(config.sources["weather"], SourceConfig(
            type: "http", url: "https://example.com/w", refresh: "30m", parse: "json"))
        XCTAssertEqual(config.theme.palette, "other")
        XCTAssertEqual(config.theme.background, "aurora")
        XCTAssertEqual(config.views["main"], ViewConfig(order: [], layout: "stack"))
    }

    func testUnknownKeysAreIgnored() throws {
        let config = try decode("""
        {"version": 1, "futureKey": [1, 2], "widgets": {"c": {"type": "clock", "someday": true}}}
        """)
        XCTAssertEqual(config.widgets["c"]?.type, "clock")
    }

    func testSourceWithoutTypeFailsToDecode() {
        XCTAssertThrowsError(try decode(#"{"sources": {"x": {"url": "https://example.com"}}}"#))
    }

    func testFullConfigRoundTrips() throws {
        let config = try decode("""
        {
          "version": 1,
          "hotkey": "f3",
          "theme": {"palette": "tokyo-night", "background": "blur"},
          "sources": {
            "rates": {"type": "http", "url": "https://example.com/rates.json", "refresh": "4h", "parse": "json"},
            "calendar": {"type": "eventkit", "refresh": "5m", "parse": "raw"}
          },
          "widgets": {
            "clock": {"type": "clock", "worldClocks": [{"label": "UTC", "tz": "UTC"}]},
            "bar": {"type": "systemBar", "show": ["uptime", "network"]},
            "systems": {"type": "systemHealth", "provider": "foyer",
                        "hosts": [{"name": "local", "source": "local"}, {"name": "box", "url": "https://box.example"}]},
            "fx": {"type": "keyValueList", "title": "FX", "source": "rates",
                   "items": [{"label": "A", "match": {"k": "a", "n": 1, "d": 1.5, "b": true, "z": null},
                              "picks": {"buy": "x", "sell": "y"}, "format": "int"},
                             {"label": "B", "source": "other", "pick": "rates.B", "format": "decimal"}]},
            "weather": {"type": "weatherCard", "source": "w", "units": "imperial",
                        "fields": {"temp": ".t"}, "fixedLocation": {"lat": 1.25, "lon": -2.5}},
            "media": {"type": "spotify", "hideWhenOff": false},
            "agenda": {"type": "agendaList", "source": "calendar", "maxEvents": 3}
          },
          "views": {"main": {"order": ["clock", "bar"], "layout": "stack"}}
        }
        """)
        XCTAssertEqual(try roundTrip(config), config)
        XCTAssertEqual(config.hotkey, "f3")
        XCTAssertEqual(config.widgets["fx"]?.items?.first?.match?["n"], .int(1))
        XCTAssertEqual(config.widgets["fx"]?.items?.first?.match?["d"], .double(1.5))
        XCTAssertEqual(config.widgets["fx"]?.items?.first?.match?["b"], .bool(true))
        XCTAssertEqual(config.widgets["fx"]?.items?.first?.match?["z"], .null)
        XCTAssertEqual(config.widgets["weather"]?.fixedLocation, FixedLocation(lat: 1.25, lon: -2.5))
    }

    func testBundledDefaultsRoundTrip() throws {
        XCTAssertEqual(try roundTrip(DefaultConfig.config), DefaultConfig.config)
    }

    func testBundledDefaultsReferenceExistingWidgetsAndSources() {
        let config = DefaultConfig.config
        for key in config.views["main"]?.order ?? [] {
            XCTAssertNotNil(config.widgets[key], "view order names missing widget \(key)")
        }
        for (key, widget) in config.widgets {
            if let source = widget.source {
                XCTAssertNotNil(config.sources[source], "widget \(key) names missing source \(source)")
            }
            for item in widget.items ?? [] {
                if let source = item.source {
                    XCTAssertNotNil(config.sources[source], "item \(item.label) names missing source \(source)")
                }
            }
        }
    }

    // MARK: AnyJSON

    func testAnyJSONDecodesEachScalarKind() throws {
        let values = try JSONDecoder().decode(
            [String: AnyJSON].self,
            from: Data(#"{"s": "blue", "i": 7, "d": 2.5, "b": false, "n": null}"#.utf8))
        XCTAssertEqual(values, ["s": .string("blue"), "i": .int(7), "d": .double(2.5), "b": .bool(false), "n": .null])
    }

    func testAnyJSONRejectsContainers() {
        XCTAssertThrowsError(try JSONDecoder().decode(AnyJSON.self, from: Data("[1]".utf8)))
    }

    func testAnyJSONMatchesStrings() {
        XCTAssertTrue(AnyJSON.string("blue").matches("blue"))
        XCTAssertFalse(AnyJSON.string("blue").matches("oficial"))
        XCTAssertFalse(AnyJSON.string("1").matches(1))
        XCTAssertFalse(AnyJSON.string("blue").matches(nil))
    }

    func testAnyJSONMatchesNumbersAcrossIntAndDouble() {
        XCTAssertTrue(AnyJSON.int(3).matches(3))
        XCTAssertTrue(AnyJSON.int(3).matches(3.0))
        XCTAssertFalse(AnyJSON.int(3).matches(4))
        XCTAssertFalse(AnyJSON.int(3).matches("3"))
        XCTAssertTrue(AnyJSON.double(2.5).matches(2.5))
        XCTAssertTrue(AnyJSON.double(2.0).matches(2))
        XCTAssertFalse(AnyJSON.double(2.5).matches(2))
    }

    func testAnyJSONMatchesBoolsAndNull() {
        XCTAssertTrue(AnyJSON.bool(true).matches(true))
        XCTAssertFalse(AnyJSON.bool(true).matches(false))
        XCTAssertTrue(AnyJSON.null.matches(nil))
        XCTAssertTrue(AnyJSON.null.matches(NSNull()))
        XCTAssertFalse(AnyJSON.null.matches("x"))
    }

    func testAnyJSONMatchesValuesFromJSONSerialization() throws {
        let element = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(#"{"casa": "blue", "n": 42, "x": 1.5, "z": null}"#.utf8))
                as? [String: Any])
        XCTAssertTrue(AnyJSON.string("blue").matches(element["casa"]))
        XCTAssertTrue(AnyJSON.int(42).matches(element["n"]))
        XCTAssertTrue(AnyJSON.double(42).matches(element["n"]))
        XCTAssertTrue(AnyJSON.double(1.5).matches(element["x"]))
        XCTAssertTrue(AnyJSON.null.matches(element["z"]))
        XCTAssertTrue(AnyJSON.null.matches(element["missing"]))
    }

    // MARK: Durations

    func testDurationUnits() {
        XCTAssertEqual(AppRuntime.parseDuration("30s"), .seconds(30))
        XCTAssertEqual(AppRuntime.parseDuration("5m"), .seconds(300))
        XCTAssertEqual(AppRuntime.parseDuration("4h"), .seconds(14_400))
        XCTAssertEqual(AppRuntime.parseDuration("1d"), .seconds(86_400))
        XCTAssertEqual(AppRuntime.parseDuration(" 2h "), .seconds(7_200))
    }

    func testInvalidDurations() {
        for input in ["", "5", "m", "5x", "0s", "-5m", "1.5h", "5 m", "5M", "h5"] {
            XCTAssertNil(AppRuntime.parseDuration(input), "\"\(input)\" should not parse")
        }
    }
}
