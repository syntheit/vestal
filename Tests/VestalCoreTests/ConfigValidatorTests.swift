import Foundation
import VestalCore
import XCTest

/// What `check-config` warns about.
final class ConfigValidatorTests: XCTestCase {
    /// Warnings for a user file layered on the defaults, as (path, kind).
    private func warnings(_ text: String, platform: ConfigPlatform = .macos) -> [ConfigWarning] {
        ConfigLoader.load(data: Data(text.utf8), platform: platform).warnings
    }

    private func pairs(_ text: String) -> [String: ConfigWarning.Kind] {
        var result: [String: ConfigWarning.Kind] = [:]
        for warning in warnings(text) { result[warning.path] = warning.kind }
        return result
    }

    // MARK: Hotkey

    func testHotkeys() {
        XCTAssertEqual(warnings(#"{"hotkey": "f3"}"#), [])
        XCTAssertEqual(warnings(#"{"hotkey": "cmd+shift+space"}"#), [])
        XCTAssertEqual(warnings(#"{"hotkey": null}"#), [])
        let bad = warnings(#"{"hotkey": "shift+a"}"#)
        XCTAssertEqual(bad.map(\.description), [
            "hotkey: 'shift+a': 'a' needs cmd, ctrl or alt, or it would be taken from every app"
                + " (only f1-f20, home and end may stand alone); no hotkey is registered",
        ])
        XCTAssertEqual(bad.first?.kind, .invalidValue)
        XCTAssertEqual(warnings(#"{"hotkey": "cmd+"}"#).first?.kind, .invalidValue)
        XCTAssertEqual(warnings(#"{"hotkey": 3}"#).first?.kind, .wrongType)
    }

    // MARK: Unknown keys

    func testUnknownKeysAtEveryLevel() {
        let found = pairs("""
        {
          "extra": 1,
          "theme": {"font": "x"},
          "sources": {
            "h": {"type": "http", "url": "https://x.example", "headers": {}},
            "c": {"type": "command", "argv": ["x"], "url": "https://x.example"},
            "k": {"type": "calendar", "parse": "raw"}
          },
          "widgets": {
            "clock": {"type": "clock", "title": "Now", "worldClocks": [{"label": "U", "tz": "UTC", "city": "x"}]},
            "media": {"type": "media", "source": "h"},
            "systems": {"type": "systemHealth", "hosts": [{"source": "local", "port": 1}]},
            "fx": {"type": "keyValueList", "source": "h", "items": [{"label": "A", "pick": "a", "unit": "x"}]},
            "systemBar": {"type": "systemBar", "privacy": {"script": "x"}},
            "weather": {"type": "weatherCard", "fields": {"humidity": ".h"}}
          },
          "views": {"main": {"columns": 2}}
        }
        """)
        XCTAssertEqual(found, [
            "extra": .unknownKey,
            "theme.font": .unknownKey,
            "sources.h.headers": .unknownKey,
            "sources.c.url": .unknownKey,
            "sources.k.parse": .unknownKey,
            "widgets.clock.title": .unknownKey,
            "widgets.clock.worldClocks[0].city": .unknownKey,
            "widgets.media.source": .unknownKey,
            "widgets.systems.hosts[0].port": .unknownKey,
            "widgets.fx.items[0].unit": .unknownKey,
            "widgets.systemBar.privacy.script": .unknownKey,
            "widgets.weather.fields.humidity": .unknownKey,
            "views.main.columns": .unknownKey,
        ])
    }

    func testUnknownTypes() {
        let found = warnings(#"{"sources": {"f": {"type": "ftp"}}, "widgets": {"g": {"type": "gauge", "anything": 1}}}"#)
        XCTAssertEqual(found.map(\.path), ["sources.f.type", "widgets.g.type"])
        XCTAssertEqual(found.map(\.kind), [.unknownType, .unknownType])
        XCTAssertEqual(found[1].message,
                       "unknown widget type \"gauge\" (expected agendaList, claudeUsage, clock, keyValueList, media, systemBar, systemHealth or weatherCard)")
    }

    func testAliasesAreKnownTypes() {
        XCTAssertEqual(warnings(#"{"sources": {"calendar": {"type": "eventkit"}}, "widgets": {"media": {"type": "spotify"}}}"#), [])
    }

    // MARK: References

    func testMissingReferences() {
        let found = warnings("""
        {
          "widgets": {
            "agenda": {"source": "cal"},
            "weather": {"source": "nope"},
            "fx": {"type": "keyValueList", "items": [{"label": "A", "source": "gone", "pick": "a"},
                                                     {"label": "B", "pick": "b"}]},
            "systems": {"hosts": [{"name": "box", "source": "health"}]}
          },
          "views": {"main": {"order": ["clock", "missing", "clock", "fx"]}}
        }
        """)
        XCTAssertEqual(found.map(\.path), [
            "views.main.order[1]", "views.main.order[2]",
            "widgets.agenda.source", "widgets.fx.items[0].source", "widgets.fx.items[1]",
            "widgets.systems.hosts[0].source", "widgets.weather.source",
        ])
        XCTAssertEqual(found.map(\.kind), [
            .missingReference, .invalidValue,
            .missingReference, .missingReference, .missingKey,
            .missingReference, .missingReference,
        ])
    }

    func testDeletingADefaultWidgetFlagsTheOrder() {
        let found = warnings(#"{"widgets": {"media": null}}"#)
        XCTAssertEqual(found.map(\.description), ["views.main.order[2]: no widget named \"media\""])
        XCTAssertEqual(warnings(#"{"widgets": {"media": null}, "views": {"main": {"order": ["clock"]}}}"#), [])
    }

    func testSourceKindsMustFitTheWidget() {
        let found = warnings(#"{"widgets": {"agenda": {"source": "weather"}, "weather": {"source": "calendar"}}}"#)
        XCTAssertEqual(found.map(\.path), ["widgets.agenda.source", "widgets.weather.source"])
        XCTAssertEqual(found.map(\.kind), [.invalidValue, .invalidValue])
    }

    func testMissingMainView() {
        XCTAssertEqual(warnings(#"{"views": null}"#).map(\.path), ["views.main"])
        XCTAssertEqual(warnings(#"{"views": {"main": null, "other": {"order": []}}}"#).map(\.path), ["views.main"])
    }

    // MARK: Values

    func testInvalidDurations() {
        let found = warnings("""
        {"sources": {"weather": {"refresh": "5x"}, "c": {"type": "command", "argv": ["x"], "timeout": "10"}},
         "widgets": {"systems": {"hosts": [{"source": "local", "interval": "0s"}]}}}
        """)
        XCTAssertEqual(found.map(\.path), ["sources.c.timeout", "sources.weather.refresh", "widgets.systems.hosts[0].interval"])
        XCTAssertEqual(Set(found.map(\.kind)), [.invalidValue])
        XCTAssertTrue(found[1].message.hasSuffix("using 30m"), found[1].message)
        XCTAssertTrue(found[0].message.hasSuffix("using 10s"), found[0].message)
        XCTAssertTrue(found[2].message.hasSuffix("using 5s"), found[2].message)
    }

    func testUnknownEnumValues() {
        let found = warnings("""
        {"theme": {"palette": "dracula", "background": "glass"},
         "sources": {"weather": {"parse": "xml"}},
         "widgets": {"weather": {"units": "kelvin"}, "systems": {"provider": "netdata"},
                     "systemBar": {"show": ["uptime", "cpu"]},
                     "fx": {"type": "keyValueList", "source": "weather", "items": [{"label": "A", "pick": "a", "format": "hex"}]}},
         "views": {"main": {"layout": "grid"}}}
        """)
        XCTAssertEqual(found.map(\.path), [
            "sources.weather.parse", "theme.palette", "theme.background", "views.main.layout",
            "widgets.fx.items[0].format", "widgets.systemBar.show[1]", "widgets.systems.provider", "widgets.weather.units",
        ])
        XCTAssertEqual(Set(found.map(\.kind)), [.invalidValue])
        XCTAssertEqual(found[1].message, "unknown value \"dracula\" (expected tokyo-night)")
        XCTAssertEqual(found[2].message, "unknown value \"glass\" (expected aurora, blur or none)")
    }

    func testWrongJSONTypes() {
        let found = warnings("""
        {"hotkey": 3, "version": "1", "theme": [],
         "widgets": {"agenda": {"maxEvents": "5"}, "media": {"hideWhenOff": "yes"},
                     "systemBar": {"show": ["uptime", 2]}}}
        """)
        XCTAssertEqual(found.map(\.path), [
            "hotkey", "theme", "version",
            "widgets.agenda.maxEvents", "widgets.media.hideWhenOff", "widgets.systemBar.show[1]",
        ])
        XCTAssertEqual(Set(found.map(\.kind)), [.wrongType])
        XCTAssertEqual(found[3].message,
                       "expected a whole number, found a string; treated as absent; the built-in value is not restored")
    }

    func testRequiredKeys() {
        let found = warnings("""
        {"sources": {"t": {"url": "https://x.example"}, "h": {"type": "http"}, "c": {"type": "command"}},
         "widgets": {"w": {"title": "x"},
                     "systems": {"hosts": [{"url": "https://x.example"}, {"name": "n"}]},
                     "clock": {"worldClocks": [{"label": "A"}]}}}
        """)
        XCTAssertEqual(found.map(\.path), [
            "sources.c", "sources.h", "sources.t",
            "widgets.clock.worldClocks[0]", "widgets.systems.hosts[0]", "widgets.systems.hosts[1]", "widgets.w",
        ])
        XCTAssertEqual(Set(found.map(\.kind)), [.missingKey])
    }

    func testHostKeys() {
        let found = warnings("""
        {"widgets": {"systems": {"hosts": [
          {"name": "a", "url": "https://a.example", "key": "A"},
          {"name": "b", "url": "https://b.example", "key": "a"},
          {"name": "c", "url": "https://c.example", "key": "p"},
          {"name": "d", "url": "https://d.example", "key": "dd"}
        ]}}}
        """)
        XCTAssertEqual(found.map(\.path), [
            "widgets.systems.hosts[1].key", "widgets.systems.hosts[2].key", "widgets.systems.hosts[3].key",
        ])
        XCTAssertEqual(found[0].message, "\"a\" is already the key of widgets.systems.hosts[0]")
    }

    func testPrivacyNeedsCommandAndStateFile() {
        let listed = #"{"widgets": {"systemBar": {"show": ["privacy"], "privacy": {"command": ["t"]}}}}"#
        XCTAssertEqual(warnings(listed).map(\.path), ["widgets.systemBar.privacy"])
        XCTAssertEqual(warnings(#"{"widgets": {"systemBar": {"show": ["privacy"], "privacy": {"command": ["t"], "stateFile": "/s"}}}}"#), [])
        // Not listed in show: nothing to warn about.
        XCTAssertEqual(warnings(#"{"widgets": {"systemBar": {"privacy": {"command": ["t"]}}}}"#), [])
    }

    func testPlatformBlockShape() {
        let found = warnings(#"{"platform": {"windows": {}, "linux": 3}}"#)
        XCTAssertEqual(found.map(\.path), ["platform.linux", "platform.windows"])
        XCTAssertEqual(found.map(\.kind), [.wrongType, .unknownKey])
        XCTAssertEqual(warnings(#"{"platform": []}"#).map(\.kind), [.wrongType])
    }

    func testCountsBelowOneAreReplacedByTheDefault() throws {
        let text = """
        {"sources": {"calendar": {"days": 0}},
         "widgets": {"agenda": {"maxEvents": -1},
                     "claude": {"type": "claudeUsage", "fiveHourLimit": 0, "weeklyLimit": -5}}}
        """
        let found = warnings(text)
        XCTAssertEqual(found.map(\.path), [
            "sources.calendar.days", "widgets.agenda.maxEvents", "widgets.claude.fiveHourLimit", "widgets.claude.weeklyLimit",
        ])
        XCTAssertEqual(found.map(\.message), [
            "must be at least 1; using 1", "must be at least 1; using 5",
            "must be at least 1; using 8000000", "must be at least 1; using 95000000",
        ])
        // Decoded as absent: the defaults apply, and nothing traps later.
        let config = ConfigLoader.load(data: Data(text.utf8)).config
        XCTAssertEqual(config.sources["calendar"]?.days, 1)
        XCTAssertNil(config.widgets["agenda"]?.maxEvents)
        XCTAssertNil(config.widgets["claude"]?.fiveHourLimit)
        XCTAssertNil(config.widgets["claude"]?.weeklyLimit)
    }

    func testOverflowingDurationIsInvalid() {
        let found = warnings(#"{"sources": {"weather": {"refresh": "999999999999999999m"}}}"#)
        XCTAssertEqual(found.map(\.path), ["sources.weather.refresh"])
        XCTAssertEqual(found.map(\.kind), [.invalidValue])
    }

    func testUnsupportedVersion() {
        XCTAssertEqual(warnings(#"{"version": 2}"#).map(\.kind), [.invalidValue])
    }
}
