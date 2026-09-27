import Foundation
import VestalCore
import XCTest

// Phase 2 (data layer), the agent-facing side: IPC requests with
// arguments, the resident's `sources` and `fetch`, `vestal sources` and
// `vestal fetch` (EXTENSIBILITY.md 11.4), and check-config for the new keys.

final class IPCFetchRequestTests: XCTestCase {
    private func parsed(_ line: String) -> IPCRequest? {
        try? IPCRequest.parse(line).get()
    }

    func testRequestsWithoutArgumentsStayBareWords() {
        XCTAssertEqual(IPCRequest(.status).wireLine, "status")
        XCTAssertEqual(IPCRequest(.sources).wireLine, "sources")
        XCTAssertEqual(parsed("toggle\n"), IPCRequest(.toggle))
        XCTAssertNil(parsed("bogus"))
    }

    func testFetchArgumentsAreJSON() {
        let request = IPCRequest(.fetch, source: "system", raw: true, timeout: 10)
        XCTAssertEqual(request.wireLine, #"{"cmd":"fetch","raw":true,"source":"system","timeout":10}"#)
        XCTAssertEqual(parsed(request.wireLine), request)
        XCTAssertEqual(parsed(#"{"cmd": "fetch", "source": "a", "cached": true, "extra": 1}"#),
                       IPCRequest(.fetch, source: "a", cached: true), "unknown keys are ignored")
        XCTAssertNil(parsed(#"{"cmd": "fetch", "source": 3}"#))
        XCTAssertNil(parsed(#"{"cmd": "fetch", "timeout": "soon"}"#))
        XCTAssertNil(parsed(#"{"cmd": "explode"}"#))
    }


    func testTheServerHandsOverTheArguments() throws {
        let directory = NSTemporaryDirectory() + "vsr-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/s.sock"
        let queue = DispatchQueue(label: "test.handler")
        let server = IPCServer.forRequests(paths: [path], queue: queue) { request, reply in
            reply(IPCResponse(ok: true, data: .string(request.source ?? "none")))
        }
        try server.start()
        addTeardownBlock { server.stop() }
        let fetched = try IPCClient.send(IPCRequest(.fetch, source: "weather"), paths: [path])
        XCTAssertEqual(fetched.data, .string("weather"))
        let bare = try IPCClient.send(.status, path: path)
        XCTAssertEqual(bare.data, .string("none"), "a bare word is a request without arguments")
    }
}

@MainActor
private final class QuietSurface: ResidentSurface {
    func show() {}
    func hide() {}
    func apply(_ loaded: LoadedConfig) {}
    func quit() {}
}

private final class Replies: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [IPCResponse] = []
    var all: [IPCResponse] { lock.lock(); defer { lock.unlock() }; return stored }
    func add(_ response: IPCResponse) { lock.lock(); stored.append(response); lock.unlock() }
}

final class ResidentSourceTests: XCTestCase {
    @MainActor
    func testSourcesAndFetchAgainstTheInstance() async {
        let json = """
        {"sources": {"notes": {"type": "file", "path": "/notes.json", "transform": ".items"}},
         "widgets": {"bar": {"type": "systemBar", "show": ["uptime"]}},
         "views": {"main": {"order": ["bar"]}}}
        """
        let loaded = ConfigLoader.load(data: Data(json.utf8))
        let fetcher = FakeFetcher()
        fetcher.reply("file", .data(#"{"items": [1, 2]}"#))
        let runtime = AppRuntime(config: loaded.config, fetcher: fetcher, cache: nil)
        let surface = QuietSurface()
        let resident = Resident(loaded: loaded, runtime: runtime, surface: surface)
        let replies = Replies()

        resident.handle(IPCRequest(.sources)) { replies.add($0) }
        let listed = replies.all.last?.sources ?? []
        XCTAssertEqual(listed.first { $0.name == "system" }?.usedBy, ["main/bar"])
        XCTAssertEqual(listed.first { $0.name == "system" }?.status, "idle")
        XCTAssertEqual(listed.first { $0.name == "notes" }?.origin, "config")

        resident.handle(IPCRequest(.fetch, source: "notes")) { replies.add($0) }
        await waitUntil { replies.all.count == 2 }
        XCTAssertEqual(replies.all.last?.data, .array([.int(1), .int(2)]), "after transform")
        resident.handle(IPCRequest(.fetch, source: "notes", raw: true, cached: true)) { replies.add($0) }
        XCTAssertEqual(replies.all.last?.data, .object(["items": .array([.int(1), .int(2)])]), "raw, from the snapshot")
        XCTAssertEqual(fetcher.count("file"), 1)

        resident.handle(IPCRequest(.fetch, source: "note")) { replies.add($0) }
        XCTAssertEqual(replies.all.last?.ok, false)
        XCTAssertEqual(replies.all.last?.code, IPCResponse.notFound)
        XCTAssertEqual(replies.all.last?.error, "no source named \"note\"; did you mean \"notes\"?")
        _ = surface
    }
}

final class SourceCommandsTests: XCTestCase {
    private let notRunning: SourceCommands.Client = { _, _ in throw IPCError.notRunning(path: "/x") }

    private func makeConfig(_ extra: String = "") throws -> (config: String, dir: URL) {
        let dir = try makeTemporaryDirectory()
        try #"{"items": [{"n": 1, "at": "2026-09-26T18:02:11Z"}]}"#
            .write(to: dir.appendingPathComponent("notes.json"), atomically: true, encoding: .utf8)
        let config = dir.appendingPathComponent("config.json")
        try """
        {"sources": {
          "notes": {"type": "file", "path": "\(dir.path)/notes.json"},
          "items": {"type": "file", "path": "\(dir.path)/notes.json", "transform": ".items"},
          "run": {"type": "command", "argv": ["echo", "{\\"ran\\": true}"]}\(extra)
        }}
        """.write(to: config, atomically: true, encoding: .utf8)
        return (config.path, dir)
    }

    func testFetchLocallyWhenNothingRuns() throws {
        let (_, dir) = try makeConfig()
        try """
        {"sources": {"notes": {"type": "file", "path": "\(dir.path)/notes.json"}}}
        """.write(to: dir.appendingPathComponent("vestal.json"), atomically: true, encoding: .utf8)
        let environment = ["VESTAL_CONFIG": dir.appendingPathComponent("vestal.json").path]
        let output = SourceCommands.fetch(["notes"], environment: environment, home: dir.path,
                                          platform: SourcePlatform(), client: notRunning,
                                          cache: SnapshotCache(directory: dir.path + "/cache"))
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertEqual(output.stdout, """
        {
          "items": [
            {
              "at": "2026-09-26T18:02:11Z",
              "n": 1
            }
          ]
        }

        """)
    }

    func testTransformRawShapeAndUnknownNames() throws {
        let (config, dir) = try makeConfig()
        let cache = SnapshotCache(directory: dir.path + "/cache")
        func run(_ arguments: [String]) -> SourceCommands.Output {
            SourceCommands.fetch(arguments + ["--config", config], environment: [:], home: dir.path,
                                 platform: SourcePlatform(), client: notRunning, cache: cache)
        }
        XCTAssertEqual(run(["items"]).stdout.filter { !$0.isWhitespace }, #"[{"at":"2026-09-26T18:02:11Z","n":1}]"#)
        XCTAssertTrue(run(["items", "--raw"]).stdout.contains("\"items\""), "--raw is before transform")
        XCTAssertEqual(run(["items", "--shape"]).stdout, """
        . array[1]
        .[] object
        .[].at string  "2026-09-26T18:02:11Z"   (ISO 8601: use to_epoch)
        .[].n number  1

        """)
        let unknown = run(["note"])
        XCTAssertEqual(unknown.status, 4)
        XCTAssertEqual(unknown.stderr, "vestal: no source named \"note\"; did you mean \"notes\"?\n")
        let json = run(["note", "--json"])
        XCTAssertEqual(json.status, 4)
        XCTAssertTrue(json.stderr.contains(#""suggestion":"notes""#), json.stderr)
        XCTAssertEqual(run([]).status, 2)
        XCTAssertEqual(run(["notes", "--bogus"]).status, 2)
    }

    func testDraftsDontRunCommandsUnlessAllowed() throws {
        let (config, dir) = try makeConfig()
        func run(_ arguments: [String]) -> SourceCommands.Output {
            SourceCommands.fetch(arguments + ["--config", config], environment: [:], home: dir.path,
                                 platform: SourcePlatform(), client: notRunning,
                                 cache: SnapshotCache(directory: dir.path + "/cache"))
        }
        let refused = run(["run"])
        XCTAssertEqual(refused.status, 1)
        XCTAssertEqual(refused.stderr, "vestal: run: not loaded (draft: pass --allow-commands)\n")
        let allowed = run(["run", "--allow-commands"])
        XCTAssertEqual(allowed.status, 0, allowed.stderr)
        XCTAssertEqual(allowed.stdout, "{\n  \"ran\": true\n}\n")
    }

    func testCachedAndTheRunningInstance() throws {
        let (config, dir) = try makeConfig()
        let cache = SnapshotCache(directory: dir.path + "/cache")
        let nothing = SourceCommands.fetch(["notes", "--cached", "--config", config], environment: [:], home: dir.path,
                                           platform: SourcePlatform(), client: notRunning, cache: cache)
        XCTAssertEqual(nothing.status, 1)
        XCTAssertEqual(nothing.stderr, "vestal: notes: nothing cached\n")

        // An instance that loaded this very file answers the fetch itself.
        var sent: [IPCRequest] = []
        let instance: SourceCommands.Client = { request, _ in
            sent.append(request)
            if request.command == .status {
                return .status(IPCStatus(pid: 1, version: "", visible: false, configPath: config))
            }
            return IPCResponse(ok: true, data: .object(["from": .string("instance")]))
        }
        let answered = SourceCommands.fetch(["notes", "--config", config, "--timeout", "3s"], environment: [:],
                                            home: dir.path, platform: SourcePlatform(), client: instance, cache: cache)
        XCTAssertEqual(answered.stdout, "{\n  \"from\": \"instance\"\n}\n")
        XCTAssertEqual(sent.last, IPCRequest(.fetch, source: "notes", timeout: 3))

        // An instance from before v0.4 doesn't know `fetch`: fetched here.
        let old: SourceCommands.Client = { request, _ in
            request.command == .status
                ? .status(IPCStatus(pid: 1, version: "", visible: false, configPath: config))
                : .failure("unknown command '\(request.wireLine)' (expected one of toggle, show, hide, reload, status, quit)")
        }
        let fallback = SourceCommands.fetch(["notes", "--config", config], environment: [:], home: dir.path,
                                            platform: SourcePlatform(), client: old, cache: cache)
        XCTAssertEqual(fallback.status, 0, fallback.stderr)
        XCTAssertTrue(fallback.stdout.contains("\"items\""))
    }

    func testSourcesFromTheCacheWhenNothingRuns() throws {
        let (config, dir) = try makeConfig()
        let cache = SnapshotCache(directory: dir.path + "/cache")
        let loaded = ConfigLoader.load(path: config)
        cache.save(SourceSnapshot(data: Data("{}".utf8), fetchedAt: Date(timeIntervalSince1970: 1_790_000_000)),
                   source: try XCTUnwrap(loaded.config.sources["notes"]), as: "notes")
        let output = SourceCommands.sources(["--config", config], environment: [:], home: dir.path,
                                            client: notRunning, cache: cache,
                                            now: Date(timeIntervalSince1970: 1_790_000_125))
        XCTAssertEqual(output.status, 0)
        let lines = output.stdout.split(separator: "\n").map(String.init)
        func fields(_ name: String) -> [String] {
            lines.first { $0.hasPrefix(name + " ") }?.split(separator: " ").map(String.init) ?? []
        }
        XCTAssertEqual(fields("NAME"), ["NAME", "TYPE", "REFRESH", "WHEN", "AGE", "STATUS", "USED", "BY"])
        XCTAssertEqual(fields("notes"), ["notes", "file", "30s", "always", "2m", "cache", "-"], output.stdout)
        XCTAssertEqual(fields("system"), ["system", "system", "3s", "visible", "-", "idle",
                                          "main/systemBar,", "main/media,", "main/systems"], output.stdout)
        let json = SourceCommands.sources(["--json", "--config", config], environment: [:], home: dir.path,
                                          client: notRunning, cache: cache)
        guard case .array(let items)? = AnyJSON.decode(Data(json.stdout.utf8)) else { return XCTFail(json.stdout) }
        XCTAssertEqual(items.first { $0.objectValue?["name"] == .string("notes") }?.objectValue?["status"], .string("cache"))
        XCTAssertEqual(SourceCommands.sources(["--bogus"], client: notRunning).status, 2)
    }

    func testShapeGolden() throws {
        let value = try XCTUnwrap(AnyJSON.decode(try Fixture.data("shape/prs.json")))
        let expected = try String(contentsOf: Fixture.url("shape/prs.shape.txt"), encoding: .utf8)
        XCTAssertEqual(SourceShape.text(SourceShape.outline(value)), expected)
        let lines = SourceShape.outline(value)
        let milestone = try XCTUnwrap(lines.first { $0.path == ".[].milestone" })
        XCTAssertEqual(milestone.types, ["null", "string"])
        XCTAssertTrue(milestone.nullable)
        XCTAssertEqual(milestone.count, 2)
        XCTAssertEqual(milestone.sample, .string("v2"))
        let labels = try XCTUnwrap(lines.first { $0.path == ".[].labels" })
        XCTAssertTrue(labels.nullable, "missing from one of the objects")
        XCTAssertFalse(try XCTUnwrap(lines.first { $0.path == ".[].title" }).nullable)
        guard case .array(let json)? = AnyJSON.decode(Data(SourceShape.jsonText(lines).utf8)) else { return XCTFail() }
        XCTAssertEqual(json.first { $0.objectValue?["path"] == .string(".[].title") }, .object([
            "path": .string(".[].title"), "types": .array([.string("string")]), "nullable": .bool(false),
            "count": .int(2), "sample": .string("Fix tray icon on HiDPI"),
        ]))
    }

    func testDidYouMean() {
        XCTAssertEqual(SourceCommands.unknownSourceMessage("wether", among: ["weather", "calendar"]),
                       "no source named \"wether\"; did you mean \"weather\"?")
        XCTAssertEqual(SourceCommands.unknownSourceMessage("cal", among: ["weather", "calendar"]),
                       "no source named \"cal\"; did you mean \"calendar\"?")
        XCTAssertEqual(SourceCommands.unknownSourceMessage("zzz", among: ["weather"]), "no source named \"zzz\"")
    }
}

final class SourceValidationTests: XCTestCase {
    private func warnings(_ json: String) -> [String] {
        ConfigLoader.load(data: Data(json.utf8)).warnings.map(\.description)
    }

    func testV04SourceKeysAreKnown() {
        XCTAssertEqual(warnings("""
        {"sources": {
          "a": {"type": "http", "url": "https://x.example", "method": "POST", "headers": {"X": "1"},
                "body": {"q": 1}, "timeout": "5s", "when": "visible", "transform": ".a", "maxAge": "1h",
                "cache": false, "parse": "feed", "history": {"p": {"value": ".p", "size": 10, "every": "1m"}}},
          "f": {"type": "file", "path": "~/x", "parse": "exists"},
          "s": {"type": "system", "disks": ["/", "/home"], "interfaces": ["en0"]},
          "m": {"type": "media", "player": ["Spotify", "spotifyd"]},
          "c": {"type": "claude"},
          "x": {"type": "codex", "argv": ["~/bin/codex", "app-server"], "refresh": "10m"},
          "k": {"type": "calendar", "ics": ["~/cal"], "calendars": ["Work"]},
          "u": {"type": "http", "url": "https://x.example/?k={{ $secrets.k }}"}
        },
         "secrets": {"k": {"env": "K"}, "f": {"file": "~/t"}, "c": {"command": ["pass", "x"]}}}
        """), [])
    }

    func testMistakesInTheNewKeys() {
        let found = warnings("""
        {"sources": {
          "a": {"type": "http", "url": "https://x.example", "method": "PUT", "when": "sometimes", "maxAge": "soon",
                "history": {"p": {"size": 0}}},
          "f": {"type": "file"},
          "r": {"type": "http", "url": "https://x.example", "parse": "exists"}
        },
         "secrets": {"x": {}, "y": {"env": "A", "file": "b"}}}
        """)
        XCTAssertEqual(found, [
            "secrets.x: needs \"file\", \"env\" or \"command\"",
            "secrets.y: give one of \"file\", \"env\" or \"command\"; \"file\" is used",
            "sources.a.when: unknown value \"sometimes\" (expected always or visible)",
            "sources.a.maxAge: invalid duration \"soon\" (a whole number and s, m, h or d, such as \"30s\"); using no limit",
            "sources.a.history.p: missing \"value\"; history ignored",
            "sources.a.history.p.size: must be 1 to 10000; using 1",
            "sources.a.method: unknown value \"PUT\" (expected GET or POST)",
            "sources.f: missing \"path\"; the source never reads",
            "sources.r.parse: unknown value \"exists\" (expected json, raw, lines or feed)",
        ])
    }

    func testLiteralTokensAreFlagged() {
        let found = warnings("""
        {"sources": {"a": {"type": "http", "url": "https://x.example/?api_key=abcdefghijklmnopqrstuvwxyz",
                           "headers": {"Authorization": "Bearer abcdefghij0123456789ABCDEF"}},
                     "b": {"type": "http", "url": "https://x.example/?key={{ $secrets.k }}",
                           "headers": {"Authorization": "Bearer {{ $secrets.t }}"}},
                     "c": {"type": "command", "argv": ["curl", "-H", "Authorization: Bearer abcdefghij0123456789ABCDEF"],
                           "env": {"AUTH": "token=abcdefghijklmnopqrstuvwxyz", "OK": "{{ $secrets.t }}"}}}}
        """)
        XCTAssertEqual(found.filter { $0.contains("secret-literal") }.count, 4, "\(found)")
        XCTAssertTrue(found.allSatisfy { !$0.hasPrefix("sources.b") }, "\(found)")
    }

    func testInlineWidgetSourcesAreChecked() {
        XCTAssertEqual(warnings("""
        {"widgets": {"agenda": {"type": "agendaList", "source": {"type": "file", "path": "~/events.json"}},
                     "fx": {"type": "keyValueList", "source": {"type": "calendar"}, "items": []}},
         "views": {"main": {"order": ["agenda", "fx"]}}}
        """), ["widgets.fx.source: the inline source is a calendar source; this widget reads JSON"])
    }
}
