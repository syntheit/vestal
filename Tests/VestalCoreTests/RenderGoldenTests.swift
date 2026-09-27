import Foundation
import VestalCore
import XCTest

// Golden renders of examples/full.json from Fixtures/full (TASKS-v0.4 4c,
// 5d), `vestal explain`, and the icons the presets use.

final class RenderGoldenTests: XCTestCase {
    static let at = Date(timeIntervalSince1970: 1_790_528_602)  // 2026-09-27T17:03:22Z

    private func fullSession() throws -> (RenderSession, RenderData) {
        let loaded = ConfigLoader.load(path: Fixture.example("full.json").path)
        XCTAssertFalse(loaded.hasErrors)
        let model = RenderConfigModel(loaded: loaded)
        let session = RenderSession(model: model)
        session.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Argentina/Buenos_Aires"))
        session.locale = Locale(identifier: "en_US")
        let cache = try makeTemporaryDirectory()
        let data = RenderSources.load(
            model: model, view: session.view, mode: .fixtures(Fixture.url("full").path), platform: SourcePlatform(),
            cache: SnapshotCache(directory: cache.path), allowCommands: false, allowNetwork: false, timeout: 1, now: Self.at)
        return (session, data)
    }

    private func golden(_ name: String) throws -> String {
        String(decoding: try Fixture.data("render/\(name)"), as: UTF8.self)
    }

