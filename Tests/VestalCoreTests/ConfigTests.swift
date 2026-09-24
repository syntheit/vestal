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

    func testEntriesWithoutTypeAreDroppedAlone() throws {
        let config = try decode("""
        {"sources": {"x": {"url": "https://example.com"}, "y": {"type": "http"}},
         "widgets": {"a": {"title": "A"}, "b": {"type": "clock"}}}
        """)
        XCTAssertEqual(Set(config.sources.keys), ["y"])
        XCTAssertEqual(Set(config.widgets.keys), ["b"])
    }

    func testWrongTypedValuesCountAsAbsent() throws {
        let config = try decode("""
        {"version": "1", "theme": {"palette": 3},
         "sources": {"s": {"type": "http", "refresh": 5, "days": "2"}},
         "widgets": {"a": {"type": "agendaList", "maxEvents": "5", "source": "s"},
                     "c": {"type": "clock", "worldClocks": [{"label": "A", "tz": "UTC"}, {"label": "B"}, 7]}},
         "views": {"main": {"order": "clock"}}}
        """)
        XCTAssertEqual(config.version, 1)
        XCTAssertEqual(config.theme.palette, "tokyo-night")
        XCTAssertEqual(config.sources["s"], SourceConfig(type: "http"))
        XCTAssertNil(config.widgets["a"]?.maxEvents)
        XCTAssertEqual(config.widgets["a"]?.source, "s")
        XCTAssertEqual(config.widgets["c"]?.worldClocks, [WorldClock(label: "A", tz: "UTC")])
        XCTAssertEqual(config.views["main"], ViewConfig())
    }

    func testTypeAliases() throws {
        let config = try decode("""
        {"sources": {"cal": {"type": "eventkit"}}, "widgets": {"m": {"type": "spotify"}}}
        """)
        XCTAssertEqual(config.sources["cal"]?.type, "calendar")
        XCTAssertEqual(config.widgets["m"]?.type, "media")
    }

    func testSchemaAdditionsDecode() throws {
        let config = try decode("""
        {
          "sources": {
            "cmd": {"type": "command", "argv": ["foo", "--bar"], "timeout": "3s", "refresh": "1m",
                    "parse": "raw", "env": {"A": "1"}},
            "cal": {"type": "calendar", "days": 3, "calendars": ["Work"]}
          },
          "widgets": {
            "bar": {"type": "systemBar", "show": ["network", "uptime"],
                    "privacy": {"command": ["toggle"], "stateFile": "/run/p"}},
            "m": {"type": "media", "player": "Music", "hideWhenOff": false},
            "sys": {"type": "systemHealth", "hosts": [{"source": "local", "key": "l", "interval": "10s"},
                                                      {"name": "box", "source": "cmd"}]},
            "w": {"type": "weatherCard", "units": "imperial"},
            "cu": {"type": "claudeUsage", "path": "/x", "fiveHourLimit": 10, "weeklyLimit": 20}
          }
        }
        """)
        XCTAssertEqual(config.sources["cmd"], SourceConfig(
            type: "command", refresh: "1m", parse: "raw", argv: ["foo", "--bar"], timeout: "3s", env: ["A": "1"]))
        XCTAssertEqual(config.sources["cal"], SourceConfig(type: "calendar", days: 3, calendars: ["Work"]))
        XCTAssertEqual(config.widgets["bar"]?.show, ["network", "uptime"])
        XCTAssertEqual(config.widgets["bar"]?.privacy, PrivacyConfig(command: ["toggle"], stateFile: "/run/p"))
        XCTAssertEqual(config.widgets["bar"]?.privacy?.isConfigured, true)
        XCTAssertEqual(config.widgets["m"]?.player, "Music")
        XCTAssertEqual(config.widgets["m"]?.hideWhenOff, false)
        XCTAssertEqual(config.widgets["sys"]?.hosts, [
            HostConfig(name: LocalHost.shortName, source: "local", key: "l", interval: "10s"),
            HostConfig(name: "box", source: "cmd"),
        ])
        XCTAssertEqual(config.widgets["w"]?.units, "imperial")
        XCTAssertEqual(config.widgets["cu"], WidgetConfig(
            type: "claudeUsage", path: "/x", fiveHourLimit: 10, weeklyLimit: 20))
    }

    func testLocalHostNameDefaultsToShortHostname() throws {
        XCTAssertFalse(LocalHost.shortName.isEmpty)
        XCTAssertFalse(LocalHost.shortName.contains("."))
        let config = try decode(#"{"widgets": {"s": {"type": "systemHealth", "hosts": [{"source": "local"}, {"url": "https://x"}]}}}"#)
        // The remote host without a name is dropped; the local one is named after this machine.
        XCTAssertEqual(config.widgets["s"]?.hosts, [HostConfig(name: LocalHost.shortName, source: "local")])
    }

    func testPrivacyNeedsBothKeys() {
        XCTAssertFalse(PrivacyConfig(command: ["x"]).isConfigured)
        XCTAssertFalse(PrivacyConfig(stateFile: "/s").isConfigured)
        XCTAssertFalse(PrivacyConfig(command: [], stateFile: "/s").isConfigured)
        XCTAssertTrue(PrivacyConfig(command: ["x"], stateFile: "/s").isConfigured)
    }

    func testWidgetTitles() {
        XCTAssertEqual(WidgetConfig(type: "agendaList").title(forKey: "agenda"), "Today")
        XCTAssertEqual(WidgetConfig(type: "systemHealth").title(forKey: "systems"), "Systems")
        XCTAssertEqual(WidgetConfig(type: "weatherCard").title(forKey: "weather"), "Weather")
        XCTAssertEqual(WidgetConfig(type: "keyValueList").title(forKey: "exchangeRates"), "ExchangeRates")
        XCTAssertEqual(WidgetConfig(type: "keyValueList", title: "Currencies").title(forKey: "exchange"), "Currencies")
        XCTAssertNil(WidgetConfig(type: "clock").title(forKey: "clock"))
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
            "weather": {"type": "weatherCard", "source": "w", "units": "imperial", "fields": {"temp": ".t"}},
            "media": {"type": "spotify", "player": "Spotify", "hideWhenOff": false},
            "bar2": {"type": "systemBar", "privacy": {"command": ["t"], "stateFile": "/s"}},
            "claude": {"type": "claudeUsage", "fiveHourLimit": 1, "weeklyLimit": 2},
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
        XCTAssertEqual(config.widgets["media"]?.type, "media")
    }

    func testBuiltInDefaultsRoundTrip() throws {
        XCTAssertEqual(try roundTrip(DefaultConfig.config), DefaultConfig.config)
    }

    func testBuiltInDefaultsReferenceExistingWidgetsAndSources() {
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

    func testAnyJSONDecodesContainers() throws {
        let value = try JSONDecoder().decode(AnyJSON.self, from: Data(#"{"a": [1, 2.5, "x", null, {"b": true}], "o": {}}"#.utf8))
        XCTAssertEqual(value, .object([
            "a": .array([.int(1), .double(2.5), .string("x"), .null, .object(["b": .bool(true)])]),
            "o": .object([:]),
        ]))
        XCTAssertEqual(try JSONDecoder().decode(AnyJSON.self, from: JSONEncoder().encode(value)), value)
    }

    func testAnyJSONMatchesContainers() throws {
        let element = try JSONSerialization.jsonObject(with: Data(#"{"l": [1, "a"], "o": {"k": 2.0}}"#.utf8)) as? [String: Any]
        XCTAssertTrue(AnyJSON.array([.int(1), .string("a")]).matches(element?["l"]))
        XCTAssertFalse(AnyJSON.array([.int(1)]).matches(element?["l"]))
        XCTAssertTrue(AnyJSON.object(["k": .int(2)]).matches(element?["o"]))
        XCTAssertFalse(AnyJSON.object(["k": .int(2), "z": .null]).matches(element?["o"]))
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
        // Only exact equality: 3.5 is not 3, and a huge double doesn't trap.
        XCTAssertFalse(AnyJSON.int(3).matches(3.5))
        XCTAssertFalse(AnyJSON.int(3).matches(1e300))
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
