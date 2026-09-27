import Foundation
import VestalCore
import XCTest

/// The recipes of AGENTS.md (`vestal docs recipe/<name>`), the showcase
/// configs in examples/showcase/ and every JSON example of the reference
/// docs must be true: they load with no errors and no warnings on both OSes,
/// and render with no diagnostics against fixture data (TASKS-v0.4 9b, 9c).
///
/// Fixture data: Fixtures/full (the built-in sources) overlaid with
/// Fixtures/showcase/<recipe>/. Goldens: Fixtures/showcase/<recipe>.golden.txt,
/// the tree render at `at` in Buenos Aires, en_US. To write them again, run
/// the tests with VESTAL_UPDATE_GOLDENS=1 (on Linux: the goldens are Linux's
/// ICU output, and the clock is masked when comparing).
final class RecipeTests: XCTestCase {
    static let at = Date(timeIntervalSince1970: 1_790_528_602)  // 2026-09-27T17:03:22Z

    /// The ```json blocks of a Markdown text.
    static func jsonBlocks(_ text: String) -> [(line: Int, text: String)] {
        var blocks: [(Int, String)] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            if lines[i] == "```json" || lines[i].trimmingCharacters(in: .whitespaces) == "```json" {
                let indent = lines[i].prefix { $0 == " " }.count
                var body: [String] = []
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces) != "```" {
                    body.append(String(lines[j].dropFirst(min(indent, lines[j].prefix { $0 == " " }.count))))
                    j += 1
                }
                blocks.append((i + 1, body.joined(separator: "\n")))
                i = j
            }
            i += 1
        }
        return blocks
    }

    private func parse(_ text: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) -> AnyJSON? {
        guard case .success(let json) = AnyJSON.parse(Data(text.utf8)) else {
            XCTFail("\(label): not JSON", file: file, line: line)
            return nil
        }
        return json
    }

    private func write(_ json: AnyJSON) throws -> URL {
        let url = try makeTemporaryDirectory().appendingPathComponent("config.json")
        try Data(json.prettyPrinted().utf8).write(to: url)
        return url
    }

    /// check-config --json on both OSes: no errors, no warnings.
    private func assertClean(_ path: URL, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        for platform in ["macos", "linux"] {
            let output = ConfigCommands.checkConfig(["--json", "--platform", platform, path.path])
            XCTAssertEqual(output.status, 0, "\(label) [\(platform)]: \(output.stdout)\(output.stderr)", file: file, line: line)
            guard case .success(let report) = AnyJSON.parse(Data(output.stdout.utf8)),
                  let counts = report.objectValue?["counts"]?.objectValue else {
                XCTFail("\(label) [\(platform)]: \(output.stdout)", file: file, line: line)
                continue
            }
            XCTAssertEqual(counts["error"], .int(0), "\(label) [\(platform)]: \(output.stdout)", file: file, line: line)
            XCTAssertEqual(counts["warning"], .int(0), "\(label) [\(platform)]: \(output.stdout)", file: file, line: line)
        }
    }

    /// Fixtures/full with `overlay`'s files over it, in a new directory.
    private func fixtures(_ overlay: String?) throws -> URL {
        let dir = try makeTemporaryDirectory().appendingPathComponent("data")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var sources = [Fixture.url("full")]
        if let overlay { sources.append(Fixture.url("showcase/\(overlay)")) }
        for source in sources where FileManager.default.fileExists(atPath: source.path) {
            for name in try FileManager.default.contentsOfDirectory(atPath: source.path) where name != "README.md" {
                let target = dir.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: target)
            }
        }
        return dir
    }

    /// The render of `path` on this OS, at `at`, from `data`.
    private func render(_ path: URL, data: URL, view: String? = nil) throws -> RenderSnapshot {
        let loaded = ConfigLoader.load(path: path.path)
        XCTAssertFalse(loaded.hasErrors, "\(path.lastPathComponent): \(loaded.warnings)")
        let model = RenderConfigModel(loaded: loaded)
        let session = RenderSession(model: model, view: view)
        session.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Argentina/Buenos_Aires"))
        session.locale = Locale(identifier: "en_US")
        let cache = try makeTemporaryDirectory()
        let sourceData = RenderSources.load(
            model: model, view: session.view, mode: .fixtures(data.path), platform: SourcePlatform(),
            cache: SnapshotCache(directory: cache.path), allowCommands: false, allowNetwork: false, timeout: 1, now: Self.at)
        return session.render(data: sourceData, now: Self.at)
    }

    /// The default `systems` widget names its local host after this machine:
    /// goldens say `<host>`, and `<w>` for the name column's width, which
    /// follows the longest name.
    static func hostMasked(_ text: String) -> String {
        let host = LocalHost.shortName
        let out = text.replacingOccurrences(of: "@\(host)]", with: "@<host>]")
            .replacingOccurrences(of: "@\(host)/", with: "@<host>/")
            .replacingOccurrences(of: "\"\(host)\"", with: "\"<host>\"")
        guard let width = try? NSRegularExpression(pattern: #"(text "<host>" [^\[\n]*)minWidth=[0-9.]+"#) else { return out }
        return width.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1minWidth=<w>")
    }

    /// The clock's texts come from ICU and differ between Foundation builds.
    static func masked(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "Sunday, September 27, 2026", with: "<date>")
        if let clock = try? NSRegularExpression(pattern: #""(0?2:03:22|14:03:22)""#) {
            out = clock.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "\"<time>\"")
        }
        return out
    }

    // MARK: Recipes

    func testEveryRecipeIsAShowcaseAndTheOtherWayRound() throws {
        let recipes = DocsCommand.recipes
        XCTAssertGreaterThanOrEqual(recipes.count, 10)
        XCTAssertEqual(Set(recipes.map(\.name)).count, recipes.count, "recipe names are unique")
        let showcase = Fixture.repository("examples/showcase")
        let files = try FileManager.default.contentsOfDirectory(atPath: showcase.path).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(Set(files.map { String($0.dropLast(5)) }), Set(recipes.map(\.name)))
        for recipe in recipes {
            let blocks = Self.jsonBlocks(recipe.text)
            XCTAssertEqual(blocks.count, 1, "recipe \(recipe.name) has one complete config")
            guard let block = blocks.first, let config = parse(block.text, recipe.name) else { continue }
            XCTAssertEqual(config.objectValue?["version"], .int(1), recipe.name)
            XCTAssertNotNil(config.objectValue?["views"], "\(recipe.name) shows its widgets")
            let file = try String(contentsOf: showcase.appendingPathComponent("\(recipe.name).json"), encoding: .utf8)
            XCTAssertEqual(parse(file, recipe.name), config, "examples/showcase/\(recipe.name).json differs from its recipe")
            XCTAssertEqual(DocsCommand.run(["recipe/\(recipe.name)"]).stdout, recipe.text)
        }
    }

    func testEveryRecipeChecksCleanAndRendersItsGolden() throws {
        let update = ProcessInfo.processInfo.environment["VESTAL_UPDATE_GOLDENS"] == "1"
        for recipe in DocsCommand.recipes {
            let path = Fixture.repository("examples/showcase/\(recipe.name).json")
            assertClean(path, recipe.name)
            let data = try fixtures(recipe.name)
            let snapshot = try render(path, data: data)
            XCTAssertEqual(snapshot.diagnostics, [], recipe.name)
            XCTAssertEqual(snapshot.root.duplicateIds, [], recipe.name)
            let tree = Self.hostMasked(RenderText.tree(snapshot))
            let golden = Fixture.url("showcase/\(recipe.name).golden.txt")
            if update {
                try Data(tree.utf8).write(to: golden)
                continue
            }
            let expected = try String(contentsOf: golden, encoding: .utf8)
            XCTAssertEqual(Self.masked(tree), Self.masked(expected), "\(recipe.name): the render differs from its golden")

            // The CLI agrees: exit 0, and no diagnostics.
            let output = RenderCommands.render(
                ["--config", path.path, "--data", data.path, "--at", "1790528602", "--strict"],
                platform: SourcePlatform(), client: { _, _ in throw IPCError.notRunning(path: "") },
                cache: SnapshotCache(directory: try makeTemporaryDirectory().path))
            XCTAssertEqual(output.status, 0, "\(recipe.name): \(output.stderr)")
            XCTAssertTrue(output.stdout.hasSuffix("diagnostics: 0\n"), recipe.name)
        }
    }

    func testTheSecondViewAndItsKey() throws {
        let path = Fixture.repository("examples/showcase/focus-view.json")
        let data = try fixtures("focus-view")
        let focus = try render(path, data: data, view: "focus")
        XCTAssertEqual(focus.root.children.map(\.id), ["focus/bigClock", "focus/agenda", "focus/todo"])
        XCTAssertEqual(Set(focus.views.map(\.name)), ["focus", "main"])
        XCTAssertEqual(focus.views.first { $0.name == "focus" }?.key, "2")
        let output = RenderCommands.render(
            ["--config", path.path, "--data", data.path, "--at", "1790528602", "--press", "2"],
            platform: SourcePlatform(), client: { _, _ in throw IPCError.notRunning(path: "") },
            cache: SnapshotCache(directory: try makeTemporaryDirectory().path))
        XCTAssertTrue(output.stdout.hasPrefix("stack v gap=32"), output.stdout)
    }

    // MARK: Reference examples

    /// Every ```json block of AGENTS.md and docs/reference/*.md: a whole
    /// config (it has `version`), a widget (it has `type`: shown alone in
    /// `main`), or a config fragment. All check clean and render with no
    /// diagnostics.
    func testEveryDocumentedExampleChecksClean() throws {
        var documents = ["AGENTS.md"]
        let reference = Fixture.repository("docs/reference")
        documents += try FileManager.default.contentsOfDirectory(atPath: reference.path)
            .filter { $0.hasSuffix(".md") }.sorted().map { "docs/reference/\($0)" }
        let data = try fixtures(nil)
        var count = 0
        for document in documents {
            let text = try String(contentsOf: Fixture.repository(document), encoding: .utf8)
            for block in Self.jsonBlocks(text) {
                let label = "\(document):\(block.line)"
                guard let json = parse(block.text, label), let object = json.objectValue else { continue }
                let config: AnyJSON
                if object["version"] != nil {
                    config = json
                } else if object["type"] != nil {
                    config = .object([
                        "version": .int(1), "widgets": .object(["example": json]),
                        "views": .object(["main": .object(["children": .array([.string("example")])])]),
                    ])
                } else {
                    config = json
                }
                let path = try write(config)
                assertClean(path, label)
                XCTAssertEqual(try render(path, data: data).diagnostics, [], label)
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 40)
    }
}