    /// The clock's texts come from ICU (`fmt_localized`), whose patterns can
    /// differ between Foundation builds; everything else must match exactly.
    private func assertMatches(_ actual: String, _ expected: String, _ name: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        if actual == expected { return }
        func masked(_ text: String) -> String {
            text.replacingOccurrences(of: "02:03:22", with: "<time>")
                .replacingOccurrences(of: "Sunday, September 27, 2026", with: "<date>")
        }
        let clock = try? NSRegularExpression(pattern: #""(0?2:03:22|14:03:22)""#)
        let normalize: (String) -> String = { text in
            let m = masked(text)
            return clock?.stringByReplacingMatches(in: m, range: NSRange(m.startIndex..., in: m), withTemplate: "\"<time>\"") ?? m
        }
        XCTAssertEqual(normalize(actual), normalize(expected), "\(name) differs", file: file, line: line)
    }

    func testFullJSONGolden() throws {
        let (session, data) = try fullSession()
        let snapshot = session.render(data: data, now: Self.at)
        XCTAssertEqual(snapshot.diagnostics, [])
        XCTAssertEqual(snapshot.root.duplicateIds, [])
        assertMatches(RenderCommands.jsonText(snapshot) + "\n", try golden("full.golden.json"), "full.golden.json")
        assertMatches(RenderText.tree(snapshot), try golden("full.golden.txt"), "full.golden.txt")
        // The v0.3 widgets are all there, in `order`.
        XCTAssertEqual(snapshot.root.children.map(\.id),
                       ["main/clock", "main/systemBar", "main/spotify", "main/agenda", "main/systems", "main/exchange", "main/weather"])
        // And the render model round-trips.
        let decoded = try RenderJSON.decoder.decode(RenderSnapshot.self, from: Data(RenderCommands.jsonText(snapshot).utf8))
        XCTAssertEqual(decoded, snapshot)
    }

    func testHostPopupGolden() throws {
        let (session, data) = try fullSession()
        _ = session.render(data: data, now: Self.at)
        XCTAssertEqual(session.widgetKeys["h"], "main/systems/1/@harbor")
        XCTAssertEqual(session.widgetKeys["p"], "main/systemBar/2")
        XCTAssertEqual(session.key("h", data: data, now: Self.at), [.changed])
        let snapshot = session.render(data: data, now: Self.at)
        XCTAssertEqual(snapshot.diagnostics, [])
        XCTAssertEqual(snapshot.popup?.width, 520)
        assertMatches(RenderCommands.jsonText(snapshot) + "\n", try golden("full-popup.golden.json"), "full-popup.golden.json")
    }

    func testEveryIconInTheGoldensExists() throws {
        for name in IconMap.presetIcons {
            XCTAssertTrue(IconMap.contains(name), name)
        }
        for file in ["full.golden.json", "full-popup.golden.json"] {
            guard case .success(let json) = AnyJSON.parse(try Fixture.data("render/\(file)")) else { return XCTFail(file) }
            var names: Set<String> = []
            func walk(_ value: AnyJSON) {
                switch value {
                case .object(let members):
                    if members["type"] == .string("icon"), let name = members["name"]?.stringValue {
                        names.insert(name)
                        XCTAssertNotNil(members["glyph"], name)
                    }
                    members.values.forEach(walk)
                case .array(let items):
                    items.forEach(walk)
                default:
                    break
                }
            }
            walk(json)
            XCTAssertFalse(names.isEmpty)
            for name in names { XCTAssertTrue(IconMap.contains(name), "\(file): \(name)") }
        }
    }

    // MARK: vestal explain

    private func explain(_ arguments: [String], config: String) throws -> [String: AnyJSON] {
        let dir = try makeTemporaryDirectory()
        let path = dir.appendingPathComponent("config.json")
        try Data(config.utf8).write(to: path)
        let out = RenderCommands.explain(arguments + ["--config", path.path, "--json", "--data", dir.path],
                                         environment: [:], home: dir.path, platform: SourcePlatform(),
                                         client: { _, _ in throw IPCError.notRunning(path: "/nowhere") },
                                         cache: SnapshotCache(directory: dir.appendingPathComponent("cache").path))
        XCTAssertEqual(out.status, 0, out.stderr)
        guard case .success(let json) = AnyJSON.parse(Data(out.stdout.utf8)), let object = json.objectValue else {
            XCTFail("not JSON: \(out.stdout)")
            return [:]
        }
        return object
    }

    func testExplainAHiddenWidget() throws {
        let report = try explain(["gone"], config: """
            { "widgets": { "gone": { "type": "text", "text": "x", "vars": { "n": "2 + 2" }, "when": "$n > 10" } },
              "views": { "main": { "children": ["gone"] } } }
            """)
        XCTAssertEqual(report["id"], .string("main/gone"))
        XCTAssertEqual(report["shown"], .bool(false))
        let trace = report["trace"]?.objectValue ?? [:]
        XCTAssertEqual(trace["vars"], .object(["n": .int(4)]))
        XCTAssertEqual(trace["when"], .bool(false))
        XCTAssertEqual(trace["stoppedAt"], .string("when is false"))
        XCTAssertNil(report["resolved"])
        XCTAssertEqual(report["written"]?.objectValue?["when"], .string("$n > 10"))
    }

    func testExplainAListRow() throws {
        let report = try explain(["main/l/@b"], config: """
            { "widgets": { "l": { "type": "list", "items": [ {"n": "a"}, {"n": "b"} ], "rowId": ".n",
                                  "row": { "type": "text", "text": "{{ .n }}", "action": { "open": "https://x/{{ .n }}" } } } },
              "views": { "main": { "children": ["l"] } } }
            """)
        XCTAssertEqual(report["shown"], .bool(true))
        XCTAssertEqual(report["widget"], .string("l"))
        XCTAssertEqual(report["resolved"]?.objectValue?["text"], .string("b"))
        XCTAssertEqual(report["action"]?.objectValue?["."], .object(["n": .string("b")]))
        XCTAssertEqual(report["dependencies"]?.objectValue?["now"], .bool(false))
    }

    func testExplainUnknownTarget() throws {
        let dir = try makeTemporaryDirectory()
        let out = RenderCommands.explain(["nosuchwidget", "--data", dir.path], environment: [:], home: dir.path, platform: SourcePlatform(),
                                         client: { _, _ in throw IPCError.notRunning(path: "/nowhere") },
                                         cache: SnapshotCache(directory: dir.path))
        XCTAssertEqual(out.status, 4)
    }
}
