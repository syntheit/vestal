import Foundation
import VestalCore
import XCTest

/// Resolution, layering, merge and parse errors.
final class ConfigLoaderTests: XCTestCase {
    private func json(_ text: String) -> AnyJSON {
        guard case .success(let value) = AnyJSON.parse(Data(text.utf8)) else {
            XCTFail("bad JSON literal: \(text)")
            return .null
        }
        return value
    }

    private func object(_ text: String) -> [String: AnyJSON] {
        json(text).objectValue ?? [:]
    }

    // MARK: Merge

    func testObjectsMergeKeyByKey() {
        let merged = ConfigLoader.merge(
            json(#"{"a": {"x": 1, "y": {"deep": 1, "keep": true}}, "b": 1}"#),
            json(#"{"a": {"y": {"deep": 2}, "z": 3}, "c": "new"}"#))
        XCTAssertEqual(merged, json(#"{"a": {"x": 1, "y": {"deep": 2, "keep": true}, "z": 3}, "b": 1, "c": "new"}"#))
    }

    func testArraysAndScalarsReplace() {
        let merged = ConfigLoader.merge(
            json(#"{"list": [1, 2, 3], "n": 1, "o": {"k": 1}, "s": "x"}"#),
            json(#"{"list": [4], "n": "one", "o": [1], "s": {"now": "object"}}"#))
        XCTAssertEqual(merged, json(#"{"list": [4], "n": "one", "o": [1], "s": {"now": "object"}}"#))
    }

    func testNullDeletes() {
        let merged = ConfigLoader.merge(
            json(#"{"widgets": {"media": {"type": "media"}, "clock": {"type": "clock", "title": "t"}}}"#),
            json(#"{"widgets": {"media": null, "clock": {"title": null}, "gone": null}}"#))
        XCTAssertEqual(merged, json(#"{"widgets": {"clock": {"type": "clock"}}}"#))
    }

    func testNullsInsideNewObjectsAreStrippedButListsAreKept() {
        let merged = ConfigLoader.merge(
            json(#"{"a": 1}"#),
            json(#"{"b": {"x": null, "y": {"z": null, "w": 1}, "l": [null, {"m": null}]}}"#))
        XCTAssertEqual(merged, json(#"{"a": 1, "b": {"y": {"w": 1}, "l": [null, {"m": null}]}}"#))
    }

    // MARK: Layering

    func testPlatformBlockOverridesAndIsStripped() {
        let user = object("""
        {"hotkey": "f3", "theme": {"background": "blur"},
         "platform": {"macos": {"hotkey": "cmd+space", "theme": {"palette": "p"}},
                      "linux": {"hotkey": "home", "widgets": {"clock": null}}}}
        """)
        let defaults = json(#"{"version": 1, "theme": {"palette": "tokyo-night", "background": "aurora"}, "widgets": {"clock": {"type": "clock"}}}"#)

        let mac = ConfigLoader.layer(defaults: defaults, user: user, platform: .macos)
        XCTAssertEqual(mac, json("""
        {"version": 1, "hotkey": "cmd+space", "theme": {"palette": "p", "background": "blur"},
         "widgets": {"clock": {"type": "clock"}}}
        """))
        let linux = ConfigLoader.layer(defaults: defaults, user: user, platform: .linux)
        XCTAssertEqual(linux, json("""
        {"version": 1, "hotkey": "home", "theme": {"palette": "tokyo-night", "background": "blur"}, "widgets": {}}
        """))
        XCTAssertNil(mac.objectValue?["platform"])
        XCTAssertNil(linux.objectValue?["platform"])
    }

    func testPlatformNeverReachesTheDecoder() {
        let loaded = ConfigLoader.load(data: Data("""
        {"platform": {"macos": {"platform": {"linux": {}}, "version": 1}, "linux": {"version": 1}}}
        """.utf8), platform: .macos)
        XCTAssertNil(loaded.merged.objectValue?["platform"])
        XCTAssertEqual(loaded.warnings.map(\.path), ["platform.macos.platform"])
    }

    func testOtherPlatformWarningsAreTagged() {
        let text = """
        {"platform": {"macos": {"widgets": {"clock": {"mac": 1}}}, "linux": {"widgets": {"clock": {"lin": 1}}}}}
        """
        let onMac = ConfigLoader.load(data: Data(text.utf8), platform: .macos).warnings
        XCTAssertEqual(onMac.map(\.path), ["widgets.clock.mac", "widgets.clock.lin"])
        XCTAssertEqual(onMac.map(\.platform), [nil, .linux])
        XCTAssertTrue(onMac[1].description.hasPrefix("[linux] widgets.clock.lin: unknown key"))
        let onLinux = ConfigLoader.load(data: Data(text.utf8), platform: .linux).warnings
        XCTAssertEqual(onLinux.map(\.path), ["widgets.clock.lin", "widgets.clock.mac"])
        XCTAssertEqual(onLinux.map(\.platform), [nil, .macos])
    }

    // MARK: Resolution

    func testVestalConfigWinsEvenWhenMissing() {
        let path = ConfigLoader.resolvePath(
            environment: ["VESTAL_CONFIG": "~/cfg/vestal.json", "XDG_CONFIG_HOME": "/xdg"],
            home: "/home/me", fileExists: { _ in true })
        XCTAssertEqual(path, "/home/me/cfg/vestal.json")
    }

    func testXDGThenHomeFallback() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home").path
        let xdg = root.appendingPathComponent("xdg").path
        let exists = { (path: String) in FileManager.default.fileExists(atPath: path) }

        // Nothing on disk: no file, whichever base applies.
        XCTAssertNil(ConfigLoader.resolvePath(environment: [:], home: home, fileExists: exists))
        XCTAssertNil(ConfigLoader.resolvePath(environment: ["XDG_CONFIG_HOME": xdg], home: home, fileExists: exists))

        let homeFile = try write("{}", to: "\(home)/.config/vestal/config.json")
        XCTAssertEqual(ConfigLoader.resolvePath(environment: [:], home: home, fileExists: exists), homeFile)
        XCTAssertEqual(ConfigLoader.resolvePath(environment: ["XDG_CONFIG_HOME": "", "VESTAL_CONFIG": ""],
                                                home: home, fileExists: exists), homeFile)
        // A set XDG_CONFIG_HOME is used alone, without falling back to ~/.config.
        XCTAssertNil(ConfigLoader.resolvePath(environment: ["XDG_CONFIG_HOME": xdg], home: home, fileExists: exists))

        let xdgFile = try write("{}", to: "\(xdg)/vestal/config.json")
        XCTAssertEqual(ConfigLoader.resolvePath(environment: ["XDG_CONFIG_HOME": xdg], home: home, fileExists: exists), xdgFile)
        // A relative XDG_CONFIG_HOME is invalid per the spec and ignored.
        XCTAssertEqual(ConfigLoader.resolvePath(environment: ["XDG_CONFIG_HOME": "rel"], home: home, fileExists: exists), homeFile)

        let explicit = try write("{}", to: "\(root.path)/explicit.json")
        XCTAssertEqual(ConfigLoader.resolvePath(environment: ["XDG_CONFIG_HOME": xdg, "VESTAL_CONFIG": explicit],
                                                home: home, fileExists: exists), explicit)
    }

    func testLoadReadsTheResolvedFile() throws {
        let root = try makeTemporaryDirectory()
        let file = try write(#"{"hotkey": "f3"}"#, to: "\(root.path)/xdg/vestal/config.json")
        let loaded = ConfigLoader.load(environment: ["XDG_CONFIG_HOME": "\(root.path)/xdg"], home: root.path)
        XCTAssertEqual(loaded.path, file)
        XCTAssertEqual(loaded.config.hotkey, "f3")
        XCTAssertEqual(loaded.warnings, [])

        let none = ConfigLoader.load(environment: [:], home: root.path)
        XCTAssertNil(none.path)
        XCTAssertEqual(none.config, DefaultConfig.config)
        XCTAssertEqual(none.merged, DefaultConfig.tree)
    }

    func testMissingVestalConfigFileWarnsAndUsesDefaults() throws {
        let root = try makeTemporaryDirectory()
        let loaded = ConfigLoader.load(environment: ["VESTAL_CONFIG": "\(root.path)/nope.json"], home: root.path)
        XCTAssertEqual(loaded.path, "\(root.path)/nope.json")
        XCTAssertEqual(loaded.warnings.map(\.kind), [.unreadable])
        XCTAssertTrue(loaded.hasErrors)
        XCTAssertEqual(loaded.config, DefaultConfig.config)
    }

    // MARK: Parse errors

    func testParseErrorKeepsDefaultsAndReportsLineAndColumn() {
        let loaded = ConfigLoader.load(data: Data("{\n  \"version\": 1,\n  \"hotkey\": x\n}\n".utf8), path: "/c.json")
        XCTAssertEqual(loaded.config, DefaultConfig.config)
        XCTAssertEqual(loaded.merged, DefaultConfig.tree)
        XCTAssertEqual(loaded.warnings.count, 1)
        let warning = loaded.warnings[0]
        XCTAssertEqual(warning.kind, .invalidJSON)
        XCTAssertTrue(warning.isError)
        XCTAssertEqual(warning.line, 3)
        XCTAssertNotNil(warning.column)
        XCTAssertTrue(warning.description.hasPrefix("line 3, column "), warning.description)
    }

    func testTruncatedFilePointsAtTheEnd() {
        let result = AnyJSON.parse(Data("{\n \"a\": [1, 2\n".utf8))
        guard case .failure(let error) = result else { return XCTFail("parsed a truncated document") }
        #if os(Linux)
        // corelibs reports no position for a truncated file; the end is where it broke.
        XCTAssertEqual(error.line, 3)
        XCTAssertEqual(error.column, 1)
        #endif
        XCTAssertFalse(error.message.isEmpty)
    }

    func testPositionsFromEachFoundationErrorForm() {
        let data = Data("{\n  \"a\": x\n}".utf8)
        func locate(_ info: [String: Any]) -> JSONParseError {
            AnyJSON.locate(NSError(domain: NSCocoaErrorDomain, code: 3840, userInfo: info), in: data)
        }
        // corelibs: a byte offset in the message.
        XCTAssertEqual(locate([NSDebugDescriptionErrorKey: "Invalid value around character 9."]),
                       JSONParseError(message: "invalid value", line: 2, column: 8))
        // Darwin: the offset in userInfo wins over the message's line and column.
        XCTAssertEqual(locate([NSDebugDescriptionErrorKey: "Unexpected character 'x' around line 2, column 8.",
                               "NSJSONSerializationErrorIndex": 9]),
                       JSONParseError(message: "unexpected character 'x'", line: 2, column: 8))
        XCTAssertEqual(locate([NSDebugDescriptionErrorKey: "Invalid value around line 2, column 7."]),
                       JSONParseError(message: "invalid value", line: 2, column: 7))
        XCTAssertEqual(locate([NSDebugDescriptionErrorKey: "Unexpected end of file during JSON parse."]),
                       JSONParseError(message: "unexpected end of file during JSON parse", line: 3, column: 2))
        XCTAssertEqual(locate([NSDebugDescriptionErrorKey: "Something else."]),
                       JSONParseError(message: "something else"))
    }

    func testTopLevelMustBeAnObject() {
        for text in ["[1]", "\"x\"", "3", "null"] {
            let loaded = ConfigLoader.load(data: Data(text.utf8))
            XCTAssertEqual(loaded.warnings.map(\.kind), [.invalidJSON], text)
            XCTAssertEqual(loaded.config, DefaultConfig.config, text)
        }
    }

    func testLineAndColumnFromOffset() {
        let data = Data("{\n  \"é\": x\n}".utf8)
        XCTAssertEqual(AnyJSON.lineAndColumn(ofOffset: 0, in: data).line, 1)
        XCTAssertEqual(AnyJSON.lineAndColumn(ofOffset: 0, in: data).column, 1)
        // "x" is byte 10 ("é" takes two bytes) but the 8th character of line 2.
        XCTAssertEqual(AnyJSON.lineAndColumn(ofOffset: 10, in: data).line, 2)
        XCTAssertEqual(AnyJSON.lineAndColumn(ofOffset: 10, in: data).column, 8)
        XCTAssertEqual(AnyJSON.lineAndColumn(ofOffset: 99, in: data).line, 3)
        XCTAssertEqual(AnyJSON.lineAndColumn(ofOffset: 99, in: data).column, 2)
    }

    // MARK: Defaults and the example

    func testDefaultsParseAndValidateWithoutWarnings() {
        XCTAssertNotEqual(DefaultConfig.tree, .object([:]))
        let loaded = ConfigLoader.load(data: Data(DefaultConfig.json.utf8))
        XCTAssertEqual(loaded.warnings, [])
        XCTAssertEqual(loaded.merged, DefaultConfig.tree)
        XCTAssertEqual(loaded.config, DefaultConfig.config)
    }

    func testDefaultsAreGeneric() {
        let config = DefaultConfig.config
        XCTAssertNil(config.hotkey)
        XCTAssertEqual(config.theme, ThemeConfig(palette: "tokyo-night", background: "aurora"))
        XCTAssertEqual(config.views["main"]?.order, ["clock", "systemBar", "media", "agenda", "systems", "weather"])
        XCTAssertEqual(config.widgets["clock"], WidgetConfig(type: "clock"))
        XCTAssertEqual(config.widgets["systemBar"]?.show, ["uptime", "disk", "battery", "network"])
        XCTAssertEqual(config.widgets["media"], WidgetConfig(type: "media", hideWhenOff: true))
        XCTAssertEqual(config.widgets["agenda"], WidgetConfig(type: "agendaList", source: "calendar", maxEvents: 5))
        XCTAssertEqual(config.widgets["systems"]?.hosts, [HostConfig(name: LocalHost.shortName, source: "local")])
        XCTAssertEqual(config.sources["calendar"]?.type, "calendar")
        XCTAssertEqual(config.sources["weather"]?.url, "https://wttr.in/?m&format=j1")
        XCTAssertEqual(Set(config.sources.keys), ["weather", "calendar"])
    }

    func testFullExampleLoadsWithoutWarnings() throws {
        let path = Fixture.example("full.json").path
        for platform in ConfigPlatform.allCases {
            let loaded = ConfigLoader.load(path: path, platform: platform)
            XCTAssertEqual(loaded.warnings, [], "\(platform)")
            XCTAssertEqual(loaded.path, path)
        }
        let config = ConfigLoader.load(path: path).config
        XCTAssertEqual(config.views["main"]?.order,
                       ["clock", "systemBar", "spotify", "agenda", "systems", "exchange", "weather"])
        XCTAssertEqual(Set(config.widgets.keys),
                       ["clock", "systemBar", "claude", "spotify", "agenda", "systems", "exchange", "weather"])
        XCTAssertEqual(config.widgets.mapValues(\.type), [
            "clock": "clock", "systemBar": "systemBar", "claude": "claudeUsage", "spotify": "media",
            "agenda": "agendaList", "systems": "systemHealth", "exchange": "keyValueList", "weather": "weatherCard",
        ])
        XCTAssertNil(config.hotkey)
        XCTAssertEqual(config.widgets["clock"]?.worldClocks?.map(\.label), ["BA", "NYC", "CHI"])
        XCTAssertEqual(config.widgets["systemBar"]?.show,
                       ["uptime", "disk", "battery", "claudeUsage", "network", "privacy"])
        XCTAssertEqual(config.widgets["systemBar"]?.privacy,
                       PrivacyConfig(command: ["bash", "~/.local/bin/toggle-privacy"], stateFile: "/tmp/.privacy-mode"))
        XCTAssertEqual(config.widgets["systems"]?.hosts?.map(\.name), ["swift", "harbor", "raven", "conduit"])
        XCTAssertEqual(config.widgets["systems"]?.hosts?.first?.isLocal, true)
        XCTAssertEqual(config.widgets["exchange"]?.title(forKey: "exchange"), "Currencies")
        XCTAssertEqual(config.widgets["exchange"]?.items?.map(\.label), ["Blue", "Official", "MEP", "BRL"])
        XCTAssertEqual(config.widgets["spotify"], WidgetConfig(type: "media", player: "Spotify", hideWhenOff: true))
        XCTAssertEqual(config.widgets["claude"]?.fiveHourLimit, 8_000_000)
        XCTAssertEqual(config.widgets["claude"]?.weeklyLimit, 95_000_000)
        XCTAssertEqual(config.widgets["agenda"]?.maxEvents, 5)
        XCTAssertEqual(Set(config.sources.keys), ["weather", "dolares", "rates", "calendar"])
    }

    func testClaudeUsageOptionsComeFromTheFirstWidgetByKey() {
        XCTAssertNil(DefaultConfig.config.claudeUsageWidget)
        let config = Config(widgets: [
            "b": WidgetConfig(type: "claudeUsage", weeklyLimit: 2),
            "a": WidgetConfig(type: "claudeUsage", weeklyLimit: 1),
            "0": WidgetConfig(type: "clock"),
        ])
        XCTAssertEqual(config.claudeUsageWidget?.weeklyLimit, 1)
    }

    // MARK: Helpers

    @discardableResult
    private func write(_ text: String, to path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return path
    }
}
