import Foundation
import VestalCore
import XCTest

/// check-config v2: pointers into the user's file, layers, codes,
/// suggestions, `--json`, `--strict`, `--platform`,
/// stdin and `--commands`, and `print-config --origins`.
final class CheckConfigTests: XCTestCase {
    private func diagnose(_ text: String, platform: ConfigPlatform, otherPlatforms: Bool = true) -> [ConfigDiagnostic] {
        let data = Data(text.utf8)
        let loaded = ConfigLoader.load(data: data, platform: platform, otherPlatforms: otherPlatforms)
        guard case .success(let tree) = AnyJSON.parse(data) else { return [] }
        return ConfigDiagnostics.make(loaded, user: tree.objectValue, platform: platform, positions: JSONPositions(data))
    }

    private func check(_ arguments: [String], _ text: String?, stdin: String = "") throws -> (ConfigCommands.Output, String) {
        let dir = try makeTemporaryDirectory()
        let path = dir.appendingPathComponent("config.json").path
        if let text { FileManager.default.createFile(atPath: path, contents: Data(text.utf8)) }
        let output = ConfigCommands.checkConfig(arguments.map { $0 == "PATH" ? path : $0 }, environment: [:],
                                                home: dir.path, stdin: { Data(stdin.utf8) })
        return (output, path)
    }

    private func json(_ text: String) throws -> [String: AnyJSON] {
        guard case .success(let tree) = AnyJSON.parse(Data(text.utf8)), let object = tree.objectValue else {
            throw XCTSkip("not JSON: \(text)")
        }
        return object
    }

    // MARK: Pointers and layers

    private let platformConfig = """
    {
      "widgets": {"clock": {"zone": "x"}},
      "platform": {
        "linux": {
          "widgets": {"systems": {"hosts": [{"source": "local", "port": 1}]}, "clock": {"tz": 1}},
          "hotkey": "shift+a"
        }
      }
    }
    """

    /// A problem in the platform.linux block points into that block of the
    /// user's file, never into the merged document.
    func testPointersIntoThePlatformBlock() {
        let linux = diagnose(platformConfig, platform: .linux)
        XCTAssertEqual(linux.map(\.pointer), [
            "/platform/linux/hotkey", "/platform/linux/widgets/clock/tz", "/widgets/clock/zone",
            "/platform/linux/widgets/systems/hosts/0/port",
        ])
        XCTAssertEqual(linux.map(\.layer), [.platformLinux, .platformLinux, .user, .platformLinux])
        XCTAssertEqual(linux.map(\.line), [6, 5, 2, 5])
        XCTAssertEqual(linux.map(\.column), [7, 85, 25, 61])
        XCTAssertEqual(linux.map(\.code), ["invalid-key", "unknown-key", "unknown-key", "unknown-key"])
        XCTAssertEqual(linux[3].suggestions, [], "port is nothing like a host key")

        // Checked on macOS, the Linux block's findings are still reported,
        // tagged, with the same pointers.
        let macos = diagnose(platformConfig, platform: .macos)
        XCTAssertEqual(macos.map(\.pointer), [
            "/widgets/clock/zone", "/platform/linux/hotkey", "/platform/linux/widgets/clock/tz",
            "/platform/linux/widgets/systems/hosts/0/port",
        ])
        XCTAssertEqual(macos.map(\.warning.platform), [nil, .linux, .linux, .linux])
        XCTAssertEqual(macos[1].json.objectValue?["platform"], .string("linux"))
        // --platform macos: this OS only.
        XCTAssertEqual(diagnose(platformConfig, platform: .macos, otherPlatforms: false).map(\.pointer), ["/widgets/clock/zone"])
    }

    /// A finding the other OS's block causes by setting a value itself is
    /// reported there, even when the base file has the same one.
    func testTheOtherBlockKeepsItsOwnFinding() {
        let text = #"{"sources": {"weather": {"url": "ftp://x"}}, "platform": {"linux": {"sources": {"weather": {"url": "ftp://x"}}}}}"#
        let found = diagnose(text, platform: .macos)
        XCTAssertEqual(found.map(\.pointer), ["/sources/weather/url", "/platform/linux/sources/weather/url"])
        XCTAssertEqual(found.map(\.warning.platform), [nil, .linux])
        // One the base file causes on both OSes is reported once.
        XCTAssertEqual(diagnose(#"{"sources": {"weather": {"url": "ftp://x"}}, "platform": {"linux": {}}}"#, platform: .macos)
            .map(\.pointer), ["/sources/weather/url"])
    }

    func testTheBlockItselfIsInTheUserLayer() {
        let found = diagnose(#"{"platform": {"linux": {"platform": {}}, "macOS": {}}}"#, platform: .linux)
        XCTAssertEqual(found.map(\.pointer), ["/platform/linux/platform", "/platform/macOS"])
        XCTAssertEqual(found.map(\.layer), [.user, .user])
        XCTAssertEqual(found[1].suggestions, ["macos"])
    }

    func testFindingsInTheDefaultsLayer() {
        // Deleting a default widget leaves the default order naming it.
        let deleted = diagnose(#"{"widgets": {"media": null}}"#, platform: .macos)
        XCTAssertEqual(deleted.map(\.pointer), ["/views/main/order/2"])
        XCTAssertEqual(deleted.map(\.layer), [.defaults])
        XCTAssertNil(deleted[0].line, "no position outside the user's file")
        XCTAssertEqual(deleted[0].code, "unknown-widget")
        XCTAssertEqual(deleted[0].hint, "at /views/main/order/2 (in the built-in defaults)")

        // A key the user deleted is theirs, at the null.
        let views = diagnose("{\n  \"views\": null\n}", platform: .macos)
        XCTAssertEqual(views.map(\.pointer), ["/views/main"])
        XCTAssertEqual(views.map(\.layer), [.user])
        XCTAssertEqual(views.map(\.line), [2])

        // A key the user overrode in a default entry is theirs; one they
        // left alone is the defaults'.
        let override = diagnose(#"{"sources": {"weather": {"refresh": "5x", "url": "ftp://x"}}}"#, platform: .macos)
        XCTAssertEqual(override.map(\.pointer), ["/sources/weather/refresh", "/sources/weather/url"])
        XCTAssertEqual(override.map(\.layer), [.user, .user])
        let typeOnly = diagnose(#"{"sources": {"weather": {"type": "command"}}}"#, platform: .macos)
        XCTAssertEqual(typeOnly.map(\.pointer), ["/sources/weather/url", "/sources/weather"])
        XCTAssertEqual(typeOnly.map(\.layer), [.defaults, .user])
    }

    func testKeysWithDotsAndSlashes() {
        let found = diagnose("""
        {"widgets": {"a.b": {"type": "media", "x": 1}, "c/d": {"type": "media", "y": 1}, "a": {"type": "clock"}},
         "views": {"main": {"order": ["a.b", "c/d", "a"]}}}
        """, platform: .macos)
        XCTAssertEqual(found.map(\.pointer), ["/widgets/a.b/x", "/widgets/c~1d/y"])
        XCTAssertEqual(found.map(\.line), [1, 1])
    }

    func testSegmentsPreferTheLongestKey() {
        let tree = AnyJSON.object(["a": .object(["b": .int(1)]), "a.b": .object(["c": .array([.int(1)])])])
        XCTAssertEqual(ConfigDiagnostics.segments(of: "a.b.c[0]", in: tree), ["a.b", "c", "0"])
        XCTAssertEqual(ConfigDiagnostics.segments(of: "a.x", in: tree), ["a", "x"])
        XCTAssertEqual(ConfigDiagnostics.segments(of: "missing.q[3].r", in: tree), ["missing", "q", "3", "r"])
    }

    // MARK: Codes, suggestions, expected and found

    func testCodesAndDetails() {
        let found = diagnose("""
        {"hotkeys": "f3", "hotkey": "shift+a",
         "theme": {"background": "blurr"},
         "sources": {"rates": {"type": "htp"}, "weather": {"refresh": "5x"}},
         "widgets": {"agenda": {"source": "calender", "maxEvents": "5"},
                     "systems": {"hosts": [{"name": "a", "url": "https://a.example", "key": "q"},
                                           {"name": "b", "url": "https://b.example", "key": "q"}]}},
         "views": {"main": {"order": ["clock", "agnda"]}}}
        """, platform: .macos)
        func find(_ pointer: String) -> ConfigDiagnostic? { found.first { $0.pointer == pointer } }
        XCTAssertEqual(find("/hotkeys")?.code, "unknown-key")
        XCTAssertEqual(find("/hotkeys")?.suggestions, ["hotkey"])
        XCTAssertEqual(find("/hotkey")?.code, "invalid-key")
        XCTAssertEqual(find("/theme/background")?.code, "invalid-value")
        XCTAssertEqual(find("/theme/background")?.suggestions, ["blur"])
        XCTAssertEqual(find("/theme/background")?.found, "blurr")
        XCTAssertEqual(find("/sources/rates/type")?.code, "unknown-type")
        XCTAssertEqual(find("/sources/rates/type")?.suggestions, ["http"])
        XCTAssertEqual(find("/sources/weather/refresh")?.code, "invalid-duration")
        XCTAssertEqual(find("/sources/weather/refresh")?.found, "5x")
        XCTAssertEqual(find("/widgets/agenda/source")?.code, "unknown-source")
        XCTAssertEqual(find("/widgets/agenda/source")?.suggestions, ["calendar"])
        XCTAssertEqual(find("/widgets/agenda/maxEvents")?.code, "type-mismatch")
        XCTAssertEqual(find("/widgets/agenda/maxEvents")?.expected, "integer")
        XCTAssertEqual(find("/widgets/agenda/maxEvents")?.found, "string")
        XCTAssertEqual(find("/widgets/systems/hosts/1/key")?.code, "key-conflict")
        XCTAssertEqual(find("/views/main/order/1")?.code, "unknown-widget")
        XCTAssertEqual(find("/views/main/order/1")?.suggestions, ["agenda"])
        // The legacy adapter adds info notes; nothing is an error.
        XCTAssertTrue(found.filter { $0.severity != .info }.allSatisfy { $0.severity == .warning }, "a v0.3 config has no errors")
        XCTAssertEqual(found.filter { $0.severity == .info }.map(\.code), ["legacy"])

        let json = find("/views/main/order/1")!.json.objectValue!
        XCTAssertEqual(json["suggestion"], .string("agenda"))
        XCTAssertEqual(json["suggestions"], .array([.string("agenda")]))
        XCTAssertEqual(json["severity"], .string("warning"))
        XCTAssertEqual(json["layer"], .string("user"))
        XCTAssertEqual(json["line"], .int(7))
    }

    // MARK: The command

    func testHumanOutputKeepsTheV03LinesAndAddsAHint() throws {
        let (output, path) = try check(["PATH"], "{\n  \"hotkeys\": \"f3\"\n}")
        XCTAssertEqual(output, ConfigCommands.Output(status: 0, stdout: """
            \(path): 1 warning
              hotkeys: unknown key (known: version, hotkey, theme, sources, widgets, views, secrets, defaultView, keys, templates, functions, platform)
                at /hotkeys, line 2, column 3; did you mean "hotkey"?

            """))
    }

    func testJSONOutput() throws {
        let (output, path) = try check(["--json", "PATH"], #"{"hotkeys": "f3", "theme": {"palette": 1}}"#)
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.stderr, "")
        let report = try json(output.stdout)
        XCTAssertEqual(report["file"], .string(path))
        XCTAssertEqual(report["status"], .string("warnings"))
        XCTAssertEqual(report["counts"], .object(["error": .int(0), "warning": .int(2), "info": .int(0)]))
        let diagnostics = try XCTUnwrap(report["diagnostics"]?.arrayValue)
        XCTAssertEqual(diagnostics.first, .object([
            "severity": .string("warning"), "code": .string("unknown-key"), "pointer": .string("/hotkeys"),
            "layer": .string("user"), "message": .string("unknown key (known: version, hotkey, theme, sources, widgets, views, secrets, defaultView, keys, templates, functions, platform)"),
            "suggestion": .string("hotkey"), "suggestions": .array([.string("hotkey")]), "line": .int(1), "column": .int(2),
        ]))
        XCTAssertEqual(diagnostics.last?.objectValue?["expected"], .string("string"))
        XCTAssertEqual(diagnostics.last?.objectValue?["found"], .string("integer"))

        let clean = try json(try check(["--json", "PATH"], #"{"version": 1}"#).0.stdout)
        XCTAssertEqual(clean["status"], .string("ok"))
        XCTAssertEqual(clean["diagnostics"], .array([]))
    }

    func testExitCodes() throws {
        XCTAssertEqual(try check(["PATH"], #"{"extra": 1}"#).0.status, 0, "warnings exit 0, as in v0.3")
        XCTAssertEqual(try check(["--strict", "PATH"], #"{"extra": 1}"#).0.status, 3)
        XCTAssertEqual(try check(["--strict", "PATH"], #"{"version": 1}"#).0.status, 0)

        let syntax = try check(["PATH", "--json"], "{\n  \"a\": 1,\n}")
        XCTAssertEqual(syntax.0.status, 1)
        let report = try json(syntax.0.stdout)
        XCTAssertEqual(report["status"], .string("errors"))
        let diagnostic = try XCTUnwrap(report["diagnostics"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(diagnostic["code"], .string("json-syntax"))
        XCTAssertEqual(diagnostic["severity"], .string("error"))
        XCTAssertEqual(diagnostic["line"], .int(2))

        let missing = try check(["PATH", "--json"], nil)
        XCTAssertEqual(missing.0.status, 1)
        XCTAssertEqual(try json(missing.0.stdout)["diagnostics"]?.arrayValue?.first?.objectValue?["code"], .string("unreadable"))

        let none = try check(["--json"], nil)
        XCTAssertEqual(none.0.status, 0)
        XCTAssertEqual(try json(none.0.stdout)["file"], .null)

        // Usage errors, as JSON with --json.
        XCTAssertEqual(try check(["--bogus", "PATH"], "{}").0.status, 2)
        XCTAssertEqual(try check(["a", "b"], "{}").0.status, 2)
        XCTAssertEqual(try check(["--platform", "windows", "PATH"], "{}").0.status, 2)
        let usage = try check(["--json", "--platfrom", "linux"], "{}").0
        XCTAssertEqual(usage.status, 2)
        XCTAssertEqual(usage.stdout, "")
        XCTAssertEqual(usage.stderr,
                       #"{"error":{"code":"usage","message":"unknown option '--platfrom'; did you mean \"--platform\"?"}}"# + "\n")
    }

    /// `--` ends the options, so a path that looks like one still works.
    func testDoubleDashEndsTheOptions() throws {
        let (output, path) = try check(["--json", "--", "PATH"], #"{"version": 1}"#)
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(try json(output.stdout)["file"], .string(path))
        let missing = try check(["--", "--json"], nil).0
        XCTAssertEqual(missing.status, 1, "--json is a file name here, and it doesn't exist")
        XCTAssertTrue(missing.stdout.hasPrefix("--json: "), missing.stdout)
    }

    /// A hotkey on Linux is reported (info), not ignored.
    func testAHotkeyOnLinuxIsReportedAsInfo() throws {
        let linux = try json(try check(["--json", "--platform", "linux", "PATH"], #"{"hotkey": "f3"}"#).0.stdout)
        XCTAssertEqual(linux["counts"], .object(["error": .int(0), "warning": .int(0), "info": .int(1)]))
        XCTAssertEqual(linux["diagnostics"]?.arrayValue?.first?.objectValue?["code"], .string("unsupported-platform"))
        let macos = try json(try check(["--json", "--platform", "macos", "PATH"], #"{"hotkey": "f3"}"#).0.stdout)
        XCTAssertEqual(macos["diagnostics"], .array([]))
        XCTAssertEqual(ConfigLoader.load(data: Data(#"{"hotkey": "f3"}"#.utf8), platform: .linux).warnings, [],
                       "a note, not a warning")
    }

    func testStdinAndConfigOption() throws {
        XCTAssertEqual(try check(["-"], nil, stdin: #"{"version": 1}"#).0, ConfigCommands.Output(status: 0, stdout: "-: ok\n"))
        XCTAssertEqual(try check(["-"], nil, stdin: "{").0.status, 1)
        let (viaOption, path) = try check(["--config", "PATH"], #"{"version": 1}"#)
        XCTAssertEqual(viaOption, ConfigCommands.Output(status: 0, stdout: "\(path): ok\n"))
        XCTAssertEqual(try check(["--config", "PATH", "PATH"], "{}").0.status, 2)
    }

    func testPlatformOption() throws {
        let text = #"{"platform": {"linux": {"extra": 1}, "macos": {"other": 1}}}"#
        let linux = try check(["--platform", "linux", "PATH"], text).0.stdout
        XCTAssertTrue(linux.contains("\n  extra: unknown key"), linux)
        XCTAssertFalse(linux.contains("other"), linux)
        let macos = try check(["--platform=macos", "PATH"], text).0.stdout
        XCTAssertTrue(macos.contains("\n  other: unknown key"), macos)
        XCTAssertFalse(macos.contains("extra"), macos)
        let all = try check(["--platform", "all", "PATH"], text).0.stdout
        XCTAssertTrue(all.contains(": 2 warnings\n"), all)
    }

    /// The example configs check clean on both OSes.
    func testExamplesHaveNoDiagnostics() throws {
        for platform in ConfigPlatform.allCases {
            let full = ConfigCommands.checkConfig([Fixture.example("full.json").path, "--json", "--strict", "--platform", platform.rawValue])
            XCTAssertEqual(full.status, 0, full.stdout)
            XCTAssertEqual(try json(full.stdout)["status"], .string("ok"))
        }
    }

    // MARK: --commands

    func testCommandsListsEveryArgvWithProvenance() throws {
        let text = """
        {
          "sources": {
            "gh": {"type": "command", "argv": ["no-such-program-xyz", "--token", "{{ $secrets.gh }}"],
                   "env": {"B": "1", "A": "2"}, "refresh": "5m"},
            "weather": null
          },
          "widgets": {
            "systemBar": {"show": ["privacy"], "privacy": {"command": ["sh", "-c", "true"], "stateFile": "/tmp/p"}},
            "systems": {"hosts": [{"source": "local"}, {"name": "web", "url": "https://web.example", "interval": "10s"},
                                  {"name": "nas", "url": "https://nas.example", "source": "gh"}]}
          },
          "platform": {"linux": {"sources": {"lin": {"type": "command", "argv": ["uname"]}}}}
        }
        """
        let (output, _) = try check(["--commands", "--json", "--platform", "macos", "PATH"], text)
        XCTAssertEqual(output.status, 0)
        let commands = try XCTUnwrap(try json(output.stdout)["commands"]?.arrayValue).map { $0.objectValue ?? [:] }
        XCTAssertEqual(commands.map { $0["pointer"] }, [
            .string("/sources/gh/argv"), .string("/widgets/systemBar/privacy/command"), .string("/widgets/systems/hosts/1/url"),
        ])
        XCTAssertEqual(commands[0]["argv"], .array([.string("no-such-program-xyz"), .string("--token"), .string("{{ $secrets.gh }}")]),
                       "text holes are shown as written")
        XCTAssertEqual(commands[0]["env"], .array([.string("A"), .string("B")]))
        XCTAssertEqual(commands[0]["found"], .bool(false))
        XCTAssertEqual(commands[0]["trigger"], .string("source \"gh\", every 5m, shown or hidden"))
        XCTAssertEqual(commands[1]["layer"], .string("user"))
        XCTAssertEqual(commands[2]["argv"], .array([.string("foyer-api"), .string("--host"), .string("https://web.example"), .string("/api/health")]))
        XCTAssertEqual(commands[2]["trigger"], .string("widget \"systems\", host \"web\": every 10s while the dashboard is shown"))

        // Without --platform, the other OS's block is listed too, tagged.
        let all = try check(["--commands", "--json", "--platform", "all", "PATH"], text).0.stdout
        let tagged = try XCTUnwrap(try json(all)["commands"]?.arrayValue).compactMap(\.objectValue).filter { $0["platform"] != nil }
        if ConfigPlatform.current == .macos {
            XCTAssertEqual(tagged.map { $0["pointer"] }, [.string("/platform/linux/sources/lin/argv")])
            XCTAssertEqual(tagged.first?["layer"], .string("platform.linux"))
        } else {
            XCTAssertEqual(tagged, [])
        }

        let human = try check(["--commands", "--platform", "macos", "PATH"], text).0.stdout
        XCTAssertTrue(human.contains("""

            /sources/gh/argv
              trigger: source "gh", every 5m, shown or hidden
              env: A, B
              program: no-such-program-xyz (not found on PATH)
              argv: ["no-such-program-xyz","--token","{{ $secrets.gh }}"]

            """), human)
        XCTAssertEqual(try check(["--commands", "PATH"], #"{"widgets": {"systems": null}}"#).0.stdout.hasSuffix(": runs no commands\n"), true)
    }

    func testARunActionMustBeAnArgvList() {
        let text = """
        {"widgets": {"t": {"type": "text", "text": "x",
          "action": [{"run": "make deploy"}, {"run": []}, {"run": ["make", "deploy"]}]}}}
        """
        let errors = diagnose(text, platform: .linux).filter { $0.severity == .error }
        XCTAssertEqual(errors.map(\.pointer), ["/widgets/t/action/0/run", "/widgets/t/action/1/run"])
        XCTAssertEqual(errors.first?.found, "string")
    }

    func testASourceTemplateWithoutItsRequiredKeyIsFlagged() {
        let text = """
        {"templates": {"api": {"params": {"q": {"type": "string"}}, "source": {"type": "http", "method": "POST"}},
                       "ok": {"params": {"u": {"type": "string"}}, "source": {"type": "http", "url": {"param": "u"}}}},
         "sources": {"x": {"type": "api", "q": "a"}, "y": {"type": "ok", "u": "https://a.example"},
                     "z": {"type": "foyer", "url": "https://nas.example"}}}
        """
        // A warning, like a plain http source without a url.
        let found = diagnose(text, platform: .linux).filter { $0.message.contains("never fetches") }
        XCTAssertEqual(found.map(\.pointer), ["/sources/x"])
        XCTAssertEqual(found.first?.message.hasPrefix("missing \"url\""), true)
    }

    func testCommandsListsV04SecretsActionsAndInlineSources() throws {
        let text = """
        {
          "secrets": {"gh": {"command": ["gh", "auth", "token"]}, "f": {"file": "~/x"}},
          "keys": {"r": {"run": ["make", "deploy"], "env": {"X": "1"}}},
          "sources": {"nas": {"type": "foyer", "url": "https://nas.example"}},
          "widgets": {
            "systems": null,
            "t": {"type": "text", "text": "x", "source": {"type": "command", "argv": ["date"], "refresh": "1m"},
                  "action": [{"run": ["notify-send", "{{ . }}"]}, {"copy": "x"}]}
          },
          "templates": {"ping": {"source": {"type": "command", "argv": ["ping", "-c1", "{{ $host }}"]},
                                 "params": {"host": {"type": "string"}}}}
        }
        """
        let (output, _) = try check(["--commands", "--json", "--platform", "macos", "PATH"], text)
        let commands = try XCTUnwrap(try json(output.stdout)["commands"]?.arrayValue).map { $0.objectValue ?? [:] }
        XCTAssertEqual(commands.map { $0["pointer"] }, [
            .string("/keys/r/run"), .string("/secrets/gh/command"), .string("/sources/nas/type"),
            .string("/templates/ping/source/argv"),
            .string("/widgets/t/action/0/run"), .string("/widgets/t/source/argv"),
        ])
        XCTAssertEqual(commands[0]["env"], .array([.string("X")]))
        XCTAssertEqual(commands[0]["trigger"], .string("an action of key \"r\" (a click or its key)"))
        XCTAssertEqual(commands[1]["trigger"], .string("secret \"gh\", once when the config loads"))
        XCTAssertEqual(commands[2]["argv"], .array([.string("foyer-api"), .string("--host"), .string("https://nas.example"), .string("/api/health")]))
        XCTAssertEqual(commands[2]["trigger"], .string("source \"nas\" (template \"foyer\"), every 5s, while the dashboard is shown"))
        XCTAssertEqual(commands[5]["trigger"], .string("an inline source of widget \"t\", every 1m"))
    }

    // MARK: print-config --origins

    func testOrigins() throws {
        let dir = try makeTemporaryDirectory()
        let path = dir.appendingPathComponent("c.json").path
        FileManager.default.createFile(atPath: path, contents: Data("""
        {"theme": {"background": "blur"}, "views": {"main": {"order": ["clock"]}},
         "platform": {"macos": {"hotkey": "f3"}, "linux": {"hotkey": "home"}}}
        """.utf8))
        let output = ConfigCommands.printConfig([path, "--origins"], environment: [:], home: dir.path)
        XCTAssertEqual(output.status, 0)
        let rows = output.stdout.split(separator: "\n").map { $0.split(separator: " ", omittingEmptySubsequences: true).map(String.init) }
        func row(_ pointer: String) -> [String]? { rows.first { $0.first == pointer } }
        let block = "/platform/\(ConfigPlatform.current.rawValue)/hotkey"
        XCTAssertEqual(row(block), [block, ConfigPlatform.current == .macos ? "\"f3\"" : "\"home\"", "platform.\(ConfigPlatform.current.rawValue)"])
        XCTAssertEqual(row("/theme/background"), ["/theme/background", "\"blur\"", "user"])
        XCTAssertEqual(row("/theme/palette"), ["/theme/palette", "\"tokyo-night\"", "defaults"])
        XCTAssertEqual(row("/views/main/order/0"), ["/views/main/order/0", "\"clock\"", "user"])
        XCTAssertEqual(row("/views/main/layout"), ["/views/main/layout", "\"stack\"", "defaults"])
        XCTAssertNil(row("/views/main/order/1"), "the user's list replaced the default one")
        XCTAssertEqual(ConfigCommands.printConfig([path, "--bogus"]).status, 2)
    }
}
